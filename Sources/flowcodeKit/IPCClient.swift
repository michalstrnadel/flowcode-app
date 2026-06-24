import Foundation
import Darwin

/// POSIX AF_UNIX stream-socket client for the flowcode <-> Python voice-core link.
///
/// The link carries newline-delimited JSON (NDJSON), one object per line. This client:
///   * connects to a Unix-domain socket using the raw Darwin BSD socket API
///     (Network.framework's AF_UNIX support is unreliable, so we avoid it);
///   * runs the blocking `read()` loop on a detached background task so the actor
///     itself never blocks;
///   * frames inbound bytes by newline and decodes each complete line into a
///     `StatusMessage`, skipping malformed lines;
///   * auto-reconnects with capped exponential backoff (0.25s..5s) whenever a
///     connect attempt fails or the peer closes the connection;
///   * exposes inbound messages and a connection-state signal as `AsyncStream`s.
///
/// Concurrency model: the actor owns all mutable state (the current fd, the active
/// reader generation, the stream continuations). The blocking syscalls themselves
/// run off-actor inside `Task.detached` closures and hop back onto the actor to
/// mutate state, so there are no data races on the fd lifecycle.
public final actor IPCClient {

    // MARK: Backoff bounds

    private static let minBackoff: Double = 0.25   // seconds
    private static let maxBackoff: Double = 5.0    // seconds

    // MARK: Inbound message stream

    /// Newline-framed, tolerantly-decoded inbound messages from the voice core.
    public nonisolated let messages: AsyncStream<StatusMessage>
    private let messagesContinuation: AsyncStream<StatusMessage>.Continuation

    // MARK: Connection-state stream

    /// Emits `true` when a connection becomes established and `false` when it drops.
    /// The store can consume this to reflect `connected` in the UI.
    public nonisolated let connectionState: AsyncStream<Bool>
    private let connectionStateContinuation: AsyncStream<Bool>.Continuation

    // MARK: Mutable actor state

    /// Currently open socket file descriptor, or -1 when not connected.
    private var fd: Int32 = -1

    /// Resolved socket path for the active/most-recent `connect(socketPath:)`.
    private var socketPath: String?

    /// Monotonic generation counter. Each `connect`/`disconnect` bumps this so that
    /// stale background reader/connector tasks know to exit without touching newer state.
    private var generation: UInt64 = 0

    /// Whether we are in the "should keep trying to stay connected" mode.
    private var running: Bool = false

    /// Last published connection flag, to avoid emitting duplicate values.
    private var lastConnectedPublished: Bool = false

    // MARK: Init / deinit

    public init() {
        var msgCont: AsyncStream<StatusMessage>.Continuation!
        self.messages = AsyncStream(StatusMessage.self, bufferingPolicy: .bufferingNewest(1024)) {
            msgCont = $0
        }
        self.messagesContinuation = msgCont

        var connCont: AsyncStream<Bool>.Continuation!
        self.connectionState = AsyncStream(Bool.self, bufferingPolicy: .bufferingNewest(8)) {
            connCont = $0
        }
        self.connectionStateContinuation = connCont
    }

    deinit {
        // Best-effort cleanup; the streams finish so consumers don't hang.
        messagesContinuation.finish()
        connectionStateContinuation.finish()
    }

    // MARK: Public API

    /// Start connecting to `socketPath`, retrying forever with capped backoff until
    /// `disconnect()` is called. Calling this again retargets to a new path and
    /// supersedes any in-flight connection (the generation bump invalidates it).
    public func connect(socketPath: String) {
        self.socketPath = socketPath
        self.running = true
        // Bump generation so any previously-running loop tears itself down.
        generation &+= 1
        let myGen = generation
        publishConnected(false)
        Task { await self.runConnectLoop(generation: myGen) }
    }

    /// Best-effort write of `cmd.jsonLine()`. Errors are ignored (e.g. when not
    /// currently connected). The actual `write()` happens off-actor.
    public func send(_ cmd: ControlCommand) {
        let payload = cmd.jsonLine()
        let currentFD = fd
        guard currentFD >= 0 else { return }
        // Run the blocking write off the actor; failures are swallowed.
        Task.detached {
            IPCClient.writeAll(fd: currentFD, data: payload)
        }
    }

    /// Stop the connect/read loop, close the fd, and report disconnected.
    /// The `messages`/`connectionState` streams remain open for reuse.
    public func disconnect() {
        running = false
        generation &+= 1            // invalidate any running loops
        closeFD()
        publishConnected(false)
    }

    // MARK: Connect + reconnect loop

    /// Runs on the actor. Loops: attempt one connection; if it succeeds, drive a
    /// reader to completion; on any failure or close, back off and retry, until the
    /// generation changes (newer connect/disconnect) or `running` becomes false.
    private func runConnectLoop(generation myGen: UInt64) async {
        var backoff = IPCClient.minBackoff
        while running && myGen == generation {
            guard let path = socketPath else { break }

            // Attempt a connection off-actor (blocking connect()).
            let newFD = await Task.detached { () -> Int32 in
                IPCClient.openAndConnect(path: path)
            }.value

            // We may have been superseded while connecting.
            guard running && myGen == generation else {
                if newFD >= 0 { IPCClient.closeFDValue(newFD) }
                break
            }

            if newFD < 0 {
                // Connect failed: back off, then retry.
                publishConnected(false)
                await IPCClient.sleep(seconds: backoff)
                backoff = min(IPCClient.maxBackoff, backoff * 2)
                continue
            }

            // Connected.
            self.fd = newFD
            publishConnected(true)
            backoff = IPCClient.minBackoff   // reset backoff on a good connection

            // Drive the blocking read loop off-actor. It returns when the peer
            // closes, on a read error, or when its generation is stale.
            await readUntilClosed(fd: newFD, generation: myGen)

            // Reader finished: connection is gone. Clean up and (maybe) retry.
            if self.fd == newFD { closeFD() }
            else { IPCClient.closeFDValue(newFD) }
            publishConnected(false)

            guard running && myGen == generation else { break }
            await IPCClient.sleep(seconds: backoff)
            backoff = min(IPCClient.maxBackoff, backoff * 2)
        }
    }

    /// Off-actor blocking read loop with newline framing. Decoded messages are
    /// yielded to `messages`. Returns when EOF/error/stale-generation is hit.
    private func readUntilClosed(fd: Int32, generation myGen: UInt64) async {
        let cont = self.messagesContinuation
        await Task.detached {
            var buffer = Data()
            var scratch = [UInt8](repeating: 0, count: 65536)

            readLoop: while true {
                let n = scratch.withUnsafeMutableBytes { ptr -> Int in
                    Darwin.read(fd, ptr.baseAddress, ptr.count)
                }
                if n > 0 {
                    buffer.append(contentsOf: scratch[0..<n])
                    // Frame by newline; keep any trailing partial line buffered.
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                        // Drop the line plus the newline byte.
                        buffer.removeSubrange(buffer.startIndex...nl)
                        if let msg = IPCClient.decode(lineData) {
                            cont.yield(msg)
                        }
                    }
                    // Guard against an unbounded buffer if a peer never sends a
                    // newline; very long unframed input is dropped.
                    if buffer.count > (8 * 1024 * 1024) {
                        buffer.removeAll(keepingCapacity: false)
                    }
                } else if n == 0 {
                    // Peer closed the connection.
                    break readLoop
                } else {
                    // n < 0: error. Retry on EINTR, otherwise bail out.
                    if errno == EINTR { continue }
                    break readLoop
                }
            }
        }.value
        _ = myGen   // generation is enforced by the actor-side loop after we return
    }

    // MARK: Connection-state publishing (actor-isolated)

    private func publishConnected(_ value: Bool) {
        guard value != lastConnectedPublished else { return }
        lastConnectedPublished = value
        connectionStateContinuation.yield(value)
    }

    private func closeFD() {
        if fd >= 0 {
            IPCClient.closeFDValue(fd)
            fd = -1
        }
    }

    // MARK: Static blocking helpers (run off-actor)

    /// Open a SOCK_STREAM AF_UNIX socket and connect to `path`.
    /// Returns the connected fd, or -1 on any failure.
    private static func openAndConnect(path: String) -> Int32 {
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy the path into sun_path, ensuring NUL-termination and bounds safety.
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)   // typically 104
        if pathBytes.count >= capacity {
            // Path too long for sockaddr_un.
            Darwin.close(s)
            return -1
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPtr in
            sunPtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in pathBytes.enumerated() {
                    dst[i] = CChar(bitPattern: b)
                }
                dst[pathBytes.count] = 0
            }
        }

        // sun_len + family + path (BSD-style explicit length).
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { aptr -> Int32 in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                Darwin.connect(s, saptr, len)
            }
        }
        if rc != 0 {
            Darwin.close(s)
            return -1
        }
        return s
    }

    /// Write all of `data` to `fd`, retrying short writes and EINTR.
    /// Returns silently on error; the caller treats this as best-effort.
    private static func writeAll(fd: Int32, data: Data) {
        guard fd >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let n = Darwin.write(fd, base + offset, total - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    // Broken pipe or other error: give up (best-effort send).
                    break
                }
            }
        }
    }

    private static func closeFDValue(_ fd: Int32) {
        if fd >= 0 { Darwin.close(fd) }
    }

    /// Tolerant decode of a single NDJSON line into a `StatusMessage`.
    /// Returns nil for empty or malformed lines (caller skips them).
    private static func decode(_ line: Data) -> StatusMessage? {
        // Ignore blank lines / stray carriage returns.
        let trimmed = line.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(StatusMessage.self, from: Data(trimmed))
    }

    /// Cancellation-aware sleep that never throws (treats cancellation as "wake now").
    private static func sleep(seconds: Double) async {
        let nanos = UInt64((seconds * 1_000_000_000).rounded())
        try? await Task.sleep(nanoseconds: nanos)
    }
}
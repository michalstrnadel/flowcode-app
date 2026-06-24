//
//  flowcode-selftest — runnable verification of the flowcodeKit IPC layer.
//
//  XCTest is unavailable under the Command Line Tools (it ships with Xcode), so the
//  Phase 1 verification lives in this small executable. It checks (1) the NDJSON wire
//  contract decode/encode against the exact bytes the Python status_broadcaster uses,
//  and (2) a live AF_UNIX loopback: server -> IPCClient -> VoiceSessionStore mapping,
//  plus the app -> server control (send) path. Exits non-zero on any failure.
//
//  Run: swift run flowcode-selftest
//

import Foundation
import Darwin
import Metal
import simd
import flowcodeKit

// MARK: - tiny check harness

final class Checks: @unchecked Sendable {
    var failures = 0
    func check(_ cond: Bool, _ msg: String) {
        if cond { print("  ok  \(msg)") } else { failures += 1; print("  FAIL \(msg)") }
    }
}
let checks = Checks()

// MARK: - minimal AF_UNIX test server

final class UnixSocketTestServer: @unchecked Sendable {
    let path: String
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "selftest.unixserver")
    private let accepted = DispatchSemaphore(value: 0)

    init(path: String) { self.path = path }

    func start() -> Bool {
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = Array(path.utf8CString)
        guard cpath.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            cpath.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bindRes == 0, listen(listenFD, 1) == 0 else { return false }
        acceptQueue.async { [self] in
            let c = accept(listenFD, nil, nil)
            if c >= 0 {
                var tv = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            }
            clientFD = c
            accepted.signal()
        }
        return true
    }

    func waitForClient(timeout: Double) -> Bool {
        accepted.wait(timeout: .now() + timeout) == .success && clientFD >= 0
    }

    func send(_ jsonObject: String) {
        let bytes = Array((jsonObject + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(clientFD, $0.baseAddress, $0.count) }
    }

    func recv() -> String {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(clientFD, &buf, buf.count)
        guard n > 0 else { return "" }
        return String(decoding: buf[0..<n], as: UTF8.self)
    }

    func stop() {
        if clientFD >= 0 { close(clientFD) }
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }
}

// MARK: - wire contract checks

func wireChecks() {
    print("== wire contract ==")
    let dec = JSONDecoder()
    do {
        let m = try dec.decode(StatusMessage.self, from: Data(
            #"{"type":"event","event_type":"TTS_PLAYBACK_START","session_id":"s","ts":"t","state":"speaking"}"#.utf8))
        checks.check(m.type == "event" && m.eventType == "TTS_PLAYBACK_START"
                     && m.state == .speaking && m.sessionId == "s", "decode event + state=speaking")

        let amp = try dec.decode(StatusMessage.self, from: Data(#"{"type":"amplitude","rms":0.42}"#.utf8))
        checks.check(amp.type == "amplitude" && amp.rms == 0.42 && amp.state == nil, "decode amplitude frame")

        let weird = try dec.decode(StatusMessage.self, from: Data(#"{"type":"event","state":"teleporting"}"#.utf8))
        checks.check(weird.state == nil, "unknown state -> nil (forward-compatible)")

        let minimal = try dec.decode(StatusMessage.self, from: Data(#"{"type":"event","event_type":"RECORDING_START"}"#.utf8))
        checks.check(minimal.eventType == "RECORDING_START" && minimal.state == nil, "missing optional keys tolerated")
    } catch {
        checks.check(false, "decode threw: \(error)")
    }

    func line(_ c: ControlCommand) -> String { String(data: c.jsonLine(), encoding: .utf8) ?? "" }
    checks.check(line(.start) == "{\"cmd\":\"start\"}\n", "encode start")
    checks.check(line(.stop) == "{\"cmd\":\"stop\"}\n", "encode stop")
    checks.check(line(.setFlag(key: "VOICEMODE_BARGEIN_ENABLED", value: "true"))
                 == "{\"cmd\":\"set_flag\",\"key\":\"VOICEMODE_BARGEIN_ENABLED\",\"value\":\"true\"}\n", "encode set_flag")
    checks.check(line(.confirm(id: "abc", verdict: "allow"))
                 == "{\"cmd\":\"confirm\",\"id\":\"abc\",\"verdict\":\"allow\"}\n", "encode confirm")
}

// MARK: - live IPC loopback

@MainActor
func loopbackChecks() async {
    print("== ipc loopback ==")
    let sock = "/tmp/fc-selftest-\(getpid()).sock"
    let server = UnixSocketTestServer(path: sock)
    guard server.start() else { checks.check(false, "test server failed to start"); return }
    defer { server.stop() }

    let client = IPCClient()
    let store = VoiceSessionStore()
    store.bind(to: client)
    await client.connect(socketPath: sock)

    guard server.waitForClient(timeout: 3.0) else {
        checks.check(false, "IPCClient never connected"); return
    }
    checks.check(true, "IPCClient connected to socket")

    // python -> app: open a session, then speak.
    server.send(#"{"type":"event","event_type":"SESSION_START","state":"idle"}"#)
    server.send(#"{"type":"event","event_type":"TTS_PLAYBACK_START","state":"speaking"}"#)

    var mapped = false
    for _ in 0..<80 {
        try? await Task.sleep(nanoseconds: 50_000_000)   // yields so MainActor consumer runs
        if store.state == .speaking && store.sessionActive && store.connected { mapped = true; break }
    }
    checks.check(mapped, "store mapped -> speaking + sessionActive + connected")

    // app -> python: control send path writes the exact wire bytes.
    await client.send(.start)
    var got = ""
    for _ in 0..<3 where !got.contains("{\"cmd\":\"start\"}") { got += server.recv() }
    checks.check(got.contains("{\"cmd\":\"start\"}"), "server received start cmd over socket")
}

// MARK: - jarvis orb (phase 2) checks

@MainActor
func metalChecks() async {
    print("== jarvis orb (phase 2) ==")
    checks.check(MemoryLayout<OrbUniforms>.stride == 48, "OrbUniforms stride == 48 (matches MSL 3x float4)")
    checks.check(orbParams(for: .idle).motion != orbParams(for: .speaking).motion,
                 "orbParams distinct per state (idle vs speaking)")
    if let device = MTLCreateSystemDefaultDevice() {
        do {
            _ = try OrbMetalView.makePipeline(device: device)
            checks.check(true, "orb shader compiles + pipeline builds at runtime (no offline metal compiler)")
        } catch {
            checks.check(false, "orb pipeline build failed: \(error)")
        }
    } else {
        print("  skip: no Metal device available (headless)")
    }
}

// MARK: - entry

wireChecks()
await loopbackChecks()
await metalChecks()
print(checks.failures == 0 ? "\nALL PASS" : "\n\(checks.failures) FAILURE(S)")
exit(checks.failures == 0 ? 0 : 1)

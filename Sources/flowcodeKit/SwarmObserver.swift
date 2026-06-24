//
//  SwarmObserver.swift
//  flowcodeKit — Phase 8 (orchestration / swarm visualization). DEFAULT OFF.
//
//  Watches the Claude Code session files for a single turn and drives a `SwarmState`.
//  This is the ONLY component here that touches disk / the filesystem framework; the
//  decode (`SwarmJSONL`) and model (`SwarmModels`) layers stay pure so they can be tested
//  without it.
//
//  What it watches (plan §5/§8 — file-tail truth is the only authoritative live source):
//    • <session>/subagents/                     — new `agent-<id>.jsonl` files (spawns) and
//                                                  their appended lines (tool_use).
//    • <session>.jsonl  (parent)                — Task `toolUseResult` completions
//                                                  (authoritative tokens/cost/status).
//
//  Mechanism: a single FSEvents stream rooted at the project directory (so it catches both
//  the parent file and the subagents subtree). On each batch we re-scan: for every tracked
//  file we read only the bytes appended since our last offset, split into lines, decode via
//  `SwarmJSONL`, and push events into the `SwarmState` on the main actor.
//
//  Lifecycle: fully inert until `start(...)` is called — which the app only does when swarm
//  mode is ON. `stop()` tears the stream down and is safe to call repeatedly. With swarm
//  mode off, this object is never constructed/started, so upstream behaviour is unchanged.
//
//  Honesty: we do NOT pretend to start/stop/pause workflows or read a mid-run token stream.
//  We only read appended file bytes. A `Stop` collapse is best-effort (session-end summary
//  or an external hook ping forwarded via `pushSyntheticStop()`).
//

import Foundation
import CoreServices

@MainActor
public final class SwarmObserver {

    // MARK: Dependencies

    private let state: SwarmState

    // MARK: Paths

    /// Absolute path to the parent `<session>.jsonl`.
    private let parentSessionPath: String
    /// Absolute path to the `<session>/subagents/` directory.
    private let subagentsDir: String
    /// FSEvents watch root (the project directory containing both of the above).
    private let watchRoot: String

    // MARK: FSEvents

    private var stream: FSEventStreamRef?
    private var started = false

    // MARK: Tail bookkeeping

    /// Byte offset already consumed per file path. New bytes are read from here on each scan.
    private var offsets: [String: UInt64] = [:]
    /// Carry-over partial line per file (a line split across two appends).
    private var partials: [String: String] = [:]

    // MARK: Init

    /// Construct an observer for one Claude session.
    ///
    /// - Parameters:
    ///   - state: the model to drive.
    ///   - encodedProjectDir: `~/.claude/projects/<encoded-project>` (the FSEvents watch root).
    ///   - sessionId: the session UUID. The parent file is `<root>/<sessionId>.jsonl` and the
    ///     subagents dir is `<root>/<sessionId>/subagents/`.
    public init(state: SwarmState, encodedProjectDir: String, sessionId: String) {
        self.state = state
        let root = (encodedProjectDir as NSString).expandingTildeInPath
        self.watchRoot = root
        self.parentSessionPath = (root as NSString).appendingPathComponent("\(sessionId).jsonl")
        let sessionDir = (root as NSString).appendingPathComponent(sessionId)
        self.subagentsDir = (sessionDir as NSString).appendingPathComponent("subagents")
    }

    // MARK: Lifecycle

    /// Begin watching. Performs one initial scan (to pick up files that already exist) and
    /// then arms the FSEvents stream. No-op if already started.
    public func start() {
        guard !started else { return }
        started = true

        // Initial catch-up pass so an already-running turn is reflected immediately.
        scan()

        // One stream rooted at the project dir catches the parent file and the whole
        // subagents subtree with a single watcher.
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let observer = Unmanaged<SwarmObserver>.fromOpaque(info).takeUnretainedValue()
            // FSEvents delivers on the run loop we scheduled (main), so this hop is cheap
            // and keeps all SwarmState mutation on the main actor.
            MainActor.assumeIsolated { observer.scan() }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &ctx,
            [watchRoot] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,                       // coalescing latency (s) — batches rapid appends
            flags
        ) else {
            NSLog("flowcode: SwarmObserver failed to create FSEventStream for \(watchRoot)")
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        if !FSEventStreamStart(stream) {
            NSLog("flowcode: SwarmObserver failed to start FSEventStream")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Stop watching and release the stream. Safe to call multiple times. Does NOT reset the
    /// model (the HUD may still want to render the final collapsed state).
    public func stop() {
        started = false
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Forward an external `Stop` signal (e.g. a hook ping arriving over the control socket)
    /// as a collapse. Decoupled from the file tail because the `Stop` hook is not written
    /// into the session file.
    public func pushSyntheticStop() {
        state.apply(.stop)
    }

    // MARK: Scanning

    /// Re-scan all tracked files, reading only newly-appended bytes and pushing decoded
    /// events into the model. Called on the main actor (initial pass + every FSEvents batch).
    private func scan() {
        // 1) Parent session file: agent completions (authoritative) + session-end summary.
        tail(path: parentSessionPath, origin: .parentSession)

        // 2) Each agent file under subagents/: spawn (first line) + tool_use (appended).
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: subagentsDir) else { return }
        for name in entries where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
            let path = (subagentsDir as NSString).appendingPathComponent(name)
            let agentIdFromFilename = SwarmLineDecoder.agentId(fromFilename: name)
            tail(path: path, origin: .agentFile(agentIdFromFilename: agentIdFromFilename))
        }
    }

    /// Read bytes appended to `path` since the last scan, frame into lines (carrying any
    /// partial trailing line), decode each via `SwarmJSONL`, and apply to the model.
    private func tail(path: String, origin: SwarmLineOrigin) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        let previous = offsets[path] ?? 0
        do {
            try handle.seek(toOffset: previous)
        } catch {
            // File shrank/rotated (e.g. session reset): start over from the top.
            offsets[path] = 0
            partials[path] = nil
            try? handle.seek(toOffset: 0)
        }

        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            // Still record the (unchanged) current offset so we don't re-read on no-op events.
            offsets[path] = (try? handle.offset()) ?? previous
            return
        }
        offsets[path] = (try? handle.offset()) ?? (previous + UInt64(data.count))

        guard let chunk = String(data: data, encoding: .utf8) else { return }
        let buffer = (partials[path] ?? "") + chunk

        // Split on newlines; the final element (no trailing newline) is carried over.
        var lines = buffer.components(separatedBy: "\n")
        let carry = lines.removeLast()
        partials[path] = carry

        for line in lines {
            if let event = SwarmLineDecoder.decode(line, origin: origin) {
                state.apply(event)
            }
        }
    }
}

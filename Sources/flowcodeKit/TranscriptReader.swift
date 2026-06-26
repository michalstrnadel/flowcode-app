//
//  TranscriptReader.swift
//  flowcode — Model B (self-contained voice layer)
//
//  Tails the user's ACTIVE Claude Code session transcript and emits each NEW
//  assistant prose message, so flowcode can read it aloud. Claude Code is not
//  modified — this is a pure read-only observer of the JSONL it already writes.
//
//  Source: ~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl (append-only).
//  The active session is the most-recently-modified .jsonl across all projects.
//  We byte-offset tail the active file; when a different file becomes active
//  (the user switched/started a session) we baseline at its current end so we
//  only ever speak messages that arrive AFTER we start watching — never history.
//
//  Only `type == "assistant"` lines contribute, and only their
//  `message.content[].text` parts (tool_use / thinking / tool_result are skipped).
//

import Foundation

@MainActor
public final class TranscriptReader {

    /// Fired with the raw assistant prose for each new assistant message.
    public var onAssistantText: ((String) -> Void)?

    private let projectRoots: [URL]
    private var timer: Timer?
    // Per-file byte offset + partial-line carryover. Tracking EVERY session file
    // (not just "the most recent") is what makes this robust to multiple concurrent
    // Claude Code sessions: each file advances monotonically from its own baseline,
    // so an mtime flip between sessions can never re-baseline mid-message and drop text.
    private var offsets: [String: UInt64] = [:]
    private var partials: [String: Data] = [:]

    public init(projectRoots: [URL]? = nil) {
        if let projectRoots {
            self.projectRoots = projectRoots
        } else {
            // Claude Code writes session transcripts under <CLAUDE_CONFIG_DIR>/projects.
            // Different setups use different config dirs, so watch all the common ones:
            //   ~/.claude/projects          (default)
            //   ~/.claude-personal/projects (this machine's real sessions)
            //   ~/.claude-work/projects     (symlink → personal here; deduped by realpath)
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.projectRoots = [".claude/projects", ".claude-personal/projects", ".claude-work/projects"]
                .map { home.appendingPathComponent($0, isDirectory: true) }
        }
    }

    public func start() {
        stop()
        // 0.25s: read-aloud starts within a quarter second of Claude finishing a message.
        // The poll is just fstat + tail of appended bytes per file, so CPU cost is negligible.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Polling

    private func poll() {
        let files = allSessionFiles()
        // Speak ONLY from the single active session — the most-recently-modified
        // transcript (the one the user is actually interacting with). We still TAIL
        // every file (advancing its offset) so that when the user switches sessions we
        // don't replay the backlog that accumulated while it was in the background — we
        // just don't read those background lines aloud. This is what stops flowcode from
        // reading EVERY concurrent Claude Code session (including, during development,
        // the session that is building flowcode itself).
        let active = mostRecentlyModified(files)
        for path in files {
            // First time we see a file → baseline at its current end so we never
            // speak pre-existing history (only messages that arrive from now on).
            guard let off = offsets[path] else {
                offsets[path] = fileSize(path)
                partials[path] = Data()
                continue
            }
            tail(path, from: off, speak: path == active)
        }
    }

    /// The most-recently-modified session file = the one the user is actively using.
    private func mostRecentlyModified(_ paths: [String]) -> String? {
        var best: String?
        var bestTime: TimeInterval = -1
        for p in paths {
            let attrs = try? FileManager.default.attributesOfItem(atPath: p)
            let t = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            if t > bestTime { bestTime = t; best = p }
        }
        return best
    }

    private func tail(_ path: String, from off: UInt64, speak: Bool) {
        let size = fileSize(path)
        var offset = off
        if size < offset {                // file truncated / rotated
            offset = 0
            partials[path] = Data()
        }
        guard size > offset, let fh = FileHandle(forReadingAtPath: path) else {
            offsets[path] = offset
            return
        }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: offset)
            let chunk = try fh.readToEnd() ?? Data()
            offsets[path] = size

            var buf = (partials[path] ?? Data()) + chunk
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf = buf.subdata(in: buf.index(after: nl)..<buf.endIndex)
                handleLine(line, speak: speak)
            }
            partials[path] = buf
        } catch {
            offsets[path] = offset        // retry next tick
        }
    }

    private func handleLine(_ data: Data, speak: Bool) {
        // Background session: its offset was already advanced by tail(); we just don't
        // read its lines aloud. Only the active session reaches the emit below.
        guard speak else { return }
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              (message["role"] as? String) == "assistant",
              let content = message["content"] as? [[String: Any]]
        else { return }

        // Skip "action" messages — text that merely narrates a tool call
        // ("Let me update memory:", "I'll fix that…"). Read only Claude's pure-prose
        // replies (messages with no tool_use), i.e. what it actually says to you.
        let hasToolUse = content.contains { ($0["type"] as? String) == "tool_use" }
        if hasToolUse { return }

        var parts: [String] = []
        for item in content where (item["type"] as? String) == "text" {
            if let t = item["text"] as? String, !t.isEmpty { parts.append(t) }
        }
        let text = parts.joined(separator: "\n")
        if !text.isEmpty { onAssistantText?(text) }
    }

    // MARK: - File discovery

    /// All *.jsonl session files across every watched root's <proj>/ subdirs. Each is
    /// tailed independently from its own baseline; idle sessions simply never append.
    /// Deduped by canonical (symlink-resolved) path so a root that symlinks to another
    /// (e.g. ~/.claude-work → ~/.claude-personal) is never read twice.
    private func allSessionFiles() -> [String] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [String] = []
        for root in projectRoots {
            guard let projDirs = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for proj in projDirs {
                guard let files = try? fm.contentsOfDirectory(
                    at: proj, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) else { continue }
                for f in files where f.pathExtension == "jsonl" {
                    let canonical = f.resolvingSymlinksInPath().path
                    if seen.insert(canonical).inserted {
                        result.append(canonical)
                    }
                }
            }
        }
        return result
    }

    private func fileSize(_ path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}

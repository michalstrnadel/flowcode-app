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

    private let projectsDir: URL
    private var timer: Timer?
    // Per-file byte offset + partial-line carryover. Tracking EVERY session file
    // (not just "the most recent") is what makes this robust to multiple concurrent
    // Claude Code sessions: each file advances monotonically from its own baseline,
    // so an mtime flip between sessions can never re-baseline mid-message and drop text.
    private var offsets: [String: UInt64] = [:]
    private var partials: [String: Data] = [:]

    public init(projectsDir: URL? = nil) {
        self.projectsDir = projectsDir
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public func start() {
        stop()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
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
        for path in allSessionFiles() {
            // First time we see a file → baseline at its current end so we never
            // speak pre-existing history (only messages that arrive from now on).
            guard let off = offsets[path] else {
                offsets[path] = fileSize(path)
                partials[path] = Data()
                continue
            }
            tail(path, from: off)
        }
    }

    private func tail(_ path: String, from off: UInt64) {
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
                handleLine(line)
            }
            partials[path] = buf
        } catch {
            offsets[path] = offset        // retry next tick
        }
    }

    private func handleLine(_ data: Data) {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              (message["role"] as? String) == "assistant",
              let content = message["content"] as? [[String: Any]]
        else { return }

        var parts: [String] = []
        for item in content where (item["type"] as? String) == "text" {
            if let t = item["text"] as? String, !t.isEmpty { parts.append(t) }
        }
        let text = parts.joined(separator: "\n")
        if !text.isEmpty { onAssistantText?(text) }
    }

    // MARK: - File discovery

    /// All *.jsonl session files across ~/.claude/projects/<proj>/. Each is tailed
    /// independently from its own baseline; idle sessions simply never append.
    private func allSessionFiles() -> [String] {
        let fm = FileManager.default
        guard let projDirs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [String] = []
        for proj in projDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: proj,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                result.append(f.path)
            }
        }
        return result
    }

    private func fileSize(_ path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}

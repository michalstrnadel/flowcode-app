//
//  AssistantTextSource.swift
//  flowcode — Model B (self-contained voice layer)
//
//  The seam that lets read-aloud come from more than one place. Anything that can
//  surface "a new assistant message arrived, here's its prose" conforms to this and
//  feeds the same `LocalVoiceController.speak()` pipeline:
//
//    TranscriptReader   — tails Claude Code's session JSONL (the original source)
//    ClaudeDesktopSource — scrapes the Claude desktop app's Accessibility tree
//
//  The callback name matches `TranscriptReader.onAssistantText` exactly, so the
//  Claude Code path conforms with a one-line extension and zero behavior change.
//

import Foundation

@MainActor
public protocol AssistantTextSource: AnyObject {
    /// Fired with the raw assistant prose for each new assistant message.
    var onAssistantText: ((String) -> Void)? { get set }
    func start()
    func stop()

    /// Switch a source into live, incremental ("streaming") emission when supported.
    /// When on, a source that observes a reply being typed (the Claude Desktop AX
    /// reader) emits each finished *block* as soon as it's done — speaking as Claude
    /// writes — instead of waiting for the whole message. Sources that read complete
    /// messages (the Claude Code JSONL reader) ignore this. Default: no-op.
    func setStreaming(_ on: Bool)
}

public extension AssistantTextSource {
    /// Default: sources that only ever surface complete messages ignore streaming.
    func setStreaming(_ on: Bool) {}
}

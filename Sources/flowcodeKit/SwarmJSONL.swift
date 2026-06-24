//
//  SwarmJSONL.swift
//  flowcodeKit — Phase 8 (orchestration / swarm visualization). DEFAULT OFF.
//
//  PURE, file-IO-free decoders for the Claude Code session JSONL line shapes that the
//  swarm observer cares about. The single entry point `SwarmLineDecoder.decode(_:)`
//  takes one raw JSONL line (a `String`) plus the *origin* of that line (an agent file,
//  the parent session file, or a hook/synthetic source) and returns a typed
//  `SwarmEvent` — or `nil` if the line is irrelevant or unparsable.
//
//  Everything here is deliberately:
//    • file-IO-free  — the observer reads bytes; this only decodes already-read strings.
//    • tolerant      — unknown fields are ignored, malformed lines yield `nil` (never throw
//                      out of `decode`), and missing optional keys are fine.
//    • pure          — same (line, origin) -> same event; no global/instance state.
//  This is what makes the parsing layer trivially unit-testable from the selftest harness.
//
//  Anchored to REAL on-disk shapes observed in ~/.claude/projects/<proj>/<session>/...:
//
//   1. Agent spawn  (subagents/agent-<id>.jsonl, FIRST line):
//        {"type":"user","isSidechain":true,"agentId":"a46e7b2c04daf30b7",
//         "slug":"...", "sessionId":"...", "message":{...}, ...}
//      -> identity for a node: agentId (required) + slug (label, optional).
//
//   2. Agent tool use (subagents/agent-<id>.jsonl, appended line):
//        {"type":"assistant","agentId":"...","message":{"content":[
//            {"type":"tool_use","name":"Bash", ...}, ...]}, ...}
//      -> a node pulse with the tool name.
//
//   3. Agent done (PARENT <session>.jsonl, the Task tool result):
//        {"type":"user","toolUseResult":{"status":"completed","agentId":"a0d942e24aab08a0a",
//            "agentType":"...","totalTokens":51272,"totalDurationMs":69169,
//            "totalToolUseCount":14,"usage":{...}, ...}}
//      -> authoritative completion: status, tokens, duration (cost only trustworthy here).
//
//   4. Stop (top-level): the Claude `Stop` hook fires when the whole turn ends; it is NOT
//      a line inside the session file, so it is delivered to us as a synthetic line from a
//      hook ping (origin `.hook`). We accept either a `{"hook":"Stop"}` ping or the
//      session-end `system` summary line as a collapse trigger.
//

import Foundation

// MARK: - Line origin

/// Where a JSONL line came from. The same JSON shape means different things depending on
/// the file it was appended to, so the observer must tell the decoder the origin.
public enum SwarmLineOrigin: Sendable, Equatable {
    /// A `subagents/agent-<id>.jsonl` file. `agentIdFromFilename` is parsed from the path
    /// (e.g. "agent-a46e7b2c04daf30b7.jsonl" -> "a46e7b2c04daf30b7") and used as a fallback
    /// when a line omits its own `agentId`.
    case agentFile(agentIdFromFilename: String?)
    /// The parent `<session>.jsonl` file (carries Task `toolUseResult` completions).
    case parentSession
    /// A hook ping or other synthetic source (e.g. a `Stop` notification).
    case hook
}

// MARK: - Typed events

/// The typed result of decoding one JSONL line. `SwarmState` consumes these directly.
public enum SwarmEvent: Sendable, Equatable {
    /// A new subagent appeared (first line of its agent file).
    case agentSpawn(agentId: String, slug: String?)
    /// A subagent invoked a tool (appended assistant line in its agent file).
    case toolUse(agentId: String, tool: String)
    /// A subagent finished, per the authoritative parent `toolUseResult`.
    case agentDone(agentId: String, status: SwarmAgentResultStatus, tokens: Int?, durationMs: Int?, toolUseCount: Int?)
    /// The whole turn ended — collapse the constellation.
    case stop
}

/// Completion status as reported by the parent `toolUseResult.status` string.
/// Observed value on disk: "completed". Anything non-success-looking maps to `.failed`
/// so a node can desaturate; unknown-but-not-error strings default to `.completed`.
public enum SwarmAgentResultStatus: String, Sendable, Equatable {
    case completed
    case failed

    /// Tolerant mapping from the raw `status` string. Treats the known success token as
    /// completed; the common error/abort tokens as failed; everything else as completed
    /// (a result line at all implies the agent returned).
    static func from(raw: String?) -> SwarmAgentResultStatus {
        guard let raw = raw?.lowercased() else { return .completed }
        switch raw {
        case "completed", "success", "ok", "done":
            return .completed
        case "failed", "error", "errored", "cancelled", "canceled", "aborted", "interrupted", "timeout", "timed_out":
            return .failed
        default:
            return .completed
        }
    }
}

// MARK: - Decoder

/// Pure, tolerant JSONL line -> `SwarmEvent` decoder. No file IO, no shared state.
public enum SwarmLineDecoder {

    /// Decode one raw JSONL line given its origin. Returns `nil` for irrelevant or
    /// unparsable lines — never throws.
    public static func decode(_ line: String, origin: SwarmLineOrigin) -> SwarmEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any] else {
            return nil
        }

        switch origin {
        case let .agentFile(agentIdFromFilename):
            return decodeAgentLine(obj, fallbackAgentId: agentIdFromFilename)
        case .parentSession:
            return decodeParentLine(obj)
        case .hook:
            return decodeHookLine(obj)
        }
    }

    /// Parse the agent id out of a `subagents/agent-<id>.jsonl` filename or path.
    /// Returns `nil` if the basename doesn't match the expected pattern.
    public static func agentId(fromFilename path: String) -> String? {
        let base = (path as NSString).lastPathComponent
        guard base.hasPrefix("agent-"), base.hasSuffix(".jsonl") else { return nil }
        let start = base.index(base.startIndex, offsetBy: "agent-".count)
        let end = base.index(base.endIndex, offsetBy: -".jsonl".count)
        guard start < end else { return nil }
        let id = String(base[start..<end])
        return id.isEmpty ? nil : id
    }

    // MARK: Agent-file lines

    private static func decodeAgentLine(_ obj: [String: Any], fallbackAgentId: String?) -> SwarmEvent? {
        let agentId = (obj["agentId"] as? String) ?? fallbackAgentId
        guard let agentId, !agentId.isEmpty else { return nil }

        let type = obj["type"] as? String

        // A spawn line is the first user line of an agent file (isSidechain == true).
        // We treat any user-type line that carries a slug, OR the very first sidechain
        // user line, as the spawn marker. The observer only feeds the first line as a
        // candidate spawn, but we stay tolerant here.
        if type == "user" {
            let slug = (obj["slug"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let isSidechain = (obj["isSidechain"] as? Bool) ?? false
            if slug != nil || isSidechain {
                return .agentSpawn(agentId: agentId, slug: slug)
            }
            // A plain user line with no spawn markers isn't interesting.
            return nil
        }

        // An assistant line may contain one or more tool_use blocks; emit the first.
        if type == "assistant", let tool = firstToolUseName(in: obj) {
            return .toolUse(agentId: agentId, tool: tool)
        }

        return nil
    }

    /// Extract the first `tool_use` block's `name` from a message content array.
    private static func firstToolUseName(in obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [Any] else { return nil }
        for block in content {
            guard let b = block as? [String: Any] else { continue }
            if (b["type"] as? String) == "tool_use",
               let name = b["name"] as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    // MARK: Parent-session lines

    private static func decodeParentLine(_ obj: [String: Any]) -> SwarmEvent? {
        // The authoritative completion is the Task `toolUseResult` carrying an agentId.
        guard let tur = obj["toolUseResult"] as? [String: Any],
              let agentId = tur["agentId"] as? String, !agentId.isEmpty else {
            // Not an agent-result line; could still be a session-end system summary.
            return decodeSessionEnd(obj)
        }
        let status = SwarmAgentResultStatus.from(raw: tur["status"] as? String)
        let tokens = intValue(tur["totalTokens"])
        let durationMs = intValue(tur["totalDurationMs"])
        let toolCount = intValue(tur["totalToolUseCount"])
        return .agentDone(
            agentId: agentId,
            status: status,
            tokens: tokens,
            durationMs: durationMs,
            toolUseCount: toolCount
        )
    }

    /// A trailing `system` summary line (subtype indicating the turn finished) is a
    /// best-effort collapse signal when no hook ping arrives.
    private static func decodeSessionEnd(_ obj: [String: Any]) -> SwarmEvent? {
        guard (obj["type"] as? String) == "system" else { return nil }
        let subtype = (obj["subtype"] as? String)?.lowercased() ?? ""
        if subtype.contains("stop") || subtype.contains("end") || subtype.contains("summary") {
            return .stop
        }
        return nil
    }

    // MARK: Hook / synthetic lines

    private static func decodeHookLine(_ obj: [String: Any]) -> SwarmEvent? {
        // Accept either {"hook":"Stop"} or {"hook_event_name":"Stop"} (Claude hook payload),
        // tolerant to casing.
        let hook = (obj["hook"] as? String) ?? (obj["hook_event_name"] as? String) ?? (obj["type"] as? String)
        if let hook, hook.lowercased() == "stop" {
            return .stop
        }
        return nil
    }

    // MARK: Helpers

    /// Tolerant numeric extraction: accepts Int, Double, or numeric String.
    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }
}

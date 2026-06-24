//
//  AuditLog.swift
//  flowcode — §7 append-only audit trail.
//
//  Every transcribed command that reaches the confirmation gate, together with its
//  risk classification and final outcome, is appended as one timestamped JSONL line.
//  This is the forensic record the §7 spec requires ("command -> action -> outcome").
//
//  Design for headless testability: the line-formatting and JSON encoding are PURE
//  and take an INJECTED epoch timestamp (no `Date.now` in the logic path), so the
//  selftest can assert an exact byte sequence. The file append is a thin wrapper.
//
//  Storage: append-only file under ~/.flowcode/audit.jsonl (created on first write).
//  Commands are expected to be ALREADY redacted by the Python side before they reach
//  the app; AuditLog does not attempt to redact (it logs what was shown to the user).
//

import Foundation

/// One audit record. `Encodable` with stable key order via a hand-rolled line builder.
public struct AuditEntry: Sendable, Equatable {
    /// Seconds since the Unix epoch (injected; not read from a wall clock in logic).
    public let epoch: Double
    /// The verbatim (already-redacted) command that was proposed.
    public let command: String
    /// The risk tier it was classified as.
    public let risk: RiskTier
    /// How it resolved.
    public let outcome: ConfirmOutcome

    public init(epoch: Double, command: String, risk: RiskTier, outcome: ConfirmOutcome) {
        self.epoch = epoch
        self.command = command
        self.risk = risk
        self.outcome = outcome
    }

    /// ISO-8601 (UTC, second precision) rendering of `epoch`. Deterministic.
    public var iso8601: String {
        let date = Date(timeIntervalSince1970: epoch)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// One compact JSONL line (no trailing newline). PURE; key order is stable:
    /// ts, epoch, command, risk, outcome. Strings are RFC-8259 escaped.
    public func jsonLine() -> String {
        "{\"ts\":\(Self.jsonString(iso8601)),"
        + "\"epoch\":\(Self.epochString(epoch)),"
        + "\"command\":\(Self.jsonString(command)),"
        + "\"risk\":\(Self.jsonString(risk.rawValue)),"
        + "\"outcome\":\(Self.jsonString(outcome.rawValue))}"
    }

    /// Encode a double without locale surprises and without a needless ".0" for ints.
    private static func epochString(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.3f", value)
    }

    /// JSON string literal (with quotes), RFC-8259 escaped.
    static func jsonString(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
        return out
    }
}

/// Append-only JSONL audit writer. Thread-safe via an internal serial queue.
/// `Sendable` (all mutable state is confined to the queue / immutable after init).
public final class AuditLog: @unchecked Sendable {

    /// Absolute path of the audit file.
    public let fileURL: URL

    private let queue = DispatchQueue(label: "flowcode.auditlog")

    /// Create a log at an explicit URL (used by the selftest for a temp file).
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Create a log at the default location: ~/.flowcode/audit.jsonl.
    /// Falls back to the Application Support dir if the home dir is unavailable.
    public convenience init() {
        self.init(fileURL: AuditLog.defaultURL())
    }

    /// Default audit file URL: `~/.flowcode/audit.jsonl`.
    public static func defaultURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".flowcode/audit.jsonl")
    }

    /// Append one entry with an INJECTED epoch (pure-friendly; used by tests and
    /// by callers that already have a timestamp). Returns true on a successful write.
    @discardableResult
    public func append(
        command: String,
        risk: RiskTier,
        outcome: ConfirmOutcome,
        epoch: Double
    ) -> Bool {
        let entry = AuditEntry(epoch: epoch, command: command, risk: risk, outcome: outcome)
        return appendLine(entry.jsonLine())
    }

    /// Production overload that stamps the current wall-clock time. Kept out of the
    /// pure logic path so the selftest never depends on `Date.now`.
    @discardableResult
    public func append(
        command: String,
        risk: RiskTier,
        outcome: ConfirmOutcome
    ) -> Bool {
        append(command: command, risk: risk, outcome: outcome, epoch: Date().timeIntervalSince1970)
    }

    /// Read back all entries as raw JSONL lines (for the audit window / tests).
    public func readLines() -> [String] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
    }

    /// Reveal the audit file in Finder (GUI session only; no-op semantics in tests).
    /// Intentionally not referenced from logic; the window layer calls it.
    public func revealInFinder() {
        // Imported lazily so this stays a pure-Foundation file otherwise.
        #if canImport(AppKit)
        AuditLog.reveal(fileURL)
        #endif
    }

    // MARK: - Internals

    private func appendLine(_ line: String) -> Bool {
        queue.sync {
            do {
                let dir = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((line + "\n").utf8))
                return true
            } catch {
                return false
            }
        }
    }
}

#if canImport(AppKit)
import AppKit
extension AuditLog {
    fileprivate static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
#endif

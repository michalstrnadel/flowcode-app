//
//  ConfirmationModels.swift
//  flowcode — §7 zero-trust confirmation gate value types.
//
//  Source-of-truth value types for the confirmation flow. Dependency-free
//  (Foundation only) and Sendable so they cross actor boundaries freely.
//
//  Security model: VOICE may only PROPOSE. The Python core emits a
//  `confirm_request` over the NDJSON status socket; the macOS app surfaces it and
//  the user COMMITS with a NON-VOICE gesture (click / hotkey / Touch ID). The
//  verdict travels back as a `ControlCommand.confirm(id:verdict:)`. Timeout = DENY.
//

import Foundation

// MARK: - RiskTier

/// Risk classification mirrored from the Python `classify_risk()`.
/// Higher tiers demand a stronger non-voice gesture (`.elevated` => Touch ID).
/// Unknown strings decode to `.confirm` (conservative: never silently downgrade).
public enum RiskTier: String, Sendable, CaseIterable {
    case none
    case confirm
    case elevated

    /// Tolerant parse: unknown / missing => `.confirm` (fail safe, never `.none`).
    public init(rawTolerant raw: String?) {
        switch raw?.lowercased() {
        case "none":     self = .none
        case "elevated": self = .elevated
        default:         self = .confirm
        }
    }

    /// Whether this tier requires biometric / device-owner authentication to commit.
    public var requiresStrongAuth: Bool { self == .elevated }
}

// MARK: - ConfirmRequest

/// One inbound `confirm_request` line (python -> app):
///
///   {"type":"confirm_request","id":"cg-1","command":"rm -rf build","risk":"elevated"}
///
/// `command` is ALREADY redacted by the Python side. The app displays it verbatim;
/// it must never re-derive or "un-redact" it. Decodes tolerantly so malformed lines
/// don't crash the reader.
public struct ConfirmRequest: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    /// The verbatim, already-redacted command to display. Never mutate before display.
    public let command: String
    public let risk: RiskTier

    private enum CodingKeys: String, CodingKey {
        case id
        case command
        case risk
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A request with no id is unusable (we couldn't route a verdict), so fail it.
        guard let id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil,
              !id.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: c, debugDescription: "confirm_request missing id")
        }
        self.id = id
        self.command = ((try? c.decodeIfPresent(String.self, forKey: .command)) ?? nil) ?? ""
        let rawRisk = (try? c.decodeIfPresent(String.self, forKey: .risk)) ?? nil
        self.risk = RiskTier(rawTolerant: rawRisk)
    }

    /// Memberwise init for tests / synthetic requests.
    public init(id: String, command: String, risk: RiskTier) {
        self.id = id
        self.command = command
        self.risk = risk
    }
}

// MARK: - ConfirmVerdict

/// The two — and only two — outcomes the app may send back. There is no third,
/// "voice said yes" value: the only way to reach `.allow` is a non-voice gesture.
public enum ConfirmVerdict: String, Sendable {
    case allow
    case deny

    /// The wire string the Python control handler matches against. Only the exact
    /// literal `"allow"` is honored by the Python side as an approval.
    public var wireValue: String { rawValue }
}

// MARK: - ConfirmOutcome (audit vocabulary)

/// How a confirmation resolved, for the audit log. The §7 vocabulary, exactly.
public enum ConfirmOutcome: String, Sendable {
    case confirmedClick   = "confirmed-click"
    case confirmedHotkey  = "confirmed-hotkey"
    case authenticated    = "authenticated"
    case denied           = "denied"
    case timedOut         = "timed-out"

    /// Whether this outcome corresponds to an approval (commit) rather than a refusal.
    public var isApproval: Bool {
        switch self {
        case .confirmedClick, .confirmedHotkey, .authenticated: return true
        case .denied, .timedOut: return false
        }
    }

    /// The verdict that must travel back to the core for this outcome.
    public var verdict: ConfirmVerdict { isApproval ? .allow : .deny }
}

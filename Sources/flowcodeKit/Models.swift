//
//  Models.swift
//  flowcode
//
//  Source-of-truth value types shared across the app. Dependency-free (Foundation only).
//  These types define the wire contract with the Python "voice core" over the NDJSON
//  Unix-domain socket. All types are Sendable so they can cross actor boundaries freely.
//

import Foundation

// MARK: - VoiceState

/// The high-level voice-session state reported by the Python side.
/// Decoded from the JSON "state" field. Unknown strings decode to `nil` (handled by
/// `StatusMessage`), so adding new states on the Python side never crashes the app.
public enum VoiceState: String, Sendable {
    case idle
    case listening
    case processing
    case speaking
    case interrupted
}

// MARK: - StatusMessage

/// One inbound NDJSON line (python -> app).
///
/// Decodes tolerantly: every property is optional except `type`, unknown/missing keys
/// never throw, and an unknown "state" string maps to `nil` rather than failing the
/// whole decode. This keeps the app forward-compatible with new Python-side fields.
///
/// Supported shapes:
///   {"type":"event","event_type":"...","session_id":"s","ts":"...","state":"speaking","data":{...}}
///   {"type":"amplitude","rms":0.42}
///   {"type":"barge_in"}
public struct StatusMessage: Decodable, Sendable {
    public let type: String          // "event" | "amplitude" | "barge_in" (other values tolerated)
    public let eventType: String?    // JSON key "event_type"
    public let state: VoiceState?    // decoded from "state"; unknown strings -> nil (never throws)
    public let rms: Double?
    public let sessionId: String?    // JSON key "session_id"
    public let ts: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case eventType = "event_type"
        case state
        case rms
        case sessionId = "session_id"
        case ts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // "type" is the only semi-required field; default to "" if absent so a malformed
        // line still decodes into a (mostly empty) message rather than throwing.
        self.type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? ""

        self.eventType = (try? container.decodeIfPresent(String.self, forKey: .eventType)) ?? nil
        self.rms = (try? container.decodeIfPresent(Double.self, forKey: .rms)) ?? nil
        self.sessionId = (try? container.decodeIfPresent(String.self, forKey: .sessionId)) ?? nil
        self.ts = (try? container.decodeIfPresent(String.self, forKey: .ts)) ?? nil

        // Decode "state" as a raw string first, then map to the enum. An unknown string
        // (or any decode failure) yields nil so the caller leaves the current state unchanged.
        if let rawState = (try? container.decodeIfPresent(String.self, forKey: .state)) ?? nil {
            self.state = VoiceState(rawValue: rawState)
        } else {
            self.state = nil
        }
    }

    /// Designated memberwise initializer (handy for tests / synthetic messages).
    public init(
        type: String,
        eventType: String? = nil,
        state: VoiceState? = nil,
        rms: Double? = nil,
        sessionId: String? = nil,
        ts: String? = nil
    ) {
        self.type = type
        self.eventType = eventType
        self.state = state
        self.rms = rms
        self.sessionId = sessionId
        self.ts = ts
    }
}

// MARK: - ControlCommand

/// One outbound NDJSON line (app -> python). Encodes to the exact inbound JSON the
/// Python core expects, one compact object per line terminated by "\n".
///
///   {"cmd":"start"}
///   {"cmd":"stop"}
///   {"cmd":"set_flag","key":"VOICEMODE_BARGEIN_ENABLED","value":"true"}
///   {"cmd":"confirm","id":"abc","verdict":"allow"}
public enum ControlCommand: Sendable {
    case start
    case stop
    case setFlag(key: String, value: String)
    case confirm(id: String, verdict: String)

    /// Stable key ordering for the encoded JSON. JSONEncoder emits keys in the order
    /// declared here, keeping output deterministic and matching the documented contract.
    private enum CodingKeys: String, CodingKey {
        case cmd
        case key
        case value
        case id
        case verdict
    }

    /// Returns the command as a single compact JSON line plus a trailing newline,
    /// ready to write directly to the socket. Hand-rolled encoding avoids any escaping
    /// surprises and guarantees exact key order without relying on encoder configuration.
    public func jsonLine() -> Data {
        var line: String
        switch self {
        case .start:
            line = "{\"cmd\":\"start\"}"
        case .stop:
            line = "{\"cmd\":\"stop\"}"
        case let .setFlag(key, value):
            line = "{\"cmd\":\"set_flag\",\"key\":\(Self.jsonString(key)),\"value\":\(Self.jsonString(value))}"
        case let .confirm(id, verdict):
            line = "{\"cmd\":\"confirm\",\"id\":\(Self.jsonString(id)),\"verdict\":\(Self.jsonString(verdict))}"
        }
        line.append("\n")
        return Data(line.utf8)
    }

    /// Encodes a Swift string as a JSON string literal (including surrounding quotes),
    /// properly escaping control characters and the JSON metacharacters. We round-trip
    /// through JSONEncoder to get RFC 8259-correct escaping for arbitrary input.
    private static func jsonString(_ value: String) -> String {
        // Encoding a bare String produces a quoted JSON string literal.
        if let data = try? JSONEncoder().encode(value),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        // Fallback: minimal manual escaping should the encoder ever fail (it won't for String).
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        escaped += "\""
        return escaped
    }
}

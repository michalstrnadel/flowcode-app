// VoiceSessionStore.swift
// flowcode — observable store that mirrors the Python voice core's session state.
//
// This is a thin, MainActor-isolated view model. It subscribes to an IPCClient's
// inbound message stream (StatusMessage) and to its connection-state signal, then
// projects them onto a handful of @Observable properties the UI binds to.

import Foundation
import Observation

/// Observable store reflecting the live state of the voice session.
///
/// All mutation happens on the main actor: `bind(to:)` spawns MainActor `Task`s
/// that consume the client's async streams and update the published properties.
@MainActor
@Observable
public final class VoiceSessionStore {

    // MARK: - Published state

    /// Current voice-core state. Defaults to idle until the core reports otherwise.
    public var state: VoiceState = .idle

    /// True while a session is in flight (between SESSION_START and SESSION_END).
    public var sessionActive: Bool = false

    /// Whether the IPC socket to the Python core is currently connected.
    public var connected: Bool = false

    /// Most recent assistant-TTS amplitude (RMS), 0...~1. Phase 4 telemetry.
    public var lastRMS: Double = 0

    /// Monotonic counter bumped on every inbound `barge_in`. The HUD watches it to
    /// flash the interrupted state — independent of the core's (unreliable when
    /// converse runs outside the MCP server) state events.
    public var bargeInTick: Int = 0

    // MARK: - Lifecycle

    public init() {}

    /// Holds the consumer tasks so re-binding cancels the previous subscriptions.
    private var messageTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?

    /// §7 fan-out: when set, every inbound `confirm_request` line is forwarded here
    /// (instead of adding a SECOND consumer to the single-consumer messages stream).
    /// AppDelegate wires this to ConfirmGateController.present(_:). Default nil =>
    /// confirm_request lines are simply ignored (gate-disabled = no behaviour change).
    public var onConfirmRequest: ((StatusMessage) -> Void)?

    // MARK: - Binding

    /// Begin consuming `client`'s message and connection streams on the main actor.
    ///
    /// Mapping rules (per contract):
    ///   - event_type SESSION_START  -> sessionActive = true
    ///   - event_type SESSION_END    -> sessionActive = false, state = .idle
    ///   - any message with non-nil `state` -> self.state = state
    ///   - type == "amplitude"       -> lastRMS = rms (when present)
    ///   - type == "barge_in"        -> tolerated (no state change required)
    ///
    /// Calling `bind(to:)` again cancels any prior subscriptions first.
    public func bind(to client: IPCClient) {
        // Cancel any existing subscriptions so we never double-consume.
        messageTask?.cancel()
        connectionTask?.cancel()

        // Consume inbound status messages and project them onto our state.
        messageTask = Task { [weak self] in
            for await message in client.messages {
                guard let self else { return }
                self.apply(message)
            }
        }

        // Track the connection-state signal so the UI can show online/offline.
        connectionTask = Task { [weak self] in
            for await isConnected in client.connectionState {
                guard let self else { return }
                self.connected = isConnected
                // Losing the core (it crashed, or Claude Code quit) means there is
                // no live session anymore. Clear it so the orb panel hides instead
                // of staying stuck — SESSION_END may never arrive if the core died
                // mid-turn. On reconnect, the broadcaster replays an active
                // SESSION_START (sticky) so a still-running session re-appears.
                if !isConnected {
                    self.sessionActive = false
                    self.state = .idle
                }
            }
        }
    }

    // MARK: - Reducer

    /// Apply a single decoded message to the published state. MainActor-isolated.
    private func apply(_ message: StatusMessage) {
        switch message.type {
        case "amplitude":
            // Assistant TTS level telemetry; ignore if rms is absent.
            if let rms = message.rms {
                lastRMS = rms
            }

        case "barge_in":
            // Out-of-band interrupt notification. Bump the tick so the HUD can flash
            // the interrupted state (the core's INTERRUPTED event isn't broadcast when
            // converse runs outside the MCP server, so this is the reliable signal).
            bargeInTick &+= 1

        case "event":
            // Session lifecycle events arrive via event_type.
            switch message.eventType {
            case "SESSION_START":
                sessionActive = true
            case "SESSION_END":
                sessionActive = false
                state = .idle
                return // SESSION_END forces idle; ignore any piggybacked state below.
            default:
                break
            }

        case "confirm_request":
            // §7: hand off to the confirmation gate (non-voice commit path). We do NOT
            // mutate voice state here. If no handler is wired, the line is ignored.
            onConfirmRequest?(message)
            return

        default:
            // Unknown message types are tolerated; still honor any state field below.
            break
        }

        // Any message may carry an explicit state; when present it wins.
        if let newState = message.state {
            state = newState
        }
    }
}

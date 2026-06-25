//
//  HUDController.swift
//  flowcode — Phase 2 orchestrator for the Jarvis orb HUD.
//
//  Owns the orb renderer, its floating click-through panel, the per-state visual model,
//  the microphone level tap, and earcons. Subscribes to the voice-session store and:
//   - sets the orb's target visual state when the voice state changes,
//   - shows/hides the panel with the session,
//   - plays earcons on transitions,
//   - feeds the orb a fresh OrbUniforms every display tick (time + amplitude + params).
//
//  Amplitude source by state: the user's mic (native tap) while listening; the assistant
//  TTS level (store.lastRMS, pushed from Python) while speaking. Honors Reduce Motion by
//  freezing the shader's animation clock.
//

import AppKit
import Foundation

@MainActor
public final class HUDController {

    private let store: VoiceSessionStore
    private let settings: SettingsStore

    private let orbView: OrbMetalView
    private let panel: HUDPanel
    private let orbState = OrbState()
    private let mic = MicLevelTap()
    private let earcons = Earcons()

    private var lastElapsed: Double = 0
    private var lastSessionActive = false
    private var micRunning = false

    // Live-signal orb inference (the core's per-state events aren't broadcast when
    // converse runs outside the MCP server, so we derive the orb state from the
    // amplitude stream + native mic + barge-in instead of store.state).
    private var lastSpeakTime: Double = -10
    private var lastMicTime: Double = -10
    private var bargeInFlashUntil: Double = 0
    private var lastBargeInTick: Int = 0
    private var lastInferred: VoiceState = .idle

    public init(store: VoiceSessionStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        self.orbView = OrbMetalView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
        self.panel = HUDPanel(contentView: orbView)

        orbView.frameProvider = { [weak self] elapsed in
            self?.makeUniforms(elapsed: elapsed)
                ?? OrbUniforms.makeDefault(time: Float(elapsed), resWidthPx: 220, resHeightPx: 220)
        }
    }

    // MARK: - Lifecycle

    /// Begin: request mic access for listening reactivity, observe the store, sync visibility.
    public func start() {
        Task { [weak self] in
            guard let self else { return }
            if await MicPermission.ensureAccess() {
                self.startMic()
            }
        }
        observeStore()
        syncVisibility()
    }

    public func stop() {
        mic.stop()
        micRunning = false
        panel.hide()
        orbView.isPaused = true
    }

    private func startMic() {
        guard !micRunning else { return }
        do {
            try mic.start()
            micRunning = true
        } catch {
            NSLog("flowcode: mic level tap failed to start: \(error)")
        }
    }

    // MARK: - Per-frame uniforms (called on the main thread by the display link)

    private func makeUniforms(elapsed: Double) -> OrbUniforms {
        let dt = max(0, elapsed - lastElapsed)
        lastElapsed = elapsed
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Drive the orb from LIVE signals rather than store.state: assistant speaking =
        // the TTS amplitude stream (store.lastRMS), user talking = the native mic, cut =
        // the barge-in tick. Each state is held briefly so word-gaps don't flicker it.
        let socketRMS = Float(min(1.0, max(0.0, store.lastRMS)))
        let micLevel: Float = micRunning ? mic.level : 0
        if socketRMS > 0.05 { lastSpeakTime = elapsed }
        if micLevel  > 0.08 { lastMicTime   = elapsed }

        if store.bargeInTick != lastBargeInTick {
            lastBargeInTick = store.bargeInTick
            bargeInFlashUntil = elapsed + 0.9     // flash the cut for ~0.9s
            earcons.play(.interrupted)
        }

        let speaking    = (elapsed - lastSpeakTime) < 0.5
        let listening   = !speaking && (elapsed - lastMicTime) < 0.7
        let interrupted = elapsed < bargeInFlashUntil
        let inferred: VoiceState = interrupted ? .interrupted
            : speaking ? .speaking
            : listening ? .listening : .idle

        if inferred != lastInferred {
            if inferred == .listening { earcons.play(.startListening) }
            orbState.setState(inferred)
            lastInferred = inferred
        }

        let rawAmp: Float = speaking ? socketRMS : (listening ? micLevel : 0)
        orbState.amplitude = rawAmp        // smoothed internally by OrbState
        orbState.step(dt: dt)              // lerp visual params toward target

        let p = orbState.current
        // Freeze the animation clock under Reduce Motion (continuous spin/vortex is what HIG flags);
        // the brief param cross-fade is retained, which is acceptable.
        let timeVal: Float = reduceMotion ? 0 : Float(elapsed)

        return OrbUniforms(
            time: timeVal,
            amplitude: orbState.amplitude,
            intensity: p.intensity,
            motion: p.motion,
            resWidthPx: 220,               // stamped with the true drawable size inside render()
            resHeightPx: 220,
            stateBlend: 0,
            color: p.color
        )
    }

    // MARK: - Store observation

    private func observeStore() {
        withObservationTracking {
            _ = store.state
            _ = store.sessionActive
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handleStoreChange()
                self?.observeStore()   // re-arm for the next change
            }
        }
    }

    private func handleStoreChange() {
        // The orb's visual state + earcons are inferred from live signals in
        // makeUniforms(); here we only react to session lifecycle (show/hide panel).
        if store.sessionActive != lastSessionActive {
            lastSessionActive = store.sessionActive
            syncVisibility()
        }
    }

    private func syncVisibility() {
        if store.sessionActive {
            if !panel.isVisible {
                orbView.isPaused = false
                panel.show(on: NSScreen.main)
            }
        } else {
            if panel.isVisible {
                panel.hide()
                orbView.isPaused = true
            }
        }
    }
}

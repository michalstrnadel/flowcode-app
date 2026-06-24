//
//  MicLevelTap.swift
//  flowcode
//
//  Live microphone level meter for the orb HUD. Wraps an AVAudioEngine and installs a
//  PLAIN tap on the input node (no voice-processing / AEC — exactly ONE AEC owner exists
//  and it is the Python voice core). Each audio buffer's RMS is computed with vDSP_rmsqv,
//  attack/release-smoothed, and published as a 0..1 `level` plus an `onLevel` callback.
//
//  Concurrency model
//  -----------------
//  The AVAudioEngine tap block runs on a real-time audio thread, NOT the main actor.
//  It must therefore never touch @MainActor-isolated state directly. Instead it:
//    1. computes + smooths the level into a tiny lock-protected `nonisolated` box, then
//    2. hops to the MainActor (Task { @MainActor in ... }) to publish `level` and fire
//       `onLevel`.
//  The smoothing state lives in the lock (not on the actor) so consecutive audio buffers
//  smooth against each other deterministically even if MainActor hops coalesce/reorder.
//

import Foundation
import AVFoundation
import Accelerate

/// Smoothed microphone RMS level source for the audio-reactive orb.
///
/// `start()` builds an `AVAudioEngine`, installs a plain tap on the shared input node,
/// and begins publishing a smoothed 0..1 `level`. `stop()` tears everything down.
/// All public API is `@MainActor`; the audio callback marshals back to the MainActor
/// before mutating any observable state.
@MainActor
public final class MicLevelTap {

    // MARK: - Public state (MainActor)

    /// Smoothed RMS level in 0...1, updated from the audio tap on the main actor.
    /// Read this from the display loop / frame provider to drive orb reactivity.
    public private(set) var level: Float = 0

    /// Optional per-buffer callback delivering the freshly smoothed level (0...1).
    /// Invoked on the main actor, once per processed audio buffer while running.
    public var onLevel: ((Float) -> Void)?

    // MARK: - Engine (MainActor)

    /// The capture engine. Created lazily in `start()` and released in `stop()` so a
    /// stopped tap holds no audio resources.
    private var engine: AVAudioEngine?

    /// Tracks whether a tap is currently installed, to make `stop()` idempotent and to
    /// avoid double-installing on the same node.
    private var isRunning = false

    /// Hardware buffer size requested for the tap, in frames. ~1024 frames balances
    /// latency against callback overhead for a UI level meter.
    private static let bufferFrames: AVAudioFrameCount = 1024

    // MARK: - Smoothing state (nonisolated, lock-protected)

    /// Lock-protected smoothing/leveling state shared between the real-time audio thread
    /// (writer) and the MainActor (reader/publisher). Kept off the actor so smoothing is
    /// continuous across buffers regardless of MainActor scheduling.
    private let smoother = LevelSmoother()

    // MARK: - Init

    public init() {}

    // MARK: - Lifecycle

    /// Starts capture: installs a PLAIN tap on the input node and starts the engine.
    ///
    /// PLAIN mode is mandatory — we deliberately do NOT call
    /// `setVoiceProcessingEnabled(_:)` on any node, because the single system AEC owner
    /// is the Python voice core; enabling it here would create a second AEC instance.
    ///
    /// - Throws: any error thrown by `AVAudioEngine.start()` (e.g. no input device,
    ///   permission denied at the HAL level). The tap is removed before rethrowing so
    ///   the instance is left in a clean, stopped state.
    public func start() throws {
        // Idempotent: a second start() while running is a no-op.
        guard !isRunning else { return }

        // Reset smoothing so a fresh session starts from silence.
        smoother.reset()

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // IMPORTANT: do NOT enable voice processing — keep the node in plain mode.
        // (No call to input.setVoiceProcessingEnabled(true).)

        // Use the input node's native output format for the tap. Passing the bus's own
        // format (rather than a custom one) keeps the tap in plain pass-through mode and
        // avoids an implicit format converter.
        let format = input.outputFormat(forBus: 0)

        // The tap block runs on the audio render thread (nonisolated). It must not capture
        // `self`'s actor-isolated members directly; it only touches the Sendable smoother
        // box and then hops to the MainActor to publish.
        let smoother = self.smoother
        input.installTap(onBus: 0, bufferSize: Self.bufferFrames, format: format) { buffer, _ in
            // Compute + smooth on the audio thread; cheap (vDSP) and avoids actor hops for
            // buffers that produce no observable change is unnecessary — we always publish.
            let smoothed = MicLevelTap.process(buffer: buffer, with: smoother)

            // Publish on the MainActor. A detached-style hop keeps the audio thread free.
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.level = smoothed
                self.onLevel?(smoothed)
            }
        }

        // Prepare + start. On failure, remove the tap and rethrow with clean state.
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        self.engine = engine
        self.isRunning = true
    }

    /// Stops capture: removes the tap, stops the engine, and releases it. Idempotent.
    /// Leaves `level` at its last value (callers may zero it via the orb state's decay).
    public func stop() {
        guard isRunning else { return }
        isRunning = false

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    // MARK: - DSP (nonisolated; runs on the audio thread)

    /// Computes the per-buffer RMS via `vDSP_rmsqv`, maps it to a perceptual 0..1 range,
    /// and applies asymmetric attack/release smoothing through the shared `smoother`.
    /// Pure function of the buffer + smoother; safe to call off the main actor.
    ///
    /// - Returns: the newly smoothed level in 0...1.
    nonisolated private static func process(
        buffer: AVAudioPCMBuffer,
        with smoother: LevelSmoother
    ) -> Float {
        // Guard against empty / non-float buffers (the tap should deliver float32, but be safe).
        guard let channels = buffer.floatChannelData else {
            return smoother.advance(towards: 0)
        }
        let frameCount = vDSP_Length(buffer.frameLength)
        guard frameCount > 0 else {
            return smoother.advance(towards: 0)
        }

        // Average RMS across all channels (typically mono input -> 1 channel).
        let channelCount = Int(buffer.format.channelCount)
        var rmsSum: Float = 0
        for ch in 0..<max(channelCount, 1) {
            var rms: Float = 0
            vDSP_rmsqv(channels[ch], 1, &rms, frameCount)
            rmsSum += rms
        }
        let rms = rmsSum / Float(max(channelCount, 1))

        // Map linear RMS to a 0..1 display level. Mic RMS for speech is small (~0.01–0.2),
        // so apply a gain and a gentle compression curve, then clamp. sqrt lifts quiet
        // signals so the orb breathes visibly without saturating on loud speech.
        let gained = min(max(rms * 8.0, 0), 1)
        let target = sqrtf(gained)

        return smoother.advance(towards: target)
    }
}

// MARK: - LevelSmoother

/// Thread-safe asymmetric (attack/release) one-pole smoother.
///
/// Shared between the real-time audio thread and the MainActor. A plain `NSLock` guards
/// the single `Float` of state; contention is negligible (one writer, brief critical
/// section). Marked `@unchecked Sendable` because access is serialized by the lock.
private final class LevelSmoother: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0

    /// Fast rise so onset of speech is responsive; slower fall so the orb doesn't flicker
    /// between words. Coefficients are per-buffer (not per-sample), tuned for ~1024-frame
    /// buffers at typical capture rates.
    private let attack: Float = 0.6   // toward louder
    private let release: Float = 0.15 // toward quieter

    /// One-pole step toward `target`, choosing attack vs. release by direction. Returns
    /// the updated (clamped 0...1) level.
    func advance(towards target: Float) -> Float {
        let t = min(max(target, 0), 1)
        lock.lock()
        defer { lock.unlock() }
        let coeff = t > value ? attack : release
        value += (t - value) * coeff
        // Snap tiny residuals to zero to avoid endless trailing decay.
        if value < 0.0005 { value = 0 }
        return value
    }

    /// Resets the smoother to silence (called on start()).
    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }
}

//
//  OrbState.swift
//  flowcodeKit
//
//  Phase 2 — visual model for the audio-reactive orb HUD.
//
//  This file is pure-ish, dependency-light (Foundation + simd) logic so it is trivially
//  unit-testable without Metal, AppKit, or a display link:
//
//    • `OrbParams`        — the per-state visual parameters (motion / color / intensity).
//    • `orbParams(for:)`  — the VoiceState -> visual mapping (calm cyan -> violet palette).
//    • `OrbState`         — a @MainActor smoother that lerps `current` toward `target`
//                           with frame-rate-independent damping, plus a live `amplitude`.
//
//  Color philosophy: state is encoded primarily by MOTION + SHAPE (handled in the shader,
//  driven by `motion`/`intensity`/`amplitude`), and only secondarily by color. The palette
//  therefore drifts gently from a deep cool cyan (calm) toward a brighter violet (active),
//  staying within one cohesive premium accent rather than switching hues abruptly.
//

import Foundation
import simd

// MARK: - Motion constants

/// Canonical `motion` float values shared with the MSL shader (see contract).
/// Kept as plain `Float` constants (not an enum) because `OrbParams.motion` is a raw
/// `Float` that the shader reads verbatim, and because intermediate lerped values fall
/// *between* these integers during a transition — an enum would be misleading here.
public enum OrbMotion {
    public static let idle: Float = 0
    public static let listening: Float = 1
    public static let processing: Float = 2
    public static let speaking: Float = 3
    public static let interrupted: Float = 4
}

// MARK: - OrbParams

/// Visual parameters describing how the orb should look for a given moment in time.
///
/// All fields are continuous so they can be linearly interpolated between states:
///   - `motion`    : one of the `OrbMotion` values (drives the shader's animation regime).
///   - `color`     : accent RGB in 0...1 (the cool cyan -> violet drift).
///   - `intensity` : overall brightness / glow energy in 0...1.
public struct OrbParams: Sendable, Equatable {
    /// Animation regime selector; one of the `OrbMotion` values (idle=0 … interrupted=4).
    public var motion: Float
    /// Accent color, linear-ish RGB in 0...1. The shader treats this as the glow tint.
    public var color: SIMD3<Float>
    /// Overall brightness / energy of the orb in 0...1.
    public var intensity: Float

    public init(motion: Float, color: SIMD3<Float>, intensity: Float) {
        self.motion = motion
        self.color = color
        self.intensity = intensity
    }
}

// MARK: - Palette

/// Named palette stops for the calm cyan -> violet accent.
/// Authored as gentle, slightly desaturated cool tones so the orb reads as "premium HUD"
/// rather than "neon demo". Values are in 0...1 RGB.
private enum OrbPalette {
    /// Deep, restful cyan — the resting/idle tint.
    static let deepCyan = SIMD3<Float>(0.10, 0.62, 0.78)
    /// Brighter, more present cyan — the orb is attending to the user.
    static let brightCyan = SIMD3<Float>(0.22, 0.78, 0.92)
    /// Cyan drifting toward blue-violet — "thinking".
    static let cyanViolet = SIMD3<Float>(0.34, 0.52, 0.95)
    /// Warmer violet — the orb is speaking back.
    static let violet = SIMD3<Float>(0.56, 0.42, 0.96)
    /// Cooled, dimmed violet for the brief interrupted flash (slightly magenta-leaning so
    /// the break in flow is felt without resorting to an alarming red).
    static let interruptViolet = SIMD3<Float>(0.62, 0.34, 0.86)
}

// MARK: - State -> visual mapping

/// Maps a high-level `VoiceState` to its target `OrbParams`.
///
/// Free function (per the shared contract) so it stays pure and unit-testable:
/// same input -> same output, no actor or instance state involved.
///
///   idle        : deep cyan, low intensity, motion = 0 (slow ambient breathing).
///   listening   : brighter cyan, higher intensity, motion = 1 (reactive to mic level).
///   processing  : cyan->violet, steady mid intensity, motion = 2 (steady churn).
///   speaking    : violet, high intensity, motion = 3 (audio-reactive pulsing).
///   interrupted : cooled violet, momentary brightness, motion = 4 (brief ripple/flash).
public func orbParams(for state: VoiceState) -> OrbParams {
    switch state {
    case .idle:
        return OrbParams(
            motion: OrbMotion.idle,
            color: OrbPalette.deepCyan,
            intensity: 0.32
        )
    case .listening:
        return OrbParams(
            motion: OrbMotion.listening,
            color: OrbPalette.brightCyan,
            intensity: 0.70
        )
    case .processing:
        return OrbParams(
            motion: OrbMotion.processing,
            color: OrbPalette.cyanViolet,
            intensity: 0.60
        )
    case .speaking:
        return OrbParams(
            motion: OrbMotion.speaking,
            color: OrbPalette.violet,
            intensity: 0.85
        )
    case .interrupted:
        return OrbParams(
            motion: OrbMotion.interrupted,
            color: OrbPalette.interruptViolet,
            intensity: 0.78
        )
    }
}

// MARK: - OrbState

/// Smooths the orb's visual parameters toward a target each frame.
///
/// `setState(_:)`/`target` define where we want to be; `step(dt:)` eases `current` toward
/// that target using frame-rate-independent exponential damping. The render layer reads
/// `current` (+ live `amplitude`) every display tick to build its `OrbUniforms`.
///
/// `@MainActor` because it is driven from the main-thread display tick alongside AppKit/Metal,
/// and because `amplitude` is fed from the (main-thread-hopped) mic tap callback.
@MainActor
public final class OrbState {

    // MARK: Tuning

    /// Smoothing time constants (seconds) — the time to close ~63% of the gap.
    /// Color/intensity ease gently for a calm feel; `motion` snaps a bit faster so the
    /// animation regime changes feel responsive rather than mushy. These are fixed
    /// constants (not stored deltas) so the smoothing is purely a function of `dt`.
    private let colorTau: Double = 0.22
    private let intensityTau: Double = 0.18
    private let motionTau: Double = 0.10

    /// Smoothing for the live amplitude follower. A short attack/decay keeps the orb lively
    /// without jitter. Applied in `setAmplitude(_:)`/the `amplitude` setter.
    private let amplitudeTau: Double = 0.06

    // MARK: Stored state

    /// The currently displayed (smoothed) parameters. Updated in `step(dt:)`.
    private var _current: OrbParams

    /// The smoothed live audio level in 0...1. Backing store for `amplitude`.
    private var _amplitude: Float = 0

    /// Wall-clock timestamp of the last `setAmplitude` so the amplitude follower can be
    /// frame-rate independent too. `nil` until the first sample arrives.
    private var lastAmplitudeStamp: CFTimeInterval?

    /// The target parameters `current` eases toward. Settable directly or via `setState(_:)`.
    public var target: OrbParams

    public init() {
        // Start at the idle look so the very first frame is already on-palette
        // (no flash from an uninitialized/zeroed state).
        let idle = orbParams(for: .idle)
        self._current = idle
        self.target = idle
    }

    // MARK: Public surface

    /// The currently displayed, smoothed parameters (read by the render layer).
    public var current: OrbParams { _current }

    /// Live audio level in 0...1 used for reactivity.
    ///
    /// The getter returns the smoothed follower value. The setter feeds a new raw sample
    /// through a frame-rate-independent attack/decay so callers can simply assign the latest
    /// RMS (e.g. `orbState.amplitude = micTap.level`) without managing smoothing themselves.
    public var amplitude: Float {
        get { _amplitude }
        set { setAmplitude(newValue) }
    }

    /// Sets `target` from a `VoiceState` using the shared `orbParams(for:)` mapping.
    public func setState(_ s: VoiceState) {
        target = orbParams(for: s)
    }

    /// Eases `current` toward `target` by an amount appropriate for the elapsed time `dt`.
    ///
    /// Uses exponential smoothing: `factor = 1 - exp(-dt / tau)`. This is frame-rate
    /// independent — the same real-time interval produces the same visual progress whether
    /// it arrives as one big `dt` or many small ones — and is unconditionally stable
    /// (factor stays in 0...1 for any non-negative `dt`).
    public func step(dt: Double) {
        // Guard against non-positive / non-finite dt (e.g. a paused-then-resumed display
        // link delivering a bogus delta): no time elapsed means no change.
        guard dt.isFinite, dt > 0 else { return }

        let colorF = Float(Self.smoothingFactor(dt: dt, tau: colorTau))
        let intensityF = Float(Self.smoothingFactor(dt: dt, tau: intensityTau))
        let motionF = Float(Self.smoothingFactor(dt: dt, tau: motionTau))

        _current.color = mix(_current.color, target.color, t: colorF)
        _current.intensity = simdMix(_current.intensity, target.intensity, t: intensityF)
        _current.motion = simdMix(_current.motion, target.motion, t: motionF)
    }

    // MARK: Amplitude follower

    /// Feeds a new raw level sample through a frame-rate-independent attack/decay follower.
    /// Clamps the input to 0...1 so a noisy tap can't push the orb out of range.
    private func setAmplitude(_ raw: Float) {
        let clamped = raw.isFinite ? simd_clamp(raw, 0, 1) : 0
        let now = CACurrentMediaTimeOrMonotonic()

        guard let last = lastAmplitudeStamp else {
            // First sample: adopt it directly so the orb reacts immediately on startup.
            _amplitude = clamped
            lastAmplitudeStamp = now
            return
        }

        let dt = now - last
        lastAmplitudeStamp = now
        guard dt > 0, dt.isFinite else {
            _amplitude = clamped
            return
        }
        let f = Float(Self.smoothingFactor(dt: dt, tau: amplitudeTau))
        _amplitude = simdMix(_amplitude, clamped, t: f)
    }

    // MARK: Math helpers

    /// Exponential smoothing factor in 0...1 for elapsed `dt` and time constant `tau`.
    /// A larger `dt` (or smaller `tau`) closes more of the gap. Guards a zero/negative
    /// `tau` by snapping fully to the target.
    nonisolated static func smoothingFactor(dt: Double, tau: Double) -> Double {
        guard tau > 0 else { return 1 }
        return 1 - exp(-dt / tau)
    }
}

// MARK: - Free interpolation helpers

/// Component-wise linear interpolation for the accent color.
private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
    a + (b - a) * t
}

/// Scalar linear interpolation (named to avoid colliding with `simd_mix`'s vector overloads).
private func simdMix(_ a: Float, _ b: Float, t: Float) -> Float {
    a + (b - a) * t
}

/// Monotonic "now" in seconds.
///
/// Uses `CACurrentMediaTime()` when QuartzCore is available (it is, on macOS), giving the
/// same clock the display link uses. Falls back through `Foundation` only if needed. Kept
/// here so `OrbState` has no hard QuartzCore import in its public surface and stays easy to
/// reason about in tests.
private func CACurrentMediaTimeOrMonotonic() -> CFTimeInterval {
    // mach_absolute_time-based monotonic clock via Foundation's ProcessInfo, which is
    // import-light and unaffected by wall-clock changes — ideal for measuring intervals.
    ProcessInfo.processInfo.systemUptime
}

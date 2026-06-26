//
//  AppleSpeechEngine.swift
//  flowcode — Model B (Czech read-aloud)
//
//  TTSEngine backed by macOS's built-in AVSpeechSynthesizer. Used for languages
//  Kokoro can't speak — Czech (cs-CZ / "Zuzana"), which ships with macOS, so this
//  is fully offline and needs no install or download.
//
//  AVSpeechSynthesizer owns playback and queues utterances in order, so `speak`
//  just enqueues and returns — ordering is preserved by the synthesizer itself.
//  It exposes no per-frame amplitude, so the orb is driven by a synthetic pulse
//  while speaking (cosmetic only).
//

import AVFoundation
import Foundation

@MainActor
public final class AppleSpeechEngine: NSObject, TTSEngine, AVSpeechSynthesizerDelegate {

    public var onAmplitude: ((Float) -> Void)?
    public var onSpeakingChanged: ((Bool) -> Void)?

    private let synth = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    /// Utterances enqueued but not yet finished/cancelled. Speaking is "on" while > 0.
    private var pending = 0
    private var speaking = false
    private var pulseTimer: Timer?
    private var pulsePhase = 0.0
    private var didLogMissingVoice = false

    /// `localeId` e.g. "cs-CZ". Falls back to the system default voice if the locale
    /// isn't installed (logged once) so we never silently do nothing.
    public init(localeId: String) {
        self.voice = AVSpeechSynthesisVoice(language: localeId)
        super.init()
        synth.delegate = self
        if voice == nil {
            NSLog("flowcode: no AVSpeech voice for \(localeId) — using the system default. Install the voice in System Settings › Accessibility › Spoken Content for best quality.")
        }
    }

    public func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utt = AVSpeechUtterance(string: trimmed)
        if let voice { utt.voice = voice }
        pending += 1
        setSpeaking(true)
        synth.speak(utt)
    }

    public func flush() {
        synth.stopSpeaking(at: .immediate)
        pending = 0
        setSpeaking(false)
    }

    // MARK: - AVSpeechSynthesizerDelegate (nonisolated; hop back to the main actor)

    public nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    public nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    private func utteranceEnded() {
        pending = max(0, pending - 1)
        if pending == 0 { setSpeaking(false) }
    }

    // MARK: - Speaking state + synthetic orb pulse

    private func setSpeaking(_ v: Bool) {
        guard v != speaking else { return }
        speaking = v
        onSpeakingChanged?(v)
        if v { startPulse() } else { stopPulse() }
    }

    private func startPulse() {
        stopPulse()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPulse() }
        }
        RunLoop.main.add(t, forMode: .common)
        pulseTimer = t
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        onAmplitude?(0)
    }

    private func tickPulse() {
        // A gentle 0.35...0.85 wobble so the orb breathes while Zuzana talks. There's
        // no real meter for AVSpeech output, so this is purely visual.
        pulsePhase += 0.30
        let wobble = (sin(pulsePhase) + sin(pulsePhase * 0.5)) * 0.25 + 0.6
        onAmplitude?(Float(min(0.9, max(0.3, wobble))))
    }
}

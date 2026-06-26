//
//  TTSEngine.swift
//  flowcode — Model B (self-contained voice layer)
//
//  A tiny text-to-speech abstraction so read-aloud can use different backends per
//  language WITHOUT touching the rest of the pipeline:
//
//    English → KokoroTTSEngine  (local Kokoro HTTP, the original byte path)
//    Czech   → AppleSpeechEngine (AVSpeechSynthesizer / Zuzana, offline, built-in)
//
//  Each engine OWNS its own playback. Kokoro returns WAV bytes that TtsPlayer plays;
//  Apple's AVSpeechSynthesizer plays audio itself and cannot hand back a WAV buffer
//  without fragile, version-dependent PCM reassembly — so the protocol deliberately
//  models "speak this and drive the orb signals" rather than "give me bytes".
//
//  The two orb signals (onAmplitude, onSpeakingChanged) are the exact callbacks the
//  HUD already observes via VoiceSessionStore, so swapping engines is transparent to
//  the orb. For Kokoro they are the real metered values; for Apple they are a
//  synthetic pulse (true metering of AVSpeech output is deferred).
//

import Foundation

/// A read-aloud backend. `LocalVoiceController` drives one of these per language.
@MainActor
public protocol TTSEngine: AnyObject {
    /// Synthesize + play `text`. May await synthesis (Kokoro) but returns once the
    /// clip is enqueued for playback so the next sentence can start synthesizing.
    func speak(_ text: String) async
    /// Stop immediately and drop anything queued (the "stop speaking" action).
    func flush()
    /// Optional cold-start warm-up (Kokoro pays a connection + model spin-up cost).
    func warmUp()
    /// 0...1 speech amplitude while playing, 0 when idle (drives the orb).
    var onAmplitude: ((Float) -> Void)? { get set }
    /// true when playback starts, false when the queue drains / is flushed.
    var onSpeakingChanged: ((Bool) -> Void)? { get set }
}

public extension TTSEngine {
    func warmUp() {}
}

/// Which backend (and which STT language) a UI language tag maps to.
///   kokoro — English (local Kokoro HTTP, :8880)
///   coqui  — Czech (on-demand neural VITS via local HTTP, :8771)
///   apple  — built-in AVSpeechSynthesizer; kept as a no-download fallback for Czech
public enum TTSEngineKind: Sendable { case kokoro, coqui, apple }

/// Pure mapping from a UI language tag → TTS backend + STT language. Centralizes the
/// "Czech uses Coqui, everything else uses Kokoro" rule so it's testable in isolation.
public enum LanguageProfile {

    /// Backend for the read-aloud voice. Czech → Coqui neural voice (downloaded on
    /// demand; Kokoro has no Czech); everything else → Kokoro.
    public static func ttsEngineKind(for language: String) -> TTSEngineKind {
        normalized(language) == "cs" ? .coqui : .kokoro
    }

    /// AVSpeechSynthesizer locale id for the Apple backend (nil when not Apple-backed).
    public static func appleLocale(for language: String) -> String? {
        normalized(language) == "cs" ? "cs-CZ" : nil
    }

    /// Whisper STT language code. We pass an explicit tag for the languages we ship
    /// (`en`/`cs`); anything unknown falls back to English rather than guessing.
    public static func sttLanguage(for language: String) -> String {
        let n = normalized(language)
        return (n == "cs" || n == "en") ? n : "en"
    }

    /// Lowercase + take the primary subtag ("cs-CZ" → "cs", "EN" → "en").
    private static func normalized(_ language: String) -> String {
        let lower = language.lowercased()
        return lower.split(separator: "-").first.map(String.init) ?? lower
    }
}

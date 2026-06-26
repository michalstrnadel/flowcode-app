//
//  KokoroClient.swift
//  flowcode — Model B (self-contained voice layer)
//
//  Minimal client for the local Kokoro TTS service (OpenAI-compatible HTTP).
//  Synthesizes text to a WAV blob (24 kHz mono int16, RIFF-wrapped) that
//  AVAudioPlayer can play directly. No auth, localhost only.
//

import Foundation

/// Stateless client for Kokoro text-to-speech at `127.0.0.1:8880`.
public struct KokoroClient: Sendable {

    public let endpoint: URL
    public let voice: String

    public init(
        endpoint: URL = URL(string: "http://127.0.0.1:8880/v1/audio/speech")!,
        voice: String = "af_sky"
    ) {
        self.endpoint = endpoint
        self.voice = voice
    }

    /// Synthesize `text` and return WAV bytes. Throws on transport / HTTP error.
    public func synthesize(_ text: String) async throws -> Data {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        let body: [String: Any] = [
            "model": "kokoro",
            "input": text,
            "voice": voice,
            "response_format": "wav",   // RIFF WAV → AVAudioPlayer plays it directly
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "KokoroClient", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Kokoro TTS HTTP \(code)"])
        }
        return data
    }
}

// MARK: - TTSEngine wrapper

/// The Kokoro read-aloud backend behind the `TTSEngine` protocol. This is the
/// ORIGINAL byte path (synthesize WAV → TtsPlayer queue) wrapped unchanged, so the
/// English experience is byte-identical — the abstraction only adds a seam for the
/// Czech engine to slot in beside it.
@MainActor
public final class KokoroTTSEngine: TTSEngine {

    private var client: KokoroClient
    private let player = TtsPlayer()

    public var voice: String { client.voice }

    public var onAmplitude: ((Float) -> Void)? {
        get { player.onAmplitude }
        set { player.onAmplitude = newValue }
    }
    public var onSpeakingChanged: ((Bool) -> Void)? {
        get { player.onSpeakingChanged }
        set { player.onSpeakingChanged = newValue }
    }

    public init(voice: String) {
        self.client = KokoroClient(voice: voice)
    }

    public func speak(_ text: String) async {
        guard let wav = try? await client.synthesize(text) else { return }
        player.enqueue(wav)
    }

    public func flush() { player.flush() }

    public func warmUp() {
        // Discard a tiny clip to pay the connection + model spin-up cost up front.
        let c = client
        Task { _ = try? await c.synthesize(".") }
    }
}

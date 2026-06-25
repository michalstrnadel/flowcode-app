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

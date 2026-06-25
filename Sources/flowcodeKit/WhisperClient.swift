//
//  WhisperClient.swift
//  flowcode — Model B (dictation)
//
//  Minimal client for the local Whisper STT service (OpenAI-compatible,
//  whisper.cpp). POSTs a WAV blob as multipart/form-data and returns the
//  transcribed text. No auth, localhost only.
//

import Foundation

public struct WhisperClient: Sendable {

    public let endpoint: URL
    public let language: String

    public init(
        endpoint: URL = URL(string: "http://127.0.0.1:2022/v1/audio/transcriptions")!,
        language: String = "en"
    ) {
        self.endpoint = endpoint
        self.language = language
    }

    /// Transcribe WAV audio → text. Returns "" if nothing was recognized.
    public func transcribe(wav: Data) async throws -> String {
        let boundary = "flowcode-\(UUID().uuidString)"
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // file part
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        body.appendString("\r\n")
        // model + language fields
        for (name, value) in [("model", "whisper-1"), ("language", language)] {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        body.appendString("--\(boundary)--\r\n")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "WhisperClient", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Whisper STT HTTP \(code)"])
        }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (obj?["text"] as? String) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Data {
    mutating func appendString(_ s: String) {
        if let d = s.data(using: .utf8) { append(d) }
    }
}

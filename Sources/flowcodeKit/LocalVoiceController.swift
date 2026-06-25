//
//  LocalVoiceController.swift
//  flowcode — Model B (self-contained voice layer over Claude Code)
//
//  Wires the read-aloud pipeline with NO socket / no voicemode / no Python core:
//
//    TranscriptReader  →  SpeechText.clean + split  →  KokoroClient.synthesize
//                                                          →  TtsPlayer (queue)
//                                                          →  VoiceSessionStore
//                                                             (drives the orb)
//
//  Claude Code runs completely unmodified; flowcode just watches the transcript
//  it already writes and speaks each new assistant message. The orb reacts
//  because TtsPlayer's amplitude + speaking signals are written to the store the
//  HUD already observes (store.lastRMS + store.sessionActive + store.state).
//

import Foundation

@MainActor
public final class LocalVoiceController {

    private let store: VoiceSessionStore
    private let reader: TranscriptReader
    private let kokoro: KokoroClient
    private let tts = TtsPlayer()
    private let dictation: DictationController

    /// Serializes synthesis so sentences (and successive messages) stay in order:
    /// each new batch awaits the previous one before enqueuing its clips.
    private var synthChain: Task<Void, Never> = Task {}

    public init(store: VoiceSessionStore, voice: String = "af_sky") {
        self.store = store
        self.kokoro = KokoroClient(voice: voice)
        self.reader = TranscriptReader()
        self.dictation = DictationController(store: store)
    }

    public func start() {
        // New assistant message in the live transcript → speak it.
        reader.onAssistantText = { [weak self] text in self?.speak(text) }

        // Push-to-talk dictation. When the user starts talking, stop read-aloud so
        // the mic doesn't capture Claude's own TTS off the speakers.
        dictation.onStartCapture = { [weak self] in self?.flush() }
        dictation.start()

        // TTS amplitude → orb speaking pulse (the HUD reads store.lastRMS).
        tts.onAmplitude = { [weak self] amp in self?.store.lastRMS = Double(amp) }

        // Speaking on/off → show/hide the orb panel + set the coarse state.
        tts.onSpeakingChanged = { [weak self] speaking in
            guard let self else { return }
            self.store.sessionActive = speaking
            self.store.state = speaking ? .speaking : .idle
            if !speaking { self.store.lastRMS = 0 }
        }

        store.connected = true   // Model B has no socket; treat as "live".
        reader.start()
    }

    public func stop() {
        reader.stop()
        dictation.stop()
        tts.flush()
        synthChain.cancel()
    }

    /// Stop speaking and drop anything queued (the "stop speaking" action).
    public func flush() {
        synthChain.cancel()
        synthChain = Task {}
        tts.flush()
    }

    // MARK: - Synthesis pipeline

    private func speak(_ raw: String) {
        let sentences = SpeechText.sentences(from: raw)
        guard !sentences.isEmpty else { return }

        let previous = synthChain
        synthChain = Task { [weak self] in
            _ = await previous.value          // preserve order across messages
            for sentence in sentences {
                if Task.isCancelled { return }
                guard let self else { return }
                guard let wav = try? await self.kokoro.synthesize(sentence) else { continue }
                if Task.isCancelled { return }
                await MainActor.run { self.tts.enqueue(wav) }
            }
        }
    }
}

// MARK: - SpeechText

/// Turns a raw assistant Markdown message into clean, speakable sentences:
/// strips code blocks / markdown noise, caps length, and splits on sentence
/// boundaries so the first sentence can start playing while the rest synthesize.
public enum SpeechText {

    /// Max characters of cleaned prose to speak per message (avoids reading a
    /// giant essay aloud; the on-screen text remains the full record).
    public static let maxChars = 1200

    public static func sentences(from raw: String) -> [String] {
        let cleaned = clean(raw)
        guard !cleaned.isEmpty else { return [] }
        let capped = String(cleaned.prefix(maxChars))
        return splitSentences(capped)
    }

    /// Strip code fences, inline code, markdown markers, URLs, and collapse space.
    public static func clean(_ s: String) -> String {
        var out = s

        out = regexReplace(out, #"```[\s\S]*?```"#, with: " ")        // fenced code blocks
        out = regexReplace(out, "`[^`]*`", with: " ")                  // inline code
        out = regexReplace(out, #"!?\[([^\]]*)\]\([^\)]*\)"#, with: "$1") // [label](url) → label
        out = regexReplace(out, #"https?://\S+"#, with: " ")          // bare URLs
        out = regexReplace(out, #"(?m)^\s{0,3}#{1,6}\s*"#, with: "")  // headings
        out = regexReplace(out, #"(?m)^\s{0,3}>\s?"#, with: "")       // blockquotes
        out = regexReplace(out, #"(?m)^\s*[-*+]\s+"#, with: "")       // bullet markers
        out = regexReplace(out, #"(?m)^\s*\d+\.\s+"#, with: "")       // numbered markers
        out = out.replacingOccurrences(of: "*", with: "")
        out = out.replacingOccurrences(of: "_", with: "")
        out = out.replacingOccurrences(of: "#", with: "")
        out = out.replacingOccurrences(of: "|", with: " ")           // table pipes
        out = regexReplace(out, #"\s+"#, with: " ")                   // collapse whitespace

        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitSentences(_ s: String) -> [String] {
        // Break after . ! ? : ; when followed by space, else keep newlines as breaks.
        let parts = regexSplit(s, #"(?<=[.!?:;])\s+"#)
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    // MARK: regex helpers

    private static func regexReplace(_ s: String, _ pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    private static func regexSplit(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [s] }
        let ns = s as NSString
        var result: [String] = []
        var last = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            result.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        result.append(ns.substring(from: last))
        return result
    }
}

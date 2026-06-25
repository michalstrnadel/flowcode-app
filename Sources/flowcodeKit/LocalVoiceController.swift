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
    private var kokoro: KokoroClient
    private let tts = TtsPlayer()
    private let dictation: DictationController

    /// True while the user has paused the voice layer (see `pause()`).
    public private(set) var isPaused = false

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

        // Warm up Kokoro so the first real sentence doesn't pay the cold-start cost
        // (connection + model spin-up). The clip is discarded — never enqueued.
        let warm = kokoro
        Task { _ = try? await warm.synthesize(".") }

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

    // MARK: - Pause / resume

    /// Pause the whole voice layer: stop speaking + drop the queue, stop tailing the
    /// transcript, and stop dictation — but keep the app running. The orb goes idle.
    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        flush()                 // stop speaking + drop queued clips
        reader.stop()           // stop reading new assistant messages
        dictation.stop()        // stop push-to-talk capture
        store.paused = true
        store.sessionActive = false
        store.state = .idle
        store.lastRMS = 0
    }

    /// Resume after `pause()`. `reader.start()` re-baselines each transcript file at its
    /// current end, so messages that arrived while paused are NOT replayed — only new ones.
    public func resume() {
        guard isPaused else { return }
        isPaused = false
        store.paused = false
        dictation.start()
        reader.start()
    }

    public func togglePause() { isPaused ? resume() : pause() }

    /// Switch the Kokoro voice used for subsequent synthesis (Model B voice picker).
    /// Cheap — `KokoroClient` is a stateless value type. Flushes any in-flight queue so
    /// the change is audible from the next message rather than mid-utterance.
    public func setVoice(_ voice: String) {
        guard voice != kokoro.voice else { return }
        kokoro = KokoroClient(voice: voice)
        flush()
    }

    // MARK: - Synthesis pipeline

    private func speak(_ raw: String) {
        guard !isPaused else { return }
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
        // Cap the raw input BEFORE the O(n) clean so a giant essay never makes the
        // first clip wait on cleaning text we'll discard anyway. Markdown shrinks when
        // cleaned (code fences etc.), so allow generous headroom (4×) before the cap.
        let bounded = String(raw.prefix(maxChars * 4))
        let cleaned = clean(bounded)
        guard !cleaned.isEmpty else { return [] }
        let capped = String(cleaned.prefix(maxChars))
        let sentences = splitSentences(capped)
        // Make the VERY FIRST clip short so audio starts sooner; keep later sentences
        // whole for natural prosody.
        return splitFirstAggressively(sentences)
    }

    /// If the first sentence is long, split it at its earliest clause boundary
    /// (comma / dash / colon / semicolon) so the first synthesized clip is short and
    /// playback starts sooner. Only the first sentence is affected.
    static func splitFirstAggressively(_ sentences: [String]) -> [String] {
        guard let first = sentences.first, first.count > 60 else { return sentences }
        let ns = first as NSString
        guard let re = try? NSRegularExpression(pattern: #"[,—–;:]"#) else { return sentences }
        var cut = -1
        re.enumerateMatches(in: first, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            guard let m else { return }
            if m.range.location >= 20 {            // don't make a tiny stub clip
                cut = m.range.location + 1          // include the punctuation
                stop.pointee = true
            }
        }
        guard cut > 0, cut < ns.length else { return sentences }
        let head = ns.substring(to: cut).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = ns.substring(from: cut).trimmingCharacters(in: .whitespacesAndNewlines)
        var out = sentences
        out[0] = head
        if !rest.isEmpty { out.insert(rest, at: 1) }
        return out.filter { $0.count >= 2 }
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

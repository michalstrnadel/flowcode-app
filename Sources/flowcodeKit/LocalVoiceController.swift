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

import AppKit
import Foundation

@MainActor
public final class LocalVoiceController {

    private let store: VoiceSessionStore
    /// One or more transcript sources feeding the same speak() pipeline (Claude Code's
    /// JSONL reader and/or the Claude Desktop AX reader). See `AssistantTextSource`.
    private var sources: [AssistantTextSource]
    /// The active read-aloud backend (Kokoro for English, Apple for Czech). Swapped live
    /// by `setLanguage` / `setVoice`.
    private var engine: TTSEngine
    private let dictation: DictationController

    // Live, mutable selections (so the menu can change them without a relaunch).
    private var currentVoice: String
    private var currentLanguage: String
    private var listenTarget: ListenTarget
    private var readAloudMode: ReadAloudMode

    /// True while the user has paused the voice layer (see `pause()`).
    public private(set) var isPaused = false

    /// Serializes synthesis so sentences (and successive messages) stay in order:
    /// each new batch awaits the previous one before enqueuing its clips.
    private var synthChain: Task<Void, Never> = Task {}

    public init(store: VoiceSessionStore,
                voice: String = "af_sky",
                language: String = "en",
                listenTarget: ListenTarget = .both,
                readAloudMode: ReadAloudMode = .full) {
        self.store = store
        self.currentVoice = voice
        self.currentLanguage = language
        self.listenTarget = listenTarget
        self.readAloudMode = readAloudMode
        self.engine = LocalVoiceController.makeEngine(language: language, voice: voice)
        self.dictation = DictationController(store: store, language: LanguageProfile.sttLanguage(for: language))
        self.sources = LocalVoiceController.makeSources(for: listenTarget)
    }

    // MARK: - Engine / source factories

    private static func makeEngine(language: String, voice: String) -> TTSEngine {
        switch LanguageProfile.ttsEngineKind(for: language) {
        case .kokoro: return KokoroTTSEngine(voice: voice)
        case .coqui:  return CoquiTTSEngine()   // Czech neural voice (local server :8771)
        case .apple:  return AppleSpeechEngine(localeId: LanguageProfile.appleLocale(for: language) ?? "cs-CZ")
        }
    }

    private static func makeSources(for target: ListenTarget) -> [AssistantTextSource] {
        switch target {
        case .claudeCode:    return [TranscriptReader()]
        case .claudeDesktop: return [ClaudeDesktopSource()]
        case .both:          return [TranscriptReader(), ClaudeDesktopSource()]
        }
    }

    public func start() {
        // Warm up the engine so the first real sentence doesn't pay the cold-start cost.
        engine.warmUp()
        bindEngine()

        // Push-to-talk dictation. When the user starts talking, stop read-aloud so
        // the mic doesn't capture Claude's own TTS off the speakers.
        dictation.onStartCapture = { [weak self] in self?.flush() }
        dictation.start()

        store.connected = true   // Model B has no socket; treat as "live".

        // New assistant message from any source → speak it.
        startSources()
    }

    /// Bind every source's callback to speak() and start it. Re-callable (resume / source swap).
    private func startSources() {
        for s in sources {
            let isDesktop = (s is ClaudeDesktopSource)
            s.onAssistantText = { [weak self] text in
                guard let self else { return }
                // Coordination (Both mode): when a Claude Desktop window is frontmost, the AX
                // source owns read-aloud (it can stream); the Claude Code JSONL reader stays
                // quiet so the SAME reply isn't read twice. When Claude Desktop is NOT frontmost,
                // the JSONL reader handles terminal Claude Code and the desktop source is already
                // inert (it's frontmost-gated). Net: exactly one source speaks any given reply.
                let desktopFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeDesktopSource.bundleID
                if isDesktop ? desktopFront : !desktopFront { self.speak(text) }
            }
        }
        // Full → stream finished blocks live (speak as Claude writes); Compact/Off settle
        // the whole message. Only sources that observe streaming (Claude Desktop) act on it.
        let stream = (readAloudMode == .full)
        sources.forEach { $0.setStreaming(stream) }
        sources.forEach { $0.start() }
    }

    /// Wire the engine's orb signals into the store the HUD observes.
    private func bindEngine() {
        engine.onAmplitude = { [weak self] amp in self?.store.lastRMS = Double(amp) }
        engine.onSpeakingChanged = { [weak self] speaking in
            guard let self else { return }
            self.store.sessionActive = speaking
            self.store.state = speaking ? .speaking : .idle
            if !speaking { self.store.lastRMS = 0 }
        }
    }

    public func stop() {
        sources.forEach { $0.stop() }
        dictation.stop()
        engine.flush()
        synthChain.cancel()
    }

    /// Stop speaking and drop anything queued (the "stop speaking" action).
    public func flush() {
        synthChain.cancel()
        synthChain = Task {}
        engine.flush()
    }

    // MARK: - Pause / resume

    /// Pause the whole voice layer: stop speaking + drop the queue, stop every source,
    /// and stop dictation — but keep the app running. The orb goes idle.
    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        flush()                       // stop speaking + drop queued clips
        sources.forEach { $0.stop() } // stop reading new assistant messages
        dictation.stop()              // stop push-to-talk capture
        store.paused = true
        store.sessionActive = false
        store.state = .idle
        store.lastRMS = 0
    }

    /// Resume after `pause()`. Each source re-baselines at its current end on start, so
    /// messages that arrived while paused are NOT replayed — only new ones.
    public func resume() {
        guard isPaused else { return }
        isPaused = false
        store.paused = false
        dictation.start()
        startSources()
    }

    public func togglePause() { isPaused ? resume() : pause() }

    // MARK: - Live settings

    /// Switch the Kokoro voice for the English engine. No-op for the Czech (Apple) engine,
    /// which has no Kokoro voice id. Rebuilds the engine so the change is audible next message.
    public func setVoice(_ voice: String) {
        guard voice != currentVoice else { return }
        currentVoice = voice
        if LanguageProfile.ttsEngineKind(for: currentLanguage) == .kokoro {
            rebuildEngine()
        }
    }

    /// Switch language for BOTH read-aloud (engine) and dictation (Whisper) — live, no relaunch.
    public func setLanguage(_ language: String) {
        guard language != currentLanguage else { return }
        currentLanguage = language
        rebuildEngine()
        dictation.setLanguage(LanguageProfile.sttLanguage(for: language))
    }

    /// Switch which app(s) flowcode reads aloud — live, no relaunch.
    public func setSources(for target: ListenTarget) {
        guard target != listenTarget else { return }
        listenTarget = target
        sources.forEach { $0.stop() }
        sources = LocalVoiceController.makeSources(for: target)
        if !isPaused { startSources() }
    }

    /// Off / Full / Compact — applied to subsequent messages immediately.
    public func setReadAloudMode(_ mode: ReadAloudMode) {
        readAloudMode = mode
        if mode == .off { flush() }   // silence anything already speaking
        // Full streams finished blocks live; Compact/Off settle the whole message. Toggling
        // re-baselines each source so an in-flight reply isn't re-spoken on the new path.
        let stream = (mode == .full)
        sources.forEach { $0.setStreaming(stream) }
    }

    private func rebuildEngine() {
        flush()                       // cancel in-flight synthesis + stop the old engine
        engine = LocalVoiceController.makeEngine(language: currentLanguage, voice: currentVoice)
        bindEngine()
        engine.warmUp()
    }

    /// Inspection hook for the selftest (proves the Claude Code path is unchanged).
    public func debugSourceTypeNames() -> [String] {
        sources.map { String(describing: type(of: $0)) }
    }

    // MARK: - Synthesis pipeline

    private func speak(_ raw: String) {
        guard !isPaused, readAloudMode != .off else { return }
        let prepared = readAloudMode == .compact ? SpeechText.compact(raw) : raw
        let sentences = SpeechText.sentences(from: prepared)
        guard !sentences.isEmpty else { return }

        let previous = synthChain
        synthChain = Task { [weak self] in
            _ = await previous.value          // preserve order across messages
            for sentence in sentences {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.engine.speak(sentence)
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

    /// Compact ("gist") read-aloud: a short spoken digest of a long reply. Offline, instant,
    /// purely extractive (it re-orders/trims Claude's OWN words — it never paraphrases). The
    /// on-screen text is always the full record. Operates on the RAW markdown so it can use
    /// the reply's own structure, then emits clean prose (re-fed through `sentences(from:)`).
    ///
    /// Strategy (from the smarter-Compact research + adversarial review):
    ///   • short, unstructured replies → spoken whole (gated on LENGTH, not sentence count —
    ///     the splitter over-segments on ":"/";");
    ///   • otherwise: take the reply's blocks (whole bullets, paragraphs), DROP code fences,
    ///     tables, headings and horizontal rules, DEMOTE a tool-narration opener ("Let me…",
    ///     "Tady to máš…"), KEEP a trailing question/offer as the closer, cap to a few points
    ///     and a hard char budget so it's genuinely shorter;
    ///   • safety net: never silence and never ~the whole reply → fall back to first+last.
    public static func compact(_ raw: String) -> String {
        let bounded = String(raw.prefix(maxChars * 4))
        let cleanedFull = clean(bounded)
        guard !cleanedFull.isEmpty else { return "" }

        // Structured reply → extract from its own scaffolding; fall back to prose if that
        // yields nothing usable.
        if hasStructure(bounded), let gist = structuredGist(bounded), !gist.isEmpty {
            return gist
        }
        return proseGist(cleanedFull)
    }

    /// Gist of a structured reply: whole bullets / paragraphs, dropping code, tables,
    /// headings and rules; a leading tool-narration line demoted; a trailing question kept
    /// as the closer; capped to a few points and a hard char budget.
    private static func structuredGist(_ bounded: String) -> String? {
        var points: [String] = []
        var inFence = false
        for rawLine in bounded.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }   // fenced code: never spoken
            if inFence || line.isEmpty { continue }
            if isTableRow(line) || isHeading(line) || isThematicBreak(line) { continue }
            let text = clean(line)                                    // whole bullet/paragraph
            if !text.isEmpty { points.append(text) }
        }
        guard !points.isEmpty else { return nil }

        var closer: String?
        if let last = points.last, isQuestionOrOffer(last) { closer = last; points.removeLast() }
        if points.count > 1, let first = points.first, isNarration(first) { points.removeFirst() }

        var spoken = Array(points.prefix(5))           // a gist is a few points, not everything
        if let closer { spoken.append(closer) }
        let gist = capToBudget(clean(spoken.joined(separator: " ")))
        return gist.isEmpty ? nil : gist
    }

    /// Gist of unstructured prose: demote a tool-narration opener, speak short replies
    /// whole, otherwise keep the opener + the conclusion (the improved first+last).
    private static func proseGist(_ cleanedFull: String) -> String {
        var sents = splitSentences(cleanedFull)
        if sents.count > 1, let first = sents.first, isNarration(first) { sents.removeFirst() }
        let text = sents.joined(separator: " ")
        if text.count <= 200 || sents.count <= 2 { return text }     // short → whole
        guard let first = sents.first, let last = sents.last else { return text }
        return capToBudget(first + " " + last)
    }

    /// Trim to a spoken budget at a sentence boundary so compact stays meaningfully short.
    private static func capToBudget(_ s: String, budget: Int = 700) -> String {
        guard s.count > budget else { return s }
        var acc = ""
        for part in splitSentences(s) where acc.count + part.count + 1 <= budget {
            acc += (acc.isEmpty ? "" : " ") + part
        }
        return acc.isEmpty ? String(s.prefix(budget)) : acc
    }

    // MARK: compact extraction helpers (offline, diacritic-safe)

    /// True if the raw reply uses markdown structure (heading / list / quote / table / code).
    static func hasStructure(_ raw: String) -> Bool {
        raw.contains("```") || regexMatches(raw, #"(?m)^\s{0,3}(#{1,6}\s|[-*+]\s|\d+[.)]\s|>|\|)"#)
    }

    static func isHeading(_ line: String) -> Bool { regexMatches(line, #"^\s{0,3}#{1,6}\s"#) }

    /// A markdown table row or separator (≥2 pipes), e.g. `| a | b |` or `|---|---|`.
    static func isTableRow(_ line: String) -> Bool {
        line.filter { $0 == "|" }.count >= 2
    }

    /// A horizontal rule / thematic break (`---`, `***`, `___`) — silence, not "dash dash".
    static func isThematicBreak(_ line: String) -> Bool {
        line.count >= 3 && line.allSatisfy { "-*_=".contains($0) }
    }

    /// A trailing question or offer to the user (kept as the compact closer). Bilingual,
    /// matched diacritic-insensitively so Czech forms hit without listing every accent.
    static func isQuestionOrOffer(_ s: String) -> Bool {
        if s.hasSuffix("?") { return true }
        return foldedMatches(s, #"\b(let me know|anything else|want me to|would you like|how do you want|shall i)\b"#)
            || foldedMatches(s, #"\b(chces|chcete|muzes|muzete|nebo je to|jak chces|mam ti|mam to)\b"#)
    }

    /// A pure tool-narration / preamble opener with no result ("Let me read…", "Tady to máš…").
    static func isNarration(_ s: String) -> Bool {
        foldedMatches(s, #"^(let me|i'?ll|i will|let's|now i'?ll|now let|going to|first,? |next,? |i'?m going to)\b"#)
            || foldedMatches(s, #"^(ted |teda |nechte |nechme |podivam se|spustim|projdu|tady to mas|pripravil jsem|jdu na)\b"#)
    }

    /// Regex test after case + diacritic folding (so ASCII patterns match Czech text).
    static func foldedMatches(_ s: String, _ pattern: String) -> Bool {
        regexMatches(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil), pattern)
    }

    static func regexMatches(_ s: String, _ pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
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
        out = stripGlyphs(out)                                        // emoji / pictographs / arrows
        out = regexReplace(out, #"\s+"#, with: " ")                   // collapse whitespace

        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove emoji, pictographs, dingbats, arrows, and the invisible joiners/selectors that
    /// glue them together (U+FE0F variation selector, U+200D ZWJ). TTS otherwise vocalises
    /// these ("party popper") or hiccups on a lone variation selector. Letters, digits, and
    /// normal punctuation — including Czech diacritics — are untouched. (Don't use
    /// CharacterSet.letters to detect glyphs: it reports U+FE0F as a letter.)
    static func stripGlyphs(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u == "\u{FE0F}" || u == "\u{200D}" { continue }       // VS16, ZWJ
            if u.properties.isEmojiPresentation { continue }         // 🎉🌍📦🚀 (not digits/#/*)
            let v = u.value
            if (0x2190...0x21FF).contains(v)        // arrows
                || (0x2300...0x27BF).contains(v)    // misc technical, dingbats (✅ ⚠ ❌ ✂ …)
                || (0x2B00...0x2BFF).contains(v)    // misc symbols & arrows (⭐ ➡ …)
                || (0x1F000...0x1FAFF).contains(v)  // emoji planes
            {
                continue
            }
            scalars.append(u)
        }
        return String(scalars)
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

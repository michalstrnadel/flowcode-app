//
//  ClaudeDesktopSource.swift
//  flowcode — Model B (Claude Desktop read-aloud)
//
//  Reads the Claude desktop app's assistant replies aloud. The desktop app keeps
//  conversations SERVER-SIDE (no transcript file to tail, unlike Claude Code), so the
//  only local signal is the on-screen text — which we read via the macOS Accessibility
//  (AX) tree of its Electron/Chromium window.
//
//  This is the most fragile part of flowcode by design: the AX tree mirrors Claude's
//  HTML and moves when the UI changes. It is therefore DEFENSIVE end to end — every AX
//  call is error-checked, failures log ONCE and no-op for that tick, and the whole
//  thing stays inert until Accessibility is granted (the same grant dictation needs).
//  If it ever misbehaves, "Read replies → Off" or "Listen to → Claude Code" disables it.
//
//  Strategy (analogous to TranscriptReader's baseline-then-tail):
//    • poll the focused Claude window every 0.25 s, but ONLY while it's frontmost
//      (so a background Claude window is never read aloud),
//    • read the text of the LAST message block in the conversation,
//    • a `MessageSettler` waits for that text to stop changing (streaming finished),
//      de-dups what was already spoken, and emits the new portion exactly once.
//
//  Chat, Cowork, and Code-in-desktop are the same Electron web view, so they're read
//  uniformly. Distinguishing assistant vs. user blocks precisely is a later refinement.
//

import AppKit
import ApplicationServices
import Foundation

// MARK: - MessageSettler (pure, unit-tested core)

/// Turns a stream of "here is the current last-message text" samples into at most one
/// emit per completed message. Pure and deterministic (time is injected) so it can be
/// tested without the Claude app. See `flowcode-selftest`.
public struct MessageSettler {

    /// How long the text must stay unchanged before we treat the message as finished.
    public let settleInterval: Double

    private var lastText = ""
    private var lastChange = 0.0
    private var lastSpoken = ""
    private var spokenHashes = Set<Int>()
    private var baselined = false

    public init(settleInterval: Double = 0.8) {
        self.settleInterval = settleInterval
    }

    /// Feed the current last-message text and a monotonic `now` (seconds). Returns the
    /// text to speak when a NEW message has settled, otherwise nil.
    public mutating func update(current raw: String, now: Double) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // First sample = baseline. Whatever is already on screen is "history" and is
        // never spoken (mirrors TranscriptReader baselining at EOF).
        if !baselined {
            baselined = true
            lastText = text
            lastChange = now
            if !text.isEmpty {
                spokenHashes.insert(text.hashValue)
                lastSpoken = text
            }
            return nil
        }

        // Still changing → it's streaming; reset the settle clock and wait.
        if text != lastText {
            lastText = text
            lastChange = now
            return nil
        }

        guard !text.isEmpty, now - lastChange >= settleInterval else { return nil }

        let hash = text.hashValue
        if spokenHashes.contains(hash) { return nil }   // already spoken this exact text

        // If the settled text simply extends what we last spoke (the same block grew),
        // speak only the new suffix; otherwise it's a fresh block → speak all of it.
        let toSpeak: String
        if !lastSpoken.isEmpty, text.hasPrefix(lastSpoken) {
            toSpeak = String(text.dropFirst(lastSpoken.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            toSpeak = text
        }

        spokenHashes.insert(hash)
        lastSpoken = text
        return toSpeak.isEmpty ? nil : toSpeak
    }
}

// MARK: - MessageStreamer (pure, unit-tested core — live block streaming)

/// The streaming counterpart to `MessageSettler`, used for Full read-aloud: instead of
/// waiting for the WHOLE reply to settle, it emits each finished *block* (paragraph /
/// list / heading) as soon as a later block confirms it's done — so flowcode speaks as
/// Claude writes. Pure and deterministic (time and the block list are injected) so it's
/// unit-testable without the Claude app. See `flowcode-selftest`.
///
/// Design (from the streaming/Compact research + adversarial review):
///   • Block boundaries are STRUCTURAL (from the AX tree), never punctuation — so it can
///     never split mid-sentence / inside "e.g." / "U.S." / a decimal / a colon list.
///   • Dedup is by CONTENT HASH, not a character offset, so AX markdown reflow can never
///     cause a re-speak (at worst a dropped block — silence is safer than repetition).
///   • A block that simply GREW (a mid-stream pause flushed it early, then more text
///     arrived) emits only the new suffix — no double-speak.
///   • It NEVER speaks a message it hasn't seen stream in: a user's own prompt / transient
///     "Thinking…" text appears fully-formed as a single static block and never grows, so it
///     stays silent. Observed growth — or any multi-block reply — marks genuine output.
public struct MessageStreamer {

    /// A block must be stable this long before it's spoken (one-tick reflow/transient guard).
    public let blockSettle: Double
    /// The trailing / only block is flushed once the whole reply is stable this long.
    public let messageSettle: Double

    private var baselined = false
    private var spoken = Set<Int>()          // hashes of blocks already emitted (reflow-safe dedup)
    private var prevBlocks: [String] = []
    private var seenAt: [Int: Double] = [:]  // block hash → first time seen (per-block stability)
    private var lastArrayChange = 0.0        // when the block list last changed (whole-message settle)
    private var lastTail = ""                // last emitted trailing block (prefix-growth suffix emit)
    private var hasEmitted = false           // emitted at least one block of the current message?
    private var observedGrowth = false       // has the current message been seen streaming in?

    public init(blockSettle: Double = 0.25, messageSettle: Double = 0.5) {
        self.blockSettle = blockSettle
        self.messageSettle = messageSettle
    }

    /// Feed the current ordered blocks of the last message and a monotonic `now` (seconds).
    /// Returns the blocks to speak this tick (in document order), or `[]`.
    public mutating func update(blocks rawBlocks: [String], now: Double) -> [String] {
        let blocks = rawBlocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // First sample = baseline. Whatever is already on screen is "history": record its
        // hashes so pre-existing chat is never replayed.
        if !baselined {
            baselined = true
            prevBlocks = blocks
            lastArrayChange = now
            for b in blocks { let h = b.hashValue; spoken.insert(h); seenAt[h] = now }
            lastTail = blocks.last ?? ""
            return []
        }

        if blocks != prevBlocks {
            lastArrayChange = now
            // Same message if the leading block is unchanged OR merely grew (a single block
            // streaming in changes `first` but is NOT a new reply). Different lead → new reply.
            let newMessage = !sameLeadBlock(blocks.first, prevBlocks.first)
            if newMessage {
                // A different leading block → a new reply. Re-arm the first-block guards.
                hasEmitted = false
                observedGrowth = false
                lastTail = ""
            } else if joinedCount(blocks) > joinedCount(prevBlocks) {
                // Same message, content grew → the assistant is streaming it in.
                observedGrowth = true
            }
            for b in blocks where seenAt[b.hashValue] == nil { seenAt[b.hashValue] = now }
            prevBlocks = blocks
        }

        guard !blocks.isEmpty else { return [] }

        // Never speak a message we haven't seen stream in: a user's own prompt or a transient
        // "Thinking…" line appears fully-formed as a single static block and never grows. A
        // reply we've watched grow — or any multi-block reply — is genuine assistant output.
        let canStart = hasEmitted || observedGrowth || blocks.count >= 2
        guard canStart else { return [] }

        var emitted: [String] = []
        let messageStable = now - lastArrayChange >= messageSettle
        for (i, b) in blocks.enumerated() {
            let h = b.hashValue
            if spoken.contains(h) { continue }                 // already emitted exactly
            let isLast = (i == blocks.count - 1)

            // A non-last block is confirmed done (Claude moved on); the last/only block
            // waits for the whole message to settle. Either way require one tick of block
            // stability (reflow guard). The canStart gate above already rejected a
            // non-streaming single block (a user prompt / transient text).
            let confirmed = !isLast || messageStable
            let stable = now - (seenAt[h] ?? now) >= blockSettle

            // Preserve order: stop at the first block that isn't ready yet.
            guard confirmed && stable else { break }

            // If this block extends the last one we spoke (a pause flushed it early, then it
            // grew), speak only the new suffix — trimming any leading joiner punctuation.
            let toSpeak: String
            if !lastTail.isEmpty, b.hasPrefix(lastTail) {
                toSpeak = String(b.dropFirst(lastTail.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n,;:—–-"))
            } else {
                toSpeak = b
            }

            spoken.insert(h)
            lastTail = b
            hasEmitted = true
            if !toSpeak.isEmpty { emitted.append(toSpeak) }
        }
        return emitted
    }

    private func joinedCount(_ blocks: [String]) -> Int {
        blocks.reduce(0) { $0 + $1.count }
    }

    /// Two leading blocks belong to the same message if one is a prefix of the other (a
    /// single block streaming in grows `first` without it being a new reply).
    private func sameLeadBlock(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }
}

// MARK: - ClaudeDesktopSource

@MainActor
public final class ClaudeDesktopSource: AssistantTextSource {

    public var onAssistantText: ((String) -> Void)?

    /// Claude desktop app bundle id. Public so the controller can coordinate sources
    /// (mute the Claude Code JSONL reader while a Claude Desktop window is frontmost).
    nonisolated public static let bundleID = "com.anthropic.claudefordesktop"

    private let bundleID: String
    private var timer: Timer?
    private var settler = MessageSettler(settleInterval: 0.5)
    private var streamer = MessageStreamer(blockSettle: 0.2, messageSettle: 0.35)
    /// Full mode → stream finished blocks live; Compact/Off → settle the whole message.
    private var streaming = false

    // Cached AX handles (re-resolved when they go stale).
    private var axApp: AXUIElement?
    private var cachedPID: pid_t = -1
    private var didLogAXIssue = false

    public init(bundleID: String = ClaudeDesktopSource.bundleID) {
        self.bundleID = bundleID
    }

    public func start() {
        stop()
        rebaseline()                 // re-baseline so pre-existing chat is never replayed
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Switch live block-streaming (Full) on/off. Re-baselines so an in-flight reply on the
    /// old path is never re-spoken on the new one (matches resume() semantics).
    public func setStreaming(_ on: Bool) {
        guard on != streaming else { return }
        streaming = on
        rebaseline()
    }

    private func rebaseline() {
        settler = MessageSettler(settleInterval: 0.5)
        streamer = MessageStreamer(blockSettle: 0.2, messageSettle: 0.35)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        axApp = nil
        cachedPID = -1
    }

    // MARK: - Polling

    private func poll() {
        // Only read when Claude Desktop is frontmost — never read a background window,
        // and never fight the Claude Code transcript reader for the user's attention.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
        // Reading another app's AX tree requires the Accessibility grant (the same one
        // dictation uses). Stay silent until it's granted — no prompt from here.
        guard AXIsProcessTrusted() else { return }
        guard let app = resolveApp() else { return }
        guard let window = focusedWindow(of: app) ?? firstWindow(of: app) else { return }
        guard let web = findWebArea(window) else {
            logAXOnce("could not find the Claude web view in the AX tree")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if streaming {
            // Full mode: speak each finished block as the reply streams in.
            let blocks = lastMessageBlocks(in: web)
            guard !blocks.isEmpty else { return }
            for block in streamer.update(blocks: blocks, now: now) { onAssistantText?(block) }
        } else {
            // Compact / Off: wait for the whole message, then hand it over as one string.
            let text = lastMessageText(in: web)
            guard !text.isEmpty else { return }
            if let toSpeak = settler.update(current: text, now: now) {
                onAssistantText?(toSpeak)
            }
        }
    }

    // MARK: - App / window resolution

    private func resolveApp() -> AXUIElement? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        guard let running, !running.isTerminated else { axApp = nil; cachedPID = -1; return nil }
        if let axApp, running.processIdentifier == cachedPID { return axApp }
        let el = AXUIElementCreateApplication(running.processIdentifier)
        axApp = el
        cachedPID = running.processIdentifier
        enableChromiumAX(el)
        return el
    }

    /// Electron/Chromium apps (Claude Desktop) build their web accessibility tree ONLY when
    /// an assistive client asks for it. Without this the AX tree is just empty AXGroups — no
    /// conversation text. Setting these attributes makes Claude expose its web content. The
    /// tree populates asynchronously (Chromium rebuilds it), so the first read or two after a
    /// fresh launch may still be sparse. Set once per app instance (re-runs when the pid
    /// changes because resolveApp only reaches here on a new element).
    private func enableChromiumAX(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        copyElement(app, kAXFocusedWindowAttribute) ?? copyElement(app, kAXMainWindowAttribute)
    }

    private func firstWindow(of app: AXUIElement) -> AXUIElement? {
        copyElements(app, kAXWindowsAttribute)?.first
    }

    // MARK: - Tree walking

    /// The Chromium web view holding the conversation. Claude Desktop exposes MORE than one
    /// `AXWebArea` (e.g. an empty/sidebar one plus the main content), so pick the one with the
    /// most text rather than the first in document order.
    private func findWebArea(_ root: AXUIElement) -> AXUIElement? {
        var areas: [AXUIElement] = []
        collectWebAreas(root, depth: 0, into: &areas)
        guard !areas.isEmpty else { return nil }
        if areas.count == 1 { return areas[0] }
        return areas.max { collectStaticText($0).count < collectStaticText($1).count }
    }

    private func collectWebAreas(_ el: AXUIElement, depth: Int, into acc: inout [AXUIElement]) {
        if depth > 80 { return }
        if role(of: el) == "AXWebArea" { acc.append(el) }   // don't recurse into nested web areas
        else { for child in children(of: el) { collectWebAreas(child, depth: depth + 1, into: &acc) } }
    }

    /// Text of the latest assistant reply. Claude Desktop tags each turn with an
    /// `AXHeading` — "You said: …" for the user, "Claude responded: …" for the assistant —
    /// so we anchor on the LAST "Claude responded:" heading and read its sibling blocks.
    /// This structurally excludes the user's own prompt and the conversation sidebar.
    /// Falls back to the old last-text-child heuristic if the heading isn't present.
    private func lastMessageText(in web: AXUIElement) -> String {
        guard let container = latestAssistantContainer(in: web) else { return "" }
        return assistantBlocks(container).joined(separator: " ")
    }

    /// The assistant heading carries this prefix in Claude Desktop (English UI).
    private let assistantHeadingPrefix = "Claude responded"

    /// The container subtree of the latest assistant reply: the parent of the last
    /// `AXHeading` whose text starts with "Claude responded".
    private func latestAssistantContainer(in web: AXUIElement) -> AXUIElement? {
        var headings: [AXUIElement] = []
        collectAssistantHeadings(web, depth: 0, into: &headings)
        guard let last = headings.last else { return nil }
        return copyElement(last, kAXParentAttribute)
    }

    private func collectAssistantHeadings(_ el: AXUIElement, depth: Int, into acc: inout [AXUIElement]) {
        if depth > 80 { return }
        if role(of: el) == "AXHeading" {
            let t = string(of: el, kAXValueAttribute) ?? string(of: el, kAXTitleAttribute) ?? ""
            if t.hasPrefix(assistantHeadingPrefix) { acc.append(el) }
        }
        for child in children(of: el) { collectAssistantHeadings(child, depth: depth + 1, into: &acc) }
    }

    /// The reply's structural blocks (paragraph, list, …) in order, skipping the
    /// "Claude responded:" heading label itself. `AXListMarker` ("•") is a non-static-text
    /// role so `collectStaticText` already drops it.
    private func assistantBlocks(_ container: AXUIElement) -> [String] {
        var blocks: [String] = []
        for child in children(of: container) {
            if role(of: child) == "AXHeading" { continue }   // the "Claude responded:" label
            let t = collectStaticText(child)
            if t.isEmpty || isTimestamp(t) { continue }      // drop the relative-time stamp
            blocks.append(t)
        }
        return blocks
    }

    /// True for the relative-time stamp Claude appends to each reply ("just now", "3m ago",
    /// "před 5 minutami", …). It must NOT be spoken, and because it ticks over time it would
    /// otherwise look like the reply changed and trigger a spurious re-read.
    private func isTimestamp(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty { return true }
        if ["just now", "now", "yesterday", "today", "právě teď", "teď", "včera", "dnes"].contains(t) { return true }
        if t.range(of: #"^\d+\s*[a-zá-ž]+\s+ago$"#, options: .regularExpression) != nil { return true }   // "5m ago", "2 hours ago"
        if t.range(of: #"^před\s+\d+.+$"#, options: .regularExpression) != nil { return true }              // "před 5 minutami"
        return false
    }

    /// The last message as ORDERED structural blocks (paragraphs / list / heading), for
    /// live streaming. Block boundaries come from the AX tree, not punctuation, so a block
    /// is never split mid-sentence. Falls back to a single block (→ behaves like the
    /// whole-message settler) when no useful structure is found.
    private func lastMessageBlocks(in web: AXUIElement) -> [String] {
        guard let container = latestAssistantContainer(in: web) else { return [] }
        return assistantBlocks(container)
    }

    /// Concatenate the visible text of all `AXStaticText` nodes under `el` (document
    /// order). Bounded by a node budget so a huge tree can't stall the 0.25 s tick.
    private func collectStaticText(_ el: AXUIElement) -> String {
        var out: [String] = []
        var budget = 4000
        func walk(_ node: AXUIElement, depth: Int) {
            guard budget > 0, depth < 60 else { return }
            budget -= 1
            if role(of: node) == "AXStaticText" {
                if let v = string(of: node, kAXValueAttribute) ?? string(of: node, kAXTitleAttribute) {
                    let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { out.append(t) }
                }
            }
            for child in children(of: node) { walk(child, depth: depth + 1) }
        }
        walk(el, depth: 0)
        return out.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - AX attribute helpers (all error-checked)

    private func role(of el: AXUIElement) -> String {
        string(of: el, kAXRoleAttribute) ?? ""
    }

    private func string(of el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func copyElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func copyElements(_ el: AXUIElement, _ attr: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private func children(of el: AXUIElement) -> [AXUIElement] {
        copyElements(el, kAXChildrenAttribute) ?? []
    }

    private func logAXOnce(_ msg: String) {
        guard !didLogAXIssue else { return }
        didLogAXIssue = true
        NSLog("flowcode: Claude Desktop read-aloud — \(msg). It will keep retrying; use 'Listen to › Claude Code' to disable.")
    }
}

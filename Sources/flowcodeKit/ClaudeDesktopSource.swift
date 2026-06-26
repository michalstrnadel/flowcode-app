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

// MARK: - ClaudeDesktopSource

@MainActor
public final class ClaudeDesktopSource: AssistantTextSource {

    public var onAssistantText: ((String) -> Void)?

    private let bundleID: String
    private var timer: Timer?
    private var settler = MessageSettler()

    // Cached AX handles (re-resolved when they go stale).
    private var axApp: AXUIElement?
    private var cachedPID: pid_t = -1
    private var didLogAXIssue = false

    public init(bundleID: String = "com.anthropic.claudefordesktop") {
        self.bundleID = bundleID
    }

    public func start() {
        stop()
        settler = MessageSettler()   // re-baseline so pre-existing chat is never replayed
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
        let text = lastMessageText(in: web)
        guard !text.isEmpty else { return }
        if let toSpeak = settler.update(current: text, now: ProcessInfo.processInfo.systemUptime) {
            onAssistantText?(toSpeak)
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
        return el
    }

    private func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        copyElement(app, kAXFocusedWindowAttribute) ?? copyElement(app, kAXMainWindowAttribute)
    }

    private func firstWindow(of app: AXUIElement) -> AXUIElement? {
        copyElements(app, kAXWindowsAttribute)?.first
    }

    // MARK: - Tree walking

    /// Depth-first search for the first Chromium web view (`AXWebArea`).
    private func findWebArea(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 80 { return nil }
        if role(of: el) == "AXWebArea" { return el }
        for child in children(of: el) {
            if let found = findWebArea(child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Text of the last message block in the conversation. Walking the children of the
    /// scroll area (the message list) from the end and taking the first text-bearing
    /// subtree usually lands on the latest assistant reply (the user's prompt is an
    /// earlier sibling). Falls back to the whole web area's text if structure differs.
    private func lastMessageText(in web: AXUIElement) -> String {
        let container = firstScrollArea(web) ?? web
        let kids = children(of: container)
        for child in kids.reversed() {
            let t = collectStaticText(child)
            if t.count >= 12 { return t }
        }
        return collectStaticText(container)
    }

    private func firstScrollArea(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 80 { return nil }
        if role(of: el) == "AXScrollArea" { return el }
        for child in children(of: el) {
            if let found = firstScrollArea(child, depth: depth + 1) { return found }
        }
        return nil
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

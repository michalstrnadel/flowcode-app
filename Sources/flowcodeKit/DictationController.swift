//
//  DictationController.swift
//  flowcode — Model B (dictation half)
//
//  Push-to-talk dictation: HOLD the Right Option (⌥) key, speak, release. The
//  captured audio is sent to Whisper (local STT) and the transcript is pasted
//  into whatever app is focused (the terminal where Claude Code's prompt is).
//  The user controls exactly WHEN it listens — no endless loop, no false
//  triggers from music or Claude's own TTS.
//
//  Permissions: microphone (capture) + Accessibility (to post Cmd-V into the
//  focused app and to receive the global modifier key event). Both are requested
//  on start. NOTE: ad-hoc-signed builds get a NEW code hash each rebuild, so
//  macOS forgets the Accessibility grant and re-prompts — expected in dev.
//

import AppKit
import AVFoundation
import Accelerate
import Carbon.HIToolbox
import ApplicationServices

@MainActor
public final class DictationController {

    private let store: VoiceSessionStore
    private var whisper: WhisperClient

    /// Called when capture starts — e.g. to stop read-aloud so the mic doesn't
    /// pick up Claude's own TTS off the speakers.
    public var onStartCapture: (() -> Void)?

    private var monitor: Any?
    private var accessibilityTimer: Timer?
    private var engine: AVAudioEngine?
    private var recording = false
    private var micDenied = false
    private var captureSampleRate: Double = 48_000
    private let accumulator = PCMAccumulator()
    private let smoother = DictationSmoother()

    public init(store: VoiceSessionStore, language: String = "en") {
        self.store = store
        self.whisper = WhisperClient(language: language)
    }

    /// Switch the STT language live (e.g. en ↔ cs). `WhisperClient` is a value type and
    /// the recording path copies it per turn, so the next dictation uses the new language.
    public func setLanguage(_ language: String) {
        whisper = WhisperClient(language: language)
    }

    public func start() {
        // Mic capture permission (engine.start would prompt anyway; ask early).
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // The global ⌥ monitor + Cmd-V posting both need Accessibility. Install the
        // monitor only once the grant exists, and keep re-checking so a grant made
        // after launch takes effect WITHOUT an app restart.
        installMonitorWhenTrusted()
    }

    public func stop() {
        accessibilityTimer?.invalidate(); accessibilityTimer = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if recording { stopRecording(transcribe: false) }
    }

    private var didPromptAccessibility = false

    private func installMonitorWhenTrusted() {
        guard monitor == nil else { return }
        // SILENT trust check (no prompt) — calling the prompting variant on every
        // timer tick is what spammed the Accessibility dialog repeatedly.
        if AXIsProcessTrusted() {
            installMonitor()
            accessibilityTimer?.invalidate(); accessibilityTimer = nil
            return
        }
        // Prompt EXACTLY ONCE; then poll silently until the grant appears.
        if !didPromptAccessibility {
            didPromptAccessibility = true
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            NSLog("flowcode: dictation needs Accessibility — enable flowcode in System Settings › Privacy & Security › Accessibility (no restart needed).")
        }
        if accessibilityTimer == nil {
            let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.installMonitorWhenTrusted() }
            }
            RunLoop.main.add(t, forMode: .common)
            accessibilityTimer = t
        }
    }

    private func installMonitor() {
        // Global push-to-talk: hold Right Option (⌥). We watch modifier changes
        // globally; reading value types out of the event keeps it Sendable-safe.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] ev in
            let keyCode = ev.keyCode
            let optionDown = ev.modifierFlags.contains(.option)
            Task { @MainActor in self?.handleFlags(keyCode: keyCode, optionDown: optionDown) }
        }
        NSLog("flowcode: dictation ready — hold Right Option (⌥) to talk.")
    }

    // MARK: - Push-to-talk key handling

    private func handleFlags(keyCode: UInt16, optionDown: Bool) {
        guard keyCode == UInt16(kVK_RightOption) else { return }
        if optionDown && !recording {
            startRecording()
        } else if !optionDown && recording {
            stopRecording(transcribe: true)
        }
    }

    // MARK: - Capture

    private func startRecording() {
        guard !recording else { return }
        if micDenied {
            // Re-check: the user may have granted mic access since the denial. Only a
            // real TCC denial keeps the latch; anything else retries.
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                micDenied = false
            } else {
                NSSound.beep()   // mic was denied before — don't silently no-op
                NSLog("flowcode: microphone access denied — enable it in System Settings › Privacy & Security › Microphone.")
                return
            }
        }
        recording = true
        onStartCapture?()                 // stop read-aloud so we don't capture TTS
        accumulator.reset()
        smoother.reset()
        store.sessionActive = true
        store.state = .listening
        store.lastRMS = 0

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        captureSampleRate = format.sampleRate

        let acc = accumulator
        let sm = smoother
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, _ in
            guard let ch = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            // Channel 0 only (mono for STT).
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
            acc.append(samples)
            var rms: Float = 0
            vDSP_rmsqv(ch[0], 1, &rms, vDSP_Length(n))
            let level = sm.advance(towards: min(max(rms * 8, 0), 1).squareRoot())
            Task { @MainActor in
                guard let self, self.recording else { return }
                self.store.lastRMS = Double(level)   // orb pulses to the user's voice
            }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap)
        engine.prepare()
        do {
            try engine.start()
            self.engine = engine
        } catch {
            NSLog("flowcode: dictation engine failed: \(error)")
            input.removeTap(onBus: 0)
            recording = false
            // Latch ONLY on a real permission denial. engine.start() also fails
            // transiently (Bluetooth handoff, input device switching) — latching on
            // those would kill dictation until relaunch even though the mic is fine
            // one second later. Transient failures beep and retry on the next press.
            let auth = AVCaptureDevice.authorizationStatus(for: .audio)
            micDenied = (auth == .denied || auth == .restricted)
            NSSound.beep()
            resetOrb()
        }
    }

    private func stopRecording(transcribe: Bool) {
        recording = false
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil

        let floats = accumulator.drain()
        guard transcribe, floats.count > Int(captureSampleRate * 0.3) else {
            // Too short / cancelled → nothing to transcribe.
            resetOrb()
            return
        }
        store.state = .processing
        store.lastRMS = 0
        let wav = DictationController.makeWav(floats: floats, sampleRate: Int(captureSampleRate))
        let whisper = self.whisper
        Task { [weak self] in
            var text = ""
            var failed = false
            do { text = try await whisper.transcribe(wav: wav) }
            catch { failed = true; NSLog("flowcode: transcription failed: \(error)") }
            await MainActor.run {
                guard let self else { return }
                if failed {
                    NSSound.beep()                       // captured audio but STT errored
                } else if let clean = DictationController.usableTranscript(text) {
                    self.insert(clean)                   // real speech → paste it
                }
                // else: silence / non-speech (e.g. "[BLANK_AUDIO]") → insert nothing.
                self.resetOrb()
            }
        }
    }

    private func resetOrb() {
        store.state = .idle
        store.sessionActive = false
        store.lastRMS = 0
    }

    // MARK: - Text insertion (pasteboard + Cmd-V)

    /// The user clipboard captured before the FIRST of a run of quick dictations, so a
    /// second dictation within the restore window never "saves" the first transcript.
    private var pendingRestore: String?
    /// changeCount of our own paste — restore fires only if this is still current.
    private var restoreStamp = 0

    private func insert(_ text: String) {
        let pb = NSPasteboard.general
        // If a previous dictation's restore hasn't fired yet, the pasteboard holds OUR
        // previous transcript — keep carrying the user's original clipboard instead.
        let saved = pendingRestore ?? pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let stamp = pb.changeCount
        pendingRestore = saved
        restoreStamp = stamp
        postCmdV()
        // Restore the user's previous clipboard after the paste is consumed. 1.5s is a
        // safer margin than 0.6s for a momentarily busy target app.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.restoreStamp == stamp else { return }  // superseded by a newer dictation
            self.pendingRestore = nil
            // If anything else wrote to the pasteboard since our paste (the user copied
            // something), restoring now would clobber it — leave the pasteboard alone.
            guard pb.changeCount == stamp else { return }
            if let saved {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
    }

    private func postCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Transcript filtering

    /// Strip whisper.cpp non-speech annotations ([BLANK_AUDIO], [ Silence ],
    /// (inaudible), [MUSIC], …). Returns nil if nothing real is left (so a
    /// silent / noise-only push-to-talk inserts NOTHING).
    static func usableTranscript(_ raw: String) -> String? {
        var t = raw
        let patterns = [
            #"(?i)\[\s*(blank[_ ]?audio|silence|music|noise|inaudible|pause|sound|applause|laughter|no speech|speaking foreign language|background noise)\s*\]"#,
            #"(?i)\(\s*(silence|inaudible|music|noise|pause|no speech|background noise)\s*\)"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
        }
        if let ws = try? NSRegularExpression(pattern: #"\s+"#) {
            t = ws.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: - WAV encoding (mono int16, native sample rate; whisper.cpp resamples)

    static func makeWav(floats: [Float], sampleRate: Int) -> Data {
        var samples = [Int16](repeating: 0, count: floats.count)
        for i in 0..<floats.count {
            let clamped = max(-1, min(1, floats[i]))
            samples[i] = Int16(clamped * 32767)
        }
        let dataSize = samples.count * 2
        let byteRate = sampleRate * 2
        var d = Data()
        func le32(_ v: UInt32) { d.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]) }
        func le16(_ v: UInt16) { d.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
        d.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + dataSize))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(UInt32(sampleRate)); le32(UInt32(byteRate)); le16(2); le16(16)
        d.append(contentsOf: Array("data".utf8)); le32(UInt32(dataSize))
        samples.withUnsafeBytes { d.append(contentsOf: $0) }   // int16 LE on arm64
        return d
    }
}

// MARK: - Helpers (lock-protected, off-actor)

/// Accumulates captured float samples from the real-time audio thread.
private final class PCMAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    // ~120 s at 48 kHz mono. A push-to-talk turn is seconds; this just bounds memory
    // if the key is held indefinitely (extra audio past the cap is dropped).
    private let cap = 48_000 * 120
    func append(_ chunk: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard samples.count < cap else { return }
        samples.append(contentsOf: chunk)
    }
    func drain() -> [Float] { lock.lock(); let s = samples; samples.removeAll(); lock.unlock(); return s }
    func reset() { lock.lock(); samples.removeAll(); lock.unlock() }
}

/// Asymmetric one-pole smoother for the dictation mic level (orb reactivity).
private final class DictationSmoother: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0
    func advance(towards target: Float) -> Float {
        let t = min(max(target, 0), 1)
        lock.lock(); defer { lock.unlock() }
        value += (t - value) * (t > value ? 0.6 : 0.15)
        if value < 0.0005 { value = 0 }
        return value
    }
    func reset() { lock.lock(); value = 0; lock.unlock() }
}

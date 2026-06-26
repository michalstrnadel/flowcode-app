//
//  CoquiTTSEngine.swift
//  flowcode — Czech read-aloud (on-demand neural voice)
//
//  Czech speaks through a local Coqui VITS server (HTTP, like Kokoro). The voice is
//  OPTIONAL and heavier than English (it needs a small PyTorch runtime), so it is
//  downloaded ON DEMAND the first time the user picks Czech — never bundled.
//
//  Two parts:
//    • CoquiTTSEngine   — the TTSEngine: GET /api/tts?text=… → WAV → TtsPlayer (real
//                         metering, so the orb reacts to the actual audio).
//    • CoquiVoiceService — provisioning + lifecycle: a Download? prompt, runs
//                         scripts/czech-voice.sh to install, spawns the server (under
//                         the watchdog so it dies with the app), and health-checks it.
//
//  All user-facing strings are English to match the rest of the app.
//

import AppKit
import Foundation

// MARK: - Engine

@MainActor
public final class CoquiTTSEngine: TTSEngine {

    private let base: URL
    private let player = TtsPlayer()

    public var onAmplitude: ((Float) -> Void)? {
        get { player.onAmplitude }
        set { player.onAmplitude = newValue }
    }
    public var onSpeakingChanged: ((Bool) -> Void)? {
        get { player.onSpeakingChanged }
        set { player.onSpeakingChanged = newValue }
    }

    public init(port: Int = 8771) {
        self.base = URL(string: "http://127.0.0.1:\(port)")!
    }

    public func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var comps = URLComponents(url: base.appendingPathComponent("api/tts"),
                                        resolvingAgainstBaseURL: false) else { return }
        comps.queryItems = [URLQueryItem(name: "text", value: trimmed)]
        guard let url = comps.url else { return }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
        player.enqueue(data)
    }

    public func flush() { player.flush() }
}

// MARK: - Provisioning + lifecycle

@MainActor
public final class CoquiVoiceService {

    public let port: Int
    private let store: VoiceSessionStore
    private var serverProcess: Process?

    public init(store: VoiceSessionStore, port: Int = 8771) {
        self.store = store
        self.port = port
    }

    /// True if the Czech voice model has already been downloaded.
    public func isInstalled() -> Bool {
        guard let dir = Self.modelDir(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return names.contains { $0.lowercased().contains("cs") && $0.lowercased().contains("vits") }
    }

    /// Ensure Czech is ready to speak: prompt + download if needed, then start the local
    /// server and wait until it answers. Returns false if the user declines or it fails.
    public func ensureReady() async -> Bool {
        if !isInstalled() {
            guard promptDownload() else { return false }
            store.statusOverride = "Downloading Czech voice…"
            defer { store.statusOverride = nil }
            let installed = await runScript(["install"], logName: "coqui-install.log")
            guard installed else {
                showError("The Czech voice could not be downloaded. Check your connection and that the command-line tool ‘uv’ is installed.")
                return false
            }
        }
        if await isHealthy() { return true }
        startServer()
        store.statusOverride = "Starting Czech voice…"
        defer { store.statusOverride = nil }
        let healthy = await waitHealthy(seconds: 45)
        if !healthy {
            showError("The Czech voice service did not start. See ~/.flowcode/logs/coqui-serve.log.")
        }
        return healthy
    }

    /// Stop the local Czech server (frees the PyTorch runtime's memory). Safe to call
    /// when nothing is running.
    public func stopServer() {
        serverProcess?.terminate()
        serverProcess = nil
    }

    // MARK: Server process

    private func startServer() {
        guard serverProcess == nil else { return }
        let p = makeProcess(args: ["serve", "\(port)"], logName: "coqui-serve.log", preferWatchdog: true)
        do {
            try p.run()
            serverProcess = p
        } catch {
            NSLog("flowcode: failed to start Czech voice server: \(error.localizedDescription)")
        }
    }

    private func runScript(_ args: [String], logName: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let p = makeProcess(args: args, logName: logName, preferWatchdog: false)
            p.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus == 0) }
            do { try p.run() } catch {
                NSLog("flowcode: czech-voice.sh \(args.joined(separator: " ")) failed to launch: \(error.localizedDescription)")
                cont.resume(returning: false)
            }
        }
    }

    private func makeProcess(args: [String], logName: String, preferWatchdog: Bool) -> Process {
        let p = Process()

        // GUI-launched apps get a minimal PATH that omits ~/.local/bin (uv) and Homebrew.
        // Augment it so the script can find `uvx`.
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = env["PATH"].map { "\($0):\(extra)" } ?? extra
        p.environment = env

        let script = Self.scriptURL()
        if preferWatchdog, let wd = Self.watchdogURL() {
            // The watchdog runs the script in its own process group and kills the whole
            // group when flowcode exits — so the Python server never orphans.
            p.executableURL = wd
            p.arguments = [script.path] + args
        } else {
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path] + args
        }

        if let log = Self.logURL(logName) {
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            if let fh = try? FileHandle(forWritingTo: log) {
                p.standardOutput = fh
                p.standardError = fh
            }
        }
        return p
    }

    // MARK: Health

    private func isHealthy() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200..<500).contains(http.statusCode)   // any HTTP answer = the server is up
    }

    private func waitHealthy(seconds: Int) async -> Bool {
        for _ in 0..<seconds {
            if await isHealthy() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    // MARK: UI

    private func promptDownload() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Download the Czech voice?"
        alert.informativeText = "Czech read-aloud uses a neural voice that runs fully offline on your Mac. flowcode will download it once (about 350 MB, including a small speech runtime). English is unaffected."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Czech voice unavailable"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    // MARK: Paths

    private static func scriptURL() -> URL {
        if let u = Bundle.main.url(forResource: "czech-voice", withExtension: "sh") { return u }
        // Dev (`swift run`): fall back to the repo script relative to the working dir.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return cwd.appendingPathComponent("scripts/czech-voice.sh")
    }

    private static func watchdogURL() -> URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/flowcode-watchdog")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private static func modelDir() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("tts")
    }

    private static func logURL(_ name: String) -> URL? {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".flowcode/logs/\(name)")
    }
}

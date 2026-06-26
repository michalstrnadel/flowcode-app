// SettingsStore.swift
// flowcode — user-facing settings, persisted to UserDefaults.
//
// Per shared contract: @MainActor @Observable final class backed by
// UserDefaults.standard with stable string keys. Each stored property
// persists on `didSet`; `init` seeds current values from defaults (with
// sensible fallbacks). Provides a computed `socketPath` that defaults to
// the voice-core Unix-domain socket under the user's home directory.

import Foundation
import Observation
import ServiceManagement

/// Which app(s) flowcode reads aloud. Persisted by raw value.
public enum ListenTarget: String, CaseIterable, Sendable {
    case claudeCode
    case claudeDesktop
    case both
}

/// How much of each assistant reply to speak. Persisted by raw value.
///   off     — say nothing (dictation still works)
///   full    — the whole reply (today's behavior)
///   compact — just the gist (first + last sentence), for when Claude rambles
public enum ReadAloudMode: String, CaseIterable, Sendable {
    case off
    case full
    case compact
}

/// How flowcode announces that a reply is ready — an attention cue played BEFORE the
/// reply is read aloud, so you can look away and be called back. Persisted by raw value.
///   off    — no announcement (read-aloud starts straight away)
///   chime  — a short system chime before the reply
///   spoken — a chime plus a short spoken "Claude needs your attention" before the reply
public enum ReadyAlert: String, CaseIterable, Sendable {
    case off
    case chime
    case spoken
}

@MainActor
@Observable
public final class SettingsStore {

    // MARK: - Stable UserDefaults keys
    //
    // Namespaced under "flowcode." so they don't collide with anything else
    // and stay readable in `defaults read`. These strings are part of the
    // on-disk contract — do not rename without a migration.
    private enum Keys {
        static let bargeInEnabled      = "flowcode.bargeInEnabled"
        static let streamingChunking   = "flowcode.streamingChunking"
        static let semanticEndpointing = "flowcode.semanticEndpointing"
        static let launchAtLogin       = "flowcode.launchAtLogin"
        static let language            = "flowcode.language"
        static let voice               = "flowcode.voice"
        static let swarmMode           = "flowcode.swarmMode"
        static let hudOnlyMode         = "flowcode.hudOnlyMode"
        static let readAloud           = "flowcode.readAloud"
        static let readAloudMode       = "flowcode.readAloudMode"
        static let readyAlert          = "flowcode.readyAlert"
        static let listenTarget        = "flowcode.listenTarget"
        static let socketPath          = "flowcode.socketPath"
    }

    // MARK: - Voice-core flag keys
    //
    // The VOICEMODE_* env var each toggle maps to when pushed to the Python core via
    // ControlCommand.setFlag. These are the EXACT names config.reload_configuration()
    // re-reads, so flipping a toggle reconfigures the LIVE core. (launchAtLogin is a
    // macOS-local login item and has no voice-core flag — it is never pushed.)
    public static let bargeInFlagKey   = "VOICEMODE_BARGEIN_ENABLED"
    public static let streamingFlagKey = "VOICEMODE_TTS_SENTENCE_CHUNKING"
    public static let semanticFlagKey  = "VOICEMODE_SEMANTIC_ENDPOINTING"

    // MARK: - Defaults

    /// Default language tag used when nothing is persisted yet.
    private static let defaultLanguage = "en"

    /// Default Kokoro TTS voice used when nothing is persisted yet.
    public static let defaultVoice = "af_sky"

    // MARK: - Backing store
    //
    // Inject for testing; production uses the standard suite. MainActor-isolated
    // (the class is @MainActor) — we only ever touch it here.
    private let defaults: UserDefaults

    // MARK: - Stored, observable, persisted properties

    /// Allow the assistant's speech to be interrupted by the user (barge-in).
    public var bargeInEnabled: Bool {
        didSet { defaults.set(bargeInEnabled, forKey: Keys.bargeInEnabled) }
    }

    /// Stream/chunk TTS playback as it arrives rather than waiting for the
    /// full utterance. Defaults to `true` (better perceived latency).
    public var streamingChunking: Bool {
        didSet { defaults.set(streamingChunking, forKey: Keys.streamingChunking) }
    }

    /// Use semantic (model-driven) detection of end-of-utterance instead of a
    /// fixed silence timeout.
    public var semanticEndpointing: Bool {
        didSet { defaults.set(semanticEndpointing, forKey: Keys.semanticEndpointing) }
    }

    /// Register the app as a login item. Persists the intent AND applies it via
    /// `SMAppService.mainApp` (register/unregister). The system keeps the registration
    /// across launches, so we only act on a change — `didSet` doesn't fire during `init`,
    /// which is exactly what we want (no re-register storm on every launch). Only takes
    /// effect for the packaged `.app`; under `swift run` SMAppService throws and we log.
    public var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            Self.applyLaunchAtLogin(launchAtLogin)
        }
    }

    /// BCP-47-ish language tag for STT/TTS, e.g. "en". Defaults to "en".
    public var language: String {
        didSet { defaults.set(language, forKey: Keys.language) }
    }

    /// Kokoro TTS voice id used for read-aloud (Model B). Defaults to "af_sky".
    public var voice: String {
        didSet { defaults.set(voice, forKey: Keys.voice) }
    }

    /// Swarm / deep-orchestration mode (Phase 8, SECONDARY pillar, DEFAULT OFF). When on,
    /// the app starts the read-only `SwarmObserver` and toggles the "ultracode: " transcript
    /// prepend via `ControlCommand.setUltracodePrefix`. Off by default so a normal turn never
    /// silently triggers a swarm.
    public var swarmMode: Bool {
        didSet { defaults.set(swarmMode, forKey: Keys.swarmMode) }
    }

    /// HUD-only mode (DEFAULT OFF). When on, the app does NOT spawn/supervise its own
    /// voice core — it runs purely as the HUD + menu, connecting to a core that something
    /// else owns (e.g. the voicemode MCP server hosted inside Claude Code, which binds the
    /// status socket). This is the "real voice-coding with Claude Code" setup: Claude Code's
    /// voicemode is the sole core, and flowcode never competes for the socket. (CoreSupervisor
    /// ALSO auto-detects a live core on the socket and skips spawning, so coexistence works
    /// regardless of launch order even with this off; this flag makes it deterministic.)
    public var hudOnlyMode: Bool {
        didSet { defaults.set(hudOnlyMode, forKey: Keys.hudOnlyMode) }
    }

    /// Model B (DEFAULT ON): run as a self-contained voice layer over Claude Code —
    /// flowcode tails the live session transcript and reads each new assistant message
    /// aloud (Kokoro), driving the orb, with NO socket / voicemode / Python core. When
    /// on, the socket path (CoreSupervisor + IPC) is skipped entirely.
    public var readAloudEnabled: Bool {
        didSet { defaults.set(readAloudEnabled, forKey: Keys.readAloud) }
    }

    /// How much of each assistant reply to speak (Off / Full / Compact). Live —
    /// applied by `LocalVoiceController.setReadAloudMode` without a relaunch. Defaults
    /// to `.full` (today's behavior). This is the everyday on/off + "gist" control;
    /// `readAloudEnabled` above is the (experimental) architecture switch.
    public var readAloudMode: ReadAloudMode {
        didSet { defaults.set(readAloudMode.rawValue, forKey: Keys.readAloudMode) }
    }

    /// How a finished reply is announced before it's read (Off / Chime / Spoken). Live —
    /// applied by `LocalVoiceController.setReadyAlert` without a relaunch. Defaults to
    /// `.spoken`: a chime plus a short spoken cue, so a user who looked away during a long
    /// task is called back and then gets the reply (Full or Compact per `readAloudMode`).
    /// The cue is suppressed while Claude Desktop is frontmost (you're already watching).
    public var readyAlert: ReadyAlert {
        didSet { defaults.set(readyAlert.rawValue, forKey: Keys.readyAlert) }
    }

    /// Which app(s) flowcode reads aloud (Claude Code / Claude Desktop / Both). Live —
    /// applied by `LocalVoiceController.setSources`. Defaults to `.both`: it reads
    /// Claude Code's active session AND a frontmost Claude Desktop window. The Claude
    /// Desktop source stays inert until Accessibility is granted, so this never adds a
    /// prompt for read-aloud-only users.
    public var listenTarget: ListenTarget {
        didSet { defaults.set(listenTarget.rawValue, forKey: Keys.listenTarget) }
    }

    // MARK: - Socket path

    /// Optional user override for the IPC socket path. When `nil`/empty the
    /// computed `socketPath` falls back to the default location. Persisted as
    /// a string (empty string means "use default").
    public var socketPathOverride: String? {
        didSet {
            let trimmed = socketPathOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                defaults.set(trimmed, forKey: Keys.socketPath)
            } else {
                defaults.removeObject(forKey: Keys.socketPath)
            }
        }
    }

    /// Absolute filesystem path of the Unix-domain socket joining the app to
    /// the Python voice core. Honors `socketPathOverride` if set; otherwise
    /// defaults to `~/.voicemode/run/flowcode.sock` (home expanded to an
    /// absolute path). Always returns an absolute path string.
    public var socketPath: String {
        if let override = socketPathOverride {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return Self.absolutePath(trimmed)
            }
        }
        return Self.defaultSocketPath()
    }

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Read persisted booleans. `UserDefaults.bool(forKey:)` returns false
        // for missing keys, which is the desired default for all but
        // `streamingChunking` (default true) — handle that one via object
        // presence so a user who turns it off has the choice respected.
        self.semanticEndpointing = defaults.bool(forKey: Keys.semanticEndpointing)
        self.launchAtLogin       = defaults.bool(forKey: Keys.launchAtLogin)
        self.swarmMode           = defaults.bool(forKey: Keys.swarmMode) // default false (missing key -> false)
        self.hudOnlyMode         = defaults.bool(forKey: Keys.hudOnlyMode) // default false (missing key -> false)

        // Model B (read-aloud) is the default experience. Object-presence pattern so a
        // user who turns it off keeps that choice.
        if defaults.object(forKey: Keys.readAloud) != nil {
            self.readAloudEnabled = defaults.bool(forKey: Keys.readAloud)
        } else {
            self.readAloudEnabled = true
        }

        // Read-aloud volume of speech: default Full (today's behavior); honor a stored choice.
        if let raw = defaults.string(forKey: Keys.readAloudMode), let mode = ReadAloudMode(rawValue: raw) {
            self.readAloudMode = mode
        } else {
            self.readAloudMode = .full
        }

        // Ready alert: default Spoken (chime + a short spoken cue); honor a stored choice.
        if let raw = defaults.string(forKey: Keys.readyAlert), let alert = ReadyAlert(rawValue: raw) {
            self.readyAlert = alert
        } else {
            self.readyAlert = .spoken
        }

        // Listen target: default Both (Claude Code + Claude Desktop); honor a stored choice.
        if let raw = defaults.string(forKey: Keys.listenTarget), let target = ListenTarget(rawValue: raw) {
            self.listenTarget = target
        } else {
            self.listenTarget = .both
        }

        // Barge-in is the whole point of flowcode, so default it ON (respect an
        // explicit user choice once they've toggled it). Same object-presence
        // pattern as streamingChunking below.
        if defaults.object(forKey: Keys.bargeInEnabled) != nil {
            self.bargeInEnabled = defaults.bool(forKey: Keys.bargeInEnabled)
        } else {
            self.bargeInEnabled = true
        }

        if defaults.object(forKey: Keys.streamingChunking) != nil {
            self.streamingChunking = defaults.bool(forKey: Keys.streamingChunking)
        } else {
            self.streamingChunking = true // sensible default per contract
        }

        // Language: fall back to "en" when missing or blank.
        let storedLang = defaults.string(forKey: Keys.language)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedLang, !storedLang.isEmpty {
            self.language = storedLang
        } else {
            self.language = Self.defaultLanguage
        }

        // Voice: fall back to the default Kokoro voice when missing or blank.
        let storedVoice = defaults.string(forKey: Keys.voice)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedVoice, !storedVoice.isEmpty {
            self.voice = storedVoice
        } else {
            self.voice = Self.defaultVoice
        }

        // Socket override: nil unless a non-empty value is persisted.
        let storedSocket = defaults.string(forKey: Keys.socketPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedSocket, !storedSocket.isEmpty {
            self.socketPathOverride = storedSocket
        } else {
            self.socketPathOverride = nil
        }
    }

    // MARK: - Launch at login

    /// Apply the login-item intent to the system via `SMAppService.mainApp`.
    /// Idempotent (only acts when the current status disagrees). Failures (e.g. running
    /// from `swift run` rather than a registered `.app`) are logged, not fatal — the
    /// persisted checkmark still reflects the user's intent.
    private static func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            NSLog("flowcode: SMAppService \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Path helpers

    /// Default socket location: `<home>/.voicemode/run/flowcode.sock`.
    private static func defaultSocketPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".voicemode/run/flowcode.sock")
            .path
    }

    /// Resolve a possibly-relative or tilde-prefixed path to an absolute path.
    private static func absolutePath(_ raw: String) -> String {
        // Expand a leading "~" / "~/..." against the current user's home.
        let expanded = (raw as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return (expanded as NSString).standardizingPath
        }
        // Relative path: anchor it to the home directory for determinism
        // (avoids depending on the process's current working directory).
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(expanded).standardizedFileURL.path
    }
}

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
        static let swarmMode           = "flowcode.swarmMode"
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

    /// Register the app as a login item. (The actual SMAppService wiring lives
    /// elsewhere; this flag is the persisted user intent.)
    public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    /// BCP-47-ish language tag for STT/TTS, e.g. "en". Defaults to "en".
    public var language: String {
        didSet { defaults.set(language, forKey: Keys.language) }
    }

    /// Swarm / deep-orchestration mode (Phase 8, SECONDARY pillar, DEFAULT OFF). When on,
    /// the app starts the read-only `SwarmObserver` and toggles the "ultracode: " transcript
    /// prepend via `ControlCommand.setUltracodePrefix`. Off by default so a normal turn never
    /// silently triggers a swarm.
    public var swarmMode: Bool {
        didSet { defaults.set(swarmMode, forKey: Keys.swarmMode) }
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

        // Socket override: nil unless a non-empty value is persisted.
        let storedSocket = defaults.string(forKey: Keys.socketPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedSocket, !storedSocket.isEmpty {
            self.socketPathOverride = storedSocket
        } else {
            self.socketPathOverride = nil
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

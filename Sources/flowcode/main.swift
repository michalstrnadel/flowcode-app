import AppKit
import ApplicationServices
import flowcodeKit

/// Wires the flowcode menu-bar app together: the observable stores, the IPC client
/// (a Unix-domain socket to the Python voice core), the status-item UI, and the
/// microphone permission request.
///
/// flowcode runs as an `.accessory` app — it lives in the menu bar with no Dock
/// icon and no main window. All real-time audio lives in the Python core; this
/// app only observes state (via `IPCClient.messages`) and sends control commands.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let settings = SettingsStore()
    private let store = VoiceSessionStore()
    private let client = IPCClient()              // actor
    private var statusController: StatusItemController?
    private var hud: HUDController?
    // Spawns + supervises the Python voice core as a direct child (mic TCC + no orphans).
    private var coreSupervisor: CoreSupervisor?
    // Model B: self-contained voice layer (reads Claude Code's transcript aloud). When
    // active, the socket/core path above is skipped entirely.
    private var localVoice: LocalVoiceController?
    // Czech read-aloud: on-demand neural voice (download prompt + local server lifecycle).
    private var coquiService: CoquiVoiceService?
    // §7 confirmation gate (default-OFF: inert until a confirm_request actually
    // arrives over the socket, which only happens when the Python gate is enabled).
    private var confirmGate: ConfirmGateController?
    private let commitHotKeyHolder = HotKeyHolder()
    // Model B: global ⌃⌥Space to pause/resume the voice layer.
    private let pauseHotKeyHolder = HotKeyHolder()

    // Phase 8 (swarm orchestration, DEFAULT OFF). The state is always present (cheap,
    // inert; SwarmState.init does no IO and starts no work); the FSEvents observer is
    // only created/started when swarmMode is on AND a Claude session has been resolved.
    private let swarmState = SwarmState()
    private var swarmObserver: SwarmObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if settings.readAloudEnabled {
            // ---- Model B: self-contained voice layer over Claude Code ----
            // flowcode tails the live session transcript and reads each new assistant
            // message aloud (Kokoro), driving the orb. NO socket, NO Python core, and
            // NO microphone (read-aloud doesn't capture) — so no mic prompt either.
            // Czech runs through an on-demand local server; boot the engine in English so
            // a Czech user isn't left pointing at a server that isn't up yet. If Czech was
            // the last choice, bring it up asynchronously below.
            let coqui = CoquiVoiceService(store: store)
            self.coquiService = coqui
            let bootLanguage = (settings.language == "cs") ? "en" : settings.language
            let lv = LocalVoiceController(store: store,
                                         voice: settings.voice,
                                         language: bootLanguage,
                                         listenTarget: settings.listenTarget,
                                         readAloudMode: settings.readAloudMode)
            lv.start()
            self.localVoice = lv

            // Restore a persisted Czech selection: ensure the voice + server, then switch.
            if settings.language == "cs" {
                Task { @MainActor in
                    if await coqui.ensureReady() { lv.setLanguage("cs") }
                    else { self.settings.language = "en" }
                }
            }

            // Global pause/resume hotkey (⌃⌥Space). Carbon RegisterEventHotKey needs no
            // Accessibility grant, so it works even before the user grants dictation perms.
            pauseHotKeyHolder.installIfNeeded(combo: .pauseDefault) { [weak lv] in lv?.togglePause() }

            // First-run nudge: dictation AND Claude Desktop read-aloud need the Accessibility
            // grant. If it isn't granted, ask macOS to show its prompt once so THIS
            // (correctly-signed) app registers itself in the list — the user just flips the
            // toggle, no dragging the app in or hunting stale entries.
            if !AXIsProcessTrusted() {
                // Literal avoids referencing the non-Sendable global kAXTrustedCheckOptionPrompt
                // (its value is exactly this string).
                let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
            }
        } else {
            // ---- Socket path: external voice core (voicemode MCP or spawned runner) ----
            // Request microphone access up front so the TCC grant attributes to flowcode.
            Task { _ = await MicPermission.ensureAccess() }

            let socketPath = settings.socketPath
            let supervisor = CoreSupervisor(socketPath: socketPath, hudOnly: settings.hudOnlyMode)
            supervisor.start()
            self.coreSupervisor = supervisor

            // Project the voice core's live state into the observable store, then start
            // connecting to the status socket (auto-reconnects with backoff).
            store.bind(to: client)
            Task { await client.connect(socketPath: socketPath) }

            // Push the menu's current flag state to the core whenever we (re)connect.
            observeConnection()
        }

        // Build the menu-bar UI.
        statusController = StatusItemController(
            store: store,
            settings: settings,
            onToggleSession: { [weak self] in
                guard let self else { return }
                // In Model B the toggle is "Stop Speaking" (flush the read-aloud queue);
                // on the socket path it starts/stops a converse session.
                if self.settings.readAloudEnabled { self.localVoice?.flush() }
                else { self.toggleSession() }
            },
            onQuit: { NSApp.terminate(nil) },
            onSetFlag: { [weak self] key, enabled in
                guard let self else { return }
                Task { await self.client.send(.setFlag(key: key, value: enabled ? "true" : "false")) }
            },
            onTogglePause: { [weak self] in self?.localVoice?.togglePause() },
            onOpenLog: { [weak self] in self?.openLog() },
            onSetVoice: { [weak self] voice in self?.localVoice?.setVoice(voice) },
            onSetLanguage: { [weak self] lang in
                guard let self else { return }
                if lang == "cs" {
                    // Czech: prompt+download the voice if needed, start its server, then switch.
                    Task { @MainActor in
                        guard let coqui = self.coquiService else { return }
                        if await coqui.ensureReady() {
                            self.localVoice?.setLanguage("cs")
                        } else {
                            self.settings.language = "en"   // user declined / failed → revert the menu
                        }
                    }
                } else {
                    self.localVoice?.setLanguage(lang)
                    self.coquiService?.stopServer()         // free the Czech runtime's memory
                }
            },
            onSetListenTarget: { [weak self] target in self?.localVoice?.setSources(for: target) },
            onSetReadAloudMode: { [weak self] mode in self?.localVoice?.setReadAloudMode(mode) }
        )

        // Orb HUD: the floating orb that reacts to the live voice state.
        let hud = HUDController(store: store, settings: settings)
        self.hud = hud
        hud.start()

        // §7 confirmation gate. The verdict travels back ONLY through this closure
        // (-> ControlCommand.confirm); no voice path can reach it. Default-OFF: this
        // wiring is inert until a confirm_request line arrives (only emitted when the
        // Python VOICEMODE_CONFIRM_GATE is enabled), and the global commit hotkey is
        // registered LAZILY on the first request — never at launch — so with the gate
        // off nothing observable changes.
        let gate = ConfirmGateController(
            sendVerdict: { [weak self] id, verdict in
                guard let self else { return }
                Task { await self.client.send(.confirm(id: id, verdict: verdict.wireValue)) }
            },
            timeoutSeconds: 30.0
        )
        self.confirmGate = gate
        // Fan-out from the single message consumer (NO second AsyncStream awaiter):
        // VoiceSessionStore forwards confirm_request lines here.
        store.onConfirmRequest = { [weak self] message in
            guard let self, let id = message.id else { return }
            // Lazily register the hands-on commit hotkey (Ctrl-Opt-Return) the first
            // time the gate is actually used, so default-OFF registers no global hotkey.
            self.commitHotKeyHolder.installIfNeeded { [weak gate] in gate?.hotkeyPressed() }
            let req = ConfirmRequest(
                id: id,
                command: message.command ?? "",
                risk: RiskTier(rawTolerant: message.risk))
            self.confirmGate?.present(req)
        }

        // Swarm mode (Phase 8) is default-off; only arm observation when explicitly enabled.
        startSwarmIfEnabled()
    }

    /// Tear down the supervised voice core when the app quits (it also self-exits via
    /// its parent-death watchdog).
    func applicationWillTerminate(_ notification: Notification) {
        coreSupervisor?.stop()
        localVoice?.stop()
        coquiService?.stopServer()
    }

    /// Start read-only swarm observation iff swarmMode is on. Inert otherwise.
    ///
    /// Honesty (plan §5/§8): we can only observe the file-tail truth, so we need an actual
    /// `~/.claude/projects/<encoded>` dir + session id to watch. Resolving the *active*
    /// session is a separate concern (a later wiring step / hook ping supplies it); until
    /// then this method no-ops gracefully rather than guessing.
    private func startSwarmIfEnabled() {
        guard settings.swarmMode else { return }
        guard let (projectDir, sessionId) = resolveActiveClaudeSession() else { return }
        let observer = SwarmObserver(state: swarmState, encodedProjectDir: projectDir, sessionId: sessionId)
        observer.start()
        swarmObserver = observer
        // Toggle the "ultracode: " transcript prepend in the core to match the menu setting.
        Task { await client.send(.setUltracodePrefix(true)) }
    }

    /// Resolve the active Claude session to observe. Returns nil until a real resolution
    /// mechanism is wired (deliberately conservative — we never fabricate a path).
    private func resolveActiveClaudeSession() -> (projectDir: String, sessionId: String)? {
        return nil
    }

    /// Open a useful log location in Finder. Model B writes no audit log (that's the
    /// §7/socket path), so prefer the voice-engine logs where read-aloud/dictation
    /// problems actually surface; fall back to flowcode's own dir (created if absent).
    private func openLog() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let voicemodeLogs = home.appendingPathComponent(".voicemode/logs")
        if fm.fileExists(atPath: voicemodeLogs.path) {
            NSWorkspace.shared.open(voicemodeLogs)
            return
        }
        let flowDir = home.appendingPathComponent(".flowcode")
        try? fm.createDirectory(at: flowDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(flowDir)
    }

    /// Start or stop a voice session based on the current session state.
    private func toggleSession() {
        let wantStop = store.sessionActive
        Task { await client.send(wantStop ? .stop : .start) }
    }

    // MARK: - Flag resync on (re)connect

    /// Re-arming observation of `store.connected`. On a rising edge (just connected),
    /// push the menu's current voice-core flags so the live core matches the UI even
    /// after a core restart / reconnect.
    private var wasConnected = false
    private func observeConnection() {
        withObservationTracking {
            _ = store.connected
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handleConnectionChange()
                self?.observeConnection()   // re-arm for the next change
            }
        }
    }

    private func handleConnectionChange() {
        let now = store.connected
        if now && !wasConnected { resyncFlagsToCore() }
        wasConnected = now
    }

    /// Send the three voice-core flags reflecting the current menu state. (Launch-at-Login
    /// is a local login item, not a core flag, so it is not pushed.)
    private func resyncFlagsToCore() {
        let bargeIn = settings.bargeInEnabled
        let streaming = settings.streamingChunking
        let semantic = settings.semanticEndpointing
        Task {
            await client.send(.setFlag(key: SettingsStore.bargeInFlagKey, value: bargeIn ? "true" : "false"))
            await client.send(.setFlag(key: SettingsStore.streamingFlagKey, value: streaming ? "true" : "false"))
            await client.send(.setFlag(key: SettingsStore.semanticFlagKey, value: semantic ? "true" : "false"))
        }
    }
}

// MARK: - Commit hotkey holder

// Small @MainActor holder so AppDelegate can own a GlobalHotKey without exposing
// Carbon types. installIfNeeded is idempotent and registers the global hotkey only on
// first use (lazily), so with the §7 gate disabled NO global hotkey is ever registered.
@MainActor
final class HotKeyHolder {
    private var hotKey: GlobalHotKey?
    func installIfNeeded(combo: GlobalHotKey.KeyCombo = .commitDefault,
                         _ onFire: @escaping @MainActor () -> Void) {
        guard hotKey == nil else { return }
        let hk = GlobalHotKey(onFire: onFire)
        _ = hk.enable(combo)
        hotKey = hk
    }
}

// MARK: - Entry point

// Top-level code is nonisolated under the Swift 6 language mode, but NSApplication
// and AppDelegate are @MainActor. We are provably on the main thread here, so assert
// main-actor isolation. app.run() blocks the closure for the process lifetime, which
// also keeps `delegate` (held weakly by NSApplication) alive.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

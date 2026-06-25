import AppKit
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
    // §7 confirmation gate (default-OFF: inert until a confirm_request actually
    // arrives over the socket, which only happens when the Python gate is enabled).
    private var confirmGate: ConfirmGateController?
    private let commitHotKeyHolder = HotKeyHolder()

    // Phase 8 (swarm orchestration, DEFAULT OFF). The state is always present (cheap,
    // inert; SwarmState.init does no IO and starts no work); the FSEvents observer is
    // only created/started when swarmMode is on AND a Claude session has been resolved.
    private let swarmState = SwarmState()
    private var swarmObserver: SwarmObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request microphone access up front so the TCC grant is attributed to
        // flowcode (the responsible process), not to a child or to the terminal.
        Task { _ = await MicPermission.ensureAccess() }

        // Spawn the Python voice core as our direct child BEFORE connecting, so the
        // socket comes up promptly and the mic TCC grant attributes to flowcode.app.
        // No-op if the core is already running or its binaries are missing.
        let socketPath = settings.socketPath
        let supervisor = CoreSupervisor(socketPath: socketPath)
        supervisor.start()
        self.coreSupervisor = supervisor

        // Project the voice core's live state into the observable store, then start
        // connecting to the status socket (auto-reconnects with backoff).
        store.bind(to: client)
        Task { await client.connect(socketPath: socketPath) }

        // Push the menu's current flag state to the core whenever we (re)connect, so
        // the live core always matches the menu — even after a core restart.
        observeConnection()

        // Build the menu-bar UI.
        statusController = StatusItemController(
            store: store,
            settings: settings,
            onToggleSession: { [weak self] in self?.toggleSession() },
            onQuit: { NSApp.terminate(nil) },
            onSetFlag: { [weak self] key, enabled in
                guard let self else { return }
                Task { await self.client.send(.setFlag(key: key, value: enabled ? "true" : "false")) }
            }
        )

        // Jarvis HUD: the floating orb that reacts to the live voice state.
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
    func installIfNeeded(_ onFire: @escaping @MainActor () -> Void) {
        guard hotKey == nil else { return }
        let hk = GlobalHotKey(onFire: onFire)
        _ = hk.enable()
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

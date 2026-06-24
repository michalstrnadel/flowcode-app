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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request microphone access up front so the TCC grant is attributed to
        // flowcode (the responsible process), not to a child or to the terminal.
        Task { _ = await MicPermission.ensureAccess() }

        // Project the voice core's live state into the observable store, then start
        // connecting to the status socket (auto-reconnects with backoff).
        store.bind(to: client)
        let socketPath = settings.socketPath
        Task { await client.connect(socketPath: socketPath) }

        // Build the menu-bar UI.
        statusController = StatusItemController(
            store: store,
            settings: settings,
            onToggleSession: { [weak self] in self?.toggleSession() },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    /// Start or stop a voice session based on the current session state.
    /// (Feature-flag sync to the core lands with the control handler in a later phase.)
    private func toggleSession() {
        let wantStop = store.sessionActive
        Task { await client.send(wantStop ? .stop : .start) }
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

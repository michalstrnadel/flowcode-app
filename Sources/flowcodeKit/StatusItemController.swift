import AppKit
import Observation

/// Owns the menu-bar `NSStatusItem` and its dropdown menu.
///
/// The controller renders the status button glyph/title from `store.state` and
/// rebuilds the menu header (state + connected) reactively. It uses Observation's
/// `withObservationTracking` to re-arm a render whenever any observed property it
/// reads (`store.state`, `store.connected`, `store.sessionActive`) changes.
///
/// All work touches AppKit, so the whole class is `@MainActor`.
@MainActor
public final class StatusItemController {

    // MARK: Dependencies

    private let store: VoiceSessionStore
    private let settings: SettingsStore
    private let onToggleSession: () -> Void
    private let onQuit: () -> Void

    // MARK: AppKit objects

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    // Header line at the top of the menu (state + connectivity). Disabled so it
    // reads as a label rather than a clickable item.
    private let headerItem = NSMenuItem()

    // Start/Stop entry whose title flips with `store.sessionActive`.
    private let toggleSessionItem = NSMenuItem()

    // Settings toggles. Kept as references so their checkmark state can be
    // refreshed when the underlying setting changes (e.g. via launch-at-login).
    private let bargeInItem = NSMenuItem()
    private let streamingItem = NSMenuItem()
    private let semanticItem = NSMenuItem()
    private let launchAtLoginItem = NSMenuItem()

    // Bridges target/action selectors to Swift closures so the controller can
    // stay a plain final class without exposing @objc methods itself.
    private let coordinator = ActionCoordinator()

    // MARK: Init

    public init(store: VoiceSessionStore,
                settings: SettingsStore,
                onToggleSession: @escaping () -> Void,
                onQuit: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        self.onToggleSession = onToggleSession
        self.onQuit = onQuit

        // Variable-length item so the glyph/title can size naturally.
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        buildMenu()
        statusItem.menu = menu

        // Initial paint, then begin reactive tracking.
        renderButton()
        renderMenuDynamicParts()
        startObserving()
    }

    // Swift 6.1+ isolated deinit: runs on the class's @MainActor isolation, so it can
    // touch the non-Sendable NSStatusItem directly and remove it synchronously.
    isolated deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: Menu construction

    private func buildMenu() {
        menu.autoenablesItems = false

        // Header (state + connected). Non-interactive.
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(.separator())

        // Start / Stop Voice.
        toggleSessionItem.target = coordinator
        toggleSessionItem.action = #selector(ActionCoordinator.invoke(_:))
        coordinator.bind(toggleSessionItem) { [weak self] in
            self?.onToggleSession()
        }
        menu.addItem(toggleSessionItem)

        menu.addItem(.separator())

        // Settings toggles. Each flips its bound Bool and refreshes its checkmark.
        configureToggle(bargeInItem,
                        title: "Barge-In Enabled",
                        get: { [weak self] in self?.settings.bargeInEnabled ?? false },
                        set: { [weak self] new in self?.settings.bargeInEnabled = new })
        menu.addItem(bargeInItem)

        configureToggle(streamingItem,
                        title: "Streaming Chunking",
                        get: { [weak self] in self?.settings.streamingChunking ?? false },
                        set: { [weak self] new in self?.settings.streamingChunking = new })
        menu.addItem(streamingItem)

        configureToggle(semanticItem,
                        title: "Semantic Endpointing",
                        get: { [weak self] in self?.settings.semanticEndpointing ?? false },
                        set: { [weak self] new in self?.settings.semanticEndpointing = new })
        menu.addItem(semanticItem)

        configureToggle(launchAtLoginItem,
                        title: "Launch at Login",
                        get: { [weak self] in self?.settings.launchAtLogin ?? false },
                        set: { [weak self] new in self?.settings.launchAtLogin = new })
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        // Quit.
        let quitItem = NSMenuItem(title: "Quit flowcode", action: nil, keyEquivalent: "q")
        quitItem.target = coordinator
        quitItem.action = #selector(ActionCoordinator.invoke(_:))
        coordinator.bind(quitItem) { [weak self] in
            self?.onQuit()
        }
        menu.addItem(quitItem)
    }

    /// Wires a checkmark toggle item to a getter/setter pair on `settings`.
    private func configureToggle(_ item: NSMenuItem,
                                 title: String,
                                 get: @escaping () -> Bool,
                                 set: @escaping (Bool) -> Void) {
        item.title = title
        item.target = coordinator
        item.action = #selector(ActionCoordinator.invoke(_:))
        item.state = get() ? .on : .off
        coordinator.bind(item) { [weak item] in
            let next = !get()
            set(next)
            item?.state = next ? .on : .off
        }
    }

    // MARK: Rendering

    /// Picks an SF Symbol name (with a text fallback glyph) for a given state.
    private func presentation(for state: VoiceState) -> (symbol: String, fallback: String, label: String) {
        switch state {
        case .idle:
            return ("circle", "○", "Idle")
        case .listening:
            return ("waveform", "≈", "Listening")
        case .processing:
            return ("ellipsis.circle", "…", "Processing")
        case .speaking:
            return ("waveform.circle.fill", "◉", "Speaking")
        case .interrupted:
            return ("exclamationmark.circle", "!", "Interrupted")
        }
    }

    /// Updates the status-bar button's image (or title fallback) for the current state.
    private func renderButton() {
        guard let button = statusItem.button else { return }
        let info = presentation(for: store.state)

        if let image = NSImage(systemSymbolName: info.symbol, accessibilityDescription: info.label) {
            image.isTemplate = true // adopt the menu-bar tint (light/dark aware)
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            // Fallback for environments lacking the SF Symbol.
            button.image = nil
            button.title = info.fallback
            button.imagePosition = .noImage
        }

        // Accessibility / tooltip surface for the current state + connectivity.
        button.toolTip = "flowcode — \(info.label)\(store.connected ? "" : " (disconnected)")"
    }

    /// Refreshes the menu parts that depend on observable store/settings state:
    /// the header label and the Start/Stop title.
    private func renderMenuDynamicParts() {
        let info = presentation(for: store.state)
        let connectivity = store.connected ? "Connected" : "Disconnected"
        headerItem.title = "\(info.label) • \(connectivity)"

        toggleSessionItem.title = store.sessionActive ? "Stop Voice" : "Start Voice"

        // Keep setting checkmarks in sync in case a value changed elsewhere.
        bargeInItem.state = settings.bargeInEnabled ? .on : .off
        streamingItem.state = settings.streamingChunking ? .on : .off
        semanticItem.state = settings.semanticEndpointing ? .on : .off
        launchAtLoginItem.state = settings.launchAtLogin ? .on : .off
    }

    // MARK: Observation

    /// Begins (and continuously re-arms) Observation tracking. The closure reads
    /// the observable properties we care about; when any of them changes,
    /// `onChange` fires, we re-render, then call `startObserving()` again to
    /// re-arm for the next mutation.
    private func startObserving() {
        withObservationTracking {
            // Touch every observable property we depend on so the tracker
            // registers a dependency on each.
            _ = store.state
            _ = store.connected
            _ = store.sessionActive
            _ = settings.bargeInEnabled
            _ = settings.streamingChunking
            _ = settings.semanticEndpointing
            _ = settings.launchAtLogin
        } onChange: { [weak self] in
            // onChange is delivered synchronously at willSet time and may be off
            // the main actor's static context; hop to the main actor to mutate AppKit.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.renderButton()
                self.renderMenuDynamicParts()
                self.startObserving() // re-arm for subsequent changes
            }
        }
    }
}

/// Small target/action bridge: maps an `NSMenuItem`'s selector to a stored closure.
/// Kept private to this file so `StatusItemController` need not expose @objc API.
@MainActor
private final class ActionCoordinator: NSObject {
    // Associates each menu item with the closure to run when it is chosen.
    private var handlers: [ObjectIdentifier: () -> Void] = [:]

    func bind(_ item: NSMenuItem, _ handler: @escaping () -> Void) {
        handlers[ObjectIdentifier(item)] = handler
    }

    @objc func invoke(_ sender: NSMenuItem) {
        handlers[ObjectIdentifier(sender)]?()
    }
}

import AppKit
import Observation

/// Owns the menu-bar `NSStatusItem` and its dropdown menu.
///
/// The menu has two shapes, chosen ONCE at init by `settings.readAloudEnabled` (the mode
/// is fixed for the process lifetime — `main.swift` branches the same way at launch):
///
///  - **Model B (read-aloud, the shipping default):** a clean menu for "flowcode is the
///    voice of Claude Code" — Pause/Resume, Stop Speaking, the voice picker, a dictation
///    hint, Launch at Login, Open Log. The barge-in/streaming/semantic flags are NOT shown
///    here: they only configure the Python voice core, which Model B never runs.
///  - **Socket path (experimental):** the original menu with the three `VOICEMODE_*` flag
///    toggles that drive a live voice core over the control socket.
///
/// The controller renders the status button glyph/title from `store.state` and rebuilds the
/// dynamic parts reactively via Observation's `withObservationTracking`.
///
/// All work touches AppKit, so the whole class is `@MainActor`.
@MainActor
public final class StatusItemController {

    // MARK: Dependencies

    private let store: VoiceSessionStore
    private let settings: SettingsStore
    private let onToggleSession: () -> Void
    private let onQuit: () -> Void
    /// Push a voice-core flag change to the Python core (key = VOICEMODE_* env name).
    /// Only used on the socket path; default no-op keeps the controller usable in isolation.
    private let onSetFlag: (_ key: String, _ enabled: Bool) -> Void
    /// Model B: pause/resume the voice layer (keep the app running).
    private let onTogglePause: () -> Void
    /// Open the audit/log file in Finder.
    private let onOpenLog: () -> Void
    /// Model B: pick the Kokoro read-aloud voice.
    private let onSetVoice: (_ voice: String) -> Void
    /// Model B: pick the spoken language (en/cs) for read-aloud + dictation.
    private let onSetLanguage: (_ language: String) -> Void
    /// Model B: pick which app(s) flowcode reads aloud.
    private let onSetListenTarget: (_ target: ListenTarget) -> Void
    /// Model B: pick how much of each reply to speak (off/full/compact).
    private let onSetReadAloudMode: (_ mode: ReadAloudMode) -> Void

    // MARK: AppKit objects

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    // Header line at the top of the menu (state + connectivity / what it's doing).
    // Disabled so it reads as a label rather than a clickable item.
    private let headerItem = NSMenuItem()

    // Shared: Start/Stop session (socket) — and, in Model B, "Stop Speaking".
    private let toggleSessionItem = NSMenuItem()

    // Model B items.
    private let pauseItem = NSMenuItem()
    private let readAloudItem = NSMenuItem()
    private let voiceParentItem = NSMenuItem()
    private var voiceItems: [String: NSMenuItem] = [:]
    private let readRepliesParentItem = NSMenuItem()
    private var readRepliesItems: [ReadAloudMode: NSMenuItem] = [:]
    private let languageParentItem = NSMenuItem()
    private var languageItems: [String: NSMenuItem] = [:]
    private let listenTargetParentItem = NSMenuItem()
    private var listenTargetItems: [ListenTarget: NSMenuItem] = [:]
    private let dictationHintItem = NSMenuItem()
    private let openLogItem = NSMenuItem()

    // Socket-path settings toggles (experimental voice core).
    private let bargeInItem = NSMenuItem()
    private let streamingItem = NSMenuItem()
    private let semanticItem = NSMenuItem()

    // Shared: login item.
    private let launchAtLoginItem = NSMenuItem()

    // Bridges target/action selectors to Swift closures so the controller can stay a plain
    // final class without exposing @objc methods itself.
    private let coordinator = ActionCoordinator()

    /// Curated Kokoro voices offered in the Model B voice picker.
    private struct VoiceOption { let id: String; let label: String }
    private static let voiceOptions: [VoiceOption] = [
        .init(id: "af_sky",      label: "Sky — US, female"),
        .init(id: "af_bella",    label: "Bella — US, female"),
        .init(id: "af_nicole",   label: "Nicole — US, female"),
        .init(id: "af_sarah",    label: "Sarah — US, female"),
        .init(id: "am_adam",     label: "Adam — US, male"),
        .init(id: "am_michael",  label: "Michael — US, male"),
        .init(id: "bf_emma",     label: "Emma — UK, female"),
        .init(id: "bf_isabella", label: "Isabella — UK, female"),
        .init(id: "bm_george",   label: "George — UK, male"),
        .init(id: "bm_lewis",    label: "Lewis — UK, male"),
    ]

    /// Spoken languages offered in the Model B menu. `id` is the persisted tag.
    private static let languageOptions: [VoiceOption] = [
        .init(id: "en", label: "English"),
        .init(id: "cs", label: "Čeština"),
    ]

    /// Read-aloud volume-of-speech modes, in menu order.
    private static let readAloudModeOptions: [(mode: ReadAloudMode, label: String)] = [
        (mode: .full,    label: "Full reply"),
        (mode: .compact, label: "Compact (gist)"),
        (mode: .off,     label: "Off — silent"),
    ]

    /// Which app(s) to read aloud, in menu order.
    private static let listenTargetOptions: [(target: ListenTarget, label: String)] = [
        (target: .claudeCode,    label: "Claude Code"),
        (target: .claudeDesktop, label: "Claude Desktop (experimental)"),
        (target: .both,          label: "Both"),
    ]

    // MARK: Init

    public init(store: VoiceSessionStore,
                settings: SettingsStore,
                onToggleSession: @escaping () -> Void,
                onQuit: @escaping () -> Void,
                onSetFlag: @escaping (_ key: String, _ enabled: Bool) -> Void = { _, _ in },
                onTogglePause: @escaping () -> Void = {},
                onOpenLog: @escaping () -> Void = {},
                onSetVoice: @escaping (_ voice: String) -> Void = { _ in },
                onSetLanguage: @escaping (_ language: String) -> Void = { _ in },
                onSetListenTarget: @escaping (_ target: ListenTarget) -> Void = { _ in },
                onSetReadAloudMode: @escaping (_ mode: ReadAloudMode) -> Void = { _ in }) {
        self.store = store
        self.settings = settings
        self.onToggleSession = onToggleSession
        self.onQuit = onQuit
        self.onSetFlag = onSetFlag
        self.onTogglePause = onTogglePause
        self.onOpenLog = onOpenLog
        self.onSetVoice = onSetVoice
        self.onSetLanguage = onSetLanguage
        self.onSetListenTarget = onSetListenTarget
        self.onSetReadAloudMode = onSetReadAloudMode

        // Variable-length item so the glyph/title can size naturally.
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        buildMenu()
        statusItem.menu = menu

        // Initial paint, then begin reactive tracking.
        renderButton()
        renderMenuDynamicParts()
        startObserving()
    }

    // No deinit: this controller lives for the whole app lifetime (held by AppDelegate),
    // and macOS reclaims the status item when the process exits. (We avoid `isolated
    // deinit` — a production Swift 6.1 compiler refuses to enable it — and a plain
    // nonisolated deinit can't call the @MainActor `removeStatusItem`.)

    // MARK: Menu construction

    private func buildMenu() {
        menu.autoenablesItems = false
        if settings.readAloudEnabled {
            buildReadAloudMenu()
        } else {
            buildSocketMenu()
        }
    }

    /// Model B menu: the shipping "voice of Claude Code" experience.
    private func buildReadAloudMenu() {
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(.separator())

        // Pause / Resume the whole voice layer (keeps the app running).
        bind(pauseItem, key: "p") { [weak self] in self?.onTogglePause() }
        menu.addItem(pauseItem)

        // Stop the current utterance now (reuses the session-toggle closure, which maps
        // to LocalVoiceController.flush() in main.swift). Enabled only while speaking.
        toggleSessionItem.title = "Stop Speaking"
        bind(toggleSessionItem) { [weak self] in self?.onToggleSession() }
        menu.addItem(toggleSessionItem)

        menu.addItem(.separator())

        // Read replies ▸ Full / Compact / Off — the everyday "how much to speak" control
        // (live; no relaunch). "Off" silences replies but keeps dictation working.
        buildRadioSubmenu(parent: readRepliesParentItem,
                          title: "Read replies",
                          options: Self.readAloudModeOptions.map { (key: $0.mode, label: $0.label) },
                          into: &readRepliesItems) { [weak self] mode in
            guard let self else { return }
            self.settings.readAloudMode = mode
            self.onSetReadAloudMode(mode)
        }

        // Voice picker submenu (Kokoro / English voices).
        voiceParentItem.title = "Voice"
        let voiceMenu = NSMenu()
        for opt in Self.voiceOptions {
            let item = NSMenuItem()
            item.title = opt.label
            let id = opt.id
            bind(item) { [weak self] in
                guard let self else { return }
                self.settings.voice = id
                self.onSetVoice(id)
                self.refreshVoiceChecks()
            }
            voiceMenu.addItem(item)
            voiceItems[id] = item
        }
        voiceParentItem.submenu = voiceMenu
        menu.addItem(voiceParentItem)

        // Language ▸ English / Čeština — read-aloud engine + dictation (live).
        buildRadioSubmenu(parent: languageParentItem,
                          title: "Language",
                          options: Self.languageOptions.map { (key: $0.id, label: $0.label) },
                          into: &languageItems) { [weak self] lang in
            guard let self else { return }
            self.settings.language = lang
            self.onSetLanguage(lang)
        }

        // Listen to ▸ Claude Code / Claude Desktop / Both (live).
        buildRadioSubmenu(parent: listenTargetParentItem,
                          title: "Listen to",
                          options: Self.listenTargetOptions.map { (key: $0.target, label: $0.label) },
                          into: &listenTargetItems) { [weak self] target in
            guard let self else { return }
            self.settings.listenTarget = target
            self.onSetListenTarget(target)
        }

        // Non-clickable hint for push-to-talk dictation.
        dictationHintItem.title = "Hold Right Option (⌥) to dictate"
        dictationHintItem.isEnabled = false
        menu.addItem(dictationHintItem)

        menu.addItem(.separator())

        // Read messages aloud (persisted) — the experimental architecture switch. Off
        // drops to the external voice-core path; relaunch to apply.
        configureToggle(readAloudItem,
                        title: "Read messages aloud",
                        flagKey: nil,
                        get: { [weak self] in self?.settings.readAloudEnabled ?? true },
                        set: { [weak self] new in self?.settings.readAloudEnabled = new })
        readAloudItem.toolTip = "Experimental architecture switch — takes effect after relaunch. Use “Read replies › Off” to just mute."
        menu.addItem(readAloudItem)

        configureToggle(launchAtLoginItem,
                        title: "Launch at Login",
                        flagKey: nil,
                        get: { [weak self] in self?.settings.launchAtLogin ?? false },
                        set: { [weak self] new in self?.settings.launchAtLogin = new })
        menu.addItem(launchAtLoginItem)

        openLogItem.title = "Open Log…"
        bind(openLogItem) { [weak self] in self?.onOpenLog() }
        menu.addItem(openLogItem)

        menu.addItem(.separator())

        addQuitItem()
    }

    /// Socket-path menu (experimental voice core): the original layout with the three
    /// `VOICEMODE_*` flag toggles. Kept identical to the pre-Model-B menu.
    private func buildSocketMenu() {
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(.separator())

        bind(toggleSessionItem) { [weak self] in self?.onToggleSession() }
        menu.addItem(toggleSessionItem)

        menu.addItem(.separator())

        configureToggle(bargeInItem,
                        title: "Barge-In Enabled",
                        flagKey: SettingsStore.bargeInFlagKey,
                        get: { [weak self] in self?.settings.bargeInEnabled ?? false },
                        set: { [weak self] new in self?.settings.bargeInEnabled = new })
        menu.addItem(bargeInItem)

        configureToggle(streamingItem,
                        title: "Streaming Chunking",
                        flagKey: SettingsStore.streamingFlagKey,
                        get: { [weak self] in self?.settings.streamingChunking ?? false },
                        set: { [weak self] new in self?.settings.streamingChunking = new })
        menu.addItem(streamingItem)

        configureToggle(semanticItem,
                        title: "Semantic Endpointing",
                        flagKey: SettingsStore.semanticFlagKey,
                        get: { [weak self] in self?.settings.semanticEndpointing ?? false },
                        set: { [weak self] new in self?.settings.semanticEndpointing = new })
        menu.addItem(semanticItem)

        configureToggle(launchAtLoginItem,
                        title: "Launch at Login",
                        flagKey: nil,
                        get: { [weak self] in self?.settings.launchAtLogin ?? false },
                        set: { [weak self] new in self?.settings.launchAtLogin = new })
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        addQuitItem()
    }

    private func addQuitItem() {
        let quitItem = NSMenuItem(title: "Quit flowcode", action: nil, keyEquivalent: "q")
        bind(quitItem) { [weak self] in self?.onQuit() }
        menu.addItem(quitItem)
    }

    /// Bind a plain (non-toggle) item to a closure, optionally with a key equivalent.
    private func bind(_ item: NSMenuItem, key: String = "", _ handler: @escaping () -> Void) {
        item.target = coordinator
        item.action = #selector(ActionCoordinator.invoke(_:))
        if !key.isEmpty { item.keyEquivalent = key }
        coordinator.bind(item, handler)
    }

    /// Build a checkmark "radio" submenu under `parent`, registering each item in `items`
    /// so the current selection can be ticked on render. `choose` runs on selection; the
    /// checkmarks themselves are refreshed reactively via Observation.
    private func buildRadioSubmenu<Key: Hashable>(parent: NSMenuItem,
                                                  title: String,
                                                  options: [(key: Key, label: String)],
                                                  into items: inout [Key: NSMenuItem],
                                                  choose: @escaping (Key) -> Void) {
        parent.title = title
        let sub = NSMenu()
        for opt in options {
            let item = NSMenuItem()
            item.title = opt.label
            let key = opt.key
            bind(item) { choose(key) }
            sub.addItem(item)
            items[key] = item
        }
        parent.submenu = sub
        menu.addItem(parent)
    }

    /// Wires a checkmark toggle item to a getter/setter pair on `settings`. When
    /// `flagKey` is non-nil, the new value is also pushed to the live voice core via
    /// `onSetFlag` so the menu actually reconfigures the running session.
    private func configureToggle(_ item: NSMenuItem,
                                 title: String,
                                 flagKey: String?,
                                 get: @escaping () -> Bool,
                                 set: @escaping (Bool) -> Void) {
        item.title = title
        item.target = coordinator
        item.action = #selector(ActionCoordinator.invoke(_:))
        item.state = get() ? .on : .off
        coordinator.bind(item) { [weak self, weak item] in
            let next = !get()
            set(next)
            item?.state = next ? .on : .off
            if let flagKey { self?.onSetFlag(flagKey, next) }
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

        // Paused (Model B) gets its own glyph so the menu bar shows the app is muted.
        let paused = settings.readAloudEnabled && store.paused
        let symbol = paused ? "pause.circle" : presentation(for: store.state).symbol
        let fallback = paused ? "❙❙" : presentation(for: store.state).fallback
        let label = paused ? "Paused" : presentation(for: store.state).label

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            image.isTemplate = true // adopt the menu-bar tint (light/dark aware)
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.image = nil
            button.title = fallback
            button.imagePosition = .noImage
        }

        button.toolTip = "flowcode — \(label)\(store.connected || settings.readAloudEnabled ? "" : " (disconnected)")"
    }

    /// Refreshes the menu parts that depend on observable store/settings state.
    private func renderMenuDynamicParts() {
        if settings.readAloudEnabled {
            renderReadAloudParts()
        } else {
            renderSocketParts()
        }
    }

    /// Model B dynamic parts: a friendly state header + Pause/Resume + Stop Speaking.
    private func renderReadAloudParts() {
        let paused = store.paused
        let glyph: String
        let statusText: String
        if let override = store.statusOverride, !override.isEmpty {
            glyph = "↓"
            statusText = override
        } else if paused {
            glyph = "❙❙"
            statusText = "Paused — tap Resume"
        } else {
            glyph = presentation(for: store.state).fallback
            switch store.state {
            case .idle:        statusText = "Ready — listening to Claude Code"
            case .listening:   statusText = "Listening — dictating"
            case .processing:  statusText = "Transcribing…"
            case .speaking:    statusText = "Speaking — reading Claude's reply"
            case .interrupted: statusText = "Interrupted"
            }
        }
        headerItem.title = "\(glyph)  \(statusText)"

        pauseItem.title = paused ? "Resume Voice" : "Pause Voice"
        toggleSessionItem.isEnabled = (store.state == .speaking) && !paused

        readAloudItem.state = settings.readAloudEnabled ? .on : .off
        launchAtLoginItem.state = settings.launchAtLogin ? .on : .off
        refreshVoiceChecks()
        refreshReadRepliesChecks()
        refreshLanguageChecks()
        refreshListenTargetChecks()
    }

    /// Socket-path dynamic parts (unchanged from the pre-Model-B menu).
    private func renderSocketParts() {
        let info = presentation(for: store.state)

        // In HUD-only mode the "core" is Claude Code's voicemode MCP, which only exists
        // while a `claude` session is running — so "disconnected" is the normal waiting
        // state, not an error. Word it that way.
        let connectivity: String
        if store.connected {
            connectivity = "Connected"
        } else {
            connectivity = settings.hudOnlyMode ? "Waiting for Claude Code…" : "Disconnected"
        }
        headerItem.title = "\(info.fallback)  \(info.label) • \(connectivity)"

        if settings.hudOnlyMode {
            toggleSessionItem.isEnabled = false
            toggleSessionItem.title = store.connected
                ? "Voice runs in Claude Code"
                : "Run `claude` to connect"
        } else {
            toggleSessionItem.isEnabled = store.connected
            toggleSessionItem.title = store.connected
                ? (store.sessionActive ? "Stop Voice" : "Start Voice")
                : "Start Voice (core offline)"
        }

        bargeInItem.state = settings.bargeInEnabled ? .on : .off
        streamingItem.state = settings.streamingChunking ? .on : .off
        semanticItem.state = settings.semanticEndpointing ? .on : .off
        launchAtLoginItem.state = settings.launchAtLogin ? .on : .off
    }

    /// Tick the voice item matching the persisted setting; clear the rest.
    private func refreshVoiceChecks() {
        let current = settings.voice
        for (id, item) in voiceItems {
            item.state = (id == current) ? .on : .off
        }
    }

    private func refreshReadRepliesChecks() {
        for (mode, item) in readRepliesItems { item.state = (mode == settings.readAloudMode) ? .on : .off }
    }

    private func refreshLanguageChecks() {
        for (id, item) in languageItems { item.state = (id == settings.language) ? .on : .off }
    }

    private func refreshListenTargetChecks() {
        for (target, item) in listenTargetItems { item.state = (target == settings.listenTarget) ? .on : .off }
    }

    // MARK: Observation

    /// Begins (and continuously re-arms) Observation tracking. The closure reads the
    /// observable properties we depend on; when any changes, `onChange` fires, we
    /// re-render, then re-arm.
    private func startObserving() {
        withObservationTracking {
            _ = store.state
            _ = store.connected
            _ = store.sessionActive
            _ = store.paused
            _ = store.statusOverride
            _ = settings.bargeInEnabled
            _ = settings.streamingChunking
            _ = settings.semanticEndpointing
            _ = settings.launchAtLogin
            _ = settings.readAloudEnabled
            _ = settings.voice
            _ = settings.readAloudMode
            _ = settings.language
            _ = settings.listenTarget
        } onChange: { [weak self] in
            // onChange is delivered synchronously at willSet time and may be off the main
            // actor's static context; hop to the main actor to mutate AppKit.
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

import AppKit

// Minimal scaffold: an accessory (no Dock icon) menu-bar app with an NSStatusItem.
// Phase 1 replaces this with the SwiftUI @main App + @NSApplicationDelegateAdaptor,
// @Observable stores, mic TCC, the embedded-venv spawn, and the UDS status reader.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◉"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "flowcode (scaffold)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit flowcode",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        statusItem.menu = menu
    }
}

// Top-level code in main.swift runs on the main thread but is nonisolated under the
// Swift 6 language mode, while NSApplication / AppDelegate are @MainActor. We are
// provably on the main thread here, so assert main-actor isolation to call into them.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

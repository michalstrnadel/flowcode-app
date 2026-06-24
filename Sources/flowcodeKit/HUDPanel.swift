//
//  HUDPanel.swift
//  flowcode
//
//  The floating, non-activating panel that hosts the audio-reactive orb HUD.
//
//  The panel must behave like a true heads-up overlay: it floats above normal
//  windows, joins every Space and full-screen context, never steals key/main
//  status, and is fully click-through. Showing it must NOT bring flowcode to the
//  foreground — the user keeps working in whatever app they're in. To guarantee
//  that, we order it front with `orderFrontRegardless()` and NEVER call
//  `NSApp.activate(...)`.
//
//  All AppKit access is main-actor isolated.
//

import AppKit

// MARK: - HUDPanel

/// Owns a borderless, non-activating `NSPanel` that hosts the orb's content view.
///
/// The panel is sized ~220x220pt and positioned near the top-center of the
/// target screen. It is transparent (so only the orb/glow shows), shadowless,
/// and click-through. Showing/hiding never changes app activation.
@MainActor
public final class HUDPanel {

    // MARK: Constants

    /// The fixed HUD size in points. Square so the orb's glow has equal margins.
    private static let panelSize = NSSize(width: 220, height: 220)

    /// Vertical inset from the top of the screen's visible frame to the top edge
    /// of the panel. Keeps the orb clear of the menu bar / notch area.
    private static let topInset: CGFloat = 80

    // MARK: Stored properties

    /// The hosted content view (the Metal orb view in practice).
    private let contentView: NSView

    /// The backing panel. A subclass overriding `canBecomeKey/Main` so it can
    /// never take focus even though it is ordered front.
    private let panel: NonActivatingPanel

    // MARK: Init

    /// Creates the panel and installs `contentView` as its content view.
    /// The panel is fully configured here but stays hidden until `show(on:)`.
    public init(contentView: NSView) {
        self.contentView = contentView

        // Initial frame is provisional; `show(on:)` recomputes the real position
        // for the chosen screen. Borderless + non-activating is the core of the
        // HUD behavior: borderless removes chrome, nonactivatingPanel keeps the
        // owning app in the background when the panel is shown/clicked.
        let initialFrame = NSRect(origin: .zero, size: Self.panelSize)
        self.panel = NonActivatingPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        configurePanel()
        installContentView()
    }

    // MARK: Configuration

    /// Applies the exact HUD-overlay configuration required by the contract.
    private func configurePanel() {
        // Float above ordinary windows, at the status-bar level (above normal
        // floating windows but cooperating with the menu-bar layer).
        panel.isFloatingPanel = true
        panel.level = .statusBar

        // Fully transparent background so only the orb's pixels are visible.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        // Click-through: the HUD is purely decorative and must never intercept
        // mouse events from the app behind it.
        panel.ignoresMouseEvents = true

        // Don't participate in window restoration / persisted frames.
        panel.isRestorable = false
        panel.hidesOnDeactivate = false

        // Join every Space and overlay full-screen apps; stay put across Space
        // switches rather than animating with them.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Belt-and-suspenders: even though the subclass refuses key/main, make
        // sure the title bar machinery is fully inert for a borderless panel.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
    }

    /// Installs the hosted content view, pinned to fill the panel's content area.
    private func installContentView() {
        // Make the content view layer-backed so a transparent/Metal child
        // composites correctly against the clear panel.
        contentView.wantsLayer = true
        contentView.translatesAutoresizingMaskIntoConstraints = false

        guard let container = panel.contentView else {
            // A configured NSPanel always has a content view; if AppKit ever
            // returns nil we simply skip — `show` will still order an empty panel.
            return
        }
        container.wantsLayer = true
        container.addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: container.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: Visibility

    /// Positions the panel near the top-center of `screen` (or the main screen
    /// when `nil`) and orders it front WITHOUT activating the app.
    ///
    /// - Parameter screen: Target screen; falls back to `NSScreen.main`, then to
    ///   the first available screen.
    public func show(on screen: NSScreen?) {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        positionPanel(on: targetScreen)

        // CRITICAL: order front without activating. `orderFrontRegardless()`
        // shows the panel even while another app is active, and because the
        // panel is non-activating and refuses key/main, flowcode stays in the
        // background. We must never call NSApp.activate here.
        panel.orderFrontRegardless()
    }

    /// Removes the panel from the screen. Safe to call when already hidden.
    public func hide() {
        panel.orderOut(nil)
    }

    /// Whether the panel is currently on screen.
    public var isVisible: Bool {
        panel.isVisible
    }

    // MARK: Positioning

    /// Computes and applies a top-center frame for the given screen.
    private func positionPanel(on screen: NSScreen?) {
        let size = Self.panelSize

        // Use the visible frame (excludes menu bar / Dock) so the orb sits in
        // usable space. Fall back to a zero-origin rect of the panel's own size
        // if no screen is available (e.g. headless), which is harmless.
        let area = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)

        // Horizontally centered.
        let originX = area.minX + (area.width - size.width) / 2
        // Near the top: inset from the top edge of the visible frame.
        // In Cocoa, y grows upward, so "top minus inset minus height".
        let originY = area.maxY - Self.topInset - size.height

        let frame = NSRect(x: originX.rounded(), y: originY.rounded(),
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: false)
    }
}

// MARK: - NonActivatingPanel

/// An `NSPanel` that can never become key or main, so ordering it front never
/// shifts focus away from the user's current app. Paired with the
/// `.nonactivatingPanel` style mask and `orderFrontRegardless()` this yields a
/// true non-activating HUD overlay.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

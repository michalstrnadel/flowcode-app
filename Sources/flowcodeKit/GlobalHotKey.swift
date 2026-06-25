//
//  GlobalHotKey.swift
//  flowcode — system-framework global hotkey (Carbon RegisterEventHotKey).
//
//  A hands-on COMMIT hotkey for the §7 gate: pressing it confirms the foregrounded
//  request without touching the mouse. Uses only the Carbon HIToolbox API (a system
//  framework — NO external SwiftPM dependency), which is the still-supported path for
//  process-global hotkeys on macOS.
//
//  Concurrency: @MainActor. The Carbon event handler runs on the main run loop, so
//  the trampoline hops onto the main actor before invoking the Swift callback. Clean
//  unregister on `disable()` / deinit (no dangling handler, no leaked hotkey ref).
//
//  This is a GUI-session facility (a registered hotkey needs a running event loop and
//  Accessibility/secure-input context), so end-to-end firing is a manual demo. The
//  registration/unregistration lifecycle and keycode mapping are headless-constructible.
//

import Foundation
import Carbon.HIToolbox

@MainActor
public final class GlobalHotKey {

    /// A minimal, Carbon-free description of the desired chord, so callers (and tests)
    /// don't import Carbon. Maps to Carbon virtual keycodes + modifier mask internally.
    public struct KeyCombo: Sendable, Equatable {
        public let keyCode: UInt32          // Carbon virtual key code (kVK_*)
        public let modifiers: UInt32        // Carbon modifier mask (cmdKey, optionKey, ...)
        public init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        /// Default commit chord: Control-Option-Return. Chosen to be unlikely to
        /// collide and impossible to trigger by speech.
        public static let commitDefault = KeyCombo(
            keyCode: UInt32(kVK_Return),
            modifiers: UInt32(controlKey | optionKey))

        /// Default pause/resume chord (Model B): Control-Option-Space. Global, needs no
        /// Accessibility grant, and cannot be triggered by speech.
        public static let pauseDefault = KeyCombo(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey))
    }

    /// Invoked on the main actor when the hotkey fires.
    private let onFire: @MainActor () -> Void

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var registered = false

    /// A process-unique signature/id pair so multiple hotkeys don't collide.
    private static var nextID: UInt32 = 1
    private let hotKeyID: EventHotKeyID

    public init(onFire: @escaping @MainActor () -> Void) {
        self.onFire = onFire
        let sig: UInt32 = 0x464C4F57 // 'FLOW'
        let id = GlobalHotKey.nextID
        GlobalHotKey.nextID &+= 1
        self.hotKeyID = EventHotKeyID(signature: sig, id: id)
    }

    isolated deinit {
        // isolated deinit (Swift 6.1+) runs on the MainActor, so it may touch the
        // @MainActor-isolated Carbon refs directly. Mirrors StatusItemController's
        // isolated-deinit teardown and avoids the "non-Sendable EventHotKeyRef? from
        // nonisolated deinit" whole-module build error under Swift 6.
        if let handler = eventHandler { RemoveEventHandler(handler) }
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
    }

    /// Register the global hotkey. Returns true on success. Idempotent.
    @discardableResult
    public func enable(_ combo: KeyCombo = .commitDefault) -> Bool {
        guard !registered else { return true }

        // Install one application-level handler for hotkey-pressed events.
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            GlobalHotKey.handlerCallback,
            1,
            &spec,
            selfPtr,
            &eventHandler)
        guard installStatus == noErr else { return false }

        let regStatus = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef)
        guard regStatus == noErr else {
            if let handler = eventHandler { RemoveEventHandler(handler); eventHandler = nil }
            return false
        }

        registered = true
        return true
    }

    /// Unregister and remove the handler. Idempotent.
    public func disable() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let handler = eventHandler { RemoveEventHandler(handler); eventHandler = nil }
        registered = false
    }

    public var isEnabled: Bool { registered }

    // MARK: - Carbon trampoline

    /// C callback signature. Recovers `self` from the userData pointer and dispatches
    /// the fire onto the main actor.
    private static let handlerCallback: EventHandlerUPP = { _, eventRef, userData -> OSStatus in
        guard let userData, let eventRef else { return noErr }
        // Extract the fired hotkey id to confirm it's ours.
        var firedID = EventHotKeyID()
        let err = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &firedID)
        let instance = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        if err == noErr {
            // Only fire for this instance's id.
            let myID = MainActor.assumeIsolated { instance.hotKeyID }
            guard firedID.signature == myID.signature, firedID.id == myID.id else {
                return noErr
            }
        }
        // Hop to the main actor to run the Swift callback.
        Task { @MainActor in instance.onFire() }
        return noErr
    }
}

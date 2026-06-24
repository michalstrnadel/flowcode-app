//
//  ConfirmGateController.swift
//  flowcode — §7 zero-trust confirmation gate controller (app side).
//
//  When the Python core emits a `confirm_request`, this controller:
//    * surfaces a foregrounded alert showing the VERBATIM (already-redacted) command,
//    * makes CANCEL the default button and lets Esc cancel (so an absent / fat-fingered
//      user defaults to DENY),
//    * for the `.elevated` tier additionally requires LocalAuthentication
//      (Touch ID via deviceOwnerAuthenticationWithBiometrics, falling back to
//      deviceOwnerAuthentication / device passcode),
//    * starts a hard timeout that resolves to DENY,
//    * ducks/flags TTS while a prompt is on screen (so the assistant's own speech
//      cannot be heard as a "yes"),
//    * sends the verdict back ONLY via an injected closure mapped to
//      `ControlCommand.confirm(id:verdict:)`, and audits every outcome.
//
//  HARD INVARIANT: there is NO method on this type that lets a voice/transcript path
//  set a verdict. The only entry points that resolve a request are: a non-voice button
//  click, the commit hotkey, a successful Touch ID, or the timeout (which DENIES).
//
//  The button/Touch-ID/timeout DECISION LOGIC is factored into the pure, headless
//  `ConfirmDecisionEngine` so the selftest can verify the default-cancel and
//  elevated-needs-auth invariants without a GUI.
//

import Foundation
import Observation

// MARK: - Pure decision engine (headless-testable)

/// Pure resolver: given a request, a raw gesture, and (for elevated) an auth result,
/// produce the audit outcome. No UI, no Date, no I/O. This is the security core.
public struct ConfirmDecisionEngine: Sendable {

    /// The non-voice gesture that attempted to commit. `.none` represents "no gesture"
    /// (used for the timeout path). There is deliberately no `.voice` case.
    public enum Gesture: Sendable, Equatable {
        case clickConfirm
        case hotkey
        case clickCancel
        case esc
        case timeout
    }

    public init() {}

    /// Resolve a gesture into an outcome.
    ///
    /// - For `.elevated`, an approval gesture only yields an approval outcome when
    ///   `authenticated == true`; otherwise it DENIES (failed/declined Touch ID).
    /// - Cancel / Esc / timeout always DENY regardless of tier.
    /// - The default (no explicit approval) is always DENY.
    public func resolve(
        risk: RiskTier,
        gesture: Gesture,
        authenticated: Bool
    ) -> ConfirmOutcome {
        switch gesture {
        case .clickCancel, .esc:
            return .denied
        case .timeout:
            return .timedOut
        case .clickConfirm, .hotkey:
            if risk.requiresStrongAuth {
                // Elevated: a click/hotkey is necessary but NOT sufficient — strong
                // auth must have succeeded, and we record it as `.authenticated`.
                return authenticated ? .authenticated : .denied
            }
            return gesture == .hotkey ? .confirmedHotkey : .confirmedClick
        }
    }

    /// Whether this tier requires a strong-auth challenge before an approval counts.
    public func requiresAuth(_ risk: RiskTier) -> Bool { risk.requiresStrongAuth }
}

// MARK: - TTS ducking hook

/// Injected hook the controller uses to silence/flag TTS while a prompt is up, so the
/// assistant's own voice cannot be captured as agreement. `setDucked(true)` on show,
/// `setDucked(false)` on resolve. Default implementation is a no-op.
public struct TTSDuck: Sendable {
    public let setDucked: @Sendable (Bool) -> Void
    public init(setDucked: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.setDucked = setDucked
    }
}

// MARK: - Authenticator abstraction (so the selftest can inject a fake)

/// Abstracts LocalAuthentication so logic is testable without biometric hardware.
public protocol DeviceAuthenticator: Sendable {
    /// Prompt for biometric / device-owner auth. Calls back with success on the main actor.
    @MainActor func authenticate(reason: String, completion: @escaping @MainActor (Bool) -> Void)
}

// MARK: - Controller

@MainActor
@Observable
public final class ConfirmGateController {

    // MARK: Observable UI state

    /// The request currently being prompted, or nil when idle. The UI binds to this.
    public private(set) var pending: ConfirmRequest?

    /// True while an elevated request is awaiting Touch ID (UI can show a spinner).
    public private(set) var awaitingAuth: Bool = false

    // MARK: Injected collaborators

    /// Sends the verdict to the core. Wired to `client.send(.confirm(id:verdict:))`.
    /// This is the ONLY channel by which a verdict leaves the controller.
    private let sendVerdict: @MainActor (_ id: String, _ verdict: ConfirmVerdict) -> Void
    private let audit: AuditLog
    private let duck: TTSDuck
    private let authenticator: DeviceAuthenticator
    private let engine = ConfirmDecisionEngine()
    /// Injected clock for audit timestamps (kept off the pure path; production uses Date).
    private let now: @Sendable () -> Double
    /// How long a prompt stays open before auto-denying.
    private let timeoutSeconds: Double

    private var timeoutTask: Task<Void, Never>?

    public init(
        sendVerdict: @escaping @MainActor (_ id: String, _ verdict: ConfirmVerdict) -> Void,
        audit: AuditLog = AuditLog(),
        duck: TTSDuck = TTSDuck(),
        authenticator: DeviceAuthenticator? = nil,
        timeoutSeconds: Double = 30.0,
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.sendVerdict = sendVerdict
        self.audit = audit
        self.duck = duck
        self.authenticator = authenticator ?? LocalAuthAuthenticator()
        self.timeoutSeconds = timeoutSeconds
        self.now = now
    }

    // MARK: Entry point (called by the IPC reader when a confirm_request arrives)

    /// Begin prompting for `request`. If another request is already pending, the new
    /// one is denied immediately (we never queue silently — the core can re-ask).
    public func present(_ request: ConfirmRequest) {
        guard pending == nil else {
            // Busy: deny the newcomer rather than stack prompts.
            sendVerdict(request.id, .deny)
            audit.append(command: request.command, risk: request.risk,
                         outcome: .denied, epoch: now())
            return
        }
        pending = request
        duck.setDucked(true)             // silence TTS while the prompt is up
        startTimeout(for: request)
        showAlert(for: request)
    }

    // MARK: Non-voice gesture handlers (the ONLY approval entry points)

    /// User clicked Confirm (explicit, non-default button).
    public func userClickedConfirm() { handleApprovalGesture(.clickConfirm) }

    /// User pressed the commit hotkey (hands-on, non-voice).
    public func hotkeyPressed() { handleApprovalGesture(.hotkey) }

    /// User clicked Cancel (the DEFAULT button).
    public func userClickedCancel() { resolveImmediate(.clickCancel) }

    /// User pressed Esc.
    public func userPressedEsc() { resolveImmediate(.esc) }

    // MARK: Resolution

    private func handleApprovalGesture(_ gesture: ConfirmDecisionEngine.Gesture) {
        guard let request = pending else { return }
        if engine.requiresAuth(request.risk) {
            // Elevated: a click/hotkey is necessary but not sufficient — challenge first.
            awaitingAuth = true
            authenticator.authenticate(
                reason: "Confirm a high-risk command: \(request.command)"
            ) { [weak self] ok in
                guard let self else { return }
                self.awaitingAuth = false
                // Re-validate we're still on the same request (it could have timed out).
                guard self.pending?.id == request.id else { return }
                let outcome = self.engine.resolve(
                    risk: request.risk, gesture: gesture, authenticated: ok)
                self.finish(request: request, outcome: outcome)
            }
        } else {
            let outcome = engine.resolve(risk: request.risk, gesture: gesture, authenticated: false)
            finish(request: request, outcome: outcome)
        }
    }

    private func resolveImmediate(_ gesture: ConfirmDecisionEngine.Gesture) {
        guard let request = pending else { return }
        let outcome = engine.resolve(risk: request.risk, gesture: gesture, authenticated: false)
        finish(request: request, outcome: outcome)
    }

    private func finish(request: ConfirmRequest, outcome: ConfirmOutcome) {
        timeoutTask?.cancel()
        timeoutTask = nil
        pending = nil
        awaitingAuth = false
        duck.setDucked(false)
        sendVerdict(request.id, outcome.verdict)
        audit.append(command: request.command, risk: request.risk,
                     outcome: outcome, epoch: now())
    }

    private func startTimeout(for request: ConfirmRequest) {
        timeoutTask?.cancel()
        let seconds = timeoutSeconds
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // Still the same request? Then DENY by timeout.
            guard self.pending?.id == request.id else { return }
            self.finish(request: request, outcome: .timedOut)
        }
    }

    // MARK: AppKit alert (GUI session only; logic above is independent of this)

    private func showAlert(for request: ConfirmRequest) {
        #if canImport(AppKit)
        ConfirmAlertPresenter.present(
            request: request,
            onConfirm: { [weak self] in self?.userClickedConfirm() },
            onCancel: { [weak self] in self?.userClickedCancel() })
        #endif
    }
}

// MARK: - LocalAuthentication-backed authenticator

#if canImport(LocalAuthentication)
import LocalAuthentication

/// Production authenticator: Touch ID with device-passcode fallback.
public struct LocalAuthAuthenticator: DeviceAuthenticator {
    public init() {}

    public func authenticate(
        reason: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let context = LAContext()
        var error: NSError?
        // Prefer biometrics; if unavailable, fall back to device-owner (passcode).
        let policy: LAPolicy = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
            Task { @MainActor in completion(success) }
        }
    }
}
#else
/// Non-Apple fallback: no local auth available -> deny elevated approvals.
public struct LocalAuthAuthenticator: DeviceAuthenticator {
    public init() {}
    public func authenticate(reason: String, completion: @escaping @MainActor (Bool) -> Void) {
        Task { @MainActor in completion(false) }
    }
}
#endif

// MARK: - AppKit alert presenter (GUI only)

#if canImport(AppKit)
import AppKit

enum ConfirmAlertPresenter {
    @MainActor
    static func present(
        request: ConfirmRequest,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = request.risk == .elevated ? .critical : .warning
        alert.messageText = request.risk == .elevated
            ? "Confirm high-risk command"
            : "Confirm command"
        // The command is shown VERBATIM (already redacted by the core).
        alert.informativeText = request.command

        // Order matters: the FIRST added button is the default. Make Cancel default
        // so Return/Enter cancels, and Esc maps to Cancel as well.
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"   // Esc
        let confirm = alert.addButton(withTitle: "Confirm")
        confirm.keyEquivalent = ""        // never the default; explicit click required

        // Bring the prompt to the foreground without stealing the orb's click-through.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            onConfirm()
        } else {
            onCancel()
        }
    }
}
#endif

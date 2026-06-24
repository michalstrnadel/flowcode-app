//
//  MicPermission.swift
//  flowcode
//
//  Microphone authorization helper. This is the app's own AVFoundation call so
//  the macOS TCC subsystem attributes any granted permission to flowcode itself.
//

import Foundation
import AVFoundation

/// Namespace for microphone-permission helpers.
///
/// `MicPermission` is a stateless enum used purely as a namespace; it has no
/// cases and cannot be instantiated. All work happens in `ensureAccess()`.
public enum MicPermission {

    /// Ensures the app has microphone access, prompting the user if needed.
    ///
    /// Behavior by current `AVAuthorizationStatus`:
    /// - `.authorized`: returns `true` immediately.
    /// - `.notDetermined`: triggers the system permission prompt via
    ///   `AVCaptureDevice.requestAccess(for: .audio)` and returns the user's choice.
    /// - `.denied` / `.restricted`: returns `false` without prompting (the system
    ///   will not re-prompt; the user must change this in System Settings).
    ///
    /// This call must originate from flowcode so TCC attributes the grant to the
    /// app rather than to a host process.
    ///
    /// - Returns: `true` if microphone capture is authorized, `false` otherwise.
    public static func ensureAccess() async -> Bool {
        // Snapshot the current authorization status for the audio media type.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            // Already granted; nothing to prompt for.
            return true

        case .notDetermined:
            // First-time decision: present the system prompt and await the result.
            // `requestAccess` has a completion-handler API; bridge it to async.
            return await AVCaptureDevice.requestAccess(for: .audio)

        case .denied, .restricted:
            // Explicitly denied by the user, or restricted by policy/parental
            // controls. The system will not show a prompt again, so report failure.
            return false

        @unknown default:
            // Future-proofing: treat any unrecognized status as not-authorized.
            return false
        }
    }
}

//
//  Earcons.swift
//  flowcode
//
//  Short, low-latency audio cues ("earcons") that punctuate the voice-session
//  lifecycle: a soft chime when listening starts, a settle tone at end-of-turn,
//  and a distinct cue when the user barges in / is interrupted.
//
//  Design constraints (per Phase 2 contract):
//    - @MainActor: AVAudioPlayer / NSSound and their delegate callbacks are
//      driven on the main thread, matching the rest of the HUD layer.
//    - Tolerate missing assets: no audio files are bundled yet. We attempt to
//      locate them (optional assets dir, the module's resource bundle, the main
//      bundle) and, if nothing is found, every `play(_:)` is a silent no-op.
//      The class NEVER crashes and NEVER references `Bundle.module` directly —
//      that symbol only exists when SwiftPM resources are declared, so using it
//      would break compilation in this resource-less target.
//    - Low latency: players are decoded and `prepareToPlay()`'d in `init` so the
//      first `play(_:)` doesn't pay the load/decode cost.
//

import Foundation
import AVFoundation
import AppKit

/// Plays short UI sound cues for voice-session transitions.
///
/// Asset resolution is best-effort and entirely optional. If a cue's sound file
/// cannot be found at construction time, that cue is simply skipped at play time.
/// This keeps the orb HUD shippable before any audio assets land in the bundle.
@MainActor
public final class Earcons {

    // MARK: Cue

    /// The set of distinct earcons the app can request.
    public enum Cue: Sendable, CaseIterable {
        /// Played when the session begins actively listening to the user.
        case startListening
        /// Played when the assistant finishes a turn / returns to idle.
        case endTurn
        /// Played when the user barges in or the turn is interrupted.
        case interrupted

        /// Candidate resource base names (without extension) for this cue, in
        /// preference order. Several common spellings are tried so whatever the
        /// audio designer ships will be picked up without code changes.
        fileprivate var resourceNames: [String] {
            switch self {
            case .startListening:
                return ["earcon_start_listening", "start_listening", "startListening", "listen_start"]
            case .endTurn:
                return ["earcon_end_turn", "end_turn", "endTurn", "turn_end"]
            case .interrupted:
                return ["earcon_interrupted", "interrupted", "barge_in", "bargeIn"]
            }
        }
    }

    // MARK: Public state

    /// When `true`, `play(_:)` is a no-op. Loaded players are retained so toggling
    /// `muted` back to `false` resumes instant playback without reloading.
    public var muted: Bool = false

    // MARK: Private state

    /// Pre-decoded players keyed by cue. Missing entries mean "no asset found"
    /// (or this platform fell back to `NSSound`); such cues play silently/no-op.
    private var players: [Cue: AVAudioPlayer] = [:]

    /// `NSSound` fallback used only if `AVAudioPlayer` construction fails for a
    /// found file (rare). Retained so it can be stopped/replayed promptly.
    private var sounds: [Cue: NSSound] = [:]

    /// Audio file extensions we know how to decode, in preference order.
    private static let supportedExtensions = ["caf", "aiff", "aif", "wav", "m4a", "mp3"]

    // MARK: Init

    /// Discovers and pre-loads any available cue assets.
    ///
    /// - Parameter assetsDirectory: optional explicit directory to search first
    ///   (e.g. a user-overridable sounds folder). When `nil`, only bundle-based
    ///   lookups are used. Either way, absence of assets is fine.
    public init(assetsDirectory: URL? = nil) {
        let searchBundles = Self.candidateBundles()
        for cue in Cue.allCases {
            if let url = Self.locate(cue: cue, in: assetsDirectory, bundles: searchBundles) {
                load(cue: cue, from: url)
            }
        }
    }

    // MARK: Playback

    /// Plays the given cue if an asset for it was found and the player isn't muted.
    /// Restarts from the beginning if the cue is already mid-playback so rapid
    /// transitions always produce a fresh, audible hit. No-ops otherwise.
    public func play(_ cue: Cue) {
        guard !muted else { return }

        if let player = players[cue] {
            // Rewind so repeated/rapid triggers always sound, then fire.
            player.currentTime = 0
            player.play()
            return
        }

        if let sound = sounds[cue] {
            // NSSound has no seek; stop ensures a clean restart before playing.
            sound.stop()
            sound.play()
            return
        }

        // No asset for this cue: intentionally silent.
    }

    /// Immediately stops any currently-playing cues (e.g. when hiding the HUD).
    public func stopAll() {
        for player in players.values where player.isPlaying {
            player.stop()
            player.currentTime = 0
        }
        for sound in sounds.values where sound.isPlaying {
            sound.stop()
        }
    }

    // MARK: Loading

    /// Builds an `AVAudioPlayer` (preferred) for the URL and primes it for low
    /// latency. Falls back to `NSSound` if the player can't be constructed.
    private func load(cue: Cue, from url: URL) {
        if let player = try? AVAudioPlayer(contentsOf: url) {
            player.volume = 1.0
            player.numberOfLoops = 0
            // Decode/buffer now so the first play() is instant.
            player.prepareToPlay()
            players[cue] = player
            return
        }
        // Rare fallback path. NSSound is fully main-thread friendly.
        if let sound = NSSound(contentsOf: url, byReference: false) {
            sounds[cue] = sound
        }
        // If both fail, leave the cue unmapped -> it stays a no-op.
    }

    // MARK: Asset resolution

    /// Returns the bundles to search for cue resources, most-specific first.
    ///
    /// Crucially this does NOT reference `Bundle.module` (which only exists when
    /// SwiftPM resources are declared). Instead it derives the module's resource
    /// bundle at runtime by inspecting the framework/module bundle that contains
    /// this very class, plus any sibling `*.bundle`, plus the main bundle.
    private static func candidateBundles() -> [Bundle] {
        var result: [Bundle] = []
        var seen = Set<URL>()

        func append(_ bundle: Bundle?) {
            guard let bundle else { return }
            let url = bundle.bundleURL.standardizedFileURL
            if seen.insert(url).inserted {
                result.append(bundle)
            }
        }

        // 1) The bundle that physically contains this class (the framework or,
        //    for a statically-linked SwiftPM target, the main executable bundle).
        let owning = Bundle(for: BundleToken.self)
        append(owning)

        // 2) Any sibling resource bundle laid down next to the owning bundle,
        //    e.g. "flowcode_flowcodeKit.bundle" that SwiftPM would emit IF
        //    resources were declared. Probing by directory keeps us compatible
        //    with that future without a compile-time dependency on `Bundle.module`.
        let container = owning.bundleURL.deletingLastPathComponent()
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where entry.pathExtension == "bundle" {
                append(Bundle(url: entry))
            }
        }

        // 3) The main application bundle (where a final app might ship sounds).
        append(.main)

        return result
    }

    /// Locates the first available file URL for a cue across the explicit assets
    /// directory and the candidate bundles, trying each name/extension pair.
    private static func locate(
        cue: Cue,
        in assetsDirectory: URL?,
        bundles: [Bundle]
    ) -> URL? {
        let names = cue.resourceNames
        let exts = supportedExtensions
        let fm = FileManager.default

        // a) Explicit assets directory wins (user override / dev workflow).
        if let dir = assetsDirectory {
            for name in names {
                for ext in exts {
                    let candidate = dir.appendingPathComponent(name).appendingPathExtension(ext)
                    if fm.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
        }

        // b) Bundle resource lookup (handles localized / subdir layouts for free).
        for bundle in bundles {
            for name in names {
                for ext in exts {
                    if let url = bundle.url(forResource: name, withExtension: ext) {
                        return url
                    }
                }
            }
        }

        return nil
    }
}

/// Empty anchor type used only to resolve the bundle that contains this module's
/// compiled code via `Bundle(for:)`. Kept private and non-instantiated.
private final class BundleToken {}

//
//  TtsPlayer.swift
//  flowcode — Model B (self-contained voice layer)
//
//  Sequential player for TTS clips (WAV Data from Kokoro). Clips are queued and
//  played one after another via AVAudioPlayer. While playing, an ~30 Hz meter
//  poll publishes a 0..1 speech amplitude (for the orb) and a speaking on/off
//  signal (for panel visibility). `flush()` stops everything (the "stop
//  speaking" action). All API is @MainActor.
//

import Foundation
import AVFoundation

@MainActor
public final class TtsPlayer: NSObject, AVAudioPlayerDelegate {

    /// Fired ~30×/s with the current speech amplitude (0...1) while playing; 0 when idle.
    public var onAmplitude: ((Float) -> Void)?
    /// Fired true when playback starts, false when the whole queue drains / is flushed.
    public var onSpeakingChanged: ((Bool) -> Void)?

    private var queue: [Data] = []
    private var player: AVAudioPlayer?
    private var meterTimer: Timer?
    private var speaking = false

    public override init() { super.init() }

    /// True while a clip is playing or queued.
    public var isSpeaking: Bool { speaking }

    /// Enqueue a WAV clip for sequential playback. Starts playback if idle.
    public func enqueue(_ wav: Data) {
        queue.append(wav)
        if player == nil { playNext() }
    }

    /// Stop immediately and drop everything queued (user hit "stop speaking",
    /// or the HUD is hiding). Idempotent.
    public func flush() {
        queue.removeAll()
        player?.stop()
        player = nil
        stopMeter()
        setSpeaking(false)
    }

    // MARK: - Playback

    private func playNext() {
        guard !queue.isEmpty else {
            player = nil
            stopMeter()
            setSpeaking(false)
            return
        }
        let wav = queue.removeFirst()
        do {
            let p = try AVAudioPlayer(data: wav)
            p.isMeteringEnabled = true
            p.delegate = self
            p.prepareToPlay()
            player = p
            p.play()
            setSpeaking(true)
            startMeter()
        } catch {
            NSLog("flowcode: TtsPlayer could not play clip: \(error)")
            playNext()   // skip the bad clip, keep the queue moving
        }
    }

    // MARK: - Amplitude metering

    private func startMeter() {
        stopMeter()
        // @Sendable block runs on the main run loop; hop to the actor to read state.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMeter() }
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
        onAmplitude?(0)
    }

    private func tickMeter() {
        guard let p = player, p.isPlaying else { return }
        p.updateMeters()
        let db = p.averagePower(forChannel: 0)        // ~ -160...0 dB
        // Map dB to 0..1 with a ~ -45 dB noise floor, then a gentle curve for punch.
        let norm = max(0, (db + 45) / 45)
        onAmplitude?(min(1, norm * norm))
    }

    private func setSpeaking(_ v: Bool) {
        guard v != speaking else { return }
        speaking = v
        onSpeakingChanged?(v)
    }

    // MARK: - AVAudioPlayerDelegate (nonisolated; hop to MainActor)

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playNext() }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.playNext() }
    }
}

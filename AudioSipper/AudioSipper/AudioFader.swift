import Foundation

#if os(iOS)
import AVFoundation

/// Reusable audio fade utility. Supports fade-out and fade-in on any AVAudioPlayer.
/// Designed as shared logic so both Short Mode and Long Mode can adopt it.
///
/// Usage:
///   let fader = AudioFader()
///   fader.fadeOut(player: player, duration: 0.2) { player.pause() }
///
/// Thread safety: all public methods must be called on the MainActor.
@MainActor
final class AudioFader {

    /// Whether a fade is currently in progress.
    private(set) var isFading: Bool = false

    private var displayLink: CADisplayLink?
    private var fadeStartTime: CFTimeInterval = 0
    private var fadeDuration: CFTimeInterval = 0
    private var fadeStartVolume: Float = 1.0
    private var fadeEndVolume: Float = 0.0
    private weak var fadePlayer: AVAudioPlayer?
    private var fadeCompletion: (() -> Void)?

    // MARK: - Public API

    /// Fade the player's volume from its current level to 0 over `duration` seconds.
    /// Calls `completion` when finished (or immediately if duration <= 0).
    func fadeOut(player: AVAudioPlayer, duration: TimeInterval = 0.2, completion: @escaping () -> Void) {
        fade(player: player, to: 0.0, duration: duration, completion: completion)
    }

    /// Fade the player's volume from its current level to 1 over `duration` seconds.
    /// Calls `completion` when finished (or immediately if duration <= 0).
    func fadeIn(player: AVAudioPlayer, duration: TimeInterval = 0.2, completion: @escaping () -> Void) {
        fade(player: player, to: 1.0, duration: duration, completion: completion)
    }

    /// Cancel any in-progress fade. Leaves volume at its current value.
    /// Does NOT call the pending completion handler.
    func cancel() {
        tearDownDisplayLink()
        isFading = false
        fadeCompletion = nil
        fadePlayer = nil
    }

    /// Force-finish: immediately jump to the target volume and fire completion.
    /// Use this for backgrounding — avoids stuck half-volume states.
    func forceFinish() {
        guard isFading, let player = fadePlayer else { return }
        player.volume = fadeEndVolume
        let completion = fadeCompletion
        tearDownDisplayLink()
        isFading = false
        fadeCompletion = nil
        fadePlayer = nil
        completion?()
    }

    // MARK: - Private

    private func fade(player: AVAudioPlayer, to targetVolume: Float, duration: TimeInterval, completion: @escaping () -> Void) {
        // Cancel any existing fade first — prevents stacking
        cancel()

        // Trivial case: no duration or already at target
        if duration <= 0 || player.volume == targetVolume {
            player.volume = targetVolume
            completion()
            return
        }

        isFading = true
        fadePlayer = player
        fadeStartVolume = player.volume
        fadeEndVolume = targetVolume
        fadeDuration = duration
        fadeCompletion = completion
        fadeStartTime = CACurrentMediaTime()

        let link = CADisplayLink(target: self, selector: #selector(displayLinkTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayLinkTick() {
        guard let player = fadePlayer else {
            finishFade()
            return
        }

        let elapsed = CACurrentMediaTime() - fadeStartTime
        let progress = min(Float(elapsed / fadeDuration), 1.0)
        player.volume = fadeStartVolume + (fadeEndVolume - fadeStartVolume) * progress

        if progress >= 1.0 {
            finishFade()
        }
    }

    private func finishFade() {
        if let player = fadePlayer {
            player.volume = fadeEndVolume
        }
        let completion = fadeCompletion
        tearDownDisplayLink()
        isFading = false
        fadeCompletion = nil
        fadePlayer = nil
        completion?()
    }

    private func tearDownDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
}
#endif

import Foundation
import UIKit

#if os(iOS)

// MARK: - Sleep Timer Option

enum SleepTimerOption {
    case minutes(Int)
    case endOfTrack

    var label: String {
        switch self {
        case .minutes(let m) where m < 60: return "\(m) min"
        case .minutes: return "1 hour"
        case .endOfTrack: return "End of Track"
        }
    }
}

// MARK: - Sleep Timer Manager

/// Manages the sleep timer state. Lives in memory only — does not persist across launches.
/// Placed at the ContentView level and passed down to both mode views.
@MainActor
final class SleepTimerManager: ObservableObject {

    // MARK: Published State

    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var isActive: Bool = false
    /// True when the timer is in "End of Track" mode (no countdown, fires on next track completion).
    @Published private(set) var isEndOfTrack: Bool = false

    // MARK: Callback

    /// Set by whichever mode view is currently active. Called on timer expiry.
    var onExpire: (() -> Void)?

    // MARK: Private

    private var countdownTimer: Timer?

    // MARK: - Public Interface

    /// Start or replace the active timer with the given option.
    func set(_ option: SleepTimerOption) {
        cancelTimer()
        switch option {
        case .minutes(let m):
            remainingSeconds = m * 60
            isEndOfTrack = false
            isActive = true
            startCountdown()
        case .endOfTrack:
            remainingSeconds = 0
            isEndOfTrack = true
            isActive = true
        }
    }

    /// Cancel the active timer without firing expiry.
    func cancel() {
        cancelTimer()
    }

    /// Called by the active player manager when a track ends naturally.
    /// If End of Track mode is active this fires the expiry callback and resets state.
    func notifyTrackEnded() {
        guard isActive && isEndOfTrack else { return }
        isActive = false
        isEndOfTrack = false
        fireExpiry()
    }

    // MARK: - Formatting

    var formattedRemaining: String {
        let s = remainingSeconds
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        } else {
            return String(format: "%d:%02d", m, sec)
        }
    }

    // MARK: - Private

    private func startCountdown() {
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self else { t.invalidate(); return }
                self.remainingSeconds -= 1
                if self.remainingSeconds <= 0 {
                    t.invalidate()
                    self.countdownTimer = nil
                    self.isActive = false
                    self.fireExpiry()
                }
            }
        }
    }

    private func cancelTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        isActive = false
        isEndOfTrack = false
        remainingSeconds = 0
    }

    private func fireExpiry() {
        // Brief haptic to signal the stop
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        onExpire?()
    }
}

#endif

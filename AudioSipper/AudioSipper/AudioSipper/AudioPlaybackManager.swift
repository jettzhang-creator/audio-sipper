import Foundation

#if os(iOS)
import AVFoundation
import UIKit   // UIBackgroundTaskIdentifier

// MARK: - Playback State Machine

enum PlaybackState: Equatable {
    case idle           // Nothing started / fully stopped
    case playing        // Audio clip is running
    case paused         // User paused; resumable
    case countdown      // Waiting between clips
    case finished       // Unused — kept for ABI stability; playback now loops forever
}

// MARK: - Manager

@MainActor
final class AudioPlaybackManager: NSObject, ObservableObject {

    // MARK: Published

    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var currentFileName: String = ""
    @Published private(set) var countdownSeconds: Int = 0
    @Published private(set) var statusMessage: String = ""

    // MARK: Private State

    private var audioPlayer: AVAudioPlayer?
    private var playlist: [URL] = []
    private var currentIndex: Int = 0
    private var countdownTimer: Timer?
    private var pauseDuration: Int = 3
    private var activeFolderURL: URL?
    private var wasPlayingClipWhenPaused: Bool = false

    /// Background task kept alive during the silent countdown gap so the
    /// timer fires even when the screen is locked.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // MARK: Init / Deinit

    override init() {
        super.init()
        configureAudioSession()
        registerForNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public Interface

    /// Starts a new session. Tears down any existing one first.
    func startSession(folderURL: URL, recursive: Bool, pauseDuration: Int) {
        tearDown()
        self.pauseDuration = pauseDuration
        activeFolderURL = folderURL

        guard folderURL.startAccessingSecurityScopedResource() else {
            statusMessage = "Could not access the selected folder. Please choose it again."
            state = .idle
            return
        }

        statusMessage = "Scanning…"
        let files = Self.scanAudioFiles(in: folderURL, recursive: recursive)
        playlist = files.shuffled()
        currentIndex = 0

        guard !playlist.isEmpty else {
            folderURL.stopAccessingSecurityScopedResource()
            activeFolderURL = nil
            statusMessage = "No valid clips (≤ 30 s) found in this folder."
            state = .idle
            return
        }

        statusMessage = ""
        playCurrentClip()
    }

    /// Pauses if playing/counting down, resumes if paused.
    func togglePause() {
        switch state {
        case .playing:
            audioPlayer?.pause()
            wasPlayingClipWhenPaused = true
            state = .paused

        case .countdown:
            countdownTimer?.invalidate()
            countdownTimer = nil
            endBackgroundTask()
            wasPlayingClipWhenPaused = false
            // countdownSeconds preserved so resume picks up where it left off
            state = .paused

        case .paused:
            if wasPlayingClipWhenPaused {
                audioPlayer?.play()
                state = .playing
            } else {
                startCountdown(from: countdownSeconds)
            }

        default:
            break
        }
    }

    /// Ends the session entirely — returns to idle so settings can be adjusted.
    func stop() {
        tearDown()
        state = .idle
        currentFileName = ""
        countdownSeconds = 0
        statusMessage = ""
    }

    // MARK: - Private Playback

    private func playCurrentClip() {
        if currentIndex >= playlist.count {
            // End of list — reshuffle and loop seamlessly
            playlist.shuffle()
            currentIndex = 0
            statusMessage = "Reshuffled — looping…"
        }

        let url = playlist[currentIndex]

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            audioPlayer = player
            currentFileName = url.lastPathComponent
            player.prepareToPlay()
            player.play()
            state = .playing
        } catch {
            // Unplayable file — skip silently
            currentIndex += 1
            playCurrentClip()
        }
    }

    private func startCountdown(from seconds: Int? = nil) {
        countdownSeconds = seconds ?? pauseDuration
        state = .countdown
        countdownTimer?.invalidate()

        // Hold a background task for the entire silent gap so the timer fires
        // while the screen is locked. Audio playback keeps the app alive on its own.
        beginBackgroundTask()

        // .common mode ensures the timer fires even while the user scrolls.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] t in
            guard self != nil else { t.invalidate(); return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.countdownSeconds -= 1
                if self.countdownSeconds <= 0 {
                    t.invalidate()
                    self.countdownTimer = nil
                    self.endBackgroundTask()
                    self.currentIndex += 1
                    self.playCurrentClip()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    // MARK: - Background Task

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "AudioSipper.countdown") {
            [weak self] in self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - Notifications

    private func registerForNotifications() {
        // Phone calls, Siri, alarms, etc.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in self?.handleInterruption(note) }
        }

        // Headphones unplugged — pause like standard iOS apps do
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in self?.handleRouteChange(note) }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            if state == .playing { togglePause() }

        case .ended:
            let opts = AVAudioSession.InterruptionOptions(
                rawValue: (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            )
            if opts.contains(.shouldResume), state == .paused { togglePause() }

        @unknown default: break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable
        else { return }
        if state == .playing { togglePause() }
    }

    // MARK: - File Scanning

    private static func scanAudioFiles(in directory: URL, recursive: Bool) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        let allowed: Set<String> = ["mp3", "wav", "m4a"]

        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for item in contents {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir {
                if recursive { results += scanAudioFiles(in: item, recursive: true) }
                continue
            }
            guard allowed.contains(item.pathExtension.lowercased()) else { continue }
            if let probe = try? AVAudioPlayer(contentsOf: item),
               probe.duration > 0,
               probe.duration <= 30 {
                results.append(item)
            }
        }
        return results
    }

    // MARK: - Cleanup

    private func tearDown() {
        audioPlayer?.stop()
        audioPlayer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        endBackgroundTask()
        if let url = activeFolderURL {
            url.stopAccessingSecurityScopedResource()
            activeFolderURL = nil
        }
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AudioSipper] AVAudioSession setup failed: \(error)")
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlaybackManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.state == .playing else { return }
            self.startCountdown()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.currentIndex += 1
            self.playCurrentClip()
        }
    }
}
#endif

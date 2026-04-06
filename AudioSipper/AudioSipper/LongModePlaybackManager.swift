import Foundation

#if os(iOS)
import AVFoundation

// MARK: - Long Mode Playback State

enum LongPlaybackState: Equatable {
    case idle
    case playing
    case paused            // User-paused (clip or countdown)
    case withinFilePause   // Automatic interval pause inside a file
    case betweenFiles      // Fixed silence between files
    case finished
}

// MARK: - Manager

/// Handles Long Mode playback: longer audio files with automatic within-file
/// interval pauses, seek bar, previous/next, and fixed between-file pauses.
@MainActor
final class LongModePlaybackManager: NSObject, ObservableObject {

    // MARK: Published

    @Published private(set) var state: LongPlaybackState = .idle
    @Published private(set) var currentFileName: String = ""
    @Published private(set) var countdownSeconds: Int = 0
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    // MARK: Settings (set before/during session)

    var autoReplay: Bool = true
    var shuffle: Bool = true

    // MARK: Private State

    private var audioPlayer: AVAudioPlayer?
    private var playlist: [URL] = []
    private var currentIndex: Int = 0

    // Timers
    private var countdownTimer: Timer?
    private var intervalTimer: Timer?
    private var progressTimer: Timer?

    // Pause settings
    private var intervalSeconds: Int = 60
    private var minPauseDuration: Int = 10
    private var maxPauseDuration: Int = 30
    private var betweenFilesPause: Int = 5

    // Interval tracking
    private var elapsedPlaybackSinceLastPause: TimeInterval = 0
    private var lastProgressTimestamp: TimeInterval = 0

    // Pause/resume bookkeeping
    private var activeFolderURL: URL?
    private var activeFileURL: URL?
    private var wasPlayingClipWhenPaused: Bool = false

    // MARK: Init

    override init() {
        super.init()
        configureAudioSession()
    }

    // MARK: - Public Interface

    /// Starts a new Long Mode session with a folder.
    func startFolderSession(
        folderURL: URL,
        recursive: Bool,
        intervalSeconds: Int,
        minPause: Int,
        maxPause: Int,
        betweenFilesPause: Int,
        shuffle: Bool,
        autoReplay: Bool
    ) {
        tearDown()
        self.intervalSeconds = intervalSeconds
        self.minPauseDuration = minPause
        self.maxPauseDuration = maxPause
        self.betweenFilesPause = betweenFilesPause
        self.shuffle = shuffle
        self.autoReplay = autoReplay
        activeFolderURL = folderURL
        activeFileURL = nil

        guard folderURL.startAccessingSecurityScopedResource() else {
            statusMessage = "Could not access the selected folder. Please choose it again."
            state = .idle
            return
        }

        statusMessage = "Scanning..."

        let files = Self.scanAudioFiles(in: folderURL, recursive: recursive)
        playlist = shuffle
            ? files.shuffled()
            : files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        currentIndex = 0

        guard !playlist.isEmpty else {
            folderURL.stopAccessingSecurityScopedResource()
            activeFolderURL = nil
            statusMessage = "No audio files found in this folder."
            state = .idle
            return
        }

        statusMessage = ""
        playCurrentFile()
    }

    /// Starts a new Long Mode session with a single file.
    func startFileSession(
        fileURL: URL,
        intervalSeconds: Int,
        minPause: Int,
        maxPause: Int,
        autoReplay: Bool
    ) {
        tearDown()
        self.intervalSeconds = intervalSeconds
        self.minPauseDuration = minPause
        self.maxPauseDuration = maxPause
        self.betweenFilesPause = 0
        self.shuffle = false
        self.autoReplay = autoReplay
        activeFileURL = fileURL
        activeFolderURL = nil

        guard fileURL.startAccessingSecurityScopedResource() else {
            statusMessage = "Could not access the selected file. Please choose it again."
            state = .idle
            return
        }

        playlist = [fileURL]
        currentIndex = 0
        statusMessage = ""
        playCurrentFile()
    }

    /// Toggle play/pause — single button behavior per requirements.
    func togglePlayPause() {
        switch state {
        case .playing:
            audioPlayer?.pause()
            stopProgressTimer()
            wasPlayingClipWhenPaused = true
            state = .paused

        case .withinFilePause, .betweenFiles:
            countdownTimer?.invalidate()
            countdownTimer = nil
            wasPlayingClipWhenPaused = false
            state = .paused

        case .paused:
            if wasPlayingClipWhenPaused {
                audioPlayer?.play()
                startProgressTimer()
                state = .playing
            } else {
                // Resume countdown
                startCountdown(from: countdownSeconds, type: .withinFilePause)
            }

        default:
            break
        }
    }

    /// Previous: restart current file. If near the beginning (< 3s), go to previous file.
    func previous() {
        guard state == .playing || state == .paused || state == .withinFilePause || state == .betweenFiles else { return }

        stopAllTimers()

        if currentTime < 3.0 && currentIndex > 0 {
            currentIndex -= 1
        }
        playCurrentFile()
    }

    /// Next: skip to next file immediately.
    func next() {
        guard state == .playing || state == .paused || state == .withinFilePause || state == .betweenFiles else { return }

        stopAllTimers()
        currentIndex += 1
        advanceOrFinish()
    }

    /// Seek to a specific time within the current file.
    func seek(to time: TimeInterval) {
        guard let player = audioPlayer else { return }
        let clamped = min(max(time, 0), player.duration)
        player.currentTime = clamped
        currentTime = clamped
        // Do NOT reset the interval timer on seek — per requirements
    }

    /// Stop session entirely.
    func stop() {
        tearDown()
        state = .idle
        currentFileName = ""
        currentTime = 0
        duration = 0
        countdownSeconds = 0
        statusMessage = ""
    }

    // MARK: - Private Playback

    private func playCurrentFile() {
        elapsedPlaybackSinceLastPause = 0
        lastProgressTimestamp = 0

        guard currentIndex < playlist.count else {
            advanceOrFinish()
            return
        }

        let url = playlist[currentIndex]

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            audioPlayer = player
            currentFileName = url.lastPathComponent
            duration = player.duration
            currentTime = 0
            player.prepareToPlay()
            player.play()
            state = .playing
            startProgressTimer()
        } catch {
            currentIndex += 1
            playCurrentFile()
        }
    }

    private func advanceOrFinish() {
        if currentIndex >= playlist.count {
            if autoReplay {
                currentIndex = 0
                if shuffle { playlist.shuffle() }
                playCurrentFile()
            } else {
                tearDown()
                state = .finished
                currentFileName = ""
                currentTime = 0
                duration = 0
                statusMessage = "All files played."
            }
        } else {
            playCurrentFile()
        }
    }

    // MARK: - Interval Pause Logic

    /// Called periodically while playing to check if interval pause is needed.
    private func checkIntervalPause() {
        guard state == .playing, let player = audioPlayer else { return }

        currentTime = player.currentTime
        let now = player.currentTime
        let delta = now - lastProgressTimestamp
        lastProgressTimestamp = now

        if delta > 0 {
            elapsedPlaybackSinceLastPause += delta
        }

        if elapsedPlaybackSinceLastPause >= Double(intervalSeconds) {
            // Trigger within-file pause
            player.pause()
            stopProgressTimer()
            elapsedPlaybackSinceLastPause = 0
            startCountdown(from: nil, type: .withinFilePause)
        }
    }

    // MARK: - Countdown

    private func startCountdown(from seconds: Int?, type: LongPlaybackState) {
        let total: Int
        if let s = seconds {
            total = s
        } else if type == .betweenFiles {
            total = betweenFilesPause
        } else {
            total = minPauseDuration == maxPauseDuration
                ? minPauseDuration
                : Int.random(in: minPauseDuration...maxPauseDuration)
        }

        countdownSeconds = total
        state = type
        countdownTimer?.invalidate()

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.countdownSeconds -= 1
                if self.countdownSeconds <= 0 {
                    timer.invalidate()
                    self.countdownTimer = nil
                    if type == .withinFilePause {
                        self.resumeAfterIntervalPause()
                    } else {
                        // Between files — play next
                        self.playCurrentFile()
                    }
                }
            }
        }
    }

    private func resumeAfterIntervalPause() {
        guard let player = audioPlayer else { return }
        lastProgressTimestamp = player.currentTime
        player.play()
        state = .playing
        startProgressTimer()
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        stopProgressTimer()
        if let player = audioPlayer {
            lastProgressTimestamp = player.currentTime
        }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard self != nil else { return }
            Task { @MainActor [weak self] in
                self?.checkIntervalPause()
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func stopAllTimers() {
        stopProgressTimer()
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    // MARK: - File Scanning (no duration limit for Long Mode)

    private static func scanAudioFiles(in directory: URL, recursive: Bool) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        let allowed: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "aiff", "caf"]

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
            // No duration limit in Long Mode
            if let probe = try? AVAudioPlayer(contentsOf: item), probe.duration > 0 {
                results.append(item)
            }
        }
        return results
    }

    // MARK: - Cleanup

    private func tearDown() {
        audioPlayer?.stop()
        audioPlayer = nil
        stopAllTimers()
        if let url = activeFolderURL {
            url.stopAccessingSecurityScopedResource()
            activeFolderURL = nil
        }
        if let url = activeFileURL {
            url.stopAccessingSecurityScopedResource()
            activeFileURL = nil
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

extension LongModePlaybackManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.state == .playing else { return }
            self.stopProgressTimer()
            self.currentIndex += 1

            if self.currentIndex < self.playlist.count && self.betweenFilesPause > 0 {
                self.startCountdown(from: nil, type: .betweenFiles)
            } else {
                self.advanceOrFinish()
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.currentIndex += 1
            self.advanceOrFinish()
        }
    }
}
#endif

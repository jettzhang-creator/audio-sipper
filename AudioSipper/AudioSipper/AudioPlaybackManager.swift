import Foundation

#if os(iOS)
import AVFoundation

// MARK: - Playback State Machine

enum PlaybackState: Equatable {
    case idle           // Nothing started
    case playing        // Audio clip is running
    case paused         // User paused; can resume
    case countdown      // Waiting between clips
    case finished       // All clips exhausted
}

// MARK: - Manager

/// Handles all audio logic: file scanning, shuffling, sequential clip playback,
/// inter-clip pauses, and state transitions.
/// All mutations happen on the MainActor so @Published properties are safe to observe.
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
    var autoReplay: Bool = false
    var shuffle: Bool = true

    /// The security-scoped URL we must balance start/stop calls for.
    private var activeFolderURL: URL?
    /// True if we paused during clip playback; false if paused during countdown.
    private var wasPlayingClipWhenPaused: Bool = false

    // MARK: Init

    override init() {
        super.init()
        configureAudioSession()
    }

    // MARK: - Public Interface

    /// Starts a new session. Tears down any existing one first.
    func startSession(folderURL: URL, recursive: Bool, pauseDuration: Int, shuffle: Bool, autoReplay: Bool) {
        tearDown()
        self.pauseDuration = pauseDuration
        self.shuffle = shuffle
        self.autoReplay = autoReplay
        activeFolderURL = folderURL

        guard folderURL.startAccessingSecurityScopedResource() else {
            statusMessage = "Could not access the selected folder. Please choose it again."
            state = .idle
            return
        }

        statusMessage = "Scanning…"

        // Scan is synchronous; acceptable for local folders at V0 scope.
        // Files are obtained while security scope is active.
        let files = Self.scanAudioFiles(in: folderURL, recursive: recursive)
        playlist = shuffle ? files.shuffled() : files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
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
            wasPlayingClipWhenPaused = false
            // countdownSeconds is preserved for resume
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

    /// Ends the session entirely and resets all state.
    func stop() {
        tearDown()
        state = .idle
        currentFileName = ""
        countdownSeconds = 0
        statusMessage = ""
    }

    // MARK: - Private Playback

    private func playCurrentClip() {
        guard currentIndex < playlist.count else {
            if autoReplay {
                currentIndex = 0
                if shuffle { playlist.shuffle() }
                playCurrentClip()
                return
            }
            tearDown()
            state = .finished
            currentFileName = ""
            statusMessage = "All clips played."
            return
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
            // Unplayable file — skip silently and try next
            currentIndex += 1
            playCurrentClip()
        }
    }

    private func startCountdown(from seconds: Int? = nil) {
        countdownSeconds = seconds ?? pauseDuration
        state = .countdown
        countdownTimer?.invalidate()

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.countdownSeconds -= 1
                if self.countdownSeconds <= 0 {
                    timer.invalidate()
                    self.countdownTimer = nil
                    self.currentIndex += 1
                    self.playCurrentClip()
                }
            }
        }
    }

    // MARK: - File Scanning

    /// Static so it can be called safely without actor isolation.
    /// Scans `directory` for .mp3 / .wav / .m4a files whose duration is ≤ 30 s.
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

            // AVAudioPlayer gives a synchronous, reliable duration for local files.
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
    /// Called from AVFoundation internals — may not be on the main thread.
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

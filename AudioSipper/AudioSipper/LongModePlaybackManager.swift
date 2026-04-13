import Foundation

#if os(iOS)
import AVFoundation
import UIKit

// MARK: - Long Mode Playback State

enum LongPlaybackState: Equatable {
    case idle
    case playing
    case paused            // User-paused (clip or countdown)
    case withinFilePause   // Automatic interval pause inside a file (Default mode)
    case withinFileMute    // Automatic interval mute — audio keeps playing (Continue mode)
    case betweenFiles      // Fixed silence between files
    case finished
}

// MARK: - Saved Playback State

/// Persists the playback position between sessions (Long Mode only).
struct SavedPlaybackState: Codable {
    let fileURL: String            // URL string of the current file (fallback)
    let fileName: String
    let timestamp: TimeInterval    // Position within the file
    let folderURL: String?         // Folder URL (nil for single-file source)
    let folderName: String?
    let sourceType: String         // "file" or "folder"
    let includeSubfolders: Bool
    let fileBookmark: Data?        // Security-scoped bookmark for the file
    let folderBookmark: Data?      // Security-scoped bookmark for the folder

    private static let key = "LongMode_SavedPlaybackState"

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    static func load() -> SavedPlaybackState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedPlaybackState.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Resolves the file bookmark back to a security-scoped URL.
    /// Falls back to plain URL(string:) if bookmark resolution fails.
    func resolveFileURL() -> URL? {
        if let bookmark = fileBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                print("[AudioSipper] resolveFileURL: resolved from bookmark (stale=\(isStale))")
                return url
            }
        }
        print("[AudioSipper] resolveFileURL: falling back to URL string")
        return URL(string: fileURL)
    }

    /// Resolves the folder bookmark back to a security-scoped URL.
    func resolveFolderURL() -> URL? {
        if let bookmark = folderBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }
        guard let str = folderURL else { return nil }
        return URL(string: str)
    }
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

    /// True when the manager has loaded saved-session metadata and is waiting
    /// for the user to tap Play. The view checks this flag.
    @Published private(set) var restoredFromSave: Bool = false

    // MARK: Settings (set before/during session)

    var autoReplay: Bool = true
    var shuffle: Bool = true
    var fadeOutEnabled: Bool = false
    var continueMode: Bool = false
    var initialOffsetEnabled: Bool = true

    // MARK: Private State

    private let fader = AudioFader()
    private var audioPlayer: AVAudioPlayer?
    private var playlist: [URL] = []
    private var currentIndex: Int = 0

    /// The URL that `playFromRestoredPosition` will use.
    /// Set by `loadSavedSession`, consumed by `playFromRestoredPosition`.
    private var currentFileURL: URL?
    /// Seek-to time for a restored session. Applied once on play.
    private var pendingSeekTime: TimeInterval = 0

    // Timers
    private var countdownTimer: Timer?
    private var intervalTimer: Timer?
    private var progressTimer: Timer?

    // Pause settings
    private var intervalSeconds: Int = 60
    private var minPauseDuration: Int = 10
    private var maxPauseDuration: Int = 30
    private var betweenFilesPause: Int = 5

    // Interval tracking (wall-clock based so seeking doesn't affect it)
    private var elapsedPlaybackSinceLastPause: TimeInterval = 0
    private var lastWallClockTimestamp: CFTimeInterval = 0

    // Pause/resume bookkeeping
    private var activeFolderURL: URL?
    private var activeFileURL: URL?
    private var wasPlayingClipWhenPaused: Bool = false
    private var justStartedPlayback: Bool = false

    // Continue mode: track ended during mute
    private var trackEndedDuringMute: Bool = false
    // Continue mode: initial offset — true until the first mute of a track completes
    private var isFirstMuteOfTrack: Bool = true
    // When > 0, a buffer phase follows the initial random mute
    private var initialOffsetBuffer: Int = 0

    // Continue mode: asymmetric fade durations (computed from intervalSeconds)
    private var continueFadeOutDuration: TimeInterval { intervalSeconds >= 5 ? 0.9 : 0.5 }
    private var continueFadeInDuration: TimeInterval { intervalSeconds >= 5 ? 0.6 : 0.3 }

    // Source info for save/restore
    private var sourceType: String = "folder"
    private var sourceFolderName: String = ""
    private var sourceIncludeSubfolders: Bool = false

    // MARK: Init

    override init() {
        super.init()
        configureAudioSession()

        // Listen for app-going-to-background to save playback state
        NotificationCenter.default.addObserver(
            forName: .savePlaybackState,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.savePlaybackState()
            }
        }

        // Force-finish any in-progress fade when app is backgrounded
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fader.forceFinish()
            }
        }
    }

    // MARK: - Unified Audio Setup

    /// Single function that sets up AVAudioPlayer for a URL and starts playback.
    /// Both fresh sessions and restored sessions funnel through here.
    /// - Parameters:
    ///   - url: The audio file to play.
    ///   - seekTo: Optional position to seek to before playing (0 for fresh).
    /// - Returns: `true` if playback started successfully.
    @discardableResult
    private func setupAudioAndPlay(url: URL, seekTo: TimeInterval = 0) -> Bool {
        // Tear down any existing player (but NOT security-scoped access)
        audioPlayer?.stop()
        audioPlayer = nil
        stopAllTimers()

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            audioPlayer = player
            currentFileURL = url
            currentFileName = url.lastPathComponent
            duration = player.duration
            player.prepareToPlay()

            // Seek if needed
            let clampedSeek = min(max(seekTo, 0), player.duration)
            if clampedSeek > 0 {
                player.currentTime = clampedSeek
            }
            currentTime = clampedSeek

            // Reset interval tracking — fresh timer from this point
            elapsedPlaybackSinceLastPause = 0
            lastWallClockTimestamp = CACurrentMediaTime()

            // Reset pause bookkeeping so togglePlayPause works correctly
            wasPlayingClipWhenPaused = true

            // Prevent immediate interval pause on first progress tick
            justStartedPlayback = true

            // Reset initial offset for new track (Continue mode)
            isFirstMuteOfTrack = true
            initialOffsetBuffer = 0

            // Start playback
            print("[AudioSipper] PLAY CALLED for \(url.lastPathComponent)")
            player.play()
            state = .playing
            print("[AudioSipper] STATE -> \(state)")
            startProgressTimer()

            print("[AudioSipper] setupAudioAndPlay: playing \(url.lastPathComponent) from \(clampedSeek)s")
            return true
        } catch {
            print("[AudioSipper] setupAudioAndPlay: FAILED for \(url.lastPathComponent) — \(error)")
            currentFileURL = nil
            return false
        }
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
        self.sourceType = "folder"
        self.sourceFolderName = folderURL.lastPathComponent
        self.sourceIncludeSubfolders = recursive
        self.restoredFromSave = false

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
        self.sourceType = "file"
        self.sourceFolderName = ""
        self.sourceIncludeSubfolders = false
        self.restoredFromSave = false

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
        // If a fade is in progress, cancel it and pause immediately
        if fader.isFading {
            fader.cancel()
            audioPlayer?.volume = 1.0
        }

        switch state {
        case .playing:
            audioPlayer?.pause()
            stopProgressTimer()
            wasPlayingClipWhenPaused = true
            state = .paused

        case .withinFileMute:
            // Continue mode mute — pause audio, cancel countdown, restore volume
            countdownTimer?.invalidate()
            countdownTimer = nil
            audioPlayer?.pause()
            audioPlayer?.volume = 1.0
            stopProgressTimer()
            trackEndedDuringMute = false
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
        guard state == .playing || state == .paused || state == .withinFilePause
                || state == .withinFileMute || state == .betweenFiles else { return }

        trackEndedDuringMute = false
        stopAllTimers()

        if currentTime < 3.0 && currentIndex > 0 {
            currentIndex -= 1
        }
        playCurrentFile()
    }

    /// Next: skip to next file immediately.
    func next() {
        guard state == .playing || state == .paused || state == .withinFilePause
                || state == .withinFileMute || state == .betweenFiles else { return }

        trackEndedDuringMute = false
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

    /// Stop session entirely — full reset. Nothing from the current session is
    /// preserved. After this call the manager is back to its initial state and
    /// the user can change any settings before starting a fresh session.
    func stop() {
        // 1. Stop audio and release security-scoped resources / timers
        tearDown()

        // 2. Clear saved state so the next launch doesn't attempt resume
        SavedPlaybackState.clear()

        // 3. Clear playlist and file references
        playlist = []
        currentIndex = 0
        currentFileURL = nil

        // 4. Reset all published state
        state = .idle
        currentFileName = ""
        currentTime = 0
        duration = 0
        countdownSeconds = 0
        statusMessage = ""
        restoredFromSave = false

        // 5. Reset internal flags
        wasPlayingClipWhenPaused = false
        justStartedPlayback = false
        trackEndedDuringMute = false
        isFirstMuteOfTrack = true
        initialOffsetBuffer = 0
        elapsedPlaybackSinceLastPause = 0
        lastWallClockTimestamp = 0
        pendingSeekTime = 0

        // 6. Reset source metadata (sourceType/folder info remain as @AppStorage
        //    settings in the view — here we only clear the runtime references)
        sourceType = "folder"
        sourceFolderName = ""
        sourceIncludeSubfolders = false
    }

    // MARK: - Save / Restore

    /// Saves current playback position to persistent storage.
    /// Called when the app goes to background or is closed.
    func savePlaybackState() {
        guard let player = audioPlayer,
              currentIndex < playlist.count else { return }

        let fileUrl = playlist[currentIndex]

        // Create security-scoped bookmarks so we can re-access files after app restart
        let fileBookmark = try? fileUrl.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let folderBookmark: Data? = {
            guard let folder = activeFolderURL else { return nil }
            return try? folder.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }()

        let saved = SavedPlaybackState(
            fileURL: fileUrl.absoluteString,
            fileName: fileUrl.lastPathComponent,
            timestamp: player.currentTime,
            folderURL: activeFolderURL?.absoluteString,
            folderName: sourceFolderName.isEmpty ? nil : sourceFolderName,
            sourceType: sourceType,
            includeSubfolders: sourceIncludeSubfolders,
            fileBookmark: fileBookmark,
            folderBookmark: folderBookmark
        )
        saved.save()
        print("[AudioSipper] savePlaybackState: \(fileUrl.lastPathComponent) at \(player.currentTime)s bookmark=\(fileBookmark != nil)")
    }

    /// Lightweight restore: reads saved metadata, sets `currentFileURL` and
    /// `pendingSeekTime`, and sets `restoredFromSave = true`.
    /// Does NOT create an AVAudioPlayer or touch the audio engine.
    /// Returns the saved info so the view can populate its source UI.
    @discardableResult
    func loadSavedSession() -> SavedPlaybackState? {
        guard let saved = SavedPlaybackState.load(),
              let fileUrl = saved.resolveFileURL() else {
            return nil
        }

        // Store metadata only — no audio setup
        currentFileURL = fileUrl
        currentFileName = fileUrl.lastPathComponent
        pendingSeekTime = saved.timestamp
        restoredFromSave = true

        // Preserve folder context so playFromRestoredPosition can rebuild the playlist
        sourceType = saved.sourceType
        sourceFolderName = saved.folderName ?? ""
        sourceIncludeSubfolders = saved.includeSubfolders
        if saved.sourceType == "folder", let folderUrl = saved.resolveFolderURL() {
            activeFolderURL = folderUrl
        }

        print("[AudioSipper] loadSavedSession: \(fileUrl.lastPathComponent) at \(saved.timestamp)s source=\(saved.sourceType) — waiting for Play")
        return saved
    }

    /// Applies settings before resuming from a restored session.
    func applySettings(intervalSeconds: Int, minPause: Int, maxPause: Int, betweenFilesPause: Int, autoReplay: Bool) {
        self.intervalSeconds = intervalSeconds
        self.minPauseDuration = minPause
        self.maxPauseDuration = maxPause
        self.betweenFilesPause = betweenFilesPause
        self.autoReplay = autoReplay
    }

    /// Starts playback from a restored saved session.
    /// Goes through the same `setupAudioAndPlay` path as fresh sessions.
    /// Interval timer starts fresh from zero.
    func playFromRestoredPosition() {
        guard let url = currentFileURL else {
            print("[AudioSipper] playFromRestoredPosition: ABORT — currentFileURL is nil")
            assertionFailure("Missing file URL on play")
            return
        }

        print("[AudioSipper] playFromRestoredPosition: url=\(url.lastPathComponent) seekTo=\(pendingSeekTime)s source=\(sourceType)")

        // --- Rebuild playlist from folder or single file ---
        if sourceType == "folder", let folderUrl = activeFolderURL {
            // Acquire security-scoped access to the folder
            let folderAccess = folderUrl.startAccessingSecurityScopedResource()
            print("[AudioSipper] playFromRestoredPosition: folder access=\(folderAccess)")

            let files = Self.scanAudioFiles(in: folderUrl, recursive: sourceIncludeSubfolders)
            playlist = shuffle
                ? files.shuffled()
                : files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            // Find the current file's position in the playlist
            if let idx = playlist.firstIndex(where: { $0.lastPathComponent == url.lastPathComponent }) {
                currentIndex = idx
            } else {
                // File not found in folder — fall back to single-file playlist
                print("[AudioSipper] playFromRestoredPosition: file not found in folder, using single file")
                playlist = [url]
                currentIndex = 0
            }
        } else {
            // Single-file session
            playlist = [url]
            currentIndex = 0
        }

        // Use the playlist URL (which may differ from the bookmark URL in folder mode)
        let playUrl = playlist[currentIndex]

        // Acquire security-scoped access to the current file
        let hasAccess = playUrl.startAccessingSecurityScopedResource()
        if hasAccess {
            activeFileURL = playUrl
        }

        // Use the unified playback path
        let success = setupAudioAndPlay(url: playUrl, seekTo: pendingSeekTime)

        if success {
            restoredFromSave = false
            pendingSeekTime = 0
            print("[AudioSipper] playFromRestoredPosition: state=\(state) — playback started")
        } else {
            // Clean up on failure
            if hasAccess {
                playUrl.stopAccessingSecurityScopedResource()
                activeFileURL = nil
            }
            statusMessage = "Could not load saved file. It may have been moved."
            state = .idle
            restoredFromSave = false
            currentFileURL = nil
            SavedPlaybackState.clear()
            print("[AudioSipper] playFromRestoredPosition: FAILED — file could not be loaded")
        }
    }

    // MARK: - Private Playback

    /// Plays the file at `currentIndex` in the playlist from the beginning.
    /// Uses the unified `setupAudioAndPlay` path.
    private func playCurrentFile() {
        guard currentIndex < playlist.count else {
            advanceOrFinish()
            return
        }

        let url = playlist[currentIndex]
        if !setupAudioAndPlay(url: url, seekTo: 0) {
            // Unplayable file — skip silently and try next
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
        if justStartedPlayback {
            justStartedPlayback = false
            return
        }

        guard state == .playing, let player = audioPlayer else { return }

        // Update the seek bar position from the audio player
        currentTime = player.currentTime

        // Track elapsed time using wall clock so seeking doesn't affect it
        let now = CACurrentMediaTime()
        let delta = now - lastWallClockTimestamp
        lastWallClockTimestamp = now

        if delta > 0 && delta < 2.0 {
            // Only accumulate reasonable deltas (< 2s guards against
            // large jumps from app suspension or timer drift)
            elapsedPlaybackSinceLastPause += delta
        }

        if elapsedPlaybackSinceLastPause >= Double(intervalSeconds) {
            elapsedPlaybackSinceLastPause = 0

            if continueMode {
                // Continue mode: fade out then mute, keep audio playing, keep progress timer.
                // Fades are always active in Continue mode with asymmetric durations.
                fader.fadeOut(player: player, duration: continueFadeOutDuration) { [weak self] in
                    guard let self else { return }
                    self.audioPlayer?.volume = 0.0
                    self.startMuteCountdown()
                }
            } else {
                // Default mode: pause audio
                stopProgressTimer()
                if fadeOutEnabled {
                    fader.fadeOut(player: player, duration: 0.2) { [weak self] in
                        guard let self else { return }
                        self.audioPlayer?.pause()
                        self.audioPlayer?.volume = 1.0
                        self.startCountdown(from: nil, type: .withinFilePause)
                    }
                } else {
                    player.pause()
                    startCountdown(from: nil, type: .withinFilePause)
                }
            }
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
                        // Guard: bail if state changed while the timer was running
                        guard self.state == .withinFilePause else { return }
                        self.resumeAfterIntervalPause()
                    } else {
                        // Between files — guard, then use the single canonical "play next" path
                        guard self.state == .betweenFiles else { return }
                        self.advanceOrFinish()
                    }
                }
            }
        }
    }

    private func resumeAfterIntervalPause() {
        guard let player = audioPlayer else { return }
        // Ensure volume is restored (may be 0 if coming from initial offset buffer)
        player.volume = 1.0
        lastWallClockTimestamp = CACurrentMediaTime()
        justStartedPlayback = true
        player.play()
        state = .playing
        startProgressTimer()
    }

    // MARK: - Continue Mode (Mute Interval)

    /// Starts a mute countdown. Audio keeps playing at volume 0.
    /// The progress timer stays active so the seek bar updates.
    private func startMuteCountdown() {
        let total: Int

        if isFirstMuteOfTrack && initialOffsetEnabled && continueMode {
            // Initial Offset: random first mute between 1 and average mute duration.
            // After this mute, a buffer phase fills the remainder to reach the average.
            let avgMute = max(1, (minPauseDuration + maxPauseDuration) / 2)
            let randomFirst = avgMute > 1 ? Int.random(in: 1...avgMute) : 1
            initialOffsetBuffer = avgMute - randomFirst
            total = randomFirst
            isFirstMuteOfTrack = false
        } else if initialOffsetBuffer > 0 {
            // Buffer phase of initial offset — fill remaining silence
            total = initialOffsetBuffer
            initialOffsetBuffer = 0
        } else {
            // Normal mute duration
            isFirstMuteOfTrack = false
            total = minPauseDuration == maxPauseDuration
                ? minPauseDuration
                : Int.random(in: minPauseDuration...maxPauseDuration)
        }

        countdownSeconds = total
        trackEndedDuringMute = false
        state = .withinFileMute
        countdownTimer?.invalidate()

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.countdownSeconds -= 1
                if self.countdownSeconds <= 0 {
                    timer.invalidate()
                    self.countdownTimer = nil
                    // Guard: bail if state changed (e.g. user paused) while the timer was running
                    guard self.state == .withinFileMute else { return }
                    if self.initialOffsetBuffer > 0 {
                        // Buffer phase: pause audio to create the offset,
                        // then resume after the buffer countdown.
                        self.audioPlayer?.pause()
                        self.stopProgressTimer()
                        self.startCountdown(from: self.initialOffsetBuffer, type: .withinFilePause)
                        self.initialOffsetBuffer = 0
                    } else {
                        self.resumeAfterMute()
                    }
                }
            }
        }
    }

    /// Called when the mute countdown finishes.
    private func resumeAfterMute() {
        if trackEndedDuringMute {
            // Track ended while muted — move to next file
            // (between-files wait was already absorbed by the mute; see delegate)
            trackEndedDuringMute = false
            audioPlayer?.volume = 1.0
            currentIndex += 1
            advanceOrFinish()
        } else if let player = audioPlayer {
            // Normal resume: fade in and continue playing
            lastWallClockTimestamp = CACurrentMediaTime()
            justStartedPlayback = true
            state = .playing
            fader.fadeIn(player: player, duration: continueFadeInDuration) {
                // Fade-in complete — nothing else needed, already in .playing state
            }
        }
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        stopProgressTimer()
        lastWallClockTimestamp = CACurrentMediaTime()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard self != nil else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.state == .withinFileMute {
                    // During mute, just update the seek bar (audio still playing)
                    if let player = self.audioPlayer {
                        self.currentTime = player.currentTime
                    }
                } else {
                    self.checkIntervalPause()
                }
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func stopAllTimers() {
        fader.cancel()
        audioPlayer?.volume = 1.0
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
        fader.cancel()
        audioPlayer?.volume = 1.0
        audioPlayer?.stop()
        audioPlayer = nil
        currentFileURL = nil
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
            guard let self else { return }
            // Only handle natural track completion from states where it makes sense.
            // This prevents double-fires (AVAudioPlayer can occasionally fire the
            // delegate twice) from double-advancing the index or spawning duplicate timers.
            guard self.state == .playing || self.state == .withinFileMute else { return }

            if self.state == .withinFileMute {
                // Track ended while muted (Continue mode).
                // Compare remaining mute time vs between-files pause — wait for the larger.
                self.stopProgressTimer()
                self.trackEndedDuringMute = true
                let remainingMute = self.countdownSeconds
                let betweenPause = (self.currentIndex + 1 < self.playlist.count) ? self.betweenFilesPause : 0
                if betweenPause > remainingMute {
                    // Extend the countdown to the between-files duration
                    self.countdownSeconds = betweenPause
                }
                // Let the existing mute countdown timer finish and call resumeAfterMute
                return
            }

            // Cancel every in-flight timer/fader before scheduling a new one.
            self.stopAllTimers()
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

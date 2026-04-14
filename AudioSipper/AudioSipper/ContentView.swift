import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)

// MARK: - App Mode

enum AppMode: String, CaseIterable {
    case short = "Short"
    case long = "Long"
}

// MARK: - Long Mode Source Type

enum LongModeSource: String, CaseIterable {
    case file = "Single File"
    case folder = "Folder"
}

// MARK: - Long Mode Sub-Mode

enum LongModeSubMode: String, CaseIterable {
    case defaultMode = "Default"
    case continueMode = "Continue"
}

// MARK: - Root View

struct ContentView: View {

    @AppStorage("appMode") private var appMode: AppMode = .short

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                headerSection
                modeToggle
                divider

                switch appMode {
                case .short:
                    ShortModeView()
                case .long:
                    LongModeView()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
    }

    // MARK: Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Audio Sipper")
                .font(.largeTitle.bold())
                .foregroundColor(.primary)
            Text("Local clip shuffler \u{00B7} no accounts \u{00B7} no cloud")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHeading(.h1)
    }

    // MARK: Mode Toggle

    private var modeToggle: some View {
        Picker("Mode", selection: $appMode) {
            ForEach(AppMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Playback mode")
    }

    private var divider: some View {
        Divider()
            .background(Color(UIColor.separator))
    }
}

// MARK: - ============================================================
// MARK: - SHORT MODE VIEW
// MARK: - ============================================================

struct ShortModeView: View {

    @StateObject private var player = AudioPlaybackManager()

    // Folder selection
    @State private var showFolderPicker = false
    @State private var selectedFolderURL: URL?
    @State private var selectedFolderName: String = ""

    // Settings (persisted via @AppStorage)
    @AppStorage("short_includeSubfolders") private var includeSubfolders: Bool = false
    @AppStorage("short_shufflePlayback") private var shufflePlayback: Bool = true
    @AppStorage("short_autoReplay") private var autoReplay: Bool = false
    @AppStorage("short_minPauseText") private var minPauseText: String = "10"
    @AppStorage("short_maxPauseText") private var maxPauseText: String = "30"
    @AppStorage("short_lastValidMinPause") private var lastValidMinPause: Int = 10
    @AppStorage("short_lastValidMaxPause") private var lastValidMaxPause: Int = 30

    // Keyboard management
    @FocusState private var minPauseFieldFocused: Bool
    @FocusState private var maxPauseFieldFocused: Bool

    // MARK: Computed helpers

    private var canPlay: Bool {
        selectedFolderURL != nil
            && (player.state == .idle || player.state == .paused || player.state == .finished)
    }

    private var canPause: Bool {
        player.state == .playing || player.state == .countdown
    }

    private var canStop: Bool {
        player.state == .playing
            || player.state == .paused
            || player.state == .countdown
    }

    private var playButtonLabel: String {
        player.state == .paused ? "Resume" : "Play"
    }

    private var playButtonIcon: String {
        "play.fill"
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            folderSection
            settingsSection
            controlsSection
            statusSection
                .animation(.default, value: player.state)
                .animation(.default, value: player.currentFileName)
                .animation(.default, value: player.countdownSeconds)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    minPauseFieldFocused = false
                    maxPauseFieldFocused = false
                    commitPauseValues()
                }
            }
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerRepresentable(onFolderPicked: { url in
                selectedFolderURL = url
                selectedFolderName = url.lastPathComponent
                showFolderPicker = false
            })
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Sections

    private var divider: some View {
        Divider().background(Color(UIColor.separator))
    }

    // MARK: Folder

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Source Folder", icon: "folder")

            Button(action: { showFolderPicker = true }) {
                HStack(spacing: 12) {
                    Image(systemName: selectedFolderURL == nil ? "folder.badge.plus" : "folder.fill")
                        .font(.title3)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedFolderURL == nil ? "Select Folder\u{2026}" : "Selected Folder")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(selectedFolderURL == nil ? "Tap to choose" : selectedFolderName)
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .foregroundColor(.primary)
            }
            .accessibilityLabel(
                selectedFolderURL == nil
                    ? "Select folder"
                    : "Selected folder: \(selectedFolderName). Double-tap to change."
            )
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("Settings", icon: "slider.horizontal.3")

            Toggle(isOn: $includeSubfolders) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include Subfolders").foregroundColor(.primary)
                    Text("Recursively scan nested folders").font(.caption).foregroundColor(.secondary)
                }
            }
            .tint(Color(UIColor.systemBlue))
            .accessibilityLabel("Include subfolders")

            divider

            Toggle(isOn: $shufflePlayback) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shuffle").foregroundColor(.primary)
                    Text("Randomize playback order").font(.caption).foregroundColor(.secondary)
                }
            }
            .tint(Color(UIColor.systemBlue))
            .accessibilityLabel("Shuffle")

            divider

            Toggle(isOn: $autoReplay) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-Replay").foregroundColor(.primary)
                    Text("Loop playlist when all clips finish").font(.caption).foregroundColor(.secondary)
                }
            }
            .tint(Color(UIColor.systemBlue))
            .accessibilityLabel("Auto-Replay")
            .onChange(of: autoReplay) { player.autoReplay = autoReplay }

            divider

            PauseLengthEditor(
                minPauseText: $minPauseText,
                maxPauseText: $maxPauseText,
                lastValidMinPause: $lastValidMinPause,
                lastValidMaxPause: $lastValidMaxPause,
                minPauseFieldFocused: $minPauseFieldFocused,
                maxPauseFieldFocused: $maxPauseFieldFocused
            )
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(14)
    }

    // MARK: Controls

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Playback", icon: "waveform")

            HStack(spacing: 10) {
                ControlButton(title: playButtonLabel, icon: playButtonIcon, style: .primary, isEnabled: canPlay, action: handlePlayTap)
                ControlButton(title: "Pause", icon: "pause.fill", style: .secondary, isEnabled: canPause, action: { player.togglePause() })
                ControlButton(title: "Stop", icon: "stop.fill", style: .secondary, isEnabled: canStop, action: { player.stop() })
            }
        }
    }

    // MARK: Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !player.statusMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").accessibilityHidden(true)
                    Text(player.statusMessage).font(.footnote)
                }
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !player.currentFileName.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Now Playing", systemImage: "music.note")
                        .font(.caption.bold()).foregroundColor(.secondary)
                    Text(player.currentFileName)
                        .font(.body).foregroundColor(.primary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Now playing: \(player.currentFileName)")
            }

            if player.state == .countdown {
                HStack(spacing: 10) {
                    Image(systemName: "timer").foregroundColor(.primary).accessibilityHidden(true)
                    Text("Next clip in \(player.countdownSeconds)s")
                        .font(.body.monospacedDigit()).foregroundColor(.primary)
                    Spacer()
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .accessibilityLabel("Next clip in \(player.countdownSeconds) seconds")
            }
        }
    }

    // MARK: Helpers

    private func sectionLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.headline).foregroundColor(.primary)
    }

    private func handlePlayTap() {
        guard let url = selectedFolderURL else { return }
        commitPauseValues()
        minPauseFieldFocused = false
        maxPauseFieldFocused = false

        if player.state == .paused {
            player.togglePause()
        } else {
            player.startSession(
                folderURL: url,
                recursive: includeSubfolders,
                minPause: lastValidMinPause,
                maxPause: max(lastValidMinPause, lastValidMaxPause),
                shuffle: shufflePlayback,
                autoReplay: autoReplay
            )
        }
    }

    private func commitPauseValues() {
        if let v = Int(minPauseText.trimmingCharacters(in: .whitespaces)), v > 0 {
            lastValidMinPause = v
        } else { minPauseText = "\(lastValidMinPause)" }

        if let v = Int(maxPauseText.trimmingCharacters(in: .whitespaces)), v > 0 {
            lastValidMaxPause = v
        } else { maxPauseText = "\(lastValidMaxPause)" }
    }
}

// MARK: - ============================================================
// MARK: - LONG MODE VIEW
// MARK: - ============================================================

struct LongModeView: View {

    @StateObject private var player = LongModePlaybackManager()

    // Source selection
    @AppStorage("long_sourceType") private var sourceTypeRaw: String = LongModeSource.folder.rawValue
    @State private var showFolderPicker = false
    @State private var showFilePicker = false
    @State private var selectedFolderURL: URL?
    @State private var selectedFolderName: String = ""
    @State private var selectedFileURL: URL?
    @State private var selectedFileName: String = ""

    // Settings (persisted via @AppStorage)
    @AppStorage("long_subMode") private var subModeRaw: String = LongModeSubMode.defaultMode.rawValue
    @AppStorage("long_includeSubfolders") private var includeSubfolders: Bool = false
    @AppStorage("long_shufflePlayback") private var shufflePlayback: Bool = true
    @AppStorage("long_autoReplay") private var autoReplay: Bool = true

    // Interval
    @AppStorage("long_intervalText") private var intervalText: String = "60"
    @AppStorage("long_lastValidInterval") private var lastValidInterval: Int = 60

    // Within-file pause (Min/Max)
    @AppStorage("long_minPauseText") private var minPauseText: String = "10"
    @AppStorage("long_maxPauseText") private var maxPauseText: String = "30"
    @AppStorage("long_lastValidMinPause") private var lastValidMinPause: Int = 10
    @AppStorage("long_lastValidMaxPause") private var lastValidMaxPause: Int = 30

    // Between-files pause (fixed)
    @AppStorage("long_betweenFilesPauseText") private var betweenFilesPauseText: String = "5"
    @AppStorage("long_lastValidBetweenFilesPause") private var lastValidBetweenFilesPause: Int = 5

    // Fade
    @AppStorage("long_fadeOutEnabled") private var fadeOutEnabled: Bool = false

    // Initial Offset (Continue mode)
    @AppStorage("long_initialOffsetEnabled") private var initialOffsetEnabled: Bool = true

    // Seek bar
    @State private var isSeeking: Bool = false
    @State private var seekValue: Double = 0

    // Keyboard
    @FocusState private var intervalFieldFocused: Bool
    @FocusState private var minPauseFieldFocused: Bool
    @FocusState private var maxPauseFieldFocused: Bool
    @FocusState private var betweenFilesFieldFocused: Bool

    // MARK: Computed helpers

    private var hasSource: Bool {
        sourceTypeRaw == LongModeSource.folder.rawValue ? selectedFolderURL != nil : selectedFileURL != nil
    }

    private var canPlay: Bool {
        (hasSource || player.restoredFromSave) && (player.state == .idle || player.state == .finished)
    }

    private var isActive: Bool {
        player.state == .playing || player.state == .paused
            || player.state == .withinFilePause || player.state == .withinFileMute
            || player.state == .betweenFiles
    }

    private var playPauseIcon: String {
        // Mute interval: audio still playing (muted) — show Pause icon
        (player.state == .playing || player.state == .withinFileMute) ? "pause.fill" : "play.fill"
    }

    private var playPauseLabel: String {
        switch player.state {
        case .playing: return "Pause"
        case .withinFileMute: return "Pause"
        case .paused: return "Resume"
        default: return "Play"
        }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            playerSection
            settingsSection
            statusSection
                .animation(.default, value: player.state)
                .animation(.default, value: player.currentFileName)
                .animation(.default, value: player.countdownSeconds)
        }
        .onAppear { restoreSavedSession() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    dismissAllKeyboards()
                    commitAllValues()
                }
            }
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerRepresentable(onFolderPicked: { url in
                selectedFolderURL = url
                selectedFolderName = url.lastPathComponent
                showFolderPicker = false
            })
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showFilePicker) {
            FilePickerRepresentable(onFilePicked: { url in
                selectedFileURL = url
                selectedFileName = url.lastPathComponent
                showFilePicker = false
            })
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Player Section (always visible, not scrolled away)

    private var playerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("Player", icon: "waveform")

            // Current filename
            if !player.currentFileName.isEmpty {
                Text(player.currentFileName)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Seek bar
            if player.duration > 0 {
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { isSeeking ? seekValue : player.currentTime },
                            set: { newVal in
                                isSeeking = true
                                seekValue = newVal
                            }
                        ),
                        in: 0...max(player.duration, 1),
                        onEditingChanged: { editing in
                            if !editing {
                                player.seek(to: seekValue)
                                isSeeking = false
                            }
                        }
                    )
                    .tint(Color(UIColor.systemBlue))
                    .accessibilityLabel("Seek position")
                    .accessibilityValue(formatTime(player.currentTime))

                    HStack {
                        Text(formatTime(isSeeking ? seekValue : player.currentTime))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatTime(player.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Playback controls: Previous | Play/Pause | Next | Stop
            HStack(spacing: 10) {
                ControlButton(
                    title: "Previous",
                    icon: "backward.fill",
                    style: .secondary,
                    isEnabled: isActive,
                    action: { player.previous() }
                )

                ControlButton(
                    title: playPauseLabel,
                    icon: playPauseIcon,
                    style: .primary,
                    isEnabled: (canPlay || isActive) && player.state != .withinFilePause && player.state != .withinFileMute,
                    action: handlePlayPauseTap
                )

                ControlButton(
                    title: "Next",
                    icon: "forward.fill",
                    style: .secondary,
                    isEnabled: isActive,
                    action: { player.next() }
                )

                ControlButton(
                    title: "Stop",
                    icon: "stop.fill",
                    style: .secondary,
                    isEnabled: isActive,
                    action: { player.stop() }
                )
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(14)
    }

    // MARK: - Settings Section (scrollable)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("Settings", icon: "slider.horizontal.3")

            // Source selector
            VStack(alignment: .leading, spacing: 8) {
                Text("Source").foregroundColor(.primary)
                Picker("Source", selection: $sourceTypeRaw) {
                    ForEach(LongModeSource.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Source type")
            }

            // Source picker button
            if sourceTypeRaw == LongModeSource.folder.rawValue {
                sourceFolderButton
            } else {
                sourceFileButton
            }

            // Subfolder toggle (only for folder)
            if sourceTypeRaw == LongModeSource.folder.rawValue {
                divider
                Toggle(isOn: $includeSubfolders) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include Subfolders").foregroundColor(.primary)
                        Text("Recursively scan nested folders").font(.caption).foregroundColor(.secondary)
                    }
                }
                .tint(Color(UIColor.systemBlue))
                .accessibilityLabel("Include subfolders")
            }

            divider

            // Shuffle toggle
            Toggle(isOn: $shufflePlayback) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shuffle").foregroundColor(.primary)
                    Text("Randomize playback order").font(.caption).foregroundColor(.secondary)
                }
            }
            .tint(Color(UIColor.systemBlue))
            .accessibilityLabel("Shuffle")

            divider

            // Auto-Replay toggle
            Toggle(isOn: $autoReplay) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-Replay").foregroundColor(.primary)
                    Text("Loop when all files finish").font(.caption).foregroundColor(.secondary)
                }
            }
            .tint(Color(UIColor.systemBlue))
            .accessibilityLabel("Auto-Replay")
            .onChange(of: autoReplay) { player.autoReplay = autoReplay }

            divider

            // Sub-mode selector
            VStack(alignment: .leading, spacing: 8) {
                Text("Interval Mode").foregroundColor(.primary)
                Text(subModeRaw == LongModeSubMode.continueMode.rawValue
                     ? "Audio keeps playing but is muted during intervals"
                     : "Audio pauses during intervals")
                    .font(.caption).foregroundColor(.secondary)
                Picker("Interval Mode", selection: $subModeRaw) {
                    ForEach(LongModeSubMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Interval mode")
            }
            .onChange(of: subModeRaw) {
                player.continueMode = (subModeRaw == LongModeSubMode.continueMode.rawValue)
            }

            // Initial Offset (Continue mode only)
            if subModeRaw == LongModeSubMode.continueMode.rawValue {
                Toggle(isOn: $initialOffsetEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Initial Offset").foregroundColor(.primary)
                        Text("Varies how long the first mute lasts so different parts of a track are heard each time")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .tint(Color(UIColor.systemBlue))
                .accessibilityLabel("Initial Offset")
                .onChange(of: initialOffsetEnabled) { player.initialOffsetEnabled = initialOffsetEnabled }
            }

            divider

            // Interval setting
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(subModeRaw == LongModeSubMode.continueMode.rawValue ? "Mute Interval" : "Pause Interval").foregroundColor(.primary)
                    Text(subModeRaw == LongModeSubMode.continueMode.rawValue ? "Insert a mute every X seconds" : "Insert a pause every X seconds").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                TextField("60", text: $intervalText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .frame(width: 70)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(Color(UIColor.tertiarySystemBackground))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(UIColor.separator), lineWidth: 1))
                    .focused($intervalFieldFocused)
                    .onSubmit { commitAllValues() }
                    .onChange(of: intervalFieldFocused) { if !intervalFieldFocused { commitAllValues() } }
                    .accessibilityLabel("Pause interval")
                    .accessibilityValue("\(intervalText) seconds")
                Text("s").foregroundColor(.secondary).accessibilityHidden(true)
            }

            divider

            // Within-file pause/mute duration (Min/Max) — shared component
            PauseLengthEditor(
                minPauseText: $minPauseText,
                maxPauseText: $maxPauseText,
                lastValidMinPause: $lastValidMinPause,
                lastValidMaxPause: $lastValidMaxPause,
                minPauseFieldFocused: $minPauseFieldFocused,
                maxPauseFieldFocused: $maxPauseFieldFocused,
                isMuteMode: subModeRaw == LongModeSubMode.continueMode.rawValue
            )

            // Between-files pause (folder only)
            if sourceTypeRaw == LongModeSource.folder.rawValue {
                divider
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pause Between Files").foregroundColor(.primary)
                        Text("Fixed silence between files").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    TextField("5", text: $betweenFilesPauseText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .frame(width: 60)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(Color(UIColor.tertiarySystemBackground))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(UIColor.separator), lineWidth: 1))
                        .focused($betweenFilesFieldFocused)
                        .onSubmit { commitAllValues() }
                        .onChange(of: betweenFilesFieldFocused) { if !betweenFilesFieldFocused { commitAllValues() } }
                        .accessibilityLabel("Pause between files")
                        .accessibilityValue("\(betweenFilesPauseText) seconds")
                    Text("s").foregroundColor(.secondary).accessibilityHidden(true)
                }
            }

            // Fade-out toggle (Default mode only — Continue mode has its own fades)
            if subModeRaw == LongModeSubMode.defaultMode.rawValue {
                divider

                Toggle(isOn: $fadeOutEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fade-Out on Pause").foregroundColor(.primary)
                        Text("500ms fade before pause intervals").font(.caption).foregroundColor(.secondary)
                    }
                }
                .tint(Color(UIColor.systemBlue))
                .accessibilityLabel("Fade-Out on Pause")
                .onChange(of: fadeOutEnabled) { player.fadeOutEnabled = fadeOutEnabled }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(14)
    }

    // MARK: Source Buttons

    private var sourceFolderButton: some View {
        Button(action: { showFolderPicker = true }) {
            HStack(spacing: 12) {
                Image(systemName: selectedFolderURL == nil ? "folder.badge.plus" : "folder.fill")
                    .font(.title3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedFolderURL == nil ? "Select Folder\u{2026}" : "Selected Folder")
                        .font(.caption).foregroundColor(.secondary)
                    Text(selectedFolderURL == nil ? "Tap to choose" : selectedFolderName)
                        .font(.body).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.secondary).accessibilityHidden(true)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.tertiarySystemBackground))
            .cornerRadius(12)
            .foregroundColor(.primary)
        }
    }

    private var sourceFileButton: some View {
        Button(action: { showFilePicker = true }) {
            HStack(spacing: 12) {
                Image(systemName: selectedFileURL == nil ? "doc.badge.plus" : "doc.fill")
                    .font(.title3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedFileURL == nil ? "Select File\u{2026}" : "Selected File")
                        .font(.caption).foregroundColor(.secondary)
                    Text(selectedFileURL == nil ? "Tap to choose" : selectedFileName)
                        .font(.body).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.secondary).accessibilityHidden(true)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.tertiarySystemBackground))
            .cornerRadius(12)
            .foregroundColor(.primary)
        }
    }

    // MARK: Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !player.statusMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").accessibilityHidden(true)
                    Text(player.statusMessage).font(.footnote)
                }
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Countdown (within-file pause/mute or between-files)
            if player.state == .withinFilePause {
                countdownBanner(label: "Pause", seconds: player.countdownSeconds)
            } else if player.state == .withinFileMute {
                countdownBanner(label: "Mute", seconds: player.countdownSeconds)
            } else if player.state == .betweenFiles {
                countdownBanner(label: "Next file in", seconds: player.countdownSeconds)
            }
        }
    }

    private func countdownBanner(label: String, seconds: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "timer").foregroundColor(.primary).accessibilityHidden(true)
            Text("\(label) \(seconds)s")
                .font(.body.monospacedDigit()).foregroundColor(.primary)
            Spacer()
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .accessibilityLabel("\(label) \(seconds) seconds")
    }

    // MARK: - Helpers

    private var divider: some View {
        Divider().background(Color(UIColor.separator))
    }

    private func sectionLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.headline).foregroundColor(.primary)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let t = max(0, time)
        let minutes = Int(t) / 60
        let seconds = Int(t) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: Actions

    /// Silently restores a saved session on appear — populates source UI and
    /// pre-loads file + seek bar. No prompts shown.
    private func restoreSavedSession() {
        guard let saved = player.loadSavedSession() else { return }

        // Populate the source selection UI (folder/file URL and name only).
        // Settings like sourceType, includeSubfolders, shuffle, etc. are
        // already persisted independently via @AppStorage, so we don't
        // overwrite them here — the user's latest preference wins.
        if saved.sourceType == "folder" {
            if let folderUrl = saved.resolveFolderURL() {
                selectedFolderURL = folderUrl
                selectedFolderName = saved.folderName ?? folderUrl.lastPathComponent
            }
        } else {
            if let fileUrl = saved.resolveFileURL() {
                selectedFileURL = fileUrl
                selectedFileName = saved.fileName
            }
        }
    }

    private func handlePlayPauseTap() {
        print("[AudioSipper] Play tapped - restored: \(player.restoredFromSave), state: \(player.state)")

        // Block taps during automatic rest/mute intervals (safety net alongside .disabled)
        guard player.state != .withinFilePause && player.state != .withinFileMute else { return }

        if isActive {
            player.togglePlayPause()
            return
        }

        // If restored from a saved session, apply current settings then play
        if player.restoredFromSave {
            commitAllValues()
            dismissAllKeyboards()
            player.fadeOutEnabled = fadeOutEnabled
            player.continueMode = (subModeRaw == LongModeSubMode.continueMode.rawValue)
            player.initialOffsetEnabled = initialOffsetEnabled
            player.applySettings(
                intervalSeconds: lastValidInterval,
                minPause: lastValidMinPause,
                maxPause: max(lastValidMinPause, lastValidMaxPause),
                betweenFilesPause: lastValidBetweenFilesPause,
                autoReplay: autoReplay
            )
            player.playFromRestoredPosition()
            return
        }

        commitAllValues()
        dismissAllKeyboards()
        player.fadeOutEnabled = fadeOutEnabled
        player.continueMode = (subModeRaw == LongModeSubMode.continueMode.rawValue)
        player.initialOffsetEnabled = initialOffsetEnabled

        if sourceTypeRaw == LongModeSource.folder.rawValue {
            guard let url = selectedFolderURL else { return }
            player.startFolderSession(
                folderURL: url,
                recursive: includeSubfolders,
                intervalSeconds: lastValidInterval,
                minPause: lastValidMinPause,
                maxPause: max(lastValidMinPause, lastValidMaxPause),
                betweenFilesPause: lastValidBetweenFilesPause,
                shuffle: shufflePlayback,
                autoReplay: autoReplay
            )
        } else {
            guard let url = selectedFileURL else { return }
            player.startFileSession(
                fileURL: url,
                intervalSeconds: lastValidInterval,
                minPause: lastValidMinPause,
                maxPause: max(lastValidMinPause, lastValidMaxPause),
                autoReplay: autoReplay
            )
        }
    }

    private func dismissAllKeyboards() {
        intervalFieldFocused = false
        minPauseFieldFocused = false
        maxPauseFieldFocused = false
        betweenFilesFieldFocused = false
    }

    private func commitAllValues() {
        if let v = Int(intervalText.trimmingCharacters(in: .whitespaces)), v > 0 {
            lastValidInterval = v
        } else { intervalText = "\(lastValidInterval)" }

        if let v = Int(minPauseText.trimmingCharacters(in: .whitespaces)), v > 0 {
            lastValidMinPause = v
        } else { minPauseText = "\(lastValidMinPause)" }

        if let v = Int(maxPauseText.trimmingCharacters(in: .whitespaces)), v > 0 {
            lastValidMaxPause = v
        } else { maxPauseText = "\(lastValidMaxPause)" }

        if let v = Int(betweenFilesPauseText.trimmingCharacters(in: .whitespaces)), v > 0 {
            lastValidBetweenFilesPause = v
        } else { betweenFilesPauseText = "\(lastValidBetweenFilesPause)" }
    }
}

// MARK: - ============================================================
// MARK: - SHARED COMPONENTS
// MARK: - ============================================================

// MARK: - Pause Length Editor (shared between Short and Long Mode)

struct PauseLengthEditor: View {

    @Binding var minPauseText: String
    @Binding var maxPauseText: String
    @Binding var lastValidMinPause: Int
    @Binding var lastValidMaxPause: Int
    var minPauseFieldFocused: FocusState<Bool>.Binding
    var maxPauseFieldFocused: FocusState<Bool>.Binding
    var isMuteMode: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isMuteMode ? "Mute Length" : "Pause Length").foregroundColor(.primary)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isMuteMode ? "Min Mute" : "Min Pause").font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        TextField("10", text: $minPauseText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .frame(width: 60)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .background(Color(UIColor.tertiarySystemBackground))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(UIColor.separator), lineWidth: 1))
                            .focused(minPauseFieldFocused)
                            .onSubmit { commitValues() }
                            .onChange(of: minPauseFieldFocused.wrappedValue) { if !minPauseFieldFocused.wrappedValue { commitValues() } }
                            .accessibilityLabel(isMuteMode ? "Minimum mute duration" : "Minimum pause duration")
                            .accessibilityValue("\(minPauseText) seconds")
                        Text("s").foregroundColor(.secondary).accessibilityHidden(true)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(isMuteMode ? "Max Mute" : "Max Pause").font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        TextField("30", text: $maxPauseText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .frame(width: 60)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .background(Color(UIColor.tertiarySystemBackground))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(UIColor.separator), lineWidth: 1))
                            .focused(maxPauseFieldFocused)
                            .onSubmit { commitValues() }
                            .onChange(of: maxPauseFieldFocused.wrappedValue) { if !maxPauseFieldFocused.wrappedValue { commitValues() } }
                            .accessibilityLabel(isMuteMode ? "Maximum mute duration" : "Maximum pause duration")
                            .accessibilityValue("\(maxPauseText) seconds")
                        Text("s").foregroundColor(.secondary).accessibilityHidden(true)
                    }
                }

                Spacer()
            }

            if lastValidMinPause > lastValidMaxPause {
                Label("Min must be less than Max", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(Color(UIColor.systemOrange))
            } else {
                Text("Set both values equal for fixed pauses")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func commitValues() {
        if let v = Int(minPauseText.trimmingCharacters(in: .whitespaces)), v > 0 {
            lastValidMinPause = v
        } else { minPauseText = "\(lastValidMinPause)" }

        if let v = Int(maxPauseText.trimmingCharacters(in: .whitespaces)), v > 0 {
            lastValidMaxPause = v
        } else { maxPauseText = "\(lastValidMaxPause)" }
    }
}

// MARK: - ControlButton

/// Three-state button: primary (filled), secondary (outlined), disabled (muted).
/// Uses icons + labels so state is never conveyed by colour alone.
struct ControlButton: View {

    enum Style { case primary, secondary }

    let title: String
    let icon: String
    let style: Style
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2).accessibilityHidden(true)
                Text(title)
                    .font(.caption.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(buttonBackground)
            .foregroundColor(buttonForeground)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(buttonBorder, lineWidth: 1))
        }
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityHint(isEnabled ? "" : "Unavailable")
    }

    private var buttonBackground: Color {
        switch (style, isEnabled) {
        case (.primary, true):   return Color(UIColor.systemBlue)
        case (.primary, false):  return Color(UIColor.systemBlue).opacity(0.25)
        case (.secondary, _):    return Color(UIColor.secondarySystemBackground)
        }
    }

    private var buttonForeground: Color {
        switch (style, isEnabled) {
        case (.primary, true):   return .white
        case (.primary, false):  return Color(UIColor.tertiaryLabel)
        case (.secondary, true): return .primary
        case (.secondary, false): return Color(UIColor.quaternaryLabel)
        }
    }

    private var buttonBorder: Color {
        (style == .secondary && isEnabled)
            ? Color(UIColor.separator)
            : Color.clear
    }
}

// MARK: - File Picker (for single file selection in Long Mode)

struct FilePickerRepresentable: UIViewControllerRepresentable {
    let onFilePicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFilePicked: onFilePicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onFilePicked: (URL) -> Void
        init(onFilePicked: @escaping (URL) -> Void) { self.onFilePicked = onFilePicked }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onFilePicked(url)
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
#endif

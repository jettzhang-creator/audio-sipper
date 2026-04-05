import SwiftUI

#if os(iOS)
// MARK: - Root View

struct ContentView: View {

    @StateObject private var player = AudioPlaybackManager()

    // Folder selection
    @State private var showFolderPicker = false
    @State private var selectedFolderURL: URL?
    @State private var selectedFolderName: String = ""

    // Settings
    @State private var includeSubfolders: Bool = false
    @State private var shufflePlayback: Bool = true
    @State private var autoReplay: Bool = false
    @State private var pauseDurationText: String = "3"
    @State private var lastValidPauseDuration: Int = 3

    // Keyboard management
    @FocusState private var pauseFieldFocused: Bool

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
        player.state == .paused ? "play.fill" : "play.fill"
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                headerSection
                divider
                folderSection
                settingsSection
                controlsSection
                statusSection
                    .animation(.default, value: player.state)
                    .animation(.default, value: player.currentFileName)
                    .animation(.default, value: player.countdownSeconds)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        // Keyboard Done button
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    pauseFieldFocused = false
                    commitPauseDuration()
                }
            }
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerRepresentable { url in
                selectedFolderURL = url
                selectedFolderName = url.lastPathComponent
                showFolderPicker = false
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Audio Sipper")
                .font(.largeTitle.bold())
                .foregroundColor(.primary)
            Text("Local clip shuffler · no accounts · no cloud")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHeading(.h1)
    }

    private var divider: some View {
        Divider()
            .background(Color(UIColor.separator))
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
                        Text(selectedFolderURL == nil ? "Select Folder…" : "Selected Folder")
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

            // Subfolder toggle
            Toggle(isOn: $includeSubfolders) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include Subfolders")
                        .foregroundColor(.primary)
                    Text("Recursively scan nested folders")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(Color(UIColor.systemBlue))
            .accessibilityLabel("Include subfolders")
            .accessibilityHint(includeSubfolders ? "On. Subfolders will be scanned." : "Off. Only top-level files scanned.")

            divider

            // Shuffle toggle
            Toggle(isOn: $shufflePlayback) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shuffle")
                        .foregroundColor(.primary)
                    Text("Randomize playback order")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(Color(UIColor.systemBlue))
            .accessibilityLabel("Shuffle")
            .accessibilityHint(shufflePlayback ? "On. Clips will play in random order." : "Off. Clips will play in alphabetical order.")

            divider

            // Auto-replay toggle
            Toggle(isOn: $autoReplay) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-Replay")
                        .foregroundColor(.primary)
                    Text("Loop playlist when all clips finish")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(Color(UIColor.systemBlue))
            .accessibilityLabel("Auto-Replay")
            .accessibilityHint(autoReplay ? "On. Playlist will loop." : "Off. Playback stops after last clip.")
            .onChange(of: autoReplay) { player.autoReplay = autoReplay }

            divider

            // Pause duration
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pause Duration")
                        .foregroundColor(.primary)
                    Text("Seconds between clips")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Text box — invalid input reverts silently to last valid value
                TextField("3", text: $pauseDurationText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .frame(width: 60)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(Color(UIColor.tertiarySystemBackground))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(UIColor.separator), lineWidth: 1)
                    )
                    .focused($pauseFieldFocused)
                    .onSubmit { commitPauseDuration() }
                    .onChange(of: pauseFieldFocused) {
                        if !pauseFieldFocused { commitPauseDuration() }
                    }
                    .accessibilityLabel("Pause duration")
                    .accessibilityValue("\(pauseDurationText) seconds")

                Text("s")
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
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
                ControlButton(
                    title: playButtonLabel,
                    icon: playButtonIcon,
                    style: .primary,
                    isEnabled: canPlay,
                    action: handlePlayTap
                )

                ControlButton(
                    title: "Pause",
                    icon: "pause.fill",
                    style: .secondary,
                    isEnabled: canPause,
                    action: { player.togglePause() }
                )

                ControlButton(
                    title: "Stop",
                    icon: "stop.fill",
                    style: .secondary,
                    isEnabled: canStop,
                    action: { player.stop() }
                )
            }
        }
    }

    // MARK: Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Inline feedback (scan status, errors)
            if !player.statusMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .accessibilityHidden(true)
                    Text(player.statusMessage)
                        .font(.footnote)
                }
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Now playing
            if !player.currentFileName.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Now Playing", systemImage: "music.note")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)

                    Text(player.currentFileName)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Now playing: \(player.currentFileName)")
            }

            // Countdown — shown only during pause phase
            if player.state == .countdown {
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .foregroundColor(.primary)
                        .accessibilityHidden(true)
                    Text("Next clip in \(player.countdownSeconds)s")
                        .font(.body.monospacedDigit())
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .accessibilityLabel("Next clip in \(player.countdownSeconds) seconds")
            }
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.headline)
            .foregroundColor(.primary)
    }

    // MARK: Actions

    private func handlePlayTap() {
        guard let url = selectedFolderURL else { return }
        commitPauseDuration()
        pauseFieldFocused = false

        if player.state == .paused {
            player.togglePause()          // resume existing session
        } else {
            player.startSession(
                folderURL: url,
                recursive: includeSubfolders,
                pauseDuration: lastValidPauseDuration,
                shuffle: shufflePlayback,
                autoReplay: autoReplay
            )
        }
    }

    /// Validates `pauseDurationText`; reverts silently if invalid (non-positive or non-integer).
    private func commitPauseDuration() {
        if let value = Int(pauseDurationText.trimmingCharacters(in: .whitespaces)), value > 0 {
            lastValidPauseDuration = value
        } else {
            pauseDurationText = "\(lastValidPauseDuration)"
        }
    }
}

// MARK: - ControlButton

/// Three-state button: primary (filled), secondary (outlined), disabled (muted).
/// Uses icons + labels so state is never conveyed by colour alone.
private struct ControlButton: View {

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
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(buttonBackground)
            .foregroundColor(buttonForeground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(buttonBorder, lineWidth: 1)
            )
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

// MARK: - Preview

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
#endif

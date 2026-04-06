import SwiftUI

@main
struct AudioSipperApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)   // Mandatory dark UI — not a user preference
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background {
                // Notify Long Mode to save playback position
                NotificationCenter.default.post(name: .savePlaybackState, object: nil)
            }
        }
    }
}

extension Notification.Name {
    static let savePlaybackState = Notification.Name("AudioSipper.savePlaybackState")
}

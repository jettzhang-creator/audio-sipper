import SwiftUI

@main
struct AudioSipperApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)   // Mandatory dark UI — not a user preference
        }
    }
}

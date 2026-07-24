import SwiftUI

@main
struct Kestrel_Watch_Watch_AppApp: App {
    @State private var session = WatchSessionManager.shared

    var body: some Scene {
        WindowGroup {
            // The welcome screen is layered *over* the record screen rather than
            // shown in its place, so the record control isn't torn down and
            // rebuilt — with its morph geometry re-measured — as it goes away.
            ZStack {
                ContentView()
                    // The Start Recording complication opens the app with this URL
                    // (see `RecordingIntentRequest.startRecordingURL`). Delivered
                    // in-process here, so `fire()` reliably reaches the app: the
                    // flag covers a cold launch (drained on `scenePhase` active) and
                    // the notification covers an already-active app.
                    .onOpenURL { url in
                        if url == RecordingIntentRequest.startRecordingURL {
                            RecordingIntentRequest.fire()
                        }
                    }
                if session.needsOnboarding {
                    WatchWelcomeView {
                        await session.requestOnboardingPermissions()
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: session.needsOnboarding)
        }
    }
}

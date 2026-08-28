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
                // Nothing here handles a start-recording deep link any more: the
                // complication deliberately just opens the app rather than
                // kicking off a walk on a stray tap (see
                // `StartRecordingComplicationView`), so no shipped surface
                // produces that URL. `StartRecordingIntent` — which Shortcuts can
                // still run on the watch — reaches the app through
                // `RecordingIntentRequest.fire()` instead, drained by
                // `ContentView`'s scene-phase and notification handlers.
                ContentView()
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

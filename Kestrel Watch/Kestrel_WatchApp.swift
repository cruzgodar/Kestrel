import SwiftUI

@main
struct Kestrel_Watch_Watch_AppApp: App {
    var body: some Scene {
        WindowGroup {
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
        }
    }
}

import SwiftUI

@main
struct KestrelApp: App {
    @State private var recordingManager = RecordingManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(recordingManager)
        }
    }
}

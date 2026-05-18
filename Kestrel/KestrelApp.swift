import SwiftUI

@main
struct KestrelApp: App {
    @State private var recordingManager: RecordingManager
    @State private var lifeListStore = LifeListStore()

    init() {
        let manager = RecordingManager()
        // Kick off BirdNET + geo-model loading in the background as soon as
        // the app launches, so the first Start Recording tap is instant.
        manager.preload()
        _recordingManager = State(wrappedValue: manager)
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Identify", systemImage: "magnifyingglass") {
                    ContentView()
                        .environment(recordingManager)
                }
                Tab("Life List", systemImage: "bird") {
                    NavigationStack {
                        LifeListView()
                    }
                    .environment(lifeListStore)
                }
            }
        }
    }
}

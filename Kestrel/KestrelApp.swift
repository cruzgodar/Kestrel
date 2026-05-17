import SwiftUI

@main
struct KestrelApp: App {
    @State private var recordingManager = RecordingManager()
    @State private var lifeListStore = LifeListStore()

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

import SwiftUI

@main
struct KestrelApp: App {
    @State private var recordingManager: RecordingManager
    @State private var lifeListStore = LifeListStore()
    @State private var selectedTab: AppTab = .identify
    @Environment(\.scenePhase) private var scenePhase

    enum AppTab: Hashable { case identify, lifeList }

    init() {
        let manager = RecordingManager()
        // Kick off BirdNET + geo-model loading in the background as soon as
        // the app launches, so the first Start Recording tap is instant.
        manager.preload()
        _recordingManager = State(wrappedValue: manager)
        // Ask for notification permission at first launch rather than
        // deferring to the first Start Recording tap.
        Task { @MainActor in
            SpeciesNotifications.shared.requestAuthorizationIfNeeded()
        }
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                Tab("Identify", systemImage: "mic.fill", value: AppTab.identify) {
                    ContentView()
                }
                Tab("Life List", systemImage: "bird", value: AppTab.lifeList) {
                    NavigationStack {
                        LifeListView()
                    }
                }
            }
            // Both tabs need both stores.
            .environment(recordingManager)
            .environment(lifeListStore)
            // Push "is the spectrogram visible?" into the recording manager
            // — true only when the Identify tab is selected AND the scene
            // is active. RecordingManager uses this to decide whether new
            // species should fire a local notification.
            .onChange(of: selectedTab, initial: true) { _, _ in
                updateSpectrogramVisibility()
            }
            .onChange(of: scenePhase, initial: true) { _, _ in
                updateSpectrogramVisibility()
            }
        }
    }

    private func updateSpectrogramVisibility() {
        recordingManager.spectrogramVisible =
            (selectedTab == .identify) && (scenePhase == .active)
    }
}

import SwiftUI
import UIKit

@main
struct KestrelApp: App {
    @State private var recordingManager: RecordingManager
    @State private var lifeListStore: LifeListStore
    @State private var selectedTab: AppTab = .identify
    @Environment(\.scenePhase) private var scenePhase

    /// Held for lifetime; activates a WCSession and routes watch audio +
    /// start/stop handshakes into `recordingManager`.
    private let watchBridge: WatchAudioBridge

    enum AppTab: Hashable { case identify, lifeList }

    init() {
        let manager = RecordingManager()
        // Kick off BirdNET + geo-model loading in the background as soon as
        // the app launches, so the first Start Recording tap is instant.
        manager.preload()
        _recordingManager = State(wrappedValue: manager)

        watchBridge = WatchAudioBridge(manager: manager)

        let store = LifeListStore()
        _lifeListStore = State(wrappedValue: store)

        // Background-decode every life-list thumbnail at launch. Without this
        // the first switch to the Life List tab spends ~hundreds of ms
        // synchronously decoding JPEGs on the main thread.
        SpeciesImageCache.shared.preheat(
            scientificNames: store.entries.map(\.scientificName)
        )

        // Ask for notification permission at first launch rather than
        // deferring to the first Start Recording tap.
        Task { @MainActor in
            SpeciesNotifications.shared.requestAuthorizationIfNeeded()
        }

        // Warm up UIKit's keyboard subsystem off-screen. The first time a
        // text field becomes first responder anywhere in the app, the
        // keyboard's UIInputWindow + remote view service take 100–300 ms to
        // initialize. Doing it now on a fresh launch — while everything else
        // is also initializing — hides that latency behind launch.
        Self.preheatKeyboard()
    }

    /// Instantiates a throwaway text field, briefly makes it the first
    /// responder, then resigns in the same runloop turn before the system
    /// has a chance to animate the keyboard onto the screen. Triggers the
    /// keyboard subsystem initialization (UIInputWindow + remote view
    /// service + dictionary load) synchronously inside `becomeFirstResponder`,
    /// so the first real focus tap is instant.
    ///
    /// The same-runloop resign + `performWithoutAnimation` together suppress
    /// the visible slide-up flash that the previous async resign produced.
    private static func preheatKeyboard() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let window = UIApplication.shared
                .connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
                .first else { return }
            let tf = UITextField(frame: .zero)
            tf.isHidden = true
            window.addSubview(tf)
            UIView.performWithoutAnimation {
                tf.becomeFirstResponder()
                tf.resignFirstResponder()
            }
            tf.removeFromSuperview()
        }
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                Tab("Identify", systemImage: "magnifyingglass", value: AppTab.identify) {
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

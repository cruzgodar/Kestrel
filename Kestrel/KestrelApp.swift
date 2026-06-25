import Combine
import SwiftUI
import UIKit

@main
struct KestrelApp: App {
    @State private var recordingManager: RecordingManager
    @State private var lifeListStore: LifeListStore
    @State private var selectedTab: AppTab = .identify
    @State private var photoPresenter = SpeciesPhotoPresenter()
    @State private var mapNavigator = MapNavigator()
    @Environment(\.scenePhase) private var scenePhase

    /// Held for lifetime; activates a WCSession and routes watch audio +
    /// start/stop handshakes into `recordingManager`.
    private let watchBridge: WatchAudioBridge

    enum AppTab: Hashable { case identify, lifeList, map, about }

    init() {
        let manager = RecordingManager()
        // Kick off BirdNET + geo-model loading in the background as soon as
        // the app launches, so the first Start Recording tap is instant.
        manager.preload()
        _recordingManager = State(wrappedValue: manager)

        watchBridge = WatchAudioBridge(manager: manager)

        let store = LifeListStore()
        _lifeListStore = State(wrappedValue: store)

        // Let the manager read the life list directly at session start. This
        // is what keeps the "already a lifer?" check correct when the watch
        // wakes the app in the background and no SwiftUI view is mounted to
        // push the snapshot in.
        manager.lifeListStore = store

        // Warm species photos at launch: download + persist the life-list and
        // cached region species so they're available offline. These are also
        // the "protected" set the image-cache cap never evicts — set it before
        // prefetching so newly-downloaded protected images aren't pruned.
        let lifeListNames = store.entries.map(\.scientificName)
        let targets = RemoteSpeciesImageStore.launchTargets(lifeList: lifeListNames)
        RemoteSpeciesImageStore.shared.setProtectedSpecies(targets)
        RemoteSpeciesImageStore.shared.prefetch(scientificNames: targets)

        // Cap cached "other" images (anything not on the life list or in the
        // current nearby list) at 50 MB so the on-disk cache can't grow without
        // bound. Life-list + nearby images are protected and never evicted.
        RemoteSpeciesImageStore.shared.setLimitOtherImages(true)

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
                Tab("Map", systemImage: "map", value: AppTab.map) {
                    MapView()
                }
                Tab("About", systemImage: "info.circle", value: AppTab.about) {
                    NavigationStack {
                        AboutView()
                    }
                }
            }
            // Both tabs need both stores.
            .environment(recordingManager)
            .environment(lifeListStore)
            // Drives the full-screen photo viewer; read by every SpeciesPhoto
            // and the map's annotation tap handlers.
            .environment(photoPresenter)
            // Lets the full-screen viewer focus the Map tab on a bird.
            .environment(mapNavigator)
            // Full-screen species photo, opened by tapping any bird image. When
            // the species has a recorded first sighting, a "Show on Map" button
            // switches to the Map tab and zooms to that location.
            .fullScreenCover(item: Binding(
                get: { photoPresenter.presented },
                set: { photoPresenter.presented = $0 }
            )) { species in
                let coordinate = lifeListStore.firstObservationCoordinate(for: species.scientificName)
                // The Life List tab always shows the earliest sighting, so the
                // observation section mirrors that row's place + date. `nil` for
                // non-lifers (not on the list), which hides the section.
                let observation = lifeListStore.firstObservation(for: species.scientificName)
                SpeciesPhotoFullScreen(
                    scientificName: species.scientificName,
                    mapButtonTitle: coordinate != nil ? "Show on Map" : nil,
                    onShowOnMap: coordinate.map { coord in
                        {
                            photoPresenter.presented = nil
                            selectedTab = .map
                            mapNavigator.focus(latitude: coord.latitude, longitude: coord.longitude)
                        }
                    },
                    placeName: observation?.location,
                    dateFound: observation?.date
                )
            }
            // Push "is the spectrogram visible?" into the recording manager
            // — true only when the Identify tab is selected AND the scene
            // is active. RecordingManager uses this to decide whether new
            // species should fire a local notification.
            .onChange(of: selectedTab, initial: true) { _, _ in
                updateSpectrogramVisibility()
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                updateSpectrogramVisibility()
                // Cold-launch / background-launch path for the Start Recording
                // widget: drain the pending request once the scene is active.
                if phase == .active { startRecordingIfRequested() }
            }
            // Warm path: the intent fired while the app was already active.
            .onReceive(NotificationCenter.default.publisher(for: RecordingIntentRequest.notification)) { _ in
                startRecordingIfRequested()
            }
        }
    }

    /// Honors a pending Start Recording widget tap. No-op unless a request is
    /// queued; the manager itself ignores it if a session is already running.
    private func startRecordingIfRequested() {
        guard RecordingIntentRequest.consume() else { return }
        Task { await recordingManager.startFromIntent() }
    }

    private func updateSpectrogramVisibility() {
        recordingManager.spectrogramVisible =
            (selectedTab == .identify) && (scenePhase == .active)
        // Foreground = scene active, independent of tab. Drives whether
        // new/starred haptics buzz the phone (foregrounded) or the watch.
        recordingManager.appForegrounded = (scenePhase == .active)
    }
}

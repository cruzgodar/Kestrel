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

    enum AppTab: Hashable { case identify, lifeList, map, more }

    init() {
        let manager = RecordingManager()
        // Kick off BirdNET + geo-model loading in the background as soon as
        // the app launches, so the first Start Recording tap is instant.
        manager.preload()
        _recordingManager = State(wrappedValue: manager)

        let bridge = WatchAudioBridge(manager: manager)
        watchBridge = bridge
        // Push the phone's recording-authorization state (mic + location) to the
        // watch whenever it changes, so the watch's record screen reflects whether
        // recording is possible.
        manager.onRecordingAuthorizationChanged = { bridge.pushRecordingAuthorized() }

        let store = LifeListStore()
        _lifeListStore = State(wrappedValue: store)

        // Let the manager read the life list directly at session start. This
        // is what keeps the "already a lifer?" check correct when the watch
        // wakes the app in the background and no SwiftUI view is mounted to
        // push the snapshot in.
        manager.lifeListStore = store

        // Warm species photos at launch: download + persist the life-list and
        // cached region species so they're available offline, thumbnails first
        // (see `prefetchWake`). These are also the "protected" set the
        // image-cache cap never evicts — set it before prefetching so
        // newly-downloaded protected images aren't pruned.
        let lifeListNames = store.entries.map(\.scientificName)
        let nearbyNames = RemoteSpeciesImageStore.nearbyNames()
        RemoteSpeciesImageStore.shared.setProtectedSpecies(
            RemoteSpeciesImageStore.launchTargets(lifeList: lifeListNames)
        )
        RemoteSpeciesImageStore.shared.prefetchWake(lifeList: lifeListNames, nearby: nearbyNames)

        // Cap cached "other" images (anything not on the life list or in the
        // current nearby list) at 50 MB so the on-disk cache can't grow without
        // bound. Life-list + nearby images are protected and never evicted.
        RemoteSpeciesImageStore.shared.setLimitOtherImages(true)

        // Permission prompts (location, then notifications) are deferred to the
        // first Start Recording tap rather than fired at launch — see
        // `RecordingManager.startLocally`.

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
                Tab("More", systemImage: "ellipsis.circle", value: AppTab.more) {
                    NavigationStack {
                        MoreView()
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
            )) { presentation in
                // Each bird's place + date comes from its life-list entry (the
                // earliest sighting shown in the Life List tab). Non-lifers have
                // no entry, so both are nil and the sighting section is hidden.
                let items = presentation.names.map { name in
                    let observation = lifeListStore.firstObservation(for: name)
                    return SpeciesPhotoItem(
                        scientificName: name,
                        placeName: observation?.location,
                        dateFound: observation?.date
                    )
                }
                SpeciesPhotoFullScreen(
                    items: items,
                    initialIndex: presentation.index,
                    mapButtonTitle: "Show on Map",
                    onShowOnMap: { item in
                        guard let coord = lifeListStore.firstObservationCoordinate(
                            for: item.scientificName
                        ) else { return }
                        photoPresenter.presented = nil
                        selectedTab = .map
                        mapNavigator.focus(latitude: coord.latitude, longitude: coord.longitude)
                    }
                )
                // Re-inject the store: with the Observation framework, `.environment`
                // objects don't reliably cross a fullScreenCover boundary, so the
                // viewer's star toggle (which reads `LifeListStore` from the
                // environment) would otherwise find it nil and do nothing.
                .environment(lifeListStore)
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
                if phase == .active {
                    startRecordingIfRequested()
                    // No system callback fires for mic-permission changes, so
                    // re-read it on foreground in case the user flipped it in
                    // Settings while away — keeps the grayed button current.
                    recordingManager.refreshMicrophoneAuthorization()
                }
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

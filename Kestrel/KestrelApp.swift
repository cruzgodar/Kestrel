import Combine
import SwiftUI
import UIKit

/// The window's root: the app, with the first-launch welcome screen layered
/// *over* it rather than shown in its place, so nothing below is torn down and
/// rebuilt when it goes away — the preloads kicked off in `KestrelApp.init`
/// keep warming behind it while the user reads.
///
/// The screen doesn't fade *itself* out. It's unmounted outright, under a
/// snapshot of what was on screen a moment earlier, and that snapshot is what
/// crossfades away (see `WindowCrossfade`).
///
/// Two approaches were tried first and are not worth revisiting. An `if` +
/// `.transition(.opacity)` never animated at all — measured frame by frame off
/// a screen recording, the screen was replaced in a single frame whether the
/// change came from `withAnimation` around the flag or from an
/// `.animation(_:value:)` on the stack. Fading the mounted view's own
/// `.opacity` animated cleanly on the simulator but not on device, where it
/// drew one blended frame, held it for about a second, then cut to the end —
/// the fade being starved or interrupted by everything the just-granted
/// permissions set going (location, watch session, photo prefetch).
///
/// This way the fade is one `CAAnimation` on a static image, committed to the
/// render server before any of that starts. Nothing in the SwiftUI hierarchy
/// can interrupt or re-drive it, and the swap underneath is instant rather
/// than something that has to stay smooth for 0.15s.
private struct RootView<Content: View>: View {
    /// How long the welcome screen takes to crossfade away.
    private static var fadeDuration: TimeInterval { 0.15 }

    let manager: RecordingManager
    @ViewBuilder let content: () -> Content

    /// Whether the welcome screen is in the hierarchy at all.
    @State private var welcomeMounted: Bool

    init(manager: RecordingManager, @ViewBuilder content: @escaping () -> Content) {
        self.manager = manager
        self.content = content
        _welcomeMounted = State(initialValue: manager.needsOnboarding)
    }

    var body: some View {
        ZStack {
            content()
            if welcomeMounted {
                WelcomeView {
                    await manager.requestOnboardingPermissions()
                }
            }
        }
        // The flag is cleared once every permission prompt has been answered —
        // and, deliberately, not until the app is foreground-active again, since
        // nothing animates while a system alert has the scene inactive. See
        // `RecordingManager.requestOnboardingPermissions`.
        .onChange(of: manager.needsOnboarding) { _, needsOnboarding in
            guard !needsOnboarding, welcomeMounted else { return }
            // Order matters: grab the snapshot of the welcome screen *before*
            // unmounting it, so the swap happens behind a still image.
            WindowCrossfade.begin(duration: Self.fadeDuration)
            welcomeMounted = false
        }
    }
}

/// Covers the window with a snapshot of what's currently on screen and fades
/// that snapshot out, so whatever replaces the screen underneath appears to
/// crossfade in — no matter how abruptly it was swapped.
///
/// The point of going through UIKit is where the animation runs: `UIView.animate`
/// commits a `CAAnimation` to the render server, which keeps playing it even
/// while the main thread is blocked. SwiftUI's own animations are interpolated
/// on the main thread and freeze with it.
private enum WindowCrossfade {
    @MainActor
    static func begin(duration: TimeInterval) {
        guard let window = UIApplication.shared
            .connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first
        else { return }

        // `afterScreenUpdates: false` — the point is to capture what's on
        // screen *now*, before the caller tears it down, and it's the cheap
        // path: it reuses what's already been rendered.
        guard let snapshot = window.snapshotView(afterScreenUpdates: false) else { return }

        snapshot.frame = window.bounds
        // Purely decorative for the length of the fade; taps belong to the app
        // that's coming in underneath.
        snapshot.isUserInteractionEnabled = false
        window.addSubview(snapshot)

        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            snapshot.alpha = 0
        } completion: { _ in
            snapshot.removeFromSuperview()
        }
    }
}

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

    enum AppTab: Hashable { case identify, lifeList, map, settings }

    init() {
        // Sweep the compiled CoreML models that pre-`CoreMLModelCache` builds
        // left in tmp on every kill — gigabytes on a device that has been
        // recording for a while. Detached and low priority: it walks tmp, and
        // nothing at launch waits on it.
        Task.detached(priority: .background) {
            CoreMLModelCache.purgeLegacyTempModels()
        }

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

        // Register the notification delegate + idle-timeout category, and wire its
        // "End Session" action to end whichever session is active. The idle
        // watchdog now asks (via this notification) rather than stopping outright.
        SpeciesNotifications.shared.configure { [weak manager] in
            manager?.endActiveSession()
        }

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

        // Register the background tasks (must happen before launch completes) so
        // photo prefetch + the high-power image-update check can run with the app
        // backgrounded. The provider lets the prefetch task read the current life
        // list even when no view is mounted.
        BackgroundRefreshCoordinator.shared.register { [weak store] in
            store?.entries.map(\.scientificName) ?? []
        }

        // Cap cached "other" images (anything not on the life list or in the
        // current nearby list) at 50 MB so the on-disk cache can't grow without
        // bound. Life-list + nearby images are protected and never evicted.
        RemoteSpeciesImageStore.shared.setLimitOtherImages(true)

        // Permission prompts are never fired straight from launch: on a fresh
        // install the welcome screen introduces them and its Get Started button
        // runs the sequence (`RecordingManager.requestOnboardingPermissions`),
        // and after that the first Start Recording tap covers anything still
        // unanswered — see `RecordingManager.startLocally`.

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
            RootView(manager: recordingManager) {
                mainInterface
            }
        }
    }

    @ViewBuilder
    private var mainInterface: some View {
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
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
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
                    dateFound: observation?.date,
                    // These birds stand for themselves, not for one sighting, so
                    // the panel summarizes every sighting on record.
                    showsAllObservations: true
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
                    showOnMap(latitude: coord.latitude, longitude: coord.longitude)
                },
                // A sighting picked out of the observation list goes to *its*
                // coordinate rather than the species' earliest.
                onShowObservationOnMap: { observation in
                    guard let latitude = observation.latitude,
                          let longitude = observation.longitude else { return }
                    showOnMap(latitude: latitude, longitude: longitude)
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
                // Catch travel: if location is already granted and no session
                // is running, recompute the nearby region + prefetch its
                // photos now, so opening the app somewhere new updates the
                // list immediately (see `refreshRegionOnForeground`).
                recordingManager.refreshRegionOnForeground()
                // Discover photos added to the CDN since last time (throttled),
                // so a growing photo set fills in without an app update, and
                // re-check any cached image whose freshness window has lapsed.
                refreshPhotosOnForeground()
            } else if phase == .background {
                // Queue the background photo prefetch + high-power update
                // check for whenever iOS next grants us time.
                BackgroundRefreshCoordinator.shared.scheduleAll()
            }
        }
        // Warm path: the intent fired while the app was already active.
        .onReceive(NotificationCenter.default.publisher(for: RecordingIntentRequest.notification)) { _ in
            startRecordingIfRequested()
        }
    }

    /// Honors a pending Start Recording widget tap. No-op unless a request is
    /// queued; the manager itself ignores it if a session is already running.
    private func startRecordingIfRequested() {
        guard RecordingIntentRequest.consume() else { return }
        Task { await recordingManager.startFromIntent() }
    }

    /// Fetches the published photo manifest on foreground (at most every few
    /// hours) to discover species whose photos were added to the CDN since the
    /// last check, then prefetches any that are nearby / on the life list so a
    /// growing photo set fills in without an app update. Changed (vs new) photos
    /// are left to the Wi-Fi + power background pass.
    ///
    /// The manifest is the app's only record of which species have photos and
    /// who took them (nothing is bundled), so this is also what populates the
    /// photo set on a fresh install — hence the throttle bypass while metadata is
    /// missing, which covers both a first launch and an upgrade from a build that
    /// still carried bundled metadata.
    private func refreshPhotosOnForeground() {
        let lifeNames = lifeListStore.entries.map(\.scientificName)
        let discoveryDue = RemoteSpeciesImageStore.shared.manifestCheckDue(minInterval: 6 * 3600)
            || PhotoManifestStore.shared.needsMetadataBackfill
        Task {
            if discoveryDue {
                let result = await RemoteSpeciesImageStore.shared.checkForPhotoUpdates(includeChanged: false)
                if result.newCount > 0 { prefetchPhotos(lifeList: lifeNames) }
            }
            // Expire and re-check cached images a day after they were last
            // confirmed. Unchanged photos cost a hash comparison, not a download,
            // and a failed check leaves the cache exactly as it was — so this is
            // safe to run on any connection. See `revalidateStaleImages`.
            let revalidated = await RemoteSpeciesImageStore.shared.revalidateStaleImages()
            // Revalidation fetches the same manifest discovery does, so it can be
            // the pass that first sees a newly published species — and it records
            // that slug's hash, which means the discovery branch above will never
            // call it new. Prefetch here too, or those photos would only ever
            // arrive one lazy load at a time.
            if !revalidated.discoveredSlugs.isEmpty {
                prefetchPhotos(lifeList: lifeNames)
            }
        }
    }

    /// Protects the species worth keeping from the image cache's size cap, then
    /// warms their thumbnails and medium images. Shared by both paths that can
    /// turn up newly published photos.
    private func prefetchPhotos(lifeList names: [String]) {
        RemoteSpeciesImageStore.shared.setProtectedSpecies(
            RemoteSpeciesImageStore.launchTargets(lifeList: names)
        )
        RemoteSpeciesImageStore.shared.prefetchWake(
            lifeList: names, nearby: RemoteSpeciesImageStore.nearbyNames()
        )
    }

    /// Closes the photo viewer and takes the Map tab to a coordinate. Shared by
    /// the viewer's place-name link and its observation list, which differ only
    /// in which sighting's coordinate they hand over.
    private func showOnMap(latitude: Double, longitude: Double) {
        photoPresenter.presented = nil
        selectedTab = .map
        mapNavigator.focus(latitude: latitude, longitude: longitude)
    }

    private func updateSpectrogramVisibility() {
        recordingManager.spectrogramVisible =
            (selectedTab == .identify) && (scenePhase == .active)
        // Foreground = scene active, independent of tab. Drives whether
        // new/starred haptics buzz the phone (foregrounded) or the watch.
        recordingManager.appForegrounded = (scenePhase == .active)
    }
}

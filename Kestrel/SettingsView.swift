import SwiftUI

struct SettingsView: View {
    /// `@Bindable` over the shared model gives the controls two-way bindings;
    /// the `didSet`s in `AppSettings` handle persistence.
    @Bindable private var settings = AppSettings.shared
    @Environment(RecordingManager.self) private var manager

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Prefer Apple Watch microphone",
                    isOn: $settings.preferWatchMicrophone
                )
            } header: {
                Text("Apple Watch")
            } footer: {
                Text("When Prefer Apple Watch microphone is on, tapping Start Recording on the phone listens through the Watch if it's reachable, falling back to the phone. Turn it off to always use the phone's microphone. Starting from the Watch itself always uses the Watch microphone.")
            }

            Section {
                Toggle(
                    "Show repeat observations on map",
                    isOn: $settings.showRepeatObservationsOnMap
                )
            } header: {
                Text("Map")
            } footer: {
                Text("The Map normally shows each species where you first saw it. Turn this on to drop a pin for every imported sighting, so a bird you've recorded many times appears at each location.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(RecordingManager())
    .environment(LifeListStore())
}

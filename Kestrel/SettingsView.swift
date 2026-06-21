import SwiftUI

struct SettingsView: View {
    /// `@Bindable` over the shared model gives the controls two-way bindings;
    /// the `didSet`s in `AppSettings` handle persistence.
    @Bindable private var settings = AppSettings.shared
    @Environment(RecordingManager.self) private var manager

    var body: some View {
        Form {
            // Only meaningful when there's a watch app to hand off to.
            if manager.isWatchAppInstalled {
                Section {
                    Toggle(
                        "Prefer Apple Watch Microphone",
                        isOn: $settings.preferWatchMicrophone
                    )
                } footer: {
                    Text("Tapping Start Recording on iPhone will use your Apple Watch's microphone if possible.")
                }
            }

            Section {
                Toggle(
                    "Show Repeat Observations on Map",
                    isOn: $settings.showRepeatObservationsOnMap
                )
            } footer: {
                Text("Show every recorded observation of a species on the map, rather than only the earliest.")
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

import SwiftUI

struct SettingsView: View {
    /// `@Bindable` over the shared model gives the controls two-way bindings;
    /// the `didSet`s in `AppSettings` handle persistence + watch sync.
    @Bindable private var settings = AppSettings.shared
    @Environment(RecordingManager.self) private var manager

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Prefer Apple Watch microphone",
                    isOn: $settings.preferWatchMicrophone
                )
                Toggle(
                    "Background audio on Watch",
                    isOn: $settings.watchUsesBackgroundAudioEntitlement
                )
            } header: {
                Text("Apple Watch")
            } footer: {
                Text("When Prefer Apple Watch microphone is on, tapping Start Recording on the phone listens through the Watch if it's reachable, falling back to the phone. Turn it off to always use the phone's microphone. Starting from the Watch itself always uses the Watch microphone.\n\nBackground audio tries to keep listening on the Apple Watch when your wrist is down using the background-audio entitlement. This only works on builds provisioned with that entitlement — leave it off otherwise. When off, the Watch uses an extended runtime session, which the system may end sooner.")
            }

            // Current range-filter status, e.g. "Filtered to 234 nearby
            // species" — moved here from the Identify screen.
            Section("Species Filter") {
                Text(manager.locationStatus ?? "Showing all species")
                    .foregroundStyle(.secondary)
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
}

import SwiftUI

struct SettingsView: View {
    /// `@Bindable` over the shared model gives the controls two-way bindings;
    /// the `didSet`s in `AppSettings` handle persistence + watch sync.
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Background audio on Watch",
                    isOn: $settings.watchUsesBackgroundAudioEntitlement
                )
            } header: {
                Text("Apple Watch")
            } footer: {
                Text("Tries to keep listening on the Apple Watch when your wrist is down using the background-audio entitlement. This only works on builds provisioned with that entitlement — leave it off otherwise. When off, the Watch uses an extended runtime session, which the system may end sooner.")
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
}

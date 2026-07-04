import SwiftUI

/// The More tab — app settings up top, followed by the About section that
/// explains what Kestrel does, introduces the developer, and credits the model,
/// paper, and image sources it relies on.
struct MoreView: View {
    @Bindable private var settings = AppSettings.shared

    #if DEBUG
    // Backs the debug-only cached-image readout. The life list drives one column;
    // the cached nearby-region set drives the other.
    @Environment(LifeListStore.self) private var lifeListStore
    @State private var lifeCounts: RemoteSpeciesImageStore.ResolutionCounts?
    @State private var nearbyCounts: RemoteSpeciesImageStore.ResolutionCounts?
    #endif

    var body: some View {
        // A stock inset-grouped list, so the settings render as the system's own
        // Settings-app controls: the picker as a value row that drops down a
        // checkmarked list of every option, the toggle as a switch in a white
        // capsule row, and each description as a gray section footer.
        List {
            // Big "Settings" title, matching the "About Kestrel" title further
            // down. Transparent row so it reads as a section title over the
            // grouped cards rather than a tappable list item. Its own section
            // with tightened spacing so it sits flush at the top with only a
            // little gap before the first setting below.
            Section {
                Text("Settings")
                    .font(.title2.bold())
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden)
            }
            .listSectionSpacing(6)

            // Auto-stop timeout after a stretch with no detections. The matching
            // watchdog lives in `RecordingManager`. Inline style so every option
            // is a stock checkmark row, all visible at once, rather than a
            // dropdown; the setting's name is the section's subheader, and the
            // picker's own label is hidden so it doesn't render as an option row.
            Section {
                Picker("Timeout After No Detections", selection: $settings.noBirdTimeout) {
                    ForEach(AppSettings.NoBirdTimeout.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Timeout After No Detections")
            } footer: {
                Text("Kestrel can automatically stop sessions to save battery life after it doesn't hear any birds for some time.")
            }

            // Moved here from the Map tab's old settings card.
            Section {
                Toggle(
                    "Show Repeat Observations on Map",
                    isOn: $settings.showRepeatObservationsOnMap
                )
            } footer: {
                Text("Show every recorded observation of a species on the map, rather than only the earliest.")
            }

            aboutSection
        }
        .listStyle(.insetGrouped)
        // Pull the whole list up so "Settings" sits flush under the (empty) nav
        // bar with no extra space above it.
        .contentMargins(.top, 0, for: .scrollContent)
        // Intentionally no title text — the header bar stays empty.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - About

    /// The About content, kept as flowing text in a transparent list row (no
    /// grouped card) below the stock settings groups.
    private var aboutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 20) {
                Divider()
                    .padding(.vertical, 4)

                Text("About Kestrel")
                    .font(.title2.bold())

                Text(Self.intro)
                Text(Self.watch)
                Text(Self.importing)

                Divider()
                    .padding(.vertical, 4)

                aboutMeSection

                Divider()
                    .padding(.vertical, 4)

                creditsSection

                #if DEBUG
                cacheCountsView
                clearCacheButton
                #endif
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 16, trailing: 20))
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - About Me

    private var aboutMeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About Me")
                .font(.title2.bold())

            Text(.init(Self.aboutMe))
                .tint(.accentColor)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: URL(string: "https://cruzgodar.com/about")!) {
                Image("Cruz")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Debug

    #if DEBUG
    /// Debug-only readout of how many life-list and nearby-region species have an
    /// image cached at each resolution — thumbnail (320) and medium (900) from
    /// disk, full (2400) from the in-memory viewer tier. Each denominator is the
    /// number of that group's species that have photo metadata at all (the
    /// reachable maximum). Recomputed on appear and after a cache clear.
    private var cacheCountsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cached Images")
                .font(.headline)

            if let lifeCounts, let nearbyCounts {
                countGroup("Life List", lifeCounts)
                countGroup("Nearby", nearbyCounts)
            } else {
                Text("Counting…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refreshCacheCounts)
    }

    private func countGroup(
        _ title: String,
        _ counts: RemoteSpeciesImageStore.ResolutionCounts
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            countRow(title, at: 320, counts.thumb, of: counts.total)
            countRow(title, at: 900, counts.medium, of: counts.total)
            countRow(title, at: 2400, counts.full, of: counts.total)
        }
    }

    private func countRow(_ title: String, at pixels: Int, _ have: Int, of total: Int) -> some View {
        Text("\(title) @\(pixels): \(have)/\(total)")
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private func refreshCacheCounts() {
        let store = RemoteSpeciesImageStore.shared
        lifeCounts = store.cacheCounts(for: lifeListStore.entries.map(\.scientificName))
        nearbyCounts = store.cacheCounts(for: RemoteSpeciesImageStore.nearbyNames())
    }

    /// Debug-only control at the very bottom of the About screen: drops every
    /// cached species image (thumbnail, medium, and full-resolution tiers, on
    /// disk and in memory) so the next view re-downloads from scratch.
    private var clearCacheButton: some View {
        Button(role: .destructive) {
            RemoteSpeciesImageStore.shared.clearAllCaches()
            refreshCacheCounts()
        } label: {
            Text("Clear Image Cache")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .padding(.top, 8)
    }
    #endif

    // MARK: - Credits

    private var creditsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Credits")
                .font(.headline)

            // BirdNET model + the paper that introduced it.
            credit(
                "Bird identification is powered by [BirdNET](https://birdnet.cornell.edu), the open-source model developed by the K. Lisa Yang Center for Conservation Bioacoustics at the Cornell Lab of Ornithology and Chemnitz University of Technology."
            )
            credit(
                "Kahl, S., Wood, C. M., Eibl, M., & Klinck, H. (2021). BirdNET: A deep learning solution for avian diversity monitoring. *Ecological Informatics*, 61, 101236. [doi:10.1016/j.ecoinf.2021.101236](https://doi.org/10.1016/j.ecoinf.2021.101236)"
            )
            // BirdNET model license notice (CC BY-NC-SA 4.0 requires naming the
            // license, linking it, and indicating the model was modified — here,
            // converted to ONNX for on-device inference).
            credit(
                "The BirdNET model is © the Cornell Lab of Ornithology and Chemnitz University of Technology, used under the [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) license and adapted (converted to ONNX) to run on-device."
            )

            // Macaulay Library photos + their individual photographers.
            credit(
                "Bird photographs are provided by the [Macaulay Library](https://www.macaulaylibrary.org) at the Cornell Lab of Ornithology. Each photo is © its individual photographer, who is credited on the photo when you tap it."
            )
        }
    }

    private func credit(_ markdown: String) -> some View {
        Text(.init(markdown))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .tint(.accentColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Body copy

    /// Parses inline markdown (so links like `[text](url)` render), preserving
    /// the original whitespace. The plain `AttributedString(_:)` initializer does
    /// NOT parse markdown, which left the source-code link below as literal text.
    private static func markdown(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(string)
    }

    private static let intro = markdown(
        "Kestrel listens for birds in the background so you can focus on the nature around you. It uses Cornell Lab's BirdNET model to identify birds by their songs and calls, and when it hears one that you have starred in your life list or have never seen before, it notifies you. That lets you keep your focus off of your phone, with confidence that you'll know when a bird you care about is nearby. All processing happens on-device, all audio is deleted immediately after (i.e. within a few seconds of being recorded), and [the source code is freely available.](https://github.com/cruzgodar/Kestrel)"
    )

    private static let watch = markdown(
        "On Apple Watch, Kestrel can log your birding walk as a workout. That uses the watch's microphone, and so your phone can stay in your pocket. Since audio is processed on your phone, you must keep it with you to use Kestrel."
    )

    private static let importing = markdown(
        "If you use eBird or Merlin to track your observations, it's a good idea to periodically import your eBird life list into Kestrel to keep its life list and map up-to-date."
    )

    private static let aboutMe =
        "I'm a web developer and college math teacher, and most of my work focuses on mathematical art and illustration, as well as thoughtful and high-quality teaching. I've found myself hopelessly into birding on the side, though, and Kestrel is my idea of an ideal companion app that can be used independently or in conjunction with eBird and Merlin. You can see more of my work at [cruzgodar.com](https://cruzgodar.com) or reach me at [me@cruzgodar.com](mailto:me@cruzgodar.com) with bug reports or feature suggestions. Thank you for using Kestrel! –Cruz"
}

#Preview {
    NavigationStack {
        MoreView()
    }
}

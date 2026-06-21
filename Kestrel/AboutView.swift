import SwiftUI

/// The About tab — explains what Kestrel does and credits the model, paper,
/// and image sources it relies on.
struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HighlightedText(segments: Self.introSegments)
                Text(Self.watch)
                Text(Self.importing)

                Divider()
                    .padding(.vertical, 4)

                creditsSection
            }
            .font(.body)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

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

    /// First paragraph, with "starred in your life list" on a blue pill and
    /// "have never seen before" on a purple pill — the same row-background tints
    /// the Identify tab uses for starred and not-yet-on-the-list birds.
    private static let introSegments: [HighlightedText.Segment] = [
        .init("Kestrel listens for birds in the background so you can focus on the nature around you. It uses Cornell Lab's BirdNET model to identify birds by their songs and calls, and when it hears one that you have "),
        .init("starred in your life list", highlight: HighlightedText.starHighlight),
        .init(" or "),
        .init("have never seen before", highlight: HighlightedText.addHighlight),
        .init(", it notifies you. That lets you keep your focus off of your phone, with confidence that you'll know when a bird you care about is nearby."),
    ]

    private static let watch = AttributedString(
        "On Apple Watch, Kestrel can log your birding walk as a workout. That lets it use the watch's microphone, and so your phone can stay in your pocket. Since birds are identified on your phone, you must keep it with you to use Kestrel."
    )

    private static let importing = AttributedString(
        "If you use eBird or Merlin to track your observations, it's a good idea to periodically import your eBird life list into Kestrel to keep its life list and map up-to-date."
    )
}

#Preview {
    NavigationStack {
        AboutView()
    }
}

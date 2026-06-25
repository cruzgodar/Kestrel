import SwiftUI

/// The About tab — explains what Kestrel does, introduces the developer, and
/// credits the model, paper, and image sources it relies on.
struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
            }
            .font(.body)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
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

    private static let intro = AttributedString(
        "Kestrel listens for birds in the background so you can focus on the nature around you. It uses Cornell Lab's BirdNET model to identify birds by their songs and calls, and when it hears one that you have starred in your life list or have never seen before, it notifies you. That lets you keep your focus off of your phone, with confidence that you'll know when a bird you care about is nearby. All processing happens on-device, all audio is deleted immediately after (i.e. within a few seconds of being recorded), and [the source code is freely available](https://github.com/cruzgodar/Kestrel)."
    )

    private static let watch = AttributedString(
        "On Apple Watch, Kestrel can log your birding walk as a workout. That uses the watch's microphone, and so your phone can stay in your pocket. Since audio is processed on your phone, you must keep it with you to use Kestrel."
    )

    private static let importing = AttributedString(
        "If you use eBird or Merlin to track your observations, it's a good idea to periodically import your eBird life list into Kestrel to keep its life list and map up-to-date."
    )

    private static let aboutMe =
        "I'm a web developer and college math teacher, and most of my work focuses on mathematical art and illustration, as well as thoughtful and high-quality teaching. I've found myself hopelessly into birding on the side, though, and Kestrel is my idea of an ideal companion app that can be used independently or in conjunction with eBird and Merlin. You can see more of my work at [cruzgodar.com](https://cruzgodar.com) or reach me at [me@cruzgodar.com](mailto:me@cruzgodar.com) with bug reports or feature suggestions. Thank you for using Kestrel! –Cruz"
}

#Preview {
    NavigationStack {
        AboutView()
    }
}

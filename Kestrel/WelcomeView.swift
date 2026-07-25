import SwiftUI

extension Color {
    /// Kestrel's purple. The record button's idle fill and the onboarding
    /// call-to-action are the same color by design, so it lives here rather than
    /// being written out at each callsite.
    static let kestrelPurple = Color(hue: 252.0 / 360.0, saturation: 0.65, brightness: 1.0)
}

/// First-launch screen. Shown over the app while the permissions Kestrel needs
/// are still unanswered, so a new user meets an explanation of *why* the app
/// wants the microphone and their location before iOS starts throwing system
/// prompts at them — prompts that, asked cold, are easy to reflexively decline.
///
/// Deliberately gated on the permissions themselves rather than a "has launched
/// before" flag: the screen's whole job is to introduce the prompts, so once
/// either has been answered — in this session or a previous install — it has
/// nothing left to do. The denied case is already handled elsewhere, by the
/// record button's gray lock and its open-Settings alert.
struct WelcomeView: View {
    /// Bounding box for the logo, in points — the mark is fit inside a square of
    /// this edge, so whichever of its dimensions is longer ends up this long. A
    /// Home Screen app icon draws at 60pt, so this reads as a deliberately larger
    /// version of the same mark. The single knob for the logo's size; the rest of
    /// the screen lays itself out around whatever it's set to.
    private static let logoSize: CGFloat = 85

    /// Nudges the logo right by this fraction of its own width, without moving
    /// anything else. Purely for optical centering — the mark's visual mass
    /// isn't symmetric about its bounding box, so geometric center and looking
    /// centered aren't the same thing. Negative values move it left. Mirrors the
    /// watch's knob of the same name; the two are tuned independently, since the
    /// mark renders at very different sizes.
    private static let logoHorizontalNudge: CGFloat = 0.008

    /// The screen's vertical rhythm: the logo → heading and heading → body gaps
    /// are both this.
    private static let spacing: CGFloat = 20

    /// Breathing room above and below the block once it *does* outgrow the
    /// screen and starts scrolling. Below that size the block is placed by
    /// `centerFraction` and this only floors how close to the top it can get.
    private static let verticalPadding: CGFloat = 32

    /// Where the block's own center sits, as a fraction of the height above the
    /// button. 0.5 is dead center; sitting a little high reads as deliberate
    /// placement rather than as the screen having nothing else on it.
    private static let centerFraction: CGFloat = 0.45

    /// Runs the permission sequence (see `RecordingManager.requestOnboardingPermissions`).
    /// Async so the button stays disabled until every prompt has been answered,
    /// rather than inviting a second tap that would stack another sequence
    /// behind the one already on screen.
    let requestPermissions: () async -> Void

    @State private var requesting = false

    /// Height of the scroll view — i.e. everything above the button. Fed back
    /// into the content as a *minimum* height so the block can place itself in
    /// that space (see `body`).
    @State private var scrollHeight: CGFloat = 0

    /// Height of the block itself, measured without its padding.
    @State private var contentHeight: CGFloat = 0

    /// Space above the block that puts its center `centerFraction` of the way
    /// down the scroll view. Floored at `verticalPadding` so a block too tall
    /// for the screen — the largest accessibility text sizes — starts below the
    /// top edge and scrolls, rather than being pulled up off it.
    private var topInset: CGFloat {
        max(
            Self.verticalPadding,
            scrollHeight * Self.centerFraction - contentHeight / 2
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Scrolls rather than compresses, so the largest accessibility text
            // sizes stay readable on the smallest phone instead of truncating.
            ScrollView {
                VStack(spacing: Self.spacing) {
                    // Light/dark art comes from the asset catalog's appearance
                    // variants, so the mark follows the system appearance with
                    // no color-scheme branching here.
                    //
                    // A *max* frame, not a fixed one: the artwork is wider than
                    // it is tall, and a fixed square frame would keep its full
                    // height and letterbox the mark inside it — padding the gap
                    // above and below with space the stack's spacing has no say
                    // over. This way the frame hugs the fitted image and every
                    // gap on the screen is `spacing`.
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: Self.logoSize, maxHeight: Self.logoSize)
                        // `offset`, not padding: the nudge shifts what's drawn
                        // without changing the frame, so it can't push the
                        // stack's width around or pull the heading off center
                        // with it. The frame's width *is* `logoSize` (the
                        // artwork is wider than tall, so width is what the fit
                        // binds), which makes this a straight percentage of the
                        // logo's width.
                        .offset(x: Self.logoSize * Self.logoHorizontalNudge)
                        .accessibilityHidden(true)

                    Text("Meet Kestrel")
                        .font(.largeTitle.bold())

                    Text("Kestrel listens for birds in the background so you can focus on the nature around you. It needs access to the microphone, location access while using the app, and notification permissions in order to function. None of your data is stored or shared, and you will only receive notifications for identified birds.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        // The paragraph is left-justified while the logo and
                        // heading stay centered, so it needs to claim the full
                        // width itself — otherwise the block would shrink to its
                        // longest line and sit centered, ragged on both sides.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Let the paragraph take the height it needs instead of
                        // being squeezed to one line inside the scroll view.
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                .padding(.horizontal, 32)
                // Placed by `topInset` rather than centered, so the block sits
                // `centerFraction` of the way down the space above the button.
                // The frame is a *minimum* height, not a fixed one: at the
                // largest accessibility text sizes the block outgrows the
                // screen, and this way it simply gets taller than the scroll
                // view and scrolls, instead of being pinned to one screenful
                // and clipped.
                .padding(.top, topInset)
                .padding(.bottom, Self.verticalPadding)
                .frame(minHeight: scrollHeight, alignment: .top)
            }
            // No rubber-banding when the content already fits.
            .scrollBounceBehavior(.basedOnSize)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scrollHeight = $0 }

            Button {
                guard !requesting else { return }
                requesting = true
                Task {
                    await requestPermissions()
                    requesting = false
                }
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            }
            // The same style the Start Recording button uses, so the purple and
            // the press feedback match the control this screen leads to.
            .buttonStyle(RecordButtonStyle(tint: .kestrelPurple))
            .disabled(requesting)
            .opacity(requesting ? 0.6 : 1.0)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        // Opaque: this is drawn over the live app, which must not show through.
        .background(Color(.systemBackground))
    }
}

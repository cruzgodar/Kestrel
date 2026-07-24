import SwiftUI

extension Color {
    /// Kestrel's purple, matching the phone's record button and onboarding
    /// call-to-action. Duplicated from the iOS target's definition because the
    /// two apps share no source; keep the values in step.
    static let kestrelPurple = Color(hue: 252.0 / 360.0, saturation: 0.65, brightness: 1.0)
}

/// First-launch screen on the wrist, shown over the record screen while the
/// watch's own permissions are still unanswered.
///
/// The watch needs this even when the phone has already been onboarded:
/// microphone and location authorization on watchOS are per-device and can only
/// be granted from the watch.
///
/// The logo is the dark artwork unconditionally — watchOS has no light
/// appearance to switch on, and this screen draws on black.
struct WatchWelcomeView: View {
    /// Bounding box for the logo, in points — the mark is fit inside a square of
    /// this edge, so its longer dimension (the width, on the current artwork)
    /// ends up this long. Scaled off screen height so it holds its proportion of
    /// the screen from the 40mm up to the Ultra.
    private var logoSize: CGFloat {
        let screen = WatchMetrics.currentScreenSize
        return screen.height / 3.75
    }

    /// Nudges the logo right by this fraction of its own width, without moving
    /// anything else. Purely for optical centering — the mark's visual mass
    /// isn't symmetric about its bounding box, so geometric center and looking
    /// centered aren't the same thing. Negative values move it left.
    private static let logoHorizontalNudge: CGFloat = 0.008

    /// The screen's vertical rhythm: the logo → heading and heading → body gaps
    /// are both this.
    private static let spacing: CGFloat = 10

    /// Where the logo's top edge sits, as a fraction of screen height, measured
    /// from the true top of the display. A fraction rather than a point value
    /// because the clock and bezel scale with the watch, so this holds its
    /// position from the 40mm up to the Ultra. For reference, 0.125 puts the
    /// logo level with the bottom of the clock (28 of 223pt on the 42mm).
    private static let logoTopFraction: CGFloat = 0.175

    /// Extra space above the logo, added to `logoTopFraction`. Zero puts the
    /// logo level with the bottom of the clock; positive pushes it down.
    private static let topPadding: CGFloat = 0

    /// Resolved top inset for the scroll content. The scroll view drops its top
    /// safe area (watchOS reserves ~48pt there for the clock, which would sit
    /// the logo well below it), so this is the whole distance from the top of
    /// the screen.
    private var logoTopInset: CGFloat {
        WatchMetrics.currentScreenSize.height * Self.logoTopFraction + Self.topPadding
    }

    /// Runs the permission sequence (see
    /// `WatchSessionManager.requestOnboardingPermissions`). Async so the button
    /// stays disabled until every prompt has been answered rather than letting a
    /// second tap stack another sequence behind the one on screen.
    let requestPermissions: () async -> Void

    @State private var requesting = false

    var body: some View {
        ScrollView {
            VStack(spacing: Self.spacing) {
                // A *max* frame, not a fixed one: the artwork is wider than it
                // is tall, and a fixed square frame would keep its full height
                // and letterbox the mark inside it — padding the gap above and
                // below with space the stack's spacing has no say over. This way
                // the frame hugs the fitted image and every gap is `spacing`.
                Image("LogoDark")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: logoSize, maxHeight: logoSize)
                    // `offset`, not padding: the nudge shifts what's drawn
                    // without changing the frame, so it can't push the stack's
                    // width around or pull the heading off center with it. The
                    // frame's width *is* `logoSize` (the artwork is wider than
                    // tall, so width is what the fit binds), which makes this a
                    // straight percentage of the logo's width.
                    .offset(x: logoSize * Self.logoHorizontalNudge)
                    .accessibilityHidden(true)

                Text("Meet Kestrel")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                Text("Kestrel listens for birds in the background so you can focus on the nature around you. It needs access to the microphone, location access while using the app, notification permissions, and the ability to log workouts in order to function. None of your data is stored or shared, and you will only receive notifications for identified birds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    // The paragraph is left-justified while the logo and heading
                    // stay centered, so it needs to claim the full width itself
                    // — otherwise the block would shrink to its longest line and
                    // sit centered, ragged on both sides.
                    .frame(maxWidth: .infinity, alignment: .leading)

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
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.kestrelPurple, in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(requesting)
                .opacity(requesting ? 0.6 : 1.0)
                .padding(.top, 6)
            }
            .padding(.horizontal, 4)
        }
        // Drop the top safe area so `logoTopInset` is measured from the top of
        // the screen. Both modifiers are needed, in this order: `contentMargins`
        // *adds* to the safe area rather than replacing it, so on its own it
        // would read as 48 + n, not n.
        //
        // Nothing collides with the time: it sits top-right, while the logo is
        // narrower than the screen and centered, and starts level with the
        // clock's baseline. Body text scrolling up under the clock is the normal
        // watchOS behavior — it overlays content there.
        .ignoresSafeArea(.container, edges: .top)
        .contentMargins(.top, logoTopInset, for: .scrollContent)
        // Opaque: this is drawn over the live record screen, which must not
        // show through it.
        .background(Color.black.ignoresSafeArea())
    }
}

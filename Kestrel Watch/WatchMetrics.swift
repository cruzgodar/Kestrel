import WatchKit

/// Per-watch screen geometry that has no public API.
enum WatchMetrics {
    /// The layout knobs that vary by watch size. `screenCornerRadius` matches the
    /// physical bezel; `edgeMargin` is the diagonal clearance the corner buttons
    /// keep off that bezel (and the trailing margin the prompt captions use);
    /// `nameImageGap` is the vertical gap between the species name and the photo
    /// below it.
    ///
    /// The photo itself is no longer inset — it runs to the left, right and bottom
    /// edges — so its bottom corners are cut by the bezel and have an *effective*
    /// radius of `screenCornerRadius`; `imageTopCornerRadius` is derived from that
    /// so all four corners read the same.
    struct Metrics {
        var screenCornerRadius: CGFloat
        var edgeMargin: CGFloat
        var nameImageGap: CGFloat

        /// Radius of the bird photo's *top* corners.
        ///
        /// Derived, not stored, and always exactly `screenCornerRadius`. The
        /// photo runs flush to the left, right and bottom edges, so its bottom
        /// corners are cut by the bezel and have an effective radius of the
        /// bezel's own; matching the top to that is what makes all four read the
        /// same. Two independently-stored fields computed from the same
        /// expression could drift apart under an edit meant for only one of them
        /// — and the bezel radius is the one the corner-button geometry also
        /// depends on, so that edit would move the buttons too. Naming it here
        /// keeps the *reason* at the call site without letting the value diverge.
        var imageTopCornerRadius: CGFloat { screenCornerRadius }
    }

    /// Approximate corner radius of the physical watch screen, in points.
    ///
    /// watchOS exposes no accessor for this (public or private), so it's a table
    /// keyed by `screenBounds.size`. The radius values below are the community
    /// reverse-engineered corner radii (see VIkill33/AppleWatchScreenSize),
    /// restricted to watches that can run our watchOS 26 deployment target
    /// (Series 6 and later). For anything unmeasured we fall back to a
    /// proportional estimate (the 46mm ratio, 51 / 208 ≈ 0.245·width).
    ///
    /// To verify/populate a device: print `currentScreenSize` from the app, run
    /// it on that watch/simulator, read the size, then confirm the radius makes
    /// the bird image's corners hug the bezel and adjust the `case` if needed.
    /// Constant nudge added to every radius below. The reverse-engineered radii
    /// sit ~1pt inside what looks concentric against our `edgeMargin`, so this
    /// pushes them all out by the same amount.
    private static let radiusAdjustment: CGFloat = 1
    /// Defaults applied to every device unless overridden in the table below.
    private static let defaultEdgeMargin: CGFloat = 12
    private static let defaultNameImageGap: CGFloat = 10

    /// Resolved metrics for the current watch. Edit the per-size cases in
    /// `metrics(for:)` to tune a particular watch's margins.
    static var current: Metrics { metrics(for: currentScreenSize) }

    /// The table itself, keyed by screen size.
    ///
    /// Split out from `current` so it can be resolved for *any* size rather than
    /// only the watch the code happens to be running on — which is what lets the
    /// whole table be checked at once, instead of one device per simulator run.
    static func metrics(for size: CGSize) -> Metrics {
        let radius: CGFloat
        switch size {
        case CGSize(width: 162, height: 197): radius = 28   // 40mm  (SE 2/3, Series 6)
        case CGSize(width: 184, height: 224): radius = 34   // 44mm  (SE 2/3, Series 6)
        case CGSize(width: 176, height: 215): radius = 38   // 41mm  (Series 7/8/9)
        case CGSize(width: 198, height: 242): radius = 41   // 45mm  (Series 7/8/9)
        case CGSize(width: 187, height: 223): radius = 45   // 42mm  (Series 10/11)
        case CGSize(width: 208, height: 248): radius = 49   // 46mm  (Series 10/11)
        case CGSize(width: 205, height: 251): radius = 54   // 49mm  (Ultra 1/2)
        case CGSize(width: 211, height: 257): radius = 56   // 49mm  (Ultra 3)
        default: radius = 0.245 * size.width                // proportional estimate
        }

        // Per-size margin overrides. Add a `case` here to tune the corner-button
        // clearance and/or the name-to-image gap on a specific watch; sizes not
        // listed use the defaults. The bird photo is flush to the edges and is
        // unaffected by `edgeMargin` — its top radius is `imageTopCornerRadius`.
        let edgeMargin: CGFloat
        let nameImageGap: CGFloat
        switch size {
        case CGSize(width: 162, height: 197): edgeMargin = 6; nameImageGap = 7    // 40mm  (SE 2/3, Series 6)
        case CGSize(width: 184, height: 224): edgeMargin = 8; nameImageGap = 10   // 44mm  (SE 2/3, Series 6)
        case CGSize(width: 176, height: 215): edgeMargin = 8; nameImageGap = 8    // 41mm  (Series 7/8/9)
        case CGSize(width: 198, height: 242): edgeMargin = 10; nameImageGap = 12  // 45mm  (Series 7/8/9)
        case CGSize(width: 187, height: 223): edgeMargin = 8; nameImageGap = 7    // 42mm  (Series 10/11)
        case CGSize(width: 208, height: 248): edgeMargin = 10; nameImageGap = 10  // 46mm  (Series 10/11)
        case CGSize(width: 205, height: 251): edgeMargin = 10; nameImageGap = 12  // 49mm  (Ultra 1/2)
        case CGSize(width: 211, height: 257): edgeMargin = 10; nameImageGap = 13  // 49mm  (Ultra 3)
        default:
            edgeMargin = defaultEdgeMargin
            nameImageGap = defaultNameImageGap
        }

        return Metrics(
            screenCornerRadius: radius + radiusAdjustment,
            edgeMargin: edgeMargin,
            nameImageGap: nameImageGap
        )
    }

    /// Convenience accessor kept for call sites that only need the bezel radius.
    static var screenCornerRadius: CGFloat { current.screenCornerRadius }

    /// The watch's screen size in points — the key for the table above. Print
    /// this on a new device to learn which `case` to add.
    static var currentScreenSize: CGSize {
        WKInterfaceDevice.current().screenBounds.size
    }
}

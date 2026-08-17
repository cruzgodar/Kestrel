import WatchKit

/// Per-watch screen geometry that has no public API.
enum WatchMetrics {
    /// The layout knobs that vary by watch size. `screenCornerRadius` matches the
    /// physical bezel; `edgeMargin` is the diagonal clearance the corner buttons
    /// keep off that bezel (and the trailing margin the prompt captions use);
    /// `nameImageGap` is the vertical gap between the species name and the photo
    /// below it; `imageTopCornerRadius` rounds the top of the bird photo.
    ///
    /// The photo itself is no longer inset — it runs to the left, right and bottom
    /// edges — so its bottom corners are cut by the bezel and have an *effective*
    /// radius of `screenCornerRadius`. `imageTopCornerRadius` matches that so all
    /// four corners read the same; add a per-size case below to tune a device.
    struct Metrics {
        var screenCornerRadius: CGFloat
        var edgeMargin: CGFloat
        var nameImageGap: CGFloat
        var imageTopCornerRadius: CGFloat
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

    /// Resolved metrics for the current watch. Edit the per-size cases to tune a
    /// particular watch's margins.
    static var current: Metrics {
        let size = currentScreenSize
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

        // The photo's bottom corners are the bezel's own, so its top corners are
        // rounded to that same radius rather than to an inset one. Split out as
        // its own value so a device whose top corners don't read as matching can
        // be nudged here (add a `switch size` case) without moving the bezel
        // radius, which the corner-button geometry also depends on.
        let topRadius = radius + radiusAdjustment

        return Metrics(
            screenCornerRadius: radius + radiusAdjustment,
            edgeMargin: edgeMargin,
            nameImageGap: nameImageGap,
            imageTopCornerRadius: topRadius
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

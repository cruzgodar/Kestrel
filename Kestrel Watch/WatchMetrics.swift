import WatchKit

/// Per-watch screen geometry that has no public API.
enum WatchMetrics {
    /// The layout knobs that vary by watch size. `screenCornerRadius` matches the
    /// physical bezel; `imageMargin` insets the bird image/placeholder from the
    /// screen edges; `nameImageGap` is the vertical gap between the species name
    /// and the photo below it. Tune these per device below to test layouts on
    /// different watch sizes — the image's corner radius follows `imageMargin`
    /// automatically (its `ContainerRelativeShape` insets `screenCornerRadius` by
    /// however far it sits from the edge), so it stays concentric with the bezel.
    struct Metrics {
        var screenCornerRadius: CGFloat
        var imageMargin: CGFloat
        var nameImageGap: CGFloat
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
    /// sit ~1pt inside what looks concentric against our `imageMargin`, so this
    /// pushes them all out by the same amount.
    private static let radiusAdjustment: CGFloat = 1
    /// Defaults applied to every device unless overridden in the table below.
    private static let defaultImageMargin: CGFloat = 12
    private static let defaultNameImageGap: CGFloat = 10

    /// Resolved metrics for the current watch. Edit the per-size cases to tune a
    /// particular watch's margins; the image corner radius tracks `imageMargin`
    /// automatically to stay concentric.
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
        case CGSize(width: 211, height: 257): radius = 54   // 49mm  (Ultra 3)
        default: radius = 0.245 * size.width                // proportional estimate
        }

        // Per-size margin overrides. Add a `case` here to tune the image margin
        // and/or the name-to-image gap on a specific watch; sizes not listed use
        // the defaults. The image corner radius adjusts with `imageMargin`
        // automatically, so it stays concentric with the bezel.
        let imageMargin: CGFloat
        let nameImageGap: CGFloat
        switch size {
        case CGSize(width: 162, height: 197): imageMargin = 6; nameImageGap = 7    // 40mm  (SE 2/3, Series 6)
        case CGSize(width: 184, height: 224): imageMargin = 8; nameImageGap = 11   // 44mm  (SE 2/3, Series 6)
        case CGSize(width: 176, height: 215): imageMargin = 8; nameImageGap = 9    // 41mm  (Series 7/8/9)
        case CGSize(width: 198, height: 242): imageMargin = 10; nameImageGap = 14  // 45mm  (Series 7/8/9)
        case CGSize(width: 187, height: 223): imageMargin = 8; nameImageGap = 8    // 42mm  (Series 10/11)
        case CGSize(width: 208, height: 248): imageMargin = 10; nameImageGap = 13  // 46mm  (Series 10/11)
        case CGSize(width: 205, height: 251): imageMargin = 10; nameImageGap = 14  // 49mm  (Ultra 1/2)
        case CGSize(width: 211, height: 257): imageMargin = 10; nameImageGap = 14  // 49mm  (Ultra 3)
        default:
            imageMargin = defaultImageMargin
            nameImageGap = defaultNameImageGap
        }

        return Metrics(
            screenCornerRadius: radius + radiusAdjustment,
            imageMargin: imageMargin,
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

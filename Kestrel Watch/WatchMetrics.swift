import WatchKit

/// Per-watch screen geometry that has no public API.
enum WatchMetrics {
    /// Approximate corner radius of the physical watch screen, in points.
    ///
    /// watchOS exposes no accessor for this (public or private), so it's a table
    /// keyed by `screenBounds.size`. The values below are the community
    /// reverse-engineered corner radii (see VIkill33/AppleWatchScreenSize),
    /// restricted to watches that can run our watchOS 26 deployment target
    /// (Series 6 and later). For anything unmeasured we fall back to a
    /// proportional estimate (the 46mm ratio, 51 / 208 ≈ 0.245·width).
    ///
    /// To verify/populate a device: print `currentScreenSize` from the app, run
    /// it on that watch/simulator, read the size, then confirm the radius makes
    /// the bird image's corners hug the bezel and adjust the `case` if needed.
    /// Constant nudge added to every value below. The reverse-engineered radii
    /// sit ~1pt inside what looks concentric against our `imageMargin`, so this
    /// pushes them all out by the same amount.
    private static let radiusAdjustment: CGFloat = 1

    static var screenCornerRadius: CGFloat {
        let size = currentScreenSize
        let base: CGFloat
        switch size {
        case CGSize(width: 162, height: 197): base = 28   // 40mm  (SE 2/3, Series 6)
        case CGSize(width: 184, height: 224): base = 34   // 44mm  (SE 2/3, Series 6)
        case CGSize(width: 176, height: 215): base = 38   // 41mm  (Series 7/8/9)
        case CGSize(width: 198, height: 242): base = 41   // 45mm  (Series 7/8/9)
        case CGSize(width: 187, height: 223): base = 45   // 42mm  (Series 10/11)
        case CGSize(width: 208, height: 248): base = 49   // 46mm  (Series 10/11) — measured; table lists 49
        case CGSize(width: 205, height: 251): base = 54   // 49mm  (Ultra 1/2/3)
        default: base = 0.245 * size.width                // proportional estimate
        }
        return base + radiusAdjustment
    }

    /// The watch's screen size in points — the key for the table above. Print
    /// this on a new device to learn which `case` to add.
    static var currentScreenSize: CGSize {
        WKInterfaceDevice.current().screenBounds.size
    }
}

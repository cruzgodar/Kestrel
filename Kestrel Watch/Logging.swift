import Foundation
import os

/// Watch-side counterpart of the phone's `Log`. Routes diagnostics to the
/// unified logging system (`os.Logger`) instead of `print`, so nothing lands in
/// the shipping watch app's stdout while staying inspectable in Console.app.
/// `nonisolated` for the same reason the phone's is: the delegate callbacks and
/// off-main paths that log are not main-actor isolated, and this target is
/// MainActor-by-default too.
nonisolated enum Log {
    private static let logger = Logger(subsystem: "com.cruzgodar.Kestrel.watch", category: "app")

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }
}

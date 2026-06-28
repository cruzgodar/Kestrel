import Foundation
import os

/// Watch-side counterpart of the phone's `Log`. Routes diagnostics to the
/// unified logging system (`os.Logger`) instead of `print`, so nothing lands in
/// the shipping watch app's stdout while staying inspectable in Console.app.
enum Log {
    private static let logger = Logger(subsystem: "com.cruzgodar.Kestrel.watch", category: "app")

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }
}

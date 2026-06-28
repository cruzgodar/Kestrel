import Foundation
import os

/// Lightweight diagnostics wrapper. Routes the app's error/warning messages to
/// the unified logging system (`os.Logger`) rather than `print`, which writes to
/// stdout on every build — including release. Logger keeps nothing in the
/// shipping app's stdout while staying inspectable in Console.app for support.
///
/// Messages are interpolated by the caller into a `String` first, so any value
/// type works unchanged; the whole line is logged `.public` since none of it is
/// user-private (these are framework errors and lifecycle notes).
enum Log {
    private static let logger = Logger(subsystem: "com.cruzgodar.Kestrel", category: "app")

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }
}

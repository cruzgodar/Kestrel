import Foundation

/// Sub-millisecond timing log. Times are relative to the first call, so a
/// fresh start gives `[    0.0ms]` for the tap and grows from there.
enum PerfLog {
    private static var anchor: CFAbsoluteTime?

    static func reset() {
        anchor = CFAbsoluteTimeGetCurrent()
    }

    static func log(_ message: String) {
        let now = CFAbsoluteTimeGetCurrent()
        if anchor == nil { anchor = now }
        let dt = (now - (anchor ?? now)) * 1000
        print(String(format: "[%7.1fms] %@", dt, message))
    }
}

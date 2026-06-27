import Foundation
import os

/// Lightweight performance instrumentation for the Map tab. The measurement
/// bodies are compiled only in DEBUG (no-ops in release), so call sites can be
/// left in the code without a runtime cost in shipping builds.
///
/// How to read it while diagnosing the pan stutter:
///
/// • **Xcode / Console.app:** filter on subsystem `com.cruzgodar.Kestrel`,
///   category `MapPerf`. Each measured interval logs its duration; the counters
///   flush a `counters/sec` summary roughly once per second while you interact,
///   so you can watch how many annotation mounts / cluster rebuilds / camera
///   frames happen per second during a single pan.
///
/// • **Instruments:** the intervals are emitted as `os_signpost`s on the
///   **Points of Interest** instrument, and the counter ticks as signpost
///   *events*, so they line up on the timeline with everything else. Recommended
///   template + lanes:
///     1. **Time Profiler** — the ground truth. Record a pan, then in the call
///        tree invert + "Hide system libraries" and look for what's hot. If it's
///        `SpeciesPhoto`/`UIImage` decode or `computeClusters`, that's the cost.
///     2. **os_signpost / Points of Interest** — add this and watch the
///        `annotationBody`, `rebuildClusters`, and `updateVisibleEntries` regions.
///        If `annotationBody`/`annotationAppear` fire densely *during* a pan
///        (finger still down), MapKit is churning annotation hosts as they leave
///        and re-enter the viewport — the suspected cause.
///     3. **SwiftUI → View Body** (Xcode 16+) — shows how often each view's body
///        re-evaluates. A high `MapAnnotationContent` count during a pan confirms
///        the remount churn.
///   Drive a steady ~2 s pan with "Update While Moving" OFF and correlate the
///   counter summary in the console with the hot frames in Time Profiler.
enum MapPerf {
    static let subsystem = "com.cruzgodar.Kestrel"

    #if DEBUG
    private static let signpost = OSLog(subsystem: subsystem, category: .pointsOfInterest)
    private static let logger = Logger(subsystem: subsystem, category: "MapPerf")

    /// Rolling per-key counts, flushed to the log about once a second so a burst
    /// of events during a single gesture reads as a rate rather than a flood.
    /// `count` is called from MapKit's annotation / camera callbacks, which are
    /// not all on the main thread, so every access to `counts` / `lastFlush` is
    /// serialized by `countsLock` — otherwise the concurrent dictionary mutation
    /// (and an interleaved `lastFlush` read) could corrupt or crash.
    private static var counts: [String: Int] = [:]
    private static var lastFlush = DispatchTime.now()
    private static let countsLock = NSLock()
    #endif

    /// Times `body`, emitting an `os_signpost` interval (visible in Instruments)
    /// and a console line with the duration. Returns whatever `body` returns.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ detail: @autoclosure @escaping () -> String = "", _ body: () -> T) -> T {
        #if DEBUG
        let id = OSSignpostID(log: signpost)
        os_signpost(.begin, log: signpost, name: name, signpostID: id)
        let start = DispatchTime.now()
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            os_signpost(.end, log: signpost, name: name, signpostID: id)
            logger.debug("\(name, privacy: .public): \(ms, format: .fixed(precision: 2)) ms \(detail(), privacy: .public)")
        }
        return body()
        #else
        return body()
        #endif
    }

    /// Increments a named counter and flushes a one-line summary of all counters
    /// about once a second. Also fires a signpost event so the tick shows up on the
    /// Points of Interest timeline.
    static func count(_ key: String) {
        #if DEBUG
        os_signpost(.event, log: signpost, name: "tick", "%{public}s", key)
        countsLock.lock()
        defer { countsLock.unlock() }
        counts[key, default: 0] += 1
        let now = DispatchTime.now()
        // `uptimeNanoseconds` is unsigned, so a plain subtraction traps on
        // underflow. `count` can be called off the main thread (annotation /
        // camera callbacks), so an interleaving can briefly leave `lastFlush`
        // ahead of `now`; clamp the elapsed time at zero rather than crash.
        let elapsedNanos = now.uptimeNanoseconds >= lastFlush.uptimeNanoseconds
            ? now.uptimeNanoseconds - lastFlush.uptimeNanoseconds
            : 0
        if Double(elapsedNanos) / 1_000_000_000 >= 1 {
            let summary = counts.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "  ")
            if !summary.isEmpty {
                logger.debug("counters/sec — \(summary, privacy: .public)")
            }
            counts.removeAll(keepingCapacity: true)
            lastFlush = now
        }
        #endif
    }
}

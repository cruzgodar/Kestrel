import Foundation
import Observation
import QuartzCore

/// Lightweight smoothed FPS counter. `tick(_:)` should be called from the same
/// thread as the display link (i.e. main).
@Observable
@MainActor
final class FPSCounter {
    private(set) var fps: Double = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var smoothed: Double = 0

    func tick(_ timestamp: CFTimeInterval) {
        defer { lastTimestamp = timestamp }
        guard lastTimestamp > 0 else { return }
        let dt = timestamp - lastTimestamp
        guard dt > 0 else { return }
        let instant = 1.0 / dt
        smoothed = smoothed == 0 ? instant : smoothed * 0.9 + instant * 0.1
        fps = smoothed
    }

    func reset() {
        lastTimestamp = 0
        smoothed = 0
        fps = 0
    }
}

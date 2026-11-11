import CoreMedia
import CoreVideo
import Foundation
import os

/// Thread-safe "latest frame" slot. Sources write at their own rate,
/// the compositor reads at the program frame rate (frame-sync behaviour:
/// repeat the last frame if a source is slow, drop if it is fast).
final class FrameStore: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var buffer: CVPixelBuffer?
    private var updatedAt: CFTimeInterval = 0

    func put(_ pb: CVPixelBuffer) {
        os_unfair_lock_lock(&lock)
        buffer = pb
        updatedAt = HostClock.now
        os_unfair_lock_unlock(&lock)
    }

    /// Returns nil when the source has been silent for longer than `staleAfter` seconds.
    func latest(staleAfter: CFTimeInterval = 2) -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard HostClock.now - updatedAt < staleAfter else { return nil }
        return buffer
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        buffer = nil
        os_unfair_lock_unlock(&lock)
    }
}

/// Single time base for the whole pipeline: the mach host clock, in seconds.
/// Camera buffers, AVAudioEngine taps and HaishinKit's RTMP audio timestamps all use it.
enum HostClock {
    static var now: CFTimeInterval { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}

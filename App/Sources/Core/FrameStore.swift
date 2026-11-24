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
    private var seq: UInt64 = 0
    private var monitorTargets: [UUID: CGSize] = [:]

    /// A view registers drawable pixels, not points; multiple displays share the largest request.
    func setMonitorTarget(_ size: CGSize?, for id: UUID) {
        os_unfair_lock_lock(&lock)
        monitorTargets[id] = size
        os_unfair_lock_unlock(&lock)
    }

    func monitorRenderSize(maximum: CGSize) -> CGSize? {
        os_unfair_lock_lock(&lock)
        let targets = Array(monitorTargets.values)
        os_unfair_lock_unlock(&lock)
        return MonitorRendering.renderSize(maximum: maximum, targets: targets)
    }

    func put(_ pb: CVPixelBuffer) {
        os_unfair_lock_lock(&lock)
        buffer = pb
        updatedAt = HostClock.now
        seq &+= 1
        os_unfair_lock_unlock(&lock)
    }

    /// The latest frame and a counter that changes on every `put`. Pixel buffer pools hand the *same*
    /// buffer object back again and again with new pictures in it, so "same object" does not mean
    /// "same picture": a monitor that skipped redraws on the object identity stayed frozen on PVW / PGM.
    func latestFrame(staleAfter: CFTimeInterval = 2) -> (buffer: CVPixelBuffer, seq: UInt64)? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard HostClock.now - updatedAt < staleAfter, let b = buffer else { return nil }
        return (b, seq)
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

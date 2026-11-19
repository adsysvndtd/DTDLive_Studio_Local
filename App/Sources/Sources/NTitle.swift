import CoreImage
import CoreVideo
import Foundation

/// N-Title feed: the latest frame of an NDI title source (BGRA, already carrying an alpha channel)
/// plus its on-air fade, read once per program frame by the switcher's graphics provider.
/// Kept SDK-independent (only FrameStore / CVPixelBuffer) so the app builds without the NDI SDK;
/// the receiver that fills the FrameStore is created in StudioEngine under `#if NDI_SDK`.
final class NTitleFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var store: FrameStore?
    private var on = false
    private var shownAt: CFTimeInterval = 0
    private var hiddenAt: CFTimeInterval = -100
    let fade: CFTimeInterval = 0.35

    func setStore(_ s: FrameStore?) { lock.lock(); store = s; lock.unlock() }

    func setOn(_ v: Bool) {
        lock.lock()
        if v != on { if v { shownAt = HostClock.now } else { hiddenAt = HostClock.now } }
        on = v
        lock.unlock()
    }

    var hasSource: Bool { lock.lock(); defer { lock.unlock() }; return store != nil }

    /// The frame to composite now and its alpha (nil once a fade-out has finished or there is no source).
    func current(now: CFTimeInterval) -> (buffer: CVPixelBuffer, alpha: CGFloat)? {
        lock.lock()
        let st = store, vis = on, s = shownAt, h = hiddenAt
        lock.unlock()
        guard let st else { return nil }
        var a: CGFloat
        if vis { a = fade <= 0 ? 1 : CGFloat(min(1, (now - s) / fade)) }
        else { a = fade <= 0 ? 0 : CGFloat(max(0, 1 - (now - h) / fade)); if a <= 0 { return nil } }
        guard let f = st.latestFrame()?.buffer else { return nil }
        return (f, a)
    }
}

import CoreMedia
import Foundation
import os
import VideoToolbox

/// Instant replay with slow motion.
/// Keeps the last `window` seconds of the already-encoded program stream (H.264, ~6 Mbps
/// -> ~11 MB for 15 s instead of ~1.3 GB raw), decodes on demand and plays back at
/// 0.25x–1x through a regular VideoSource so it can be cut/mixed like any input.
final class ReplayBuffer: @unchecked Sendable {
    private var samples: [CMSampleBuffer] = []
    private var lock = os_unfair_lock()
    var window: Double = 60
    private(set) var frozen = false

    func append(_ sb: CMSampleBuffer) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard !frozen else { return }
        samples.append(sb)
        let newest = sb.presentationTimeStamp.seconds
        // Trim, but always start on a keyframe so decoding can begin cleanly.
        while let first = samples.first, newest - first.presentationTimeStamp.seconds > window {
            samples.removeFirst()
            while let f = samples.first, !f.isKeyframe { samples.removeFirst() }
        }
    }

    /// Clip of the last `seconds`, starting at a keyframe.
    func clip(lastSeconds seconds: Double) -> [CMSampleBuffer] {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard let newest = samples.last?.presentationTimeStamp.seconds else { return [] }
        var start = samples.lastIndex { $0.isKeyframe && newest - $0.presentationTimeStamp.seconds >= seconds }
            ?? samples.firstIndex { $0.isKeyframe }
        if start == nil { start = 0 }
        return Array(samples[start!...])
    }

    /// Copy of everything currently buffered (for the clip editor; the live buffer keeps rolling).
    func snapshot() -> [CMSampleBuffer] {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return samples
    }

    func setFrozen(_ f: Bool) { os_unfair_lock_lock(&lock); frozen = f; os_unfair_lock_unlock(&lock) }
}

@MainActor
final class ReplaySource: VideoSource {
    let id = UUID()
    var name = "REPLAY"
    let kind: SourceKind = .file
    let frames = FrameStore()
    private(set) var status: SourceStatus = .idle

    var speed: Double = 0.5
    var length: Double = 8
    private(set) var isPlaying = false
    /// Held on a frame (VAR): the replay stays on air, frames move only with step().
    private(set) var isPaused = false
    private let buffer: ReplayBuffer
    private var task: Task<Void, Never>?
    var onFinished: (() -> Void)?

    /// The range being played (for pause / step / resume).
    private var curSamples: [CMSampleBuffer] = []
    private var curIn: Double = 0, curOut: Double = 0, curLoop = false
    /// Presentation time of the frame on screen (written by the playback task).
    private let head = Playhead()
    final class Playhead: @unchecked Sendable {
        private var v: Double = 0
        private let l = NSLock()
        var value: Double { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } }
    }
    /// Sorted presentation times of the frames inside the range.
    private var frameTimes: [Double] = []

    init(buffer: ReplayBuffer) { self.buffer = buffer }

    func start() async { status = .live }
    func stop() async { cancel(); status = .idle }

    /// Last `length` seconds of the buffer (kept, so the same moment can be played again on air).
    func play() { play(clip: buffer.clip(lastSeconds: length)) }

    /// Plays the moment shown by the last play() again (e.g. cued on PVW, now taken to PGM).
    func playAgain() { lastClip.isEmpty ? play() : play(clip: lastClip) }
    private var lastClip: [CMSampleBuffer] = []

    private func play(clip: [CMSampleBuffer]) {
        cancel()
        lastClip = clip
        let pts = clip.map { $0.presentationTimeStamp.seconds }
        if let a = pts.min(), let b = pts.max() {
            // same path as an explicit range, so pause / step work on "last N seconds" too
            play(samples: clip, inPTS: a, outPTS: b, speed: speed, loop: false, keepFrozen: true)
            return
        }
        guard let fd = clip.first?.formatDescription else { return }
        buffer.setFrozen(true)
        isPlaying = true
        let store = frames, speed = speed
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let decoder = FrameDecoder(format: fd)
            var reorder = ReorderBuffer()
            var previousPTS: Double?
            func show(_ f: (pts: Double, pb: CVPixelBuffer)) async {
                if let p = previousPTS { try? await Task.sleep(nanoseconds: UInt64(max(0, (f.pts - p) / speed) * 1e9)) }
                previousPTS = f.pts
                store.put(f.pb)
            }
            for sb in clip {
                if Task.isCancelled { break }
                guard let pb = decoder.decode(sb) else { continue }
                if let f = reorder.push(sb.presentationTimeStamp.seconds, pb) { await show(f) }
            }
            for f in reorder.drain() where !Task.isCancelled { await show(f) }
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.finish() }
        }
    }

    /// Plays an explicit clip: decodes from the keyframe before `inPTS` (frames before it are
    /// decoded but not shown), shows frames up to `outPTS` at `speed`, optionally looping.
    func play(samples: [CMSampleBuffer], inPTS: Double, outPTS: Double, speed: Double, loop: Bool) {
        play(samples: samples, inPTS: inPTS, outPTS: outPTS, speed: speed, loop: loop, keepFrozen: false)
    }

    private func play(samples: [CMSampleBuffer], inPTS: Double, outPTS: Double, speed: Double, loop: Bool, keepFrozen: Bool) {
        // resuming a held replay continues the same range without "finishing" it (that would take it off air)
        let resuming = isPaused && samples.count == curSamples.count && outPTS == curOut
        if resuming { task?.cancel(); task = nil } else { cancel() }
        guard let fd = samples.first?.formatDescription else { return }
        if !resuming {
            curSamples = samples; curIn = inPTS; curOut = outPTS; curLoop = loop
            frameTimes = samples.map { $0.presentationTimeStamp.seconds }.filter { $0 >= inPTS - 0.0005 && $0 <= outPTS + 0.0005 }.sorted()
        }
        head.value = inPTS
        isPaused = false
        if keepFrozen { buffer.setFrozen(true) }
        let startIdx = samples.lastIndex { $0.isKeyframe && $0.presentationTimeStamp.seconds <= inPTS } ?? 0
        // a little past outPTS: with B-frames the last shown frames reference a later P-frame
        let clip = Array(samples[startIdx...]).filter { $0.presentationTimeStamp.seconds <= outPTS + 0.25 }
        isPlaying = true
        let store = frames, ph = head
        task = Task.detached(priority: .userInitiated) { [weak self] in
            repeat {
                let decoder = FrameDecoder(format: fd)
                var reorder = ReorderBuffer()
                var previousPTS: Double?
                func show(_ f: (pts: Double, pb: CVPixelBuffer)) async {
                    if f.pts < inPTS || f.pts > outPTS + 0.0005 { return } // pre-roll / decode-only tail
                    if let p = previousPTS { try? await Task.sleep(nanoseconds: UInt64(max(0, (f.pts - p) / speed) * 1e9)) }
                    if Task.isCancelled { return }
                    previousPTS = f.pts
                    store.put(f.pb)
                    ph.value = f.pts
                }
                for sb in clip {
                    if Task.isCancelled { break }
                    guard let pb = decoder.decode(sb) else { continue }
                    if let f = reorder.push(sb.presentationTimeStamp.seconds, pb) { await show(f) }
                }
                for f in reorder.drain() where !Task.isCancelled { await show(f) }
            } while loop && !Task.isCancelled
            // cancelled = paused / replaced: whoever cancelled decides whether the replay ends
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.finish() }
        }
    }

    func cancel() { task?.cancel(); task = nil; isPaused = false; if isPlaying { finish() } }

    // MARK: VAR: hold, frame step, resume

    /// Holds the replay on the frame on screen (it stays on air; nothing finishes).
    func pause() {
        guard isPlaying, !isPaused else { return }
        task?.cancel(); task = nil
        isPaused = true
    }

    /// Plays on from the frame on screen to the OUT point.
    func resume(speed: Double) {
        guard isPaused, !curSamples.isEmpty else { return }
        let from = head.value
        let next = frameTimes.first { $0 > from + 0.0005 } ?? curOut
        play(samples: curSamples, inPTS: next, outPTS: curOut, speed: speed, loop: curLoop, keepFrozen: true)
        // keep the original range for later steps
    }

    /// Moves exactly `n` frames (±) inside the range and shows that frame (pauses first).
    func step(_ n: Int) {
        guard isPlaying, !curSamples.isEmpty, !frameTimes.isEmpty else { return }
        if !isPaused { pause() }
        let cur = frameTimes.firstIndex { $0 >= head.value - 0.0005 } ?? 0
        let target = frameTimes[min(max(cur + n, 0), frameTimes.count - 1)]
        let samples = curSamples, store = frames, ph = head
        guard let fd = samples.first?.formatDescription else { return }
        task = Task.detached(priority: .userInitiated) {
            // decode from the keyframe before the target up to it (display order), show only the target
            let k = samples.lastIndex { $0.isKeyframe && $0.presentationTimeStamp.seconds <= target } ?? 0
            let decoder = FrameDecoder(format: fd)
            var reorder = ReorderBuffer()
            for sb in samples[k...] where sb.presentationTimeStamp.seconds <= target + 0.25 {
                if Task.isCancelled { return }
                guard let pb = decoder.decode(sb) else { continue }
                if let f = reorder.push(sb.presentationTimeStamp.seconds, pb), abs(f.pts - target) < 0.0005 {
                    store.put(f.pb); ph.value = f.pts; return
                }
            }
            for f in reorder.drain() where abs(f.pts - target) < 0.0005 { store.put(f.pb); ph.value = f.pts; return }
        }
    }

    /// Position inside the range, 0…1 (for the VAR bar).
    var progress: Double { curOut > curIn ? min(max((head.value - curIn) / (curOut - curIn), 0), 1) : 0 }

    private func finish() {
        isPlaying = false
        buffer.setFrozen(false)
        onFinished?()
    }
}

/// Decoded frames arrive in decode order; with B-frames that is not display order.
/// Holds a few frames and releases them sorted by presentation time.
struct ReorderBuffer {
    private var held: [(pts: Double, pb: CVPixelBuffer)] = []
    var depth = 4
    mutating func push(_ pts: Double, _ pb: CVPixelBuffer) -> (pts: Double, pb: CVPixelBuffer)? {
        let i = held.firstIndex { $0.pts > pts } ?? held.count
        held.insert((pts, pb), at: i)
        return held.count > depth ? held.removeFirst() : nil
    }
    mutating func drain() -> [(pts: Double, pb: CVPixelBuffer)] { defer { held = [] }; return held }
}

/// Synchronous VideoToolbox decoder (one frame in, one frame out, in decode order — see ReorderBuffer).
final class FrameDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?

    init(format: CMFormatDescription) {
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                     kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                     imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &session)
    }

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    func decode(_ sb: CMSampleBuffer) -> CVPixelBuffer? {
        guard let session else { return nil }
        var out: CVPixelBuffer?
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr { out = image }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return out
    }
}

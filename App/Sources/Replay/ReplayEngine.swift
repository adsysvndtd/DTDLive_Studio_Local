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
    private let buffer: ReplayBuffer
    private var task: Task<Void, Never>?
    var onFinished: (() -> Void)?

    init(buffer: ReplayBuffer) { self.buffer = buffer }

    func start() async { status = .live }
    func stop() async { cancel(); status = .idle }

    func play() {
        cancel()
        let clip = buffer.clip(lastSeconds: length)
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
            await MainActor.run { self?.finish() }
        }
    }

    /// Plays an explicit clip: decodes from the keyframe before `inPTS` (frames before it are
    /// decoded but not shown), shows frames up to `outPTS` at `speed`, optionally looping.
    func play(samples: [CMSampleBuffer], inPTS: Double, outPTS: Double, speed: Double, loop: Bool) {
        cancel()
        guard let fd = samples.first?.formatDescription else { return }
        let startIdx = samples.lastIndex { $0.isKeyframe && $0.presentationTimeStamp.seconds <= inPTS } ?? 0
        // a little past outPTS: with B-frames the last shown frames reference a later P-frame
        let clip = Array(samples[startIdx...]).filter { $0.presentationTimeStamp.seconds <= outPTS + 0.25 }
        isPlaying = true
        let store = frames
        task = Task.detached(priority: .userInitiated) { [weak self] in
            repeat {
                let decoder = FrameDecoder(format: fd)
                var reorder = ReorderBuffer()
                var previousPTS: Double?
                func show(_ f: (pts: Double, pb: CVPixelBuffer)) async {
                    if f.pts < inPTS || f.pts > outPTS + 0.0005 { return } // pre-roll / decode-only tail
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
            } while loop && !Task.isCancelled
            await MainActor.run { self?.finish() }
        }
    }

    func cancel() { task?.cancel(); task = nil; if isPlaying { finish() } }

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

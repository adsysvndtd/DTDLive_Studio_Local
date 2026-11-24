@preconcurrency import AVFoundation
import CoreVideo
import Foundation

/// A camera that pushes to DTD Studio (SRT caller with a streamid, RTMP publish, RTSP RECORD, or a paired
/// DTDLive). The server owns the connection; this input just shows its frames and status.
@MainActor
final class IngestSource: VideoSource {
    let id = UUID()
    var name: String
    let kind: SourceKind
    let frames: FrameStore
    private(set) var status: SourceStatus = .connecting
    /// "srt:cam1", "rtmp:cam2", "rtsp:cam3", "dtdlive:<bond prefix>"
    let ingestKey: String
    var peer = ""

    init(name: String, kind: SourceKind, ingestKey: String, frames: FrameStore = FrameStore()) {
        self.name = name; self.kind = kind; self.ingestKey = ingestKey; self.frames = frames
    }

    func setOnline(_ on: Bool, peer: String = "") {
        status = on ? .live : .error("chờ camera kết nối lại")
        if !peer.isEmpty { self.peer = peer }
        if !on { frames.clear() }
    }

    func start() async {}
    func stop() async { frames.clear(); status = .idle }
}

/// Thread-safe routing from server threads to the input's frame store / decoder / mixer channel.
final class IngestRouter: @unchecked Sendable {
    final class Sink: @unchecked Sendable {
        let frames: FrameStore
        let pipeline = RTSPDecodePipeline()
        /// Smooths Wi-Fi bursts: decoded frames are shown at their media time + a small fixed delay.
        lazy var pacer = FramePacer(store: frames)
        private let lock = NSLock()
        private var audioHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
        /// Set on the main actor once the input exists in the mixer; media threads read it.
        var onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return audioHandler }
            set { lock.lock(); audioHandler = newValue; lock.unlock() }
        }
        init(frames: FrameStore = FrameStore(), onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) {
            self.frames = frames; self.audioHandler = onAudio
        }

        /// Raw AAC access unit + AudioSpecificConfig (SRT / RTMP).
        func aac(_ data: [UInt8], asc: [UInt8], sampleRate: Int, channels: Int) {
            if !pipeline.hasAudioDecoder { pipeline.configureAAC(asc: asc, sampleRate: sampleRate, channels: channels) }
            if let pcm = pipeline.audio(data) { onAudio?(pcm) }
        }
    }

    private let lock = NSLock()
    private var sinks: [String: Sink] = [:]

    func set(_ key: String, _ sink: Sink?) { lock.lock(); sinks[key] = sink; lock.unlock() }
    /// Returns the stream's sink, creating it (synchronously, on the server thread) on first use.
    func ensure(_ key: String) -> Sink {
        lock.lock(); defer { lock.unlock() }
        if let s = sinks[key] { return s }
        let s = Sink(); sinks[key] = s
        return s
    }
    func sink(_ key: String) -> Sink? { lock.lock(); defer { lock.unlock() }; return sinks[key] }
}


enum DecodedFrameTiming {
    static func presentationTime(_ buffer: CVPixelBuffer) -> Double? {
        guard let value = CVBufferCopyAttachment(buffer, "SRTKit.DecodedPresentationTimeSeconds" as CFString, nil) as? NSNumber,
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
}

/// Plays decoded frames out at their stream timestamps (plus `delay`) instead of the moment they
/// arrive, so network bursts don't show as stutter. Re-anchors on gaps, jumps or when it falls behind.
final class FramePacer: @unchecked Sendable {
    let store: FrameStore
    var delay: Double = 0.15
    private let queue = DispatchQueue(label: "ingest.pacer", qos: .userInteractive)
    private var clock = FramePlayoutClock()
    private var arrivalClock = FrameArrivalClock()
    private var nextSequence: UInt64 = 0
    private var displayedSequence: UInt64 = 0

    init(store: FrameStore) { self.store = store }

    /// Prefer original decoder PTS. Arrival estimation is only for older bridges
    /// without timestamp metadata; network bursts must not alter the camera clock.
    func pushArrival(_ pb: CVPixelBuffer) {
        if let media = DecodedFrameTiming.presentationTime(pb) {
            push(pb, media: media)
            return
        }
        let now = HostClock.now
        queue.async { [self] in
            schedule(pb, media: arrivalClock.media(at: now), arrived: now)
        }
    }

    func push(_ pb: CVPixelBuffer, media: Double) {
        let now = HostClock.now
        queue.async { [self] in schedule(pb, media: media, arrived: now) }
    }

    private func schedule(_ pb: CVPixelBuffer, media: Double, arrived now: Double) {
        guard let timing = clock.schedule(media: media, arrived: now, delay: delay) else { return }
        nextSequence &+= 1
        let sequence = nextSequence
        let publish: @Sendable () -> Void = { [weak self] in
            guard let self, self.clock.generation == timing.generation,
                  sequence > self.displayedSequence else { return }
            self.displayedSequence = sequence
            self.store.put(pb)
        }
        let wait = timing.due - HostClock.now
        if wait <= 0 { publish() }
        else { queue.asyncAfter(deadline: .now() + wait, execute: publish) }
    }
}

/// Pure timing state, independent of buffers, so burst/reconnect behaviour can be tested.
struct FrameArrivalClock {
    private var lastArrival: Double?
    private var windowStart = 0.0
    private var count = 0
    private var mediaTime = 0.0
    private var interval = 1.0 / 30

    mutating func media(at now: Double) -> Double {
        guard let last = lastArrival, now >= last, now - last <= 1 else {
            lastArrival = now; windowStart = now; count = 0; mediaTime = 0
            interval = 1.0 / 30
            return 0
        }
        lastArrival = now
        count += 1
        let elapsed = now - windowStart
        if elapsed >= 0.5 {
            let measured = min(1.0 / 12, max(1.0 / 61, elapsed / Double(count)))
            interval = interval * 0.5 + measured * 0.5
            windowStart = now; count = 0
        }
        mediaTime += interval
        return mediaTime
    }
}

struct FramePlayoutClock {
    private var anchorHost: Double?
    private var anchorMedia = 0.0
    private var lastMedia: Double?
    private(set) var generation: UInt64 = 0

    mutating func schedule(media: Double, arrived now: Double, delay: Double) -> (due: Double, generation: UInt64)? {
        guard media.isFinite, now.isFinite, delay.isFinite else { return nil }
        let buffer = max(0, delay)
        var reset = anchorHost == nil
        if let lastMedia { reset = reset || media < lastMedia || media - lastMedia > 1 }
        var due = (anchorHost ?? now) + media - anchorMedia + buffer
        // Bound accumulated clock drift in both directions, not only late frames.
        reset = reset || due < now - 0.1 || due > now + buffer + 0.1
        if reset {
            generation &+= 1
            anchorHost = now; anchorMedia = media
            due = now + buffer
        }
        lastMedia = media
        return (due, generation)
    }
}

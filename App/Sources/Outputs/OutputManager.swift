@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Runs each destination in its own actor-isolated "slot":
/// - independent queue, so a slow RTMP server can't stall SRT/RTSP/recording
/// - automatic reconnect with exponential backoff (1,2,4..30s)
/// - every (re)connect waits for the next IDR before sending video
actor OutputSlot {
    let target: any OutputTarget
    private(set) var status: OutputStatus = .idle
    private var running = false
    private var waitingForIDR = true
    private var desc: StreamDescription?
    private var supervisor: Task<Void, Never>?
    private let requestKeyframe: @Sendable () -> Void
    var onStatus: (@Sendable (UUID, OutputStatus) -> Void)?

    enum Media: @unchecked Sendable { case video(CMSampleBuffer), audio(AVAudioCompressedBuffer, AVAudioTime) }
    /// Ordered per-destination queue. Bounded: if a destination falls ~10 s behind,
    /// new media is dropped and the slot resyncs on the next IDR.
    nonisolated let queue: AsyncStream<Media>.Continuation

    init(target: any OutputTarget, requestKeyframe: @escaping @Sendable () -> Void) {
        self.target = target
        self.requestKeyframe = requestKeyframe
        let (stream, cont) = AsyncStream<Media>.makeStream(bufferingPolicy: .bufferingOldest(600))
        self.queue = cont
        Task { await self.runPump(stream) }
    }

    private func runPump(_ stream: AsyncStream<Media>) async {
        for await m in stream {
            switch m {
            case .video(let sb): await video(sb)
            case .audio(let b, let w): await audio(b, w)
            }
        }
    }

    nonisolated func enqueue(_ m: Media) {
        if case .dropped = queue.yield(m) { Task { await self.resync() } }
    }

    private func resync() { waitingForIDR = true; requestKeyframe() }

    func setStatusHandler(_ h: @escaping @Sendable (UUID, OutputStatus) -> Void) { onStatus = h }

    func start(_ d: StreamDescription) {
        desc = d
        guard !running else { return }
        running = true
        supervisor = Task { await self.superviseLoop() }
    }

    func stop() async {
        running = false
        queue.finish()
        supervisor?.cancel()
        await target.disconnect()
        set(.idle)
    }

    private func superviseLoop() async {
        var attempt = 0
        while running && !Task.isCancelled {
            guard let desc else { return }
            set(attempt == 0 ? .connecting : .reconnecting(attempt))
            do {
                try await target.connect(desc)
                waitingForIDR = true
                requestKeyframe()
                set(.live)
                attempt = 0
                while running, await target.isHealthy() {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch {
                set(.error(String(describing: error).prefix(80).description))
            }
            await target.disconnect()
            guard running else { return }
            attempt += 1
            let delay = min(30, 1 << min(attempt - 1, 5))
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        }
    }

    func video(_ sb: CMSampleBuffer) async {
        guard status == .live else { return }
        if waitingForIDR { guard sb.isKeyframe else { return }; waitingForIDR = false }
        await target.send(video: sb)
    }

    func audio(_ b: AVAudioCompressedBuffer, _ when: AVAudioTime) async {
        guard status == .live, !waitingForIDR else { return }
        await target.send(audio: b, when: when)
    }

    private func set(_ s: OutputStatus) {
        status = s
        onStatus?(target.config.id, s)
    }
}

/// Encode-once / fan-out hub between encoders and destinations.
final class OutputManager: @unchecked Sendable {
    private var slots: [UUID: OutputSlot] = [:]
    private let lock = NSLock()
    private var description: StreamDescription?
    private let requestKeyframe: @Sendable () -> Void
    var onStatus: (@Sendable (UUID, OutputStatus) -> Void)?
    let audioFormat: AVAudioFormat

    init(audioFormat: AVAudioFormat, requestKeyframe: @escaping @Sendable () -> Void) {
        self.audioFormat = audioFormat
        self.requestKeyframe = requestKeyframe
    }

    func makeTarget(_ c: OutputConfig) -> any OutputTarget {
        switch c.proto {
        case .rtmp: return RTMPOutput(config: c)
        case .srt: return SRTOutput(config: c)
        case .rtsp: return RTSPOutput(config: c)
        case .record: return RecordOutput(config: c)
        }
    }

    func start(_ c: OutputConfig) {
        let slot = OutputSlot(target: makeTarget(c), requestKeyframe: requestKeyframe)
        lock.lock(); slots[c.id] = slot; let d = description; lock.unlock()
        let h = onStatus
        Task {
            if let h { await slot.setStatusHandler(h) }
            if let d { await slot.start(d) } else { requestKeyframe() } // starts on first encoded IDR
        }
    }

    func stop(_ id: UUID) {
        lock.lock(); let s = slots.removeValue(forKey: id); lock.unlock()
        Task { await s?.stop() }
    }

    func stopAll() {
        lock.lock(); let all = Array(slots.values); slots.removeAll(); lock.unlock()
        Task { for s in all { await s.stop() } }
    }

    // Called on the encoder callback thread.
    func video(_ sb: CMSampleBuffer) {
        lock.lock()
        if description == nil || sb.isKeyframe, let ps = sb.h264ParameterSets, let fd = sb.formatDescription {
            let isNew = description == nil
            description = StreamDescription(sps: ps.sps, pps: ps.pps, videoFormat: fd, audioFormat: audioFormat)
            if isNew {
                let d = description!
                let all = Array(slots.values)
                Task { for s in all { await s.start(d) } }
            }
        }
        let all = Array(slots.values)
        lock.unlock()
        for s in all { s.enqueue(.video(sb)) }
    }

    func audio(_ b: AVAudioCompressedBuffer, when: AVAudioTime) {
        lock.lock(); let all = Array(slots.values); lock.unlock()
        for s in all { s.enqueue(.audio(b, when)) }
    }
}

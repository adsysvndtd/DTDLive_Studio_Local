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
            case .video(let sb): backlog.add(-1); await video(sb)
            case .audio(let b, let w): await audio(b, w)
            }
        }
    }

    /// Frames queued but not yet handed to the target (lock-free read for ABR).
    nonisolated let backlog = Counter()
    /// Totals actually handed to the target — shown per destination to tell "no video" from "no audio".
    nonisolated let videoSent = Counter()
    nonisolated let audioSent = Counter()

    nonisolated func enqueue(_ m: Media) {
        if case .video = m { backlog.add(1) }
        if case .dropped = queue.yield(m) {
            if case .video = m { backlog.add(-1) }
            Task { await self.resync() }
        }
    }

    /// Codec/parameter sets changed: reconnect with the new description.
    func reconnect(_ d: StreamDescription) async {
        desc = d
        guard running else { return }
        waitingForIDR = true
        await target.disconnect() // supervisor notices !isHealthy and reconnects with `desc`
    }

    func congestionSeconds(fps: Double) async -> Double {
        guard status == .live else { return 0 }
        let pending = await target.pendingBytes()
        return Double(backlog.value) / fps + Double(pending) * 8 / 6_000_000
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
                OutputLog.shared.add(target.config.id, LF("Lỗi: %@", "\(error)"))
                set(.error(String(describing: error).prefix(80).description))
            }
            if running { OutputLog.shared.add(target.config.id, L("Mất kết nối — thử lại")) }
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
        videoSent.add(1)
    }

    func audio(_ b: AVAudioCompressedBuffer, _ when: AVAudioTime) async {
        guard status == .live, !waitingForIDR else { return }
        await target.send(audio: b, when: when)
        audioSent.add(1)
    }

    private func set(_ s: OutputStatus) {
        status = s
        onStatus?(target.config.id, s)
    }
}

/// Tiny thread-safe counter.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0
    func add(_ d: Int) { lock.lock(); v += d; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return max(0, v) }
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

    /// (video frames, audio packets) sent so far, per destination.
    func sentCounts() -> [UUID: (Int, Int)] {
        lock.lock(); let all = slots; lock.unlock()
        return all.mapValues { ($0.videoSent.value, $0.audioSent.value) }
    }

    func makeTarget(_ c: OutputConfig) -> any OutputTarget {
        switch c.proto {
        case .rtmp: return RTMPOutput(config: c)
        case .srt: return SRTOutput(config: c)
        case .rtsp: return RTSPOutput(config: c)
        case .record: return RecordOutput(config: c)
        }
    }

    /// Whether encoded audio will arrive (set by the engine).
    var hasAudio: @Sendable () -> Bool = { true }

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

    /// Worst congestion across live destinations, in seconds of video queued.
    func congestion(fps: Double) async -> Double {
        lock.lock(); let all = Array(slots.values); lock.unlock()
        var worst = 0.0
        for s in all { worst = max(worst, await s.congestionSeconds(fps: fps)) }
        return worst
    }

    // Called on the encoder callback thread.
    func video(_ sb: CMSampleBuffer) {
        lock.lock()
        if description == nil || sb.isKeyframe, let ps = sb.videoParameterSets, let fd = sb.formatDescription {
            let old = description
            let d = StreamDescription(parameterSets: ps, isHEVC: sb.isHEVC, videoFormat: fd, audioFormat: audioFormat, hasAudio: hasAudio())
            description = d
            let all = Array(slots.values)
            if old == nil {
                Task { for s in all { await s.start(d) } }
            } else if old!.isHEVC != d.isHEVC || old!.parameterSets != d.parameterSets {
                // Codec or resolution changed (e.g. switched to HEVC or vertical format).
                Task { for s in all { await s.reconnect(d) } }
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

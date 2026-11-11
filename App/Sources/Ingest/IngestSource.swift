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

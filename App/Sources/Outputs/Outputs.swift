@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import HaishinKit
import RTMPHaishinKit
import RTSPPush
import SRTHaishinKit

enum OutputProtocol: String, Codable, CaseIterable, Identifiable {
    case rtmp, srt, rtsp, record
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rtmp: return "RTMP/RTMPS"
        case .srt: return "SRT"
        case .rtsp: return "RTSP (push)"
        case .record: return "Ghi file MP4"
        }
    }
    var placeholder: String {
        switch self {
        case .rtmp: return "rtmp://a.rtmp.youtube.com/live2/xxxx-xxxx"
        case .srt: return "srt://host:9000?mode=caller&streamid=publish:live/stream&latency=200000"
        case .rtsp: return "rtsp://user:pass@host:8554/live/stream"
        case .record: return L("(lưu vào Files › DTDStudio)")
        }
    }
}

enum OutputStatus: Equatable {
    case idle, connecting, live, reconnecting(Int), error(String)
    var text: String {
        switch self {
        case .idle: return L("Dừng")
        case .connecting: return L("Đang kết nối")
        case .live: return "LIVE"
        case .reconnecting(let n): return L("Kết nối lại") + " (\(n))"
        case .error(let e): return L("Lỗi") + ": \(e)"
        }
    }
}

struct OutputConfig: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var proto: OutputProtocol
    var url: String
    var enabled = true
    /// Viewer page for lives created by sign-in (YouTube watch / Facebook post), kept with the destination.
    var watchURL: String?
}

/// Context a destination needs to start: parameter sets for RTSP SDP / MP4 header.
/// Per-destination diagnostic log (last 40 lines), shown under each output in Đầu ra.
final class OutputLog: @unchecked Sendable {
    static let shared = OutputLog()
    private let lock = NSLock()
    private var lines: [UUID: [String]] = [:]
    private let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    func add(_ id: UUID, _ text: String) {
        lock.lock(); defer { lock.unlock() }
        var l = lines[id] ?? []
        l.append("\(df.string(from: Date()))  \(text)")
        if l.count > 40 { l.removeFirst(l.count - 40) }
        lines[id] = l
    }
    func get(_ id: UUID) -> [String] { lock.lock(); defer { lock.unlock() }; return lines[id] ?? [] }
    func clear(_ id: UUID) { lock.lock(); lines[id] = nil; lock.unlock() }
}

/// Values the RTMP metadata needs from the engine (written on the main thread, read when connecting).
enum StreamStats {
    static var bitrateKbps = 6000
    static var fps = 30
}

struct StreamDescription: Sendable {
    /// H.264: [SPS, PPS]; HEVC: [VPS, SPS, PPS]
    var parameterSets: [[UInt8]]
    var isHEVC: Bool
    var videoFormat: CMFormatDescription
    var audioFormat: AVAudioFormat
    /// False when the audio engine is not running (no mic permission): muxers must not wait for audio.
    var hasAudio = true
}

/// A push destination. Receives already-encoded media (encode once, fan out).
protocol OutputTarget: AnyObject, Sendable {
    var config: OutputConfig { get }
    func connect(_ desc: StreamDescription) async throws
    func disconnect() async
    func isHealthy() async -> Bool
    func send(video: CMSampleBuffer) async
    func send(audio: AVAudioCompressedBuffer, when: AVAudioTime) async
    /// Bytes accepted but not yet on the wire (for adaptive bitrate). 0 if unknown.
    func pendingBytes() async -> Int
}

extension OutputTarget {
    func pendingBytes() async -> Int { 0 }
}

// MARK: - RTMP (HaishinKit)

final class RTMPOutput: OutputTarget, @unchecked Sendable {
    let config: OutputConfig
    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    private var watchers: [Task<Void, Never>] = []
    private var sentVideo = 0, sentAudio = 0

    init(config: OutputConfig) { self.config = config }
    private func log(_ t: String) { OutputLog.shared.add(config.id, t) }

    func connect(_ desc: StreamDescription) async throws {
        guard let url = URL(string: config.url) else { throw URLError(.badURL) }
        let (app, key) = RTMPURL.split(url)
        let masked = key.count > 6 ? String(key.prefix(4)) + "…" + String(key.suffix(2)) : "…"
        log(LF("Kết nối %@  key %@", "\(app)", "\(masked)"))
        let c = RTMPConnection()
        // fcPublishName → FMLE sequence (releaseStream / FCPublish / FCUnpublish) like OBS & Larix;
        // YouTube, Facebook and most CDN ingests expect it.
        let s = RTMPStream(connection: c, fcPublishName: key)
        connection = c; stream = s; sentVideo = 0; sentAudio = 0
        // RTMPStream registers itself with the connection in a background task; give it a moment so the
        // stream is created during connect (otherwise publish can race createStream and go to stream id 0).
        try? await Task.sleep(nanoseconds: 150_000_000)
        // server status messages (rejections, disconnect reasons) into the log
        watchers = [
            Task { [weak self] in for await st in await c.status { self?.log("Conn: \(st.code) \(st.description)") } },
            Task { [weak self] in for await st in await s.status { self?.log("Stream: \(st.code) \(st.description)") } },
        ]
        do {
            let r = try await c.connect(app)
            log("connect → \(r.status?.code ?? "ok")")
        } catch { log(LF("connect lỗi: %@", "\(error)")); throw error }
        do {
            let r = try await s.publish(key)
            log("publish → \(r.status?.code ?? "ok")")
        } catch { log(LF("publish lỗi: %@", "\(error)")); throw error }
        // HaishinKit builds onMetaData from its own capture/encoder; with pre-encoded passthrough it would
        // send an empty one, and strict ingests (Facebook) then never see a video track. Send a full one.
        let dims = CMVideoFormatDescriptionGetDimensions(desc.videoFormat)
        var meta: AMFObject = [
            "duration": 0.0,
            "width": Double(dims.width), "height": Double(dims.height),
            "videocodecid": desc.isHEVC ? ("hvc1" as any Sendable) : (7.0 as any Sendable),
            "videodatarate": Double(StreamStats.bitrateKbps),
            "framerate": Double(StreamStats.fps),
            "encoder": "DTD Studio",
        ]
        if desc.hasAudio {
            meta["audiocodecid"] = 10.0
            meta["audiodatarate"] = 128.0
            meta["audiosamplerate"] = desc.audioFormat.sampleRate
            meta["audiosamplesize"] = 16.0
            meta["stereo"] = desc.audioFormat.channelCount > 1
        }
        try? await s.send("@setDataFrame", arguments: "onMetaData", meta, isResetTimestamp: true)
        let flags = desc.audioFormat.streamDescription.pointee.mFormatFlags
        log("metadata \(dims.width)×\(dims.height) \(desc.isHEVC ? "HEVC" : "H.264") · AAC \(Int(desc.audioFormat.sampleRate)) Hz (type \(flags))")
    }

    func disconnect() async {
        if stream != nil { log(LF("Ngắt kết nối (video %@, audio %@ gói)", "\(sentVideo)", "\(sentAudio)")) }
        watchers.forEach { $0.cancel() }; watchers = []
        _ = try? await stream?.close()
        try? await connection?.close()
        stream = nil; connection = nil
    }

    func isHealthy() async -> Bool { await connection?.connected ?? false }
    func send(video: CMSampleBuffer) async {
        if sentVideo == 0 { log(LF("Gửi khung hình đầu (keyframe: %@)", "\(video.isKeyframe)")) }
        sentVideo += 1
        await stream?.append(video)
    }
    func send(audio: AVAudioCompressedBuffer, when: AVAudioTime) async {
        if sentAudio == 0 { log(LF("Gửi gói âm thanh đầu (%@ byte)", "\(audio.byteLength)")) }
        sentAudio += 1
        await stream?.append(audio, when: when)
    }
}

// MARK: - SRT (HaishinKit, MPEG-TS over SRT)

final class SRTOutput: OutputTarget, @unchecked Sendable {
    let config: OutputConfig
    private var connection: SRTConnection?
    private var stream: SRTStream?

    init(config: OutputConfig) { self.config = config }

    func connect(_ desc: StreamDescription) async throws {
        guard let url = URL(string: config.url) else { throw URLError(.badURL) }
        let c = SRTConnection()
        let s = SRTStream(connection: c)
        connection = c; stream = s
        await s.setExpectedMedias(desc.hasAudio ? [.video, .audio] : [.video])
        try await c.connect(url)
        await s.publish()
    }

    func disconnect() async {
        await stream?.close()
        await connection?.close()
        stream = nil; connection = nil
    }

    func isHealthy() async -> Bool { await connection?.connected ?? false }
    func send(video: CMSampleBuffer) async { await stream?.append(video) }
    func send(audio: AVAudioCompressedBuffer, when: AVAudioTime) async { await stream?.append(audio, when: when) }
}

// MARK: - RTSP push (own RTSPPush package: ANNOUNCE/SETUP/RECORD, RTP over TCP)

final class RTSPOutput: OutputTarget, @unchecked Sendable {
    let config: OutputConfig
    private var client: RTSPPushClient?

    init(config: OutputConfig) { self.config = config }

    func connect(_ desc: StreamDescription) async throws {
        guard let url = URL(string: config.url) else { throw URLError(.badURL) }
        let c = RTSPPushClient(url: url)
        client = c
        let audio = SDPDescription.Audio.aacLC(sampleRate: Int(desc.audioFormat.sampleRate), channels: Int(desc.audioFormat.channelCount))
        let ps = desc.parameterSets
        let video: SDPDescription.Video = desc.isHEVC ? .init(hevc: ps[0], sps: ps[1], pps: ps[2]) : .init(sps: ps[0], pps: ps[1])
        try await c.start(sdp: SDPDescription(video: video, audio: audio))
    }

    func disconnect() async {
        await client?.stop()
        client = nil
    }

    func isHealthy() async -> Bool {
        guard let client else { return false }
        return await client.state == .recording
    }

    func send(video: CMSampleBuffer) async {
        guard let client else { return }
        var nals = NALUnitSplitter.splitAVCC(video.dataBytes)
        let key = video.isKeyframe
        // Repeat SPS/PPS in-band on IDR so late joiners / server-side recorders can decode.
        if key, let ps = video.videoParameterSets { nals.insert(contentsOf: ps.map { $0[...] }, at: 0) }
        await client.sendVideo(nalUnits: nals, pts: video.presentationTimeStamp.seconds, isKeyframe: key)
    }

    func pendingBytes() async -> Int { await client?.pendingBytes ?? 0 }

    func send(audio: AVAudioCompressedBuffer, when: AVAudioTime) async {
        guard let client, audio.packetCount > 0 else { return }
        let size = Int(audio.packetDescriptions?[0].mDataByteSize ?? UInt32(audio.byteLength))
        let bytes = Array(UnsafeBufferPointer(start: audio.data.assumingMemoryBound(to: UInt8.self), count: size))
        await client.sendAudio(accessUnit: bytes, pts: AVAudioTime.seconds(forHostTime: when.hostTime))
    }
}

// MARK: - Local MP4 recording (passthrough, no re-encode)

final class RecordOutput: OutputTarget, @unchecked Sendable {
    let config: OutputConfig
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var started = false
    private var audioFormat: CMAudioFormatDescription?

    init(config: OutputConfig) { self.config = config }

    func connect(_ desc: StreamDescription) async throws {
        let dir = MediaLibrary.directory(.movie)
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("DTD-\(df.string(from: Date())).mp4")
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        w.shouldOptimizeForNetworkUse = false
        w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600) // crash-safe fragments
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: desc.videoFormat)
        v.expectsMediaDataInRealTime = true
        var asbd = desc.audioFormat.streamDescription.pointee
        var afd: CMAudioFormatDescription?
        let asc = SDPDescription.Audio.aacLC(sampleRate: Int(asbd.mSampleRate), channels: Int(asbd.mChannelsPerFrame)).audioSpecificConfig
        asc.withUnsafeBytes { cookie in
            _ = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: cookie.count,
                                               magicCookie: cookie.baseAddress, extensions: nil, formatDescriptionOut: &afd)
        }
        audioFormat = afd
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: afd)
        a.expectsMediaDataInRealTime = true
        w.add(v); w.add(a)
        w.startWriting()
        writer = w; videoIn = v; audioIn = a
    }

    func disconnect() async {
        videoIn?.markAsFinished(); audioIn?.markAsFinished()
        await writer?.finishWriting()
        writer = nil; started = false
    }

    func isHealthy() async -> Bool { writer?.status == .writing }

    func send(video: CMSampleBuffer) async {
        guard let w = writer, let v = videoIn else { return }
        if !started {
            guard video.isKeyframe else { return }
            w.startSession(atSourceTime: video.presentationTimeStamp); started = true
        }
        if v.isReadyForMoreMediaData { v.append(video) }
    }

    func send(audio: AVAudioCompressedBuffer, when: AVAudioTime) async {
        guard started, let a = audioIn, a.isReadyForMoreMediaData, let fd = audioFormat, audio.packetCount > 0 else { return }
        let pts = CMTime(seconds: AVAudioTime.seconds(forHostTime: when.hostTime), preferredTimescale: 48000)
        var sb: CMSampleBuffer?
        var bb: CMBlockBuffer?
        let len = Int(audio.byteLength)
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: len, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: len, flags: 0, blockBufferOut: &bb)
        guard let bb else { return }
        CMBlockBufferReplaceDataBytes(with: audio.data, blockBuffer: bb, offsetIntoDestination: 0, dataLength: len)
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb, formatDescription: fd,
                                                             sampleCount: Int(audio.packetCount), presentationTimeStamp: pts,
                                                             packetDescriptions: audio.packetDescriptions, sampleBufferOut: &sb)
        if let sb { a.append(sb) }
    }
}

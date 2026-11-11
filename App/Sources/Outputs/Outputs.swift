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
        case .record: return "(lưu vào Files › DTDStudio)"
        }
    }
}

enum OutputStatus: Equatable {
    case idle, connecting, live, reconnecting(Int), error(String)
    var text: String {
        switch self {
        case .idle: return "Dừng"
        case .connecting: return "Đang kết nối"
        case .live: return "LIVE"
        case .reconnecting(let n): return "Kết nối lại (\(n))"
        case .error(let e): return "Lỗi: \(e)"
        }
    }
}

struct OutputConfig: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var proto: OutputProtocol
    var url: String
    var enabled = true
}

/// Context a destination needs to start: parameter sets for RTSP SDP / MP4 header.
struct StreamDescription: Sendable {
    var sps: [UInt8]
    var pps: [UInt8]
    var videoFormat: CMFormatDescription
    var audioFormat: AVAudioFormat
}

/// A push destination. Receives already-encoded media (encode once, fan out).
protocol OutputTarget: AnyObject, Sendable {
    var config: OutputConfig { get }
    func connect(_ desc: StreamDescription) async throws
    func disconnect() async
    func isHealthy() async -> Bool
    func send(video: CMSampleBuffer) async
    func send(audio: AVAudioCompressedBuffer, when: AVAudioTime) async
}

// MARK: - RTMP (HaishinKit)

final class RTMPOutput: OutputTarget, @unchecked Sendable {
    let config: OutputConfig
    private var connection: RTMPConnection?
    private var stream: RTMPStream?

    init(config: OutputConfig) { self.config = config }

    func connect(_ desc: StreamDescription) async throws {
        guard let url = URL(string: config.url) else { throw URLError(.badURL) }
        let (app, key) = RTMPURL.split(url)
        let c = RTMPConnection()
        let s = RTMPStream(connection: c)
        connection = c; stream = s
        _ = try await c.connect(app)
        _ = try await s.publish(key)
    }

    func disconnect() async {
        _ = try? await stream?.close()
        try? await connection?.close()
        stream = nil; connection = nil
    }

    func isHealthy() async -> Bool { await connection?.connected ?? false }
    func send(video: CMSampleBuffer) async { await stream?.append(video) }
    func send(audio: AVAudioCompressedBuffer, when: AVAudioTime) async { await stream?.append(audio, when: when) }
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
        await s.setExpectedMedias([.video, .audio])
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
        try await c.start(sdp: SDPDescription(video: .init(sps: desc.sps, pps: desc.pps), audio: audio))
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
        if key, let ps = video.h264ParameterSets { nals.insert(ps.pps[...], at: 0); nals.insert(ps.sps[...], at: 0) }
        await client.sendVideo(nalUnits: nals, pts: video.presentationTimeStamp.seconds, isKeyframe: key)
    }

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
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("DTD-\(df.string(from: Date())).mp4")
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        w.shouldOptimizeForNetworkUse = false
        w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600) // crash-safe fragments
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: desc.videoFormat)
        v.expectsMediaDataInRealTime = true
        var asbd = desc.audioFormat.streamDescription.pointee
        var afd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &afd)
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

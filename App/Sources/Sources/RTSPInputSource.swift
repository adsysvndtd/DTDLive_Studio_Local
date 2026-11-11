@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import RTSPPush

/// RTSP pull input (IP cameras, encoders, MediaMTX). H.264 / H.265 video, AAC audio.
/// URL: rtsp://user:pass@192.168.1.64:554/Streaming/Channels/101
@MainActor
final class RTSPInputSource: VideoSource {
    let id = UUID()
    var name: String
    let kind: SourceKind = .rtsp
    let frames = FrameStore()
    private(set) var status: SourceStatus = .idle
    let url: URL
    var onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?

    private var client: RTSPPlayClient?
    private var supervisor: Task<Void, Never>?
    private let pipeline = RTSPDecodePipeline()

    init(name: String, url: URL) { self.name = name; self.url = url }

    func start() async {
        supervisor?.cancel()
        supervisor = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.connectOnce()
                if Task.isCancelled { return }
                attempt += 1
                self.status = .error("mất kết nối, thử lại (\(attempt))")
                try? await Task.sleep(nanoseconds: UInt64(min(10, attempt * 2)) * 1_000_000_000)
            }
        }
    }

    /// Runs until the session drops.
    private func connectOnce() async {
        status = .connecting
        let c = RTSPPlayClient(url: url)
        client = c
        let p = pipeline, store = frames, audio = onAudio
        p.reset()
        await c.setHandlers(video: { au in if let pb = p.video(au) { store.put(pb) } },
                            audio: { aac, _ in if let pcm = p.audio(aac) { audio?(pcm) } })
        do {
            try await c.start()
            let tracks = await c.tracks
            p.configure(video: tracks.video, audio: tracks.audio)
            status = .live
            while !Task.isCancelled, await c.state == .playing {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            status = .error("\(error)")
        }
        await c.stop()
    }

    func stop() async {
        supervisor?.cancel(); supervisor = nil
        await client?.stop(); client = nil
        frames.clear()
        status = .idle
    }
}

/// Depacketized media -> decoded frames / PCM. Thread-safe; called from the client's actor.
final class RTSPDecodePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var isHEVC = false
    private var parameterSets: [[UInt8]] = []
    private var format: CMVideoFormatDescription?
    private var decoder: FrameDecoder?
    private var audioConverter: AVAudioConverter?
    private var aacFormat: AVAudioFormat?
    private let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    func reset() {
        lock.lock(); defer { lock.unlock() }
        format = nil; decoder = nil; parameterSets = []; audioConverter = nil
    }

    func configure(video: SDPMedia?, audio: SDPMedia?) {
        lock.lock(); defer { lock.unlock() }
        if let v = video {
            isHEVC = v.codec == .h265
            if !v.parameterSets.isEmpty { parameterSets = v.parameterSets; makeFormat() }
        }
        if let a = audio {
            var asbd = AudioStreamBasicDescription(mSampleRate: Double(a.clockRate), mFormatID: kAudioFormatMPEG4AAC,
                                                   mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                                   mBytesPerFrame: 0, mChannelsPerFrame: UInt32(max(1, a.channels)),
                                                   mBitsPerChannel: 0, mReserved: 0)
            if let f = AVAudioFormat(streamDescription: &asbd) {
                aacFormat = f
                audioConverter = AVAudioConverter(from: f, to: pcmFormat)
                let cfg = a.aacConfig
                if !cfg.isEmpty { audioConverter?.magicCookie = Data(cfg) }
            }
        }
    }

    /// RTMP / SRT: AAC from an AudioSpecificConfig instead of SDP.
    func configureAAC(asc: [UInt8], sampleRate: Int, channels: Int) {
        lock.lock(); defer { lock.unlock() }
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatMPEG4AAC,
                                               mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                               mBytesPerFrame: 0, mChannelsPerFrame: UInt32(max(1, channels)),
                                               mBitsPerChannel: 0, mReserved: 0)
        guard let f = AVAudioFormat(streamDescription: &asbd) else { return }
        aacFormat = f
        audioConverter = AVAudioConverter(from: f, to: pcmFormat)
        if !asc.isEmpty { audioConverter?.magicCookie = Data(asc) }
    }
    var hasAudioDecoder: Bool { lock.lock(); defer { lock.unlock() }; return audioConverter != nil }

    /// RTMP: codec known from the FLV tag (H.264 or enhanced-RTMP HEVC).
    func setHEVC(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isHEVC != on { isHEVC = on; format = nil; decoder = nil; parameterSets = [] }
    }

    // MARK: Video

    func video(_ au: AccessUnit) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        // Pick up in-band parameter sets (cameras that omit sprop-* in SDP, or change resolution).
        let inBand = au.nalUnits.filter { nal in
            guard let h = nal.first else { return false }
            if isHEVC { let t = (h >> 1) & 0x3F; return t == 32 || t == 33 || t == 34 }
            let t = h & 0x1F; return t == 7 || t == 8
        }
        if !inBand.isEmpty, inBand != parameterSets, inBand.count >= (isHEVC ? 3 : 2) {
            parameterSets = inBand; makeFormat()
        }
        guard let format else { return nil }
        if decoder == nil { guard au.isKeyframe else { return nil }; decoder = FrameDecoder(format: format) }
        var avcc = [UInt8]()
        for nal in au.nalUnits {
            let n = UInt32(nal.count)
            avcc += [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            avcc += nal
        }
        guard let sb = Self.sampleBuffer(avcc, format: format) else { return nil }
        return decoder?.decode(sb)
    }

    private func makeFormat() {
        var fd: CMVideoFormatDescription?
        let sets = parameterSets.map { Data($0) }
        let status: OSStatus = sets.withPointers { ptrs, sizes in
            if isHEVC {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: ptrs.count,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: ptrs.count,
                parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
        }
        if status == noErr, let fd, fd != format { format = fd; decoder = nil }
    }

    static func sampleBuffer(_ bytes: [UInt8], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        bytes.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        var sb: CMSampleBuffer?
        var size = bytes.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sb)
        return sb
    }

    // MARK: Audio

    func audio(_ aac: [UInt8]) -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let conv = audioConverter, let fmt = aacFormat, !aac.isEmpty else { return nil }
        let input = AVAudioCompressedBuffer(format: fmt, packetCapacity: 1, maximumPacketSize: aac.count)
        aac.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: aac.count) }
        input.byteLength = UInt32(aac.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(aac.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 2048) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        return out.frameLength > 0 ? out : nil
    }
}

private extension Array where Element == Data {
    /// Calls `body` with stable pointers/sizes for every element.
    func withPointers<R>(_ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        func go(_ i: Int, _ ptrs: [UnsafePointer<UInt8>]) -> R {
            if i == count { return body(ptrs, map(\.count)) }
            return self[i].withUnsafeBytes { go(i + 1, ptrs + [$0.bindMemory(to: UInt8.self).baseAddress!]) }
        }
        return go(0, [])
    }
}

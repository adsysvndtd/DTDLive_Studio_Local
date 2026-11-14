@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

enum VideoCodecChoice: String, Codable, CaseIterable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
    var label: String { self == .h264 ? "H.264" : "HEVC (H.265)" }
}

struct EncoderSettings: Equatable, Codable {
    var codec: VideoCodecChoice = .h264
    var bitrate = 6_000_000
    /// Adaptive bitrate floor (bps) — the encoder never goes below this under congestion.
    var minBitrate = 1_500_000
    var adaptive = true
    var keyframeInterval: Double = 2 // seconds; 2s is what YouTube/Facebook require
    var profile: String {
        codec == .h264 ? kVTProfileLevel_H264_High_AutoLevel as String : kVTProfileLevel_HEVC_Main_AutoLevel as String
    }
    var audioBitrate = 128_000
    /// B-frames (frame reordering): ~10–15 % better picture at the same bitrate, ~2 frames more latency.
    var bFrames = false
}

extension EncoderSettings {
    // Tolerant decoding: settings saved by older builds (missing keys) keep their values.
    init(from d: Decoder) throws {
        self.init()
        let c = try d.container(keyedBy: CodingKeys.self)
        codec = (try? c.decodeIfPresent(VideoCodecChoice.self, forKey: .codec)) ?? codec
        bitrate = (try? c.decodeIfPresent(Int.self, forKey: .bitrate)) ?? bitrate
        minBitrate = (try? c.decodeIfPresent(Int.self, forKey: .minBitrate)) ?? minBitrate
        adaptive = (try? c.decodeIfPresent(Bool.self, forKey: .adaptive)) ?? adaptive
        keyframeInterval = (try? c.decodeIfPresent(Double.self, forKey: .keyframeInterval)) ?? keyframeInterval
        audioBitrate = (try? c.decodeIfPresent(Int.self, forKey: .audioBitrate)) ?? audioBitrate
        bFrames = (try? c.decodeIfPresent(Bool.self, forKey: .bFrames)) ?? bFrames
    }
}

/// One shared H.264 encoder for all destinations (encode once, fan out).
/// B-frames are optional (EncoderSettings.bFrames): outputs carry DTS (RTMP composition time, TS DTS,
/// RTP uses PTS), replay decoding reorders frames by PTS.
final class VideoEncoder: @unchecked Sendable {
    typealias Handler = @Sendable (CMSampleBuffer) -> Void
    private var session: VTCompressionSession?
    private var settings: EncoderSettings
    private var size: (Int32, Int32) = (0, 0)
    private var forceKeyframe = false
    private var needsRebuild = false
    private var liveBitrate: Int
    /// Program frame rate; changing it rebuilds the session on the next frame.
    var fps: Double = 30 { didSet { if fps != oldValue { invalidate(); forceKeyframe = true } } }
    /// encode() runs on the switcher's render queue; settings/ABR/keyframe requests come from
    /// the main thread and output actors. One recursive lock serialises all session access.
    private let lock = NSRecursiveLock()
    var onEncoded: Handler?
    /// Frames submitted / emitted (lock-free reads for the stall watchdog).
    let framesIn = Counter(), framesOut = Counter()
    var onProblem: (@Sendable (String) -> Void)?

    init(settings: EncoderSettings) { self.settings = settings; liveBitrate = settings.bitrate }

    func encode(_ pb: CVPixelBuffer, pts: CFTimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let w = Int32(CVPixelBufferGetWidth(pb)), h = Int32(CVPixelBufferGetHeight(pb))
        if needsRebuild { needsRebuild = false; invalidate(); forceKeyframe = true }
        if session == nil || size != (w, h) { makeSession(w, h) }
        guard let session else { return }
        var props: CFDictionary?
        if forceKeyframe {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceKeyframe = false
        }
        let time = CMTime(seconds: pts, preferredTimescale: 90_000)
        framesIn.add(1)
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: time, duration: .invalid,
                                                 frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self else { return }
            guard status == noErr, let sample else {
                // Session died (interruption, memory pressure, media services reset): rebuild on the next frame.
                // never tear the session down from inside its own callback — flag it, encode() rebuilds
                self.lock.lock(); self.needsRebuild = true; self.lock.unlock()
                self.onProblem?("VideoToolbox lỗi \(status) \(Self.explain(status)) — tạo lại bộ mã hoá")
                return
            }
            self.framesOut.add(1)
            self.onEncoded?(sample)
        }
        if st != noErr {
            onProblem?("VideoToolbox lỗi \(st) \(Self.explain(st)) — tạo lại bộ mã hoá")
            invalidate(); forceKeyframe = true
        }
    }

    /// Short reason for the common VideoToolbox codes (shown in the output log).
    static func explain(_ st: OSStatus) -> String {
        switch st {
        case -12902: return "(tham số/thời gian khung không hợp lệ)"
        case -12903: return "(phiên mã hoá mất hiệu lực — app vào nền / bị gián đoạn)"
        case -12904: return "(không tạo được bộ mã hoá)"
        case -12911: return "(bộ mã hoá phần cứng lỗi / quá tải)"
        case -12915: return "(phần cứng mã hoá đang bận)"
        case -16991, -16990: return "(hết bộ nhớ đệm)"
        default: return ""
        }
    }

    /// Called when a destination (re)connects so it can start on an IDR.
    func requestKeyframe() { lock.lock(); forceKeyframe = true; lock.unlock() }

    /// Watchdog: frames go in but nothing comes out → drop the session and start a new one.
    func restartIfStalled(_ inSinceLast: Int, _ outSinceLast: Int) -> Bool {
        guard inSinceLast >= 20, outSinceLast == 0 else { return false }
        onProblem?("Bộ mã hoá không ra hình (\(inSinceLast) khung vào, 0 ra) — khởi động lại")
        lock.lock(); needsRebuild = true; lock.unlock()
        return true
    }

    func update(_ s: EncoderSettings) {
        lock.lock(); defer { lock.unlock() }
        let codecChanged = s.codec != settings.codec || s.bFrames != settings.bFrames
        settings = s
        if codecChanged { invalidate(); forceKeyframe = true; return } // new session on next frame
        setBitrate(s.bitrate)
    }

    /// Live bitrate change (adaptive bitrate); no keyframe, no session restart.
    func setBitrate(_ bps: Int) {
        lock.lock(); defer { lock.unlock() }
        liveBitrate = bps
        if let session {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                                 value: [Double(bps) * 1.5 / 8, 1.0] as CFArray)
        }
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(session) }
        session = nil
    }

    private func makeSession(_ w: Int32, _ h: Int32) {
        invalidate()
        size = (w, h)
        var s: VTCompressionSession?
        // On iOS every H.264/HEVC encoder is hardware; the explicit requirement key only exists from 17.4.
        var spec: CFDictionary?
        if #available(iOS 17.4, *) {
            spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        }
        guard VTCompressionSessionCreate(allocator: nil, width: w, height: h, codecType: settings.codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
                                         encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr, let s else { return }
        let fps = self.fps
        let p: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            // spend the encoder's effort on quality (the hardware encoder is far faster than real time)
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: false,
            kVTCompressionPropertyKey_ProfileLevel: settings.profile,
            kVTCompressionPropertyKey_AllowFrameReordering: settings.bFrames,
            kVTCompressionPropertyKey_AverageBitRate: liveBitrate,
            kVTCompressionPropertyKey_DataRateLimits: [Double(liveBitrate) * 1.5 / 8, 1.0],
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: settings.keyframeInterval,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(fps * settings.keyframeInterval),
            // Rec.709 colour info in the SPS (VUI): players and YouTube/Facebook transcoders read the colours right.
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        // One property at a time: a key the device's encoder rejects must not stop the others
        // (bitrate, GOP, frame rate) from applying. Rejected optional keys are only logged.
        for (k, v) in p {
            let st = VTSessionSetProperty(s, key: k, value: v as CFTypeRef)
            if st != noErr { onProblem?("Bộ mã hoá không nhận thuộc tính \(k) (\(st))") }
        }
        if settings.codec == .h264 {
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        }
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }
}

extension CMSampleBuffer {
    var isKeyframe: Bool {
        guard let att = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let first = att.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    var isHEVC: Bool { formatDescription?.mediaSubType == .hevc }

    /// H.264: [SPS, PPS]; HEVC: [VPS, SPS, PPS] (and any extra SEI-prefix sets).
    var videoParameterSets: [[UInt8]]? {
        guard let fd = formatDescription else { return nil }
        let hevc = isHEVC
        func set(_ i: Int, _ count: UnsafeMutablePointer<Int>?) -> [UInt8]? {
            var ptr: UnsafePointer<UInt8>?; var len = 0
            let st = hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &len, parameterSetCountOut: count, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &len, parameterSetCountOut: count, nalUnitHeaderLengthOut: nil)
            guard st == noErr, let ptr else { return nil }
            return Array(UnsafeBufferPointer(start: ptr, count: len))
        }
        var n = 0
        guard let first = set(0, &n) else { return nil }
        var out = [first]
        for i in 1..<max(n, 1) { if let s = set(i, nil) { out.append(s) } }
        return out.count >= (hevc ? 3 : 2) ? out : nil
    }

    var dataBytes: [UInt8] {
        guard let bb = dataBuffer else { return [] }
        var out = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(bb))
        CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: out.count, destination: &out)
        return out
    }
}

/// PCM -> AAC-LC (one shared encoder). Emits AVAudioCompressedBuffer with exactly one
/// 1024-sample access unit each, stamped in host time.
final class AudioEncoder: @unchecked Sendable {
    typealias Handler = @Sendable (AVAudioCompressedBuffer, AVAudioTime) -> Void
    var onEncoded: Handler?
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var pending: [AVAudioPCMBuffer] = []
    private var firstHostSeconds: Double?
    private var samplesOut: Int64 = 0

    init(input: AVAudioFormat, bitrate: Int) {
        // mFormatFlags must carry the MPEG-4 object type (AAC-LC = 2): RTMP muxers build the AAC
        // sequence header (AudioSpecificConfig) from it. With 0 no header is sent and YouTube/Facebook
        // can't decode the audio — the stream stays "waiting" and the server drops the connection.
        var asbd = AudioStreamBasicDescription(mSampleRate: input.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                               mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
                                               mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                               mChannelsPerFrame: input.channelCount, mBitsPerChannel: 0, mReserved: 0)
        outputFormat = AVAudioFormat(streamDescription: &asbd)!
        converter = AVAudioConverter(from: input, to: outputFormat)!
        converter.bitRate = bitrate
    }

    func append(_ pcm: AVAudioPCMBuffer, when: AVAudioTime) {
        if firstHostSeconds == nil { firstHostSeconds = AVAudioTime.seconds(forHostTime: when.hostTime) }
        pending.append(pcm)
        while true {
            let out = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 1, maximumPacketSize: max(converter.maximumOutputPacketSize, 1536))
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { [weak self] _, inStatus in
                guard let self, !self.pending.isEmpty else { inStatus.pointee = .noDataNow; return nil }
                inStatus.pointee = .haveData
                return self.pending.removeFirst()
            }
            guard status == .haveData, out.packetCount > 0 else { return }
            let seconds = (firstHostSeconds ?? 0) + Double(samplesOut) / outputFormat.sampleRate
            samplesOut += 1024
            onEncoded?(out, AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: seconds)))
        }
    }
}

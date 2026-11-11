@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

struct EncoderSettings: Equatable {
    var bitrate = 6_000_000
    var keyframeInterval: Double = 2 // seconds; 2s is what YouTube/Facebook require
    var profile = kVTProfileLevel_H264_High_AutoLevel as String
    var audioBitrate = 128_000
}

/// One shared H.264 encoder for all destinations (encode once, fan out).
/// No B-frames, so PTS == DTS — keeps RTMP/SRT/RTSP timestamping simple.
final class VideoEncoder: @unchecked Sendable {
    typealias Handler = @Sendable (CMSampleBuffer) -> Void
    private var session: VTCompressionSession?
    private var settings: EncoderSettings
    private var size: (Int32, Int32) = (0, 0)
    private var forceKeyframe = false
    var onEncoded: Handler?

    init(settings: EncoderSettings) { self.settings = settings }

    func encode(_ pb: CVPixelBuffer, pts: CFTimeInterval) {
        let w = Int32(CVPixelBufferGetWidth(pb)), h = Int32(CVPixelBufferGetHeight(pb))
        if session == nil || size != (w, h) { makeSession(w, h) }
        guard let session else { return }
        var props: CFDictionary?
        if forceKeyframe {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceKeyframe = false
        }
        let time = CMTime(seconds: pts, preferredTimescale: 90_000)
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample else { return }
            self?.onEncoded?(sample)
        }
    }

    /// Called when a destination (re)connects so it can start on an IDR.
    func requestKeyframe() { forceKeyframe = true }

    func update(_ s: EncoderSettings) {
        settings = s
        if let session {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: s.bitrate as CFNumber)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                                 value: [Double(s.bitrate) * 1.5 / 8, 1.0] as CFArray)
        }
    }

    func invalidate() {
        if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(session) }
        session = nil
    }

    private func makeSession(_ w: Int32, _ h: Int32) {
        invalidate()
        size = (w, h)
        var s: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: w, height: h, codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr, let s else { return }
        let fps = 30.0
        let p: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: settings.profile,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: settings.bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [Double(settings.bitrate) * 1.5 / 8, 1.0],
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: settings.keyframeInterval,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(fps * settings.keyframeInterval),
            kVTCompressionPropertyKey_H264EntropyMode: kVTH264EntropyMode_CABAC
        ]
        VTSessionSetProperties(s, propertyDictionary: p as CFDictionary)
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

    /// SPS / PPS from an H.264 format description.
    var h264ParameterSets: (sps: [UInt8], pps: [UInt8])? {
        guard let fd = formatDescription else { return nil }
        func set(_ i: Int) -> [UInt8]? {
            var ptr: UnsafePointer<UInt8>?; var len = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &len, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil) == noErr, let ptr else { return nil }
            return Array(UnsafeBufferPointer(start: ptr, count: len))
        }
        guard let sps = set(0), let pps = set(1) else { return nil }
        return (sps, pps)
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
        var asbd = AudioStreamBasicDescription(mSampleRate: input.sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
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

// Ví dụ nối VideoToolbox + AudioConverter vào SRTKit (rút gọn, không gồm phần camera/UI).
import AVFoundation
import Network
import SRTKit
import VideoToolbox

final class StreamController: NSObject, SRTKBroadcasterDelegate {
    private var session: VTCompressionSession?
    private var forceKeyframe = true
    private let broadcaster: SRTKBroadcaster
    private let monitor = NWPathMonitor()

    init(urls: [String], bitrate: Int = 3_000_000, fps: Int = 30) throws {
        let p = SRTKStreamParams()
        p.videoCodec = .h264
        p.videoBitrate = bitrate
        p.frameRate = fps
        p.width = 1280; p.height = 720
        p.audioSampleRate = 48000; p.audioChannels = 2
        p.insertNtpTimecode = true
        broadcaster = SRTKBroadcaster(params: p)
        super.init()
        broadcaster.delegate = self

        for (i, url) in urls.prefix(5).enumerated() {
            let c = try SRTKConnectionConfig(url: url)
            c.name = "dest\(i + 1)"
            c.abrMode = .ladderAscend
            c.variableFrameRate = true
            _ = broadcaster.addConnection(c)
        }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.broadcaster.setNetworkAvailable(path.status == .satisfied)
        }
        monitor.start(queue: .global())
        makeEncoder(width: 1280, height: 720, bitrate: bitrate, fps: fps)
    }

    func start(standby: Bool = false) { standby ? broadcaster.startInStandby() : broadcaster.start() }
    func stop() { broadcaster.stop() }

    // MARK: Encoder
    private func makeEncoder(width: Int32, height: Int32, bitrate: Int, fps: Int) {
        VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
                                   encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard let s = session else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) // không B-frame
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        setBitrate(bitrate)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    private func setBitrate(_ bps: Int) {
        guard let s = session else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        let limit = [Double(bps) * 1.5 / 8, 1.0] as CFArray   // byte trong 1 giây
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limit)
    }

    /// Gọi từ AVCaptureVideoDataOutput (sau compositor overlay / pause).
    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let s = session else { return }
        var props: CFDictionary?
        if forceKeyframe {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceKeyframe = false
        }
        VTCompressionSessionEncodeFrame(s, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            if status == noErr, let sb = sb { self?.broadcaster.appendVideoSampleBuffer(sb) }
        }
    }

    /// AAC đã encode từ AVAudioConverter (mỗi packet 1024 mẫu).
    func audioEncoded(_ packet: Data, ptsUs: Int64) {
        broadcaster.appendAudioData(packet, presentationTimeUs: ptsUs)
    }

    // MARK: SRTKBroadcasterDelegate
    func broadcaster(_ b: SRTKBroadcaster, connection id: Int, didChange state: SRTKConnectionState, info: String) {
        print("conn \(id) -> \(state.rawValue) \(info)")
    }
    func broadcaster(_ b: SRTKBroadcaster, didUpdateStats stats: [SRTKConnectionStats]) {
        for s in stats { print("\(s.name): \(Int(s.sendKbps)) kbps rtt \(s.rttMs) lost \(s.packetsLost)") }
    }
    func broadcaster(_ b: SRTKBroadcaster, requestsVideoBitrate bitrate: Int) { setBitrate(bitrate) }
    func broadcaster(_ b: SRTKBroadcaster, requestsFrameRate fps: Int) {
        if let s = session { VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber) }
        // và bỏ bớt khung ở tầng capture cho đúng fps mới
    }
    func broadcasterRequestsKeyframe(_ b: SRTKBroadcaster) { forceKeyframe = true }
}

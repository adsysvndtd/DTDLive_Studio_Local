import AVFoundation
import CoreVideo
import Foundation
import QuartzCore
#if NDI_SDK
import NDI
#endif

/// NDI input/output.
///
/// The NDI SDK is licensed by Vizrt and must be downloaded by the developer from
/// https://ndi.video/for-developers/ndi-sdk/ (it cannot be redistributed in this repo
/// and must not be taken from another vendor's app bundle). To enable:
///   1. Put `libndi_ios.a` and `Processing.NDI.*.h` in `Vendor/NDI/` (git-ignored).
///   2. In project.yml uncomment the NDI section (module map + `NDI_SDK` compilation flag).
///   3. Follow the NDI licence: show "NDI®" attribution in the app and docs.
/// Without the SDK this file compiles to stubs and the UI hides NDI.
enum NDIAvailability {
    #if NDI_SDK
    static let isAvailable = true
    #else
    static let isAvailable = false
    #endif
}

/// Thread-safe holder for the Program → NDI sender (no-op without the SDK).
final class NDIOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    #if NDI_SDK
    private var sender: NDISender?
    #endif
    private var fps = 30
    func configure(on: Bool, name: String, fps: Int) {
        lock.lock(); defer { lock.unlock() }
        self.fps = fps
        #if NDI_SDK
        sender = on ? NDISender(name: name) : nil
        #endif
    }
    func send(_ pb: CVPixelBuffer) {
        #if NDI_SDK
        lock.lock(); let s = sender, f = fps; lock.unlock()
        s?.send(pb, fps: f)
        #endif
    }
    /// Program audio (the mixer output) to the same NDI source.
    func sendAudio(_ pcm: AVAudioPCMBuffer) {
        #if NDI_SDK
        lock.lock(); let s = sender; lock.unlock()
        s?.sendAudio(pcm)
        #endif
    }
}

#if NDI_SDK

final class NDIFinder: @unchecked Sendable {
    private let finder: NDIlib_find_instance_t?

    init() {
        _ = NDIlib_initialize()
        var settings = NDIlib_find_create_t(show_local_sources: true, p_groups: nil, p_extra_ips: nil)
        finder = NDIlib_find_create_v2(&settings)
    }

    deinit { if let finder { NDIlib_find_destroy(finder) } }

    func sources(waitMs: UInt32 = 500) -> [String] {
        guard let finder else { return [] }
        _ = NDIlib_find_wait_for_sources(finder, waitMs)
        var count: UInt32 = 0
        guard let list = NDIlib_find_get_current_sources(finder, &count) else { return [] }
        return (0..<Int(count)).compactMap { list[$0].p_ndi_name.map { String(cString: $0) } }
    }
}

/// One NDI receiver on its own thread: video (BGRA, alpha kept), audio (float), connection state and
/// PTZ. The NDI receiver reconnects by itself when the source comes back (camera restarted, Wi‑Fi
/// change); this only reports the state. NDI recv calls are thread-safe, so PTZ / tally can be sent
/// from the main thread while the capture loop runs.
final class NDIReceiver: @unchecked Sendable {
    let instance: NDIlib_recv_instance_t
    private let store: FrameStore
    private let lock = NSLock()
    private var running = true
    private let done = DispatchSemaphore(value: 0)
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var audioFormat: AVAudioFormat?
    private var ptz = false
    /// The camera accepts PTZ over NDI (updated once a second by the capture loop).
    var ptzSupported: Bool { lock.lock(); defer { lock.unlock() }; return ptz }

    /// Decoded audio (any thread).
    var onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Connected / not (main thread), sent when it changes.
    var onConnected: (@Sendable (Bool) -> Void)?

    init?(name: String, store: FrameStore) {
        _ = NDIlib_initialize()
        var src = NDIlib_source_t()
        let cName = strdup(name)
        defer { free(cName) }
        src.p_ndi_name = UnsafePointer(cName)
        var create = NDIlib_recv_create_v3_t()
        create.source_to_connect_to = src
        create.color_format = NDIlib_recv_color_format_BGRX_BGRA
        create.bandwidth = NDIlib_recv_bandwidth_highest
        create.allow_video_fields = false
        guard let r = NDIlib_recv_create_v3(&create) else { return nil }
        instance = r
        self.store = store
    }

    func start() {
        let t = Thread { [self] in loop() }
        t.name = "ndi.recv"
        t.qualityOfService = .userInitiated
        t.start()
    }

    /// Stops the capture loop and destroys the receiver (waits for the loop to leave).
    func stop() {
        lock.lock(); let was = running; running = false; lock.unlock()
        if was { done.wait() }
        NDIlib_recv_destroy(instance)
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func loop() {
        var connected = false
        var lastCheck = CACurrentMediaTime() - 10
        while isRunning {
            var video = NDIlib_video_frame_v2_t()
            var audio = NDIlib_audio_frame_v2_t()
            switch NDIlib_recv_capture_v2(instance, &video, &audio, nil, 100) {
            case NDIlib_frame_type_video:
                if let pb = copy(video) { store.put(pb) }
                NDIlib_recv_free_video_v2(instance, &video)
            case NDIlib_frame_type_audio:
                if let pcm = pcm(audio) { onAudio?(pcm) }
                NDIlib_recv_free_audio_v2(instance, &audio)
            default:
                break
            }
            let now = CACurrentMediaTime()
            if now - lastCheck > 1 {
                lastCheck = now
                let c = NDIlib_recv_get_no_connections(instance) > 0
                let ptz = c && NDIlib_recv_ptz_is_supported(instance)
                lock.lock(); self.ptz = ptz; lock.unlock()
                if c != connected {
                    connected = c
                    let cb = onConnected
                    DispatchQueue.main.async { cb?(c) }
                }
            }
        }
        done.signal()
    }

    // MARK: Control

    func tally(program: Bool, preview: Bool) {
        var t = NDIlib_tally_t(on_program: program, on_preview: preview)
        _ = NDIlib_recv_set_tally(instance, &t)
    }

    /// Speeds -1…1 (0 = stop).
    func ptzMove(pan: Float, tilt: Float, zoom: Float) {
        _ = NDIlib_recv_ptz_pan_tilt_speed(instance, pan, tilt)
        _ = NDIlib_recv_ptz_zoom_speed(instance, zoom)
    }
    func ptzFocus(speed: Float) { _ = NDIlib_recv_ptz_focus_speed(instance, speed) }
    func ptzAutoFocus() { _ = NDIlib_recv_ptz_auto_focus(instance) }
    /// Presets 0…99.
    func ptzStore(_ n: Int32) { _ = NDIlib_recv_ptz_store_preset(instance, n) }
    func ptzRecall(_ n: Int32, speed: Float = 1) { _ = NDIlib_recv_ptz_recall_preset(instance, n, speed) }

    // MARK: Frames

    /// Copy into a pooled BGRA buffer (one pool per size; alpha kept for N-Title).
    private func copy(_ f: NDIlib_video_frame_v2_t) -> CVPixelBuffer? {
        let w = Int(f.xres), h = Int(f.yres)
        guard w > 0, h > 0, let src = f.p_data else { return nil }
        if pool == nil || poolSize != (w, h) {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                          kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attrs as CFDictionary, &p)
            pool = p; poolSize = (w, h)
        }
        var pb: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let dst = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(pb), srcStride = Int(f.line_stride_in_bytes)
        let row = min(dstStride, srcStride, w * 4)
        for y in 0..<h { memcpy(dst + y * dstStride, src + y * srcStride, row) }
        return pb
    }

    /// NDI audio (planar float) → AVAudioPCMBuffer (non-interleaved float, at most 2 channels).
    private func pcm(_ a: NDIlib_audio_frame_v2_t) -> AVAudioPCMBuffer? {
        let n = Int(a.no_samples), ch = min(Int(a.no_channels), 2)
        guard n > 0, ch > 0, a.sample_rate > 0, let src = a.p_data else { return nil }
        if audioFormat?.sampleRate != Double(a.sample_rate) || audioFormat?.channelCount != AVAudioChannelCount(ch) {
            audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(a.sample_rate),
                                        channels: AVAudioChannelCount(ch), interleaved: false)
        }
        guard let fmt = audioFormat, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)),
              let out = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        let stride = Int(a.channel_stride_in_bytes) / MemoryLayout<Float>.size
        for c in 0..<ch { memcpy(out[c], src + c * stride, n * MemoryLayout<Float>.size) }
        return buf
    }
}

@MainActor
final class NDIInputSource: VideoSource {
    let id = UUID()
    var name: String
    let kind: SourceKind = .camera
    let frames = FrameStore()
    private(set) var status: SourceStatus = .idle
    private var receiver: NDIReceiver?
    let ndiName: String
    /// Audio to the mixer (set by the engine before start()).
    var onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Status changed (main thread).
    var onStatus: (() -> Void)?

    init(ndiName: String) { self.ndiName = ndiName; self.name = ndiName }

    func start() async {
        guard receiver == nil else { return }
        guard let r = NDIReceiver(name: ndiName, store: frames) else {
            status = .error(L("Không tạo được bộ nhận NDI")); onStatus?(); return
        }
        r.onAudio = onAudio
        r.onConnected = { [weak self] c in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.status = c ? .live : .connecting
                self.onStatus?()
            }
        }
        receiver = r
        status = .connecting
        onStatus?()
        r.start()
    }

    func stop() async {
        if let r = receiver {
            receiver = nil
            await Task.detached { r.stop() }.value
        }
        frames.clear(); status = .idle
        onStatus?()
    }

    /// Program/preview tally back to the NDI camera.
    func setTally(program: Bool, preview: Bool) { receiver?.tally(program: program, preview: preview) }

    /// The camera accepts PTZ over NDI (checked once a second while connected).
    var ptzSupported: Bool { receiver?.ptzSupported ?? false }
    func ptz(pan: Float, tilt: Float, zoom: Float) { receiver?.ptzMove(pan: pan, tilt: tilt, zoom: zoom) }
    func ptzFocus(speed: Float) { receiver?.ptzFocus(speed: speed) }
    func ptzAutoFocus() { receiver?.ptzAutoFocus() }
    func ptzRecall(_ preset: Int32) { receiver?.ptzRecall(preset) }
    func ptzStore(_ preset: Int32) { receiver?.ptzStore(preset) }
}

/// Sends Program as an NDI source. Program frames are NV12 (420v); NDI wants the UV plane right after
/// the Y plane, so each frame is packed into one contiguous buffer. Runs on its own queue and drops
/// frames while the previous one is still being sent (never stalls the render loop).
final class NDISender: @unchecked Sendable {
    private var sender: NDIlib_send_instance_t?
    private let queue = DispatchQueue(label: "ndi.send", qos: .userInitiated)
    private var busy = false
    private let lock = NSLock()
    private var packed = [UInt8]()

    init(name: String) {
        _ = NDIlib_initialize()
        let cName = strdup(name)
        var create = NDIlib_send_create_t(p_ndi_name: UnsafePointer(cName), p_groups: nil, clock_video: false, clock_audio: false)
        sender = NDIlib_send_create(&create)
        free(cName)
    }

    deinit { if let sender { NDIlib_send_destroy(sender) } }

    private let audioQueue = DispatchQueue(label: "ndi.send.audio", qos: .userInitiated)
    private var audioData = [Float]()

    /// Program audio as planar float (copied, sent on its own queue).
    func sendAudio(_ pcm: AVAudioPCMBuffer) {
        let n = Int(pcm.frameLength), ch = Int(pcm.format.channelCount)
        guard n > 0, ch > 0, let src = pcm.floatChannelData else { return }
        var planar = [Float](repeating: 0, count: n * ch)
        if pcm.format.isInterleaved {
            let p = src[0]
            for i in 0..<n { for c in 0..<ch { planar[c * n + i] = p[i * ch + c] } }
        } else {
            for c in 0..<ch { planar.withUnsafeMutableBufferPointer { _ = memcpy($0.baseAddress! + c * n, src[c], n * 4) } }
        }
        let rate = Int32(pcm.format.sampleRate)
        audioQueue.async { [self] in
            guard let sender else { return }
            audioData = planar
            audioData.withUnsafeMutableBufferPointer { b in
                var f = NDIlib_audio_frame_v2_t()
                f.sample_rate = rate
                f.no_channels = Int32(ch)
                f.no_samples = Int32(n)
                f.timecode = NDIlib_send_timecode_synthesize
                f.p_data = b.baseAddress
                f.channel_stride_in_bytes = Int32(n * MemoryLayout<Float>.size)
                NDIlib_send_send_audio_v2(sender, &f)
            }
        }
    }

    func send(_ pb: CVPixelBuffer, fps: Int) {
        lock.lock(); if busy { lock.unlock(); return }; busy = true; lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); busy = false; lock.unlock() }
            guard let sender else { return }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            var f = NDIlib_video_frame_v2_t()
            f.xres = Int32(w); f.yres = Int32(h)
            f.frame_rate_N = Int32(fps * 1000); f.frame_rate_D = 1000
            f.picture_aspect_ratio = Float(w) / Float(h)
            f.frame_format_type = NDIlib_frame_format_type_progressive
            f.timecode = NDIlib_send_timecode_synthesize
            let fmt = CVPixelBufferGetPixelFormatType(pb)
            if fmt == kCVPixelFormatType_32BGRA {
                f.FourCC = NDIlib_FourCC_video_type_BGRA
                f.p_data = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self)
                f.line_stride_in_bytes = Int32(CVPixelBufferGetBytesPerRow(pb))
                NDIlib_send_send_video_v2(sender, &f)
                return
            }
            guard CVPixelBufferGetPlaneCount(pb) == 2,
                  let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return }
            let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let need = w * h + w * (h / 2)
            if packed.count != need { packed = [UInt8](repeating: 0, count: need) }
            packed.withUnsafeMutableBytes { dst in
                let d = dst.baseAddress!
                for r in 0..<h { memcpy(d + r * w, y + r * ys, w) }
                for r in 0..<(h / 2) { memcpy(d + w * h + r * w, uv + r * uvs, w) }
                f.FourCC = NDIlib_FourCC_video_type_NV12
                f.p_data = d.assumingMemoryBound(to: UInt8.self)
                f.line_stride_in_bytes = Int32(w)
                NDIlib_send_send_video_v2(sender, &f)
            }
        }
    }
}

struct UnsafeSendable<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
#endif

import CoreVideo
import Foundation
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

@MainActor
final class NDIInputSource: VideoSource {
    let id = UUID()
    var name: String
    let kind: SourceKind = .camera
    let frames = FrameStore()
    private(set) var status: SourceStatus = .idle
    private var receiver: NDIlib_recv_instance_t?
    private var task: Task<Void, Never>?
    private let ndiName: String

    init(ndiName: String) { self.ndiName = ndiName; self.name = ndiName }

    func start() async {
        var src = NDIlib_source_t()
        let cName = strdup(ndiName)
        src.p_ndi_name = UnsafePointer(cName)
        var create = NDIlib_recv_create_v3_t()
        create.source_to_connect_to = src
        create.color_format = NDIlib_recv_color_format_BGRX_BGRA
        create.bandwidth = NDIlib_recv_bandwidth_highest
        create.allow_video_fields = false
        receiver = NDIlib_recv_create_v3(&create)
        free(cName)
        guard let receiver else { status = .error("NDI recv"); return }
        status = .live
        let store = frames
        let r = UnsafeSendable(receiver)
        task = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                var video = NDIlib_video_frame_v2_t()
                if NDIlib_recv_capture_v3(r.value, &video, nil, nil, 100) == NDIlib_frame_type_video {
                    if let pb = Self.copy(video) { store.put(pb) }
                    NDIlib_recv_free_video_v2(r.value, &video)
                }
            }
        }
    }

    func stop() async {
        task?.cancel(); task = nil
        if let receiver { NDIlib_recv_destroy(receiver) }
        receiver = nil
        frames.clear(); status = .idle
    }

    /// Program/preview tally back to the NDI camera.
    func setTally(program: Bool, preview: Bool) {
        guard let receiver else { return }
        var t = NDIlib_tally_t(on_program: program, on_preview: preview)
        _ = NDIlib_recv_set_tally(receiver, &t)
    }

    func ptz(pan: Float, tilt: Float, zoom: Float) {
        guard let receiver, NDIlib_recv_ptz_is_supported(receiver) else { return }
        _ = NDIlib_recv_ptz_pan_tilt_speed(receiver, pan, tilt)
        _ = NDIlib_recv_ptz_zoom_speed(receiver, zoom)
    }

    func ptzRecall(_ preset: Int32) {
        guard let receiver else { return }
        _ = NDIlib_recv_ptz_recall_preset(receiver, preset, 1.0)
    }

    nonisolated private static func copy(_ f: NDIlib_video_frame_v2_t) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(f.xres), Int(f.yres), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb, let src = f.p_data else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let dst = CVPixelBufferGetBaseAddress(pb)!
        let dstStride = CVPixelBufferGetBytesPerRow(pb), srcStride = Int(f.line_stride_in_bytes)
        for y in 0..<Int(f.yres) { memcpy(dst + y * dstStride, src + y * srcStride, min(dstStride, srcStride)) }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
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

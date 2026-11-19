import AVFoundation
import Foundation

/// Built-in or external (UVC, iPadOS 17+) camera.
/// Note: iOS allows only one running AVCaptureSession for built-in cameras at a time
/// (AVCaptureMultiCamSession is needed for more). External UVC devices can each run
/// their own session alongside one built-in camera.
@MainActor
final class CameraSource: NSObject, VideoSource {
    let id = UUID()
    var name: String
    let kind: SourceKind = .camera
    let frames = FrameStore()
    private(set) var status: SourceStatus = .idle

    let deviceID: String
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.capture", qos: .userInteractive)
    private lazy var delegate = Delegate(store: frames)
    /// Keeps the picture upright for any interface orientation (the sensor delivers landscape-right
    /// buffers, so holding the iPad the other way round gave a 180° rotated image).
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    /// USB-C (UVC) camera / capture card, iPadOS 17+.
    let isExternal: Bool
    private var plugObservers: [NSObjectProtocol] = []

    init(device: AVCaptureDevice) {
        self.deviceID = device.uniqueID
        self.name = device.localizedName
        self.isExternal = Self.isExternal(device)
    }

    /// A saved camera whose device is not connected (only a USB-C camera can be missing).
    init(deviceID: String, name: String) {
        self.deviceID = deviceID
        self.name = name
        self.isExternal = true
    }

    static func isExternal(_ d: AVCaptureDevice) -> Bool {
        if #available(iOS 17.0, *) { return d.deviceType == .external }
        return false
    }

    static func availableDevices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera]
        if #available(iOS 17.0, *) { types.append(.external) }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { status = .error(L("Chưa cho phép dùng camera")); return }
        watchPlug()
        guard let device = AVCaptureDevice(uniqueID: deviceID),
              let input = try? AVCaptureDeviceInput(device: device) else {
            // a USB-C camera that isn't plugged in yet starts by itself when it is
            status = .error(isExternal ? L("Chưa cắm camera USB-C") : L("Không mở được camera")); return
        }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if isExternal {
            // UVC cameras / capture cards don't take the 1080p preset: pick their best format up to 1080p30
            session.sessionPreset = .inputPriority
        } else {
            session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        }
        if session.canAddInput(input) { session.addInput(input) }
        if isExternal { Self.chooseFormat(device) }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        // Never mirror: a broadcast picture must read correctly (text, logos). Mirroring combined with the
        // rotation angle flipped the front camera upside down. Use "Lật gương" in Màu & PTZ if wanted.
        if let c = output.connection(with: .video), c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
        }
        session.commitConfiguration()
        if !isExternal { startRotationTracking(device) }   // a USB-C camera doesn't turn with the iPad
        let s = session
        queue.async { if !s.isRunning { s.startRunning() } }
        refreshControls()
        status = .live
    }

    /// Largest format up to 1920×1080 (preferring 16:9 and ≥ 30 fps), frame rate 30 when it can.
    private static func chooseFormat(_ d: AVCaptureDevice) {
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions { CMVideoFormatDescriptionGetDimensions(f.formatDescription) }
        let ok = d.formats.filter { f in
            let s = dims(f)
            return s.width <= 1920 && s.height <= 1080 && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29 }
        }
        let best = ok.max { a, b in
            let x = dims(a), y = dims(b)
            let wa = abs(Double(x.width) / Double(max(x.height, 1)) - 16.0 / 9) < 0.05, wb = abs(Double(y.width) / Double(max(y.height, 1)) - 16.0 / 9) < 0.05
            if wa != wb { return !wa }
            return Int(x.width) * Int(x.height) < Int(y.width) * Int(y.height)
        }
        guard let f = best ?? d.formats.last, (try? d.lockForConfiguration()) != nil else { return }
        d.activeFormat = f
        if f.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
            d.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            d.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        }
        d.unlockForConfiguration()
    }

    /// Unplugging a USB-C camera shows it as disconnected; plugging it back in restarts it.
    private func watchPlug() {
        guard plugObservers.isEmpty else { return }
        let nc = NotificationCenter.default, id = deviceID
        plugObservers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] n in
            guard (n.object as? AVCaptureDevice)?.uniqueID == id else { return }
            MainActor.assumeIsolated { self?.status = .error(L("Đã rút camera")) }
        })
        plugObservers.append(nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] n in
            guard (n.object as? AVCaptureDevice)?.uniqueID == id else { return }
            MainActor.assumeIsolated { Task { await self?.start() } }
        })
    }

    // MARK: Camera control (zoom, focus, exposure, white balance, torch)

    struct Controls: Equatable {
        var zoom: Double = 1
        var maxZoom: Double = 1
        var autoFocus = true
        var lensPosition: Float = 0.5
        var exposureBias: Float = 0
        var minBias: Float = -2, maxBias: Float = 2
        var whiteBalanceLocked = false
        var torch = false
        var hasTorch = false
        var stabilization = true
    }

    private(set) var controls = Controls()

    private var device: AVCaptureDevice? { AVCaptureDevice(uniqueID: deviceID) }

    private func configure(_ body: (AVCaptureDevice) throws -> Void) {
        guard let d = device else { return }
        do { try d.lockForConfiguration(); try body(d); d.unlockForConfiguration() } catch {}
    }

    func refreshControls() {
        guard let d = device else { return }
        controls.maxZoom = min(Double(d.activeFormat.videoMaxZoomFactor), 10)
        controls.zoom = Double(d.videoZoomFactor)
        controls.minBias = d.minExposureTargetBias; controls.maxBias = d.maxExposureTargetBias
        controls.exposureBias = d.exposureTargetBias
        controls.hasTorch = d.hasTorch
        controls.torch = d.torchMode == .on
        controls.autoFocus = d.focusMode == .continuousAutoFocus
        controls.lensPosition = d.lensPosition
        controls.whiteBalanceLocked = d.whiteBalanceMode == .locked
    }

    func setZoom(_ z: Double) {
        configure { $0.videoZoomFactor = CGFloat(min(max(1, z), Double($0.activeFormat.videoMaxZoomFactor))) }
        controls.zoom = z
    }

    func setAutoFocus(_ on: Bool) {
        configure { d in
            if on, d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            else if !on, d.isLockingFocusWithCustomLensPositionSupported { d.setFocusModeLocked(lensPosition: d.lensPosition) }
        }
        controls.autoFocus = on
    }

    func setLensPosition(_ p: Float) {
        configure { d in if d.isLockingFocusWithCustomLensPositionSupported { d.setFocusModeLocked(lensPosition: max(0, min(1, p))) } }
        controls.lensPosition = p; controls.autoFocus = false
    }

    func setExposureBias(_ b: Float) {
        configure { d in d.setExposureTargetBias(max(d.minExposureTargetBias, min(d.maxExposureTargetBias, b))) }
        controls.exposureBias = b
    }

    func setWhiteBalanceLocked(_ locked: Bool) {
        configure { d in
            if locked, d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked }
            else if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
        }
        controls.whiteBalanceLocked = locked
    }

    func setTorch(_ on: Bool) {
        configure { d in if d.hasTorch { d.torchMode = on ? .on : .off } }
        controls.torch = on
    }

    func setStabilization(_ on: Bool) {
        for c in output.connections where c.isVideoStabilizationSupported {
            c.preferredVideoStabilizationMode = on ? .standard : .off
        }
        controls.stabilization = on
    }

    private func startRotationTracking(_ device: AVCaptureDevice) {
        let rc = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotation = rc
        apply(angle: rc.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = rc.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] rc, _ in
            let a = rc.videoRotationAngleForHorizonLevelCapture
            DispatchQueue.main.async { self?.apply(angle: a) }
        }
    }

    private func apply(angle: CGFloat) {
        guard let c = output.connection(with: .video), c.isVideoRotationAngleSupported(angle) else { return }
        let s = session
        queue.async {
            s.beginConfiguration()
            c.videoRotationAngle = angle
            s.commitConfiguration()
        }
    }

    func stop() async {
        plugObservers.forEach { NotificationCenter.default.removeObserver($0) }; plugObservers = []
        rotationObservation?.invalidate(); rotationObservation = nil; rotation = nil
        let s = session
        queue.async { s.stopRunning() }
        frames.clear()
        status = .idle
    }

    private final class Delegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let store: FrameStore
        init(store: FrameStore) { self.store = store }
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            if let pb = sampleBuffer.imageBuffer { store.put(pb) }
        }
    }
}

/// Cameras the iPad can use right now, refreshed when a USB-C camera is plugged in or out.
@MainActor
final class CameraDeviceList: ObservableObject {
    @Published private(set) var devices: [AVCaptureDevice] = CameraSource.availableDevices()
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.devices = CameraSource.availableDevices() }
            })
        }
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}

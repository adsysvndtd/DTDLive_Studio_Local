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

    init(device: AVCaptureDevice) {
        self.deviceID = device.uniqueID
        self.name = device.localizedName
    }

    static func availableDevices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera]
        if #available(iOS 17.0, *) { types.append(.external) }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video),
              let device = AVCaptureDevice(uniqueID: deviceID),
              let input = try? AVCaptureDeviceInput(device: device) else {
            status = .error("camera unavailable"); return
        }
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        if session.canAddInput(input) { session.addInput(input) }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        let s = session
        queue.async { s.startRunning() }
        refreshControls()
        status = .live
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

    func stop() async {
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

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
        status = .live
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

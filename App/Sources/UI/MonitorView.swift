import CoreImage
import MetalKit
import SwiftUI

/// Draws the latest frame of a FrameStore.
/// Device: Metal (MTKView, display-rate). Simulator: CPU path that renders off the main thread
/// and only hands a CGImage to the layer — the Simulator's emulated GPU (especially on CI VMs)
/// can block `currentDrawable` for ~1 s per view, which froze the main thread.
struct MonitorView: UIViewRepresentable {
    let store: FrameStore
    var maxFPS = 30

    /// Low Power Mode on: monitors redraw at most 15 times a second (the program itself is not affected).
    static func fps(_ maxFPS: Int) -> Int {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? min(maxFPS, 15) : maxFPS
    }

    #if targetEnvironment(simulator)
    func makeUIView(context: Context) -> LayerMonitorView { LayerMonitorView(store: store, fps: min(maxFPS, DemoMode.isUITest ? 2 : 10)) }
    func updateUIView(_ v: LayerMonitorView, context: Context) { v.store = store }
    static func dismantleUIView(_ v: LayerMonitorView, coordinator: ()) { v.detachMonitor() }
    #else
    func makeUIView(context: Context) -> MonitorMTKView {
        let v = MonitorMTKView(store: store)
        v.preferredFramesPerSecond = Self.fps(maxFPS)
        return v
    }

    func updateUIView(_ v: MonitorMTKView, context: Context) {
        v.store = store
        v.preferredFramesPerSecond = Self.fps(maxFPS)
    }
    static func dismantleUIView(_ v: MonitorMTKView, coordinator: ()) { v.detachMonitor() }
    #endif
}

/// Simulator monitor: CGImage rendered on a utility queue, assigned to layer.contents on main.
final class LayerMonitorView: UIView {
    var store: FrameStore {
        didSet {
            guard oldValue !== store else { return }
            oldValue.setMonitorTarget(nil, for: monitorID)
            updateMonitorTarget()
        }
    }
    private let monitorID = UUID()
    func detachMonitor() { store.setMonitorTarget(nil, for: monitorID) }
    private static let ci = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    private static let queue = DispatchQueue(label: "monitor.sim", qos: .userInteractive)
    private var timer: Timer?
    private var busy = false

    init(store: FrameStore, fps: Int) {
        self.store = store
        super.init(frame: .zero)
        backgroundColor = .black
        layer.contentsGravity = .resizeAspect
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(max(fps, 1)), repeats: true) { [weak self] _ in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate(); detachMonitor() }

    override func didMoveToWindow() { super.didMoveToWindow(); updateMonitorTarget() }
    override func layoutSubviews() { super.layoutSubviews(); updateMonitorTarget() }
    private func updateMonitorTarget() {
        guard let window, bounds.width > 0, bounds.height > 0 else { detachMonitor(); return }
        contentScaleFactor = window.screen.scale
        store.setMonitorTarget(CGSize(width: bounds.width * contentScaleFactor, height: bounds.height * contentScaleFactor), for: monitorID)
    }

    private func refresh() {
        guard !busy, window != nil, let pb = store.latest() else { return }
        busy = true
        let sourceSize = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        let target = CGSize(width: bounds.width * contentScaleFactor, height: bounds.height * contentScaleFactor)
        guard let size = MonitorRendering.renderSize(maximum: sourceSize, targets: [target]) else { busy = false; return }
        Self.queue.async { [weak self] in
            let img = MonitorRendering.aspectFit(CIImage(cvPixelBuffer: pb), in: size)
            let cg = Self.ci.createCGImage(img, from: img.extent)
            DispatchQueue.main.async {
                self?.layer.contents = cg
                self?.busy = false
            }
        }
    }
}

final class MonitorMTKView: MTKView {
    var store: FrameStore {
        didSet {
            guard oldValue !== store else { return }
            oldValue.setMonitorTarget(nil, for: monitorID)
            updateMonitorTarget()
        }
    }
    private let monitorID = UUID()
    func detachMonitor() { store.setMonitorTarget(nil, for: monitorID) }
    /// One Metal device / Core Image context / command queue for every monitor on screen. Each monitor used
    /// to create its own context (with its own caches and GPU memory) — a full multiview held a dozen.
    private static let device = MTLCreateSystemDefaultDevice()!
    private static let sharedCI = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    private static let sharedQueue = device.makeCommandQueue()!
    private var ci: CIContext { Self.sharedCI }
    private var queue: MTLCommandQueue { Self.sharedQueue }

    init(store: FrameStore) {
        self.store = store
        super.init(frame: .zero, device: Self.device)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        autoResizeDrawable = false
        // iOS may drop the layer's contents in the background: draw again when the app is back.
        foreground = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.drawn = nil
        }
    }
    private var foreground: NSObjectProtocol?
    deinit { foreground.map { NotificationCenter.default.removeObserver($0) }; detachMonitor() }

    override func didMoveToWindow() { super.didMoveToWindow(); updateMonitorTarget() }
    override func layoutSubviews() { super.layoutSubviews(); updateMonitorTarget() }
    private func updateMonitorTarget() {
        guard let window, bounds.width > 0, bounds.height > 0 else { detachMonitor(); return }
        contentScaleFactor = window.screen.scale
        let pixels = CGSize(width: (bounds.width * contentScaleFactor).rounded(.up),
                            height: (bounds.height * contentScaleFactor).rounded(.up))
        if drawableSize != pixels { drawableSize = pixels }
        store.setMonitorTarget(pixels, for: monitorID)
    }

    required init(coder: NSCoder) { fatalError() }

    /// What was drawn last: which store, its frame counter (nil = no signal) and the drawable size.
    private var drawn: (store: ObjectIdentifier, seq: UInt64?, size: CGSize)?

    override func draw(_ rect: CGRect) {
        // Battery: skip the GPU work when nothing changed (same store, same frame number, same size).
        // Compared by the store's frame counter, not the buffer object: pools recycle buffer objects.
        let frame = store.latestFrame()
        let now = (store: ObjectIdentifier(store), seq: frame?.seq, size: drawableSize)
        if let d = drawn, d.store == now.store, d.seq == now.seq, d.size == now.size { return }
        let pb = frame?.buffer
        // No drawable (app in the background, view off screen): leave `drawn` alone so the next pass draws.
        guard let drawable = currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        drawn = now
        let size = drawableSize
        let bounds = CGRect(origin: .zero, size: size)
        var img = CIImage(color: .black).cropped(to: bounds)
        if let pb {
            img = MonitorRendering.aspectFit(CIImage(cvPixelBuffer: pb), in: size)
        }
        ci.render(img, to: drawable.texture, commandBuffer: cb, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        cb.present(drawable)
        cb.commit()
    }
}

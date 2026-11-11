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

    #if targetEnvironment(simulator)
    func makeUIView(context: Context) -> LayerMonitorView { LayerMonitorView(store: store, fps: min(maxFPS, DemoMode.isUITest ? 2 : 10)) }
    func updateUIView(_ v: LayerMonitorView, context: Context) { v.store = store }
    #else
    func makeUIView(context: Context) -> MonitorMTKView {
        let v = MonitorMTKView(store: store)
        v.preferredFramesPerSecond = maxFPS
        return v
    }

    func updateUIView(_ v: MonitorMTKView, context: Context) {
        v.store = store
        v.preferredFramesPerSecond = maxFPS
    }
    #endif
}

/// Simulator monitor: CGImage rendered on a utility queue, assigned to layer.contents on main.
final class LayerMonitorView: UIView {
    var store: FrameStore
    private static let ci = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    private static let queue = DispatchQueue(label: "monitor.sim", qos: .utility)
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
    deinit { timer?.invalidate() }

    private func refresh() {
        guard !busy, window != nil, let pb = store.latest() else { return }
        busy = true
        let maxW = max(bounds.width * 2, 320)
        Self.queue.async { [weak self] in
            var img = CIImage(cvPixelBuffer: pb)
            let s = min(1, maxW / img.extent.width)
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let cg = Self.ci.createCGImage(img, from: img.extent)
            DispatchQueue.main.async {
                self?.layer.contents = cg
                self?.busy = false
            }
        }
    }
}

final class MonitorMTKView: MTKView {
    var store: FrameStore
    private let ci: CIContext
    private let queue: MTLCommandQueue

    init(store: FrameStore) {
        self.store = store
        let dev = MTLCreateSystemDefaultDevice()!
        ci = CIContext(mtlDevice: dev, options: [.cacheIntermediates: false])
        queue = dev.makeCommandQueue()!
        super.init(frame: .zero, device: dev)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        autoResizeDrawable = true
    }

    required init(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let drawable = currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        let size = drawableSize
        let bounds = CGRect(origin: .zero, size: size)
        var img = CIImage(color: .black).cropped(to: bounds)
        if let pb = store.latest() {
            let src = CIImage(cvPixelBuffer: pb)
            let s = min(size.width / src.extent.width, size.height / src.extent.height)
            let scaled = src.transformed(by: .init(scaleX: s, y: s))
            img = scaled.transformed(by: .init(translationX: (size.width - scaled.extent.width) / 2,
                                               y: (size.height - scaled.extent.height) / 2))
                .composited(over: img)
        }
        ci.render(img, to: drawable.texture, commandBuffer: cb, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        cb.present(drawable)
        cb.commit()
    }
}

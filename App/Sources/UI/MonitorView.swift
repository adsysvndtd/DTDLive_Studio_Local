import CoreImage
import MetalKit
import SwiftUI

/// Draws the latest frame of a FrameStore with Metal at display rate.
struct MonitorView: UIViewRepresentable {
    let store: FrameStore
    var maxFPS = 30

    func makeUIView(context: Context) -> MonitorMTKView {
        let v = MonitorMTKView(store: store)
        v.preferredFramesPerSecond = maxFPS
        return v
    }

    func updateUIView(_ v: MonitorMTKView, context: Context) {
        v.store = store
        v.preferredFramesPerSecond = maxFPS
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

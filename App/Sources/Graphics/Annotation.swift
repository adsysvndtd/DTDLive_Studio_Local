import CoreImage
import PencilKit
import SwiftUI

/// Live telestration: draw with Apple Pencil (or finger on iPhone) over the program monitor;
/// strokes are burned into the program output in real time.
final class AnnotationLayer: @unchecked Sendable {
    private var image: CIImage?
    private let lock = NSLock()

    func update(_ drawing: PKDrawing, canvasBounds: CGRect, programSize: CGSize) {
        let scale = programSize.width / max(canvasBounds.width, 1)
        let ui = drawing.image(from: canvasBounds, scale: scale)
        let ci = ui.cgImage.map { CIImage(cgImage: $0) }
            .map { $0.transformed(by: CGAffineTransform(scaleX: programSize.width / $0.extent.width,
                                                        y: programSize.height / $0.extent.height)) }
        lock.lock(); image = drawing.strokes.isEmpty ? nil : ci; lock.unlock()
    }

    func clear() { lock.lock(); image = nil; lock.unlock() }

    var current: CIImage? { lock.lock(); defer { lock.unlock() }; return image }
}

struct AnnotationCanvas: UIViewRepresentable {
    let layer: AnnotationLayer
    let programSize: CGSize
    @Binding var clearToken: Int
    var tool: PKTool = PKInkingTool(.marker, color: .systemYellow, width: 8)

    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.drawingPolicy = .anyInput
        v.tool = tool
        v.delegate = context.coordinator
        return v
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        v.tool = tool
        if context.coordinator.lastClear != clearToken {
            context.coordinator.lastClear = clearToken
            v.drawing = PKDrawing()
            layer.clear()
        }
        context.coordinator.programSize = programSize
    }

    func makeCoordinator() -> Coordinator { Coordinator(layer: layer, programSize: programSize) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let layer: AnnotationLayer
        var programSize: CGSize
        var lastClear = 0
        init(layer: AnnotationLayer, programSize: CGSize) { self.layer = layer; self.programSize = programSize }
        func canvasViewDrawingDidChange(_ v: PKCanvasView) {
            layer.update(v.drawing, canvasBounds: v.bounds, programSize: programSize)
        }
    }
}

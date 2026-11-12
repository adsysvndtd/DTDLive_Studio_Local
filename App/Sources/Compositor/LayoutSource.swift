import CoreImage
import CoreVideo
import Foundation
import os

/// Multi-source picture-in-picture layouts (2-up, 3-up, main + side, quad strip, perspective…).
/// A layout renders into its own FrameStore, so it is an input like any camera: put it on
/// preview, then CUT / AUTO / T-bar it to program ("PiP TRANS").
struct LayoutTemplate: Identifiable, Equatable {
    struct Slot: Equatable {
        var rect: CGRect           // normalised, origin top-left
        var perspective = false    // slight 3D tilt (template 9)
    }
    let id: Int
    let name: String
    let slots: [Slot]
    var background = CIColor(red: 0.04, green: 0.05, blue: 0.07)

    static let all: [LayoutTemplate] = {
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Slot { Slot(rect: CGRect(x: x, y: y, width: w, height: h)) }
        let g: CGFloat = 0.012
        return [
            LayoutTemplate(id: 1, name: "Một khung giữa", slots: [r(0.1, 0.1, 0.8, 0.8)]),
            LayoutTemplate(id: 2, name: "Hai khung ngang", slots: [r(g, 0.25, 0.5 - 1.5 * g, 0.5), r(0.5 + g / 2, 0.25, 0.5 - 1.5 * g, 0.5)]),
            LayoutTemplate(id: 3, name: "Ba khung ngang", slots: (0..<3).map { i in r(g + CGFloat(i) * (1 - g) / 3, 0.3, (1 - g) / 3 - g, 0.4) }),
            LayoutTemplate(id: 4, name: "Chính + phụ phải", slots: [r(g, 0.15, 0.64, 0.7), r(0.66, 0.15, 0.33, 0.7)]),
            LayoutTemplate(id: 5, name: "Chính + 2 phụ xếp dọc", slots: [r(g, 0.15, 0.64, 0.7), r(0.66, 0.15, 0.33, 0.345), r(0.66, 0.505, 0.33, 0.345)]),
            LayoutTemplate(id: 6, name: "Chính + 2 phụ hàng ngang", slots: [r(g, 0.2, 0.6, 0.6), r(0.62, 0.2, 0.18, 0.6), r(0.81, 0.2, 0.18, 0.6)]),
            LayoutTemplate(id: 7, name: "Chính + 3 phụ xếp dọc", slots: [r(g, 0.08, 0.66, 0.84), r(0.68, 0.08, 0.31, 0.27), r(0.68, 0.365, 0.31, 0.27), r(0.68, 0.65, 0.31, 0.27)]),
            LayoutTemplate(id: 8, name: "Bốn khung ngang", slots: (0..<4).map { i in r(CGFloat(i) * 0.25 + g / 2, 0.15, 0.25 - g, 0.7) }),
            LayoutTemplate(id: 9, name: "Khung phối cảnh", slots: [Slot(rect: CGRect(x: 0.2, y: 0.12, width: 0.6, height: 0.76), perspective: true)]),
            LayoutTemplate(id: 10, name: "Lưới 2×2", slots: [r(g, g, 0.5 - 1.5 * g, 0.5 - 1.5 * g), r(0.5 + g / 2, g, 0.5 - 1.5 * g, 0.5 - 1.5 * g),
                                                            r(g, 0.5 + g / 2, 0.5 - 1.5 * g, 0.5 - 1.5 * g), r(0.5 + g / 2, 0.5 + g / 2, 0.5 - 1.5 * g, 0.5 - 1.5 * g)])
        ]
    }()
}

@MainActor
final class LayoutSource: VideoSource {
    let id = UUID()
    var name = "BỐ CỤC"
    let kind: SourceKind = .file
    let frames = FrameStore()
    private(set) var status: SourceStatus = .idle

    private let renderer = LayoutRenderer()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "layout.render", qos: .userInteractive)

    func configure(template: LayoutTemplate, inputs: [FrameStore?], size: CGSize, background: FrameStore?,
                   still: CIImage? = nil, color: CIColor? = nil) {
        renderer.update(template: template, inputs: inputs, size: size, background: background, still: still, color: color)
        name = "BỐ CỤC \(template.id)"
    }

    func start() async {
        status = .live
        let r = renderer, store = frames
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 30)
        t.setEventHandler { if let pb = r.render() { store.put(pb) } }
        t.resume()
        timer = t
    }

    func stop() async { timer?.cancel(); timer = nil; frames.clear(); status = .idle }
}

final class LayoutRenderer: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var template = LayoutTemplate.all[1]
    private var inputs: [FrameStore?] = []
    private var background: FrameStore?
    private var still: CIImage?          // background picture behind the windows
    private var color: CIColor?          // background colour (overrides the template's)
    private var size = CGSize(width: 1920, height: 1080)
    private var pool: CVPixelBufferPool?
    private let ci = CIContext(options: [.cacheIntermediates: false])

    func update(template: LayoutTemplate, inputs: [FrameStore?], size: CGSize, background: FrameStore?,
                still: CIImage? = nil, color: CIColor? = nil) {
        os_unfair_lock_lock(&lock)
        if size != self.size { pool = nil }
        self.template = template; self.inputs = inputs; self.size = size; self.background = background
        self.still = still; self.color = color
        os_unfair_lock_unlock(&lock)
    }

    func render() -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        let t = template, ins = inputs, bg = background, sz = size, stillImg = still, bgColor = color
        if pool == nil {
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferWidthKey as String: Int(sz.width), kCVPixelBufferHeightKey as String: Int(sz.height),
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        let p = pool
        os_unfair_lock_unlock(&lock)
        guard let p else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, p, &pb)
        guard let pb else { return nil }

        let extent = CGRect(origin: .zero, size: sz)
        var out: CIImage
        if let img = stillImg {
            // picture fills the frame (aspect fill, centred), so uncovered areas never show bare colour
            let k = max(sz.width / img.extent.width, sz.height / img.extent.height)
            let scaled = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: k, y: k))
            out = scaled.transformed(by: CGAffineTransform(translationX: (sz.width - scaled.extent.width) / 2,
                                                            y: (sz.height - scaled.extent.height) / 2))
                .cropped(to: extent)
        } else if let b = bg?.latest() {
            let img = CIImage(cvPixelBuffer: b)
            out = img.transformed(by: CGAffineTransform(scaleX: sz.width / img.extent.width, y: sz.height / img.extent.height))
                .applyingGaussianBlur(sigma: 12).cropped(to: extent)
        } else {
            out = CIImage(color: bgColor ?? t.background).cropped(to: extent)
        }
        for (i, slot) in t.slots.enumerated() {
            let r = CGRect(x: slot.rect.minX * sz.width, y: (1 - slot.rect.maxY) * sz.height,
                           width: slot.rect.width * sz.width, height: slot.rect.height * sz.height)
            var tile: CIImage
            if i < ins.count, let buf = ins[i]?.latest() {
                let img = CIImage(cvPixelBuffer: buf)
                // Aspect fill into the slot, centre-cropped.
                let s = max(r.width / img.extent.width, r.height / img.extent.height)
                let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
                tile = scaled.transformed(by: CGAffineTransform(translationX: r.midX - scaled.extent.midX, y: r.midY - scaled.extent.midY)).cropped(to: r)
            } else {
                tile = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.14)).cropped(to: r)
            }
            if slot.perspective {
                let f = CIFilter(name: "CIPerspectiveTransform")!
                f.setValue(tile, forKey: kCIInputImageKey)
                f.setValue(CIVector(cgPoint: CGPoint(x: r.minX, y: r.maxY)), forKey: "inputTopLeft")
                f.setValue(CIVector(cgPoint: CGPoint(x: r.maxX, y: r.maxY - r.height * 0.08)), forKey: "inputTopRight")
                f.setValue(CIVector(cgPoint: CGPoint(x: r.maxX, y: r.minY + r.height * 0.08)), forKey: "inputBottomRight")
                f.setValue(CIVector(cgPoint: CGPoint(x: r.minX, y: r.minY)), forKey: "inputBottomLeft")
                tile = f.outputImage ?? tile
            }
            // Thin frame around each window.
            let border = CIImage(color: CIColor(red: 0.98, green: 0.45, blue: 0.13, alpha: 0.9)).cropped(to: r.insetBy(dx: -3, dy: -3))
            out = tile.composited(over: slot.perspective ? out : border.composited(over: out))
        }
        ci.render(out.cropped(to: extent), to: pb)
        return pb
    }
}

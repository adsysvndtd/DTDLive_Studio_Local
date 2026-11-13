import CoreImage
import CoreVideo
import Foundation
import os
import UIKit

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

    /// Computed so names follow a live language switch.
    static var all: [LayoutTemplate] {
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Slot { Slot(rect: CGRect(x: x, y: y, width: w, height: h)) }
        let g: CGFloat = 0.012
        return [
            LayoutTemplate(id: 1, name: L("Một khung giữa"), slots: [r(0.1, 0.1, 0.8, 0.8)]),
            LayoutTemplate(id: 2, name: L("Hai khung ngang"), slots: [r(g, 0.25, 0.5 - 1.5 * g, 0.5), r(0.5 + g / 2, 0.25, 0.5 - 1.5 * g, 0.5)]),
            LayoutTemplate(id: 3, name: L("Ba khung ngang"), slots: (0..<3).map { i in r(g + CGFloat(i) * (1 - g) / 3, 0.3, (1 - g) / 3 - g, 0.4) }),
            LayoutTemplate(id: 4, name: L("Chính + phụ phải"), slots: [r(g, 0.15, 0.64, 0.7), r(0.66, 0.15, 0.33, 0.7)]),
            LayoutTemplate(id: 5, name: L("Chính + 2 phụ xếp dọc"), slots: [r(g, 0.15, 0.64, 0.7), r(0.66, 0.15, 0.33, 0.345), r(0.66, 0.505, 0.33, 0.345)]),
            LayoutTemplate(id: 6, name: L("Chính + 2 phụ hàng ngang"), slots: [r(g, 0.2, 0.6, 0.6), r(0.62, 0.2, 0.18, 0.6), r(0.81, 0.2, 0.18, 0.6)]),
            LayoutTemplate(id: 7, name: L("Chính + 3 phụ xếp dọc"), slots: [r(g, 0.08, 0.66, 0.84), r(0.68, 0.08, 0.31, 0.27), r(0.68, 0.365, 0.31, 0.27), r(0.68, 0.65, 0.31, 0.27)]),
            LayoutTemplate(id: 8, name: L("Bốn khung ngang"), slots: (0..<4).map { i in r(CGFloat(i) * 0.25 + g / 2, 0.15, 0.25 - g, 0.7) }),
            LayoutTemplate(id: 9, name: L("Khung phối cảnh"), slots: [Slot(rect: CGRect(x: 0.2, y: 0.12, width: 0.6, height: 0.76), perspective: true)]),
            LayoutTemplate(id: 10, name: L("Lưới 2×2"), slots: [r(g, g, 0.5 - 1.5 * g, 0.5 - 1.5 * g), r(0.5 + g / 2, g, 0.5 - 1.5 * g, 0.5 - 1.5 * g),
                                                            r(g, 0.5 + g / 2, 0.5 - 1.5 * g, 0.5 - 1.5 * g), r(0.5 + g / 2, 0.5 + g / 2, 0.5 - 1.5 * g, 0.5 - 1.5 * g)])
        ]
    }
}

/// Decorative frame drawn around every layout window (own vector designs, or a user PNG).
struct LayoutFrame: Codable, Equatable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case none, line, tech, brackets, double, image
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return L("Không")
            case .line: return L("Viền")
            case .tech: return L("Tech")
            case .brackets: return L("Góc")
            case .double: return L("Đôi")
            case .image: return L("Ảnh PNG")
            }
        }
    }
    var style: Style = .tech
    var color1 = "#3EC6E8"
    var color2 = "#D0509E"
    var color3 = "#000000"
    /// band thickness as a fraction of the output height
    var thickness: Double = 0.014
    /// PNG (transparent centre) in the Lớp phủ library, used when style == .image
    var imageName: String?
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
                   still: CIImage? = nil, color: CIColor? = nil, frame: LayoutFrame = LayoutFrame(), frameImage: CIImage? = nil) {
        renderer.update(template: template, inputs: inputs, size: size, background: background, still: still, color: color,
                        frame: frame, frameImage: frameImage)
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
    fileprivate var lock = os_unfair_lock()
    private var template = LayoutTemplate.all[1]
    private var inputs: [FrameStore?] = []
    private var background: FrameStore?
    private var still: CIImage?          // background picture behind the windows
    private var color: CIColor?          // background colour (overrides the template's)
    private var size = CGSize(width: 1920, height: 1080)
    private var frame = LayoutFrame()
    private var frameImage: CIImage?
    fileprivate var frameCache: [String: CIImage] = [:]
    private var pool: CVPixelBufferPool?
    private let ci = CIContext(options: [.cacheIntermediates: false])

    func update(template: LayoutTemplate, inputs: [FrameStore?], size: CGSize, background: FrameStore?,
                still: CIImage? = nil, color: CIColor? = nil, frame: LayoutFrame = LayoutFrame(), frameImage: CIImage? = nil) {
        os_unfair_lock_lock(&lock)
        if size != self.size { pool = nil }
        if frame != self.frame || frameImage !== self.frameImage { frameCache.removeAll() }
        self.frame = frame; self.frameImage = frameImage
        self.template = template; self.inputs = inputs; self.size = size; self.background = background
        self.still = still; self.color = color
        os_unfair_lock_unlock(&lock)
    }

    func render() -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        let t = template, ins = inputs, bg = background, sz = size, stillImg = still, bgColor = color, fr = frame, frImg = frameImage
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
            out = tile.composited(over: out)
            if !slot.perspective, let f = frameOverlay(fr, image: frImg, rect: r, canvas: sz) {
                out = f.composited(over: out)
            }
        }
        ci.render(out.cropped(to: extent), to: pb)
        return pb
    }
}

// MARK: Window frames

extension LayoutRenderer {
    /// Frame for one window, positioned in CoreImage (bottom-left) pixel space. Cached per size/style.
    fileprivate func frameOverlay(_ f: LayoutFrame, image: CIImage?, rect r: CGRect, canvas: CGSize) -> CIImage? {
        if f.style == .none { return nil }
        let t = max(2, (f.thickness * canvas.height).rounded())
        if f.style == .image {
            guard let img = image, img.extent.width > 0 else { return nil }
            // PNG frame with transparent centre: stretched slightly past the window so its border sits on the edge
            let target = r.insetBy(dx: -r.width * 0.04, dy: -r.height * 0.04)
            let sx = target.width / img.extent.width, sy = target.height / img.extent.height
            return img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
        }
        let key = "\(f.style.rawValue)|\(f.color1)|\(f.color2)|\(f.color3)|\(Int(t))|\(Int(r.width))x\(Int(r.height))"
        os_unfair_lock_lock(&lock)
        let cached = frameCache[key]
        os_unfair_lock_unlock(&lock)
        let base: CIImage
        if let cached { base = cached } else {
            guard let drawn = Self.drawFrame(f, size: r.size, band: t) else { return nil }
            base = drawn
            os_unfair_lock_lock(&lock)
            frameCache[key] = drawn
            os_unfair_lock_unlock(&lock)
        }
        // drawn canvas is the window grown by `t` on every side
        return base.transformed(by: CGAffineTransform(translationX: r.minX - t, y: r.minY - t))
    }

    /// Vector frames (original designs). Canvas = window + band on each side; origin top-left.
    static func drawFrame(_ f: LayoutFrame, size: CGSize, band t: CGFloat) -> CIImage? {
        let W = size.width + 2 * t, H = size.height + 2 * t
        guard W > 4, H > 4 else { return nil }
        let c1 = UIColor(hex: f.color1), c2 = UIColor(hex: f.color2), c3 = UIColor(hex: f.color3)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        let img = UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: fmt).image { ctx in
            let g = ctx.cgContext
            let outer = CGRect(x: 0, y: 0, width: W, height: H)
            let inner = outer.insetBy(dx: t, dy: t)
            func band(_ rect: CGRect, _ col: UIColor) {     // ring between rect and rect inset by t
                let p = UIBezierPath(rect: rect); p.append(UIBezierPath(rect: rect.insetBy(dx: t, dy: t)))
                p.usesEvenOddFillRule = true; col.setFill(); p.fill()
            }
            func poly(_ pts: [CGPoint], _ col: UIColor) {
                guard let f = pts.first else { return }
                g.beginPath(); g.move(to: f); pts.dropFirst().forEach { g.addLine(to: $0) }; g.closePath()
                g.setFillColor(col.cgColor); g.fillPath()
            }
            switch f.style {
            case .line:
                band(outer, c1)
            case .double:
                band(outer, c1)
                // thin colour-2 line just inside the band
                let p = UIBezierPath(rect: inner.insetBy(dx: t * 0.15, dy: t * 0.15)); p.lineWidth = max(1, t * 0.3)
                c2.setStroke(); p.stroke()
            case .brackets:
                let L = min(W, H) * 0.16
                c1.setFill()
                let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0, 0, 1, 1), (W, 0, -1, 1), (0, H, 1, -1), (W, H, -1, -1)]
                for (x, y, sx, sy) in corners {
                    g.fill(CGRect(x: sx > 0 ? x : x - L, y: sy > 0 ? y : y - t, width: L, height: t))
                    g.fill(CGRect(x: sx > 0 ? x : x - t, y: sy > 0 ? y : y - L, width: t, height: L))
                    // small accent tick in colour 2
                    c2.setFill()
                    g.fill(CGRect(x: sx > 0 ? x + L + t : x - L - 2 * t, y: sy > 0 ? y : y - t, width: t, height: t))
                    c1.setFill()
                }
            case .tech:
                // 1) base ring in colour 1
                band(outer, c1)
                // 2) colour-2 accent runs with 45° ends (top-middle, top-right corner, bottom-right, bottom-left corner)
                let d = t                                    // chamfer = band thickness
                poly([CGPoint(x: W * 0.22, y: 0), CGPoint(x: W * 0.52, y: 0), CGPoint(x: W * 0.52 - d, y: t), CGPoint(x: W * 0.22 + d, y: t)], c2)
                poly([CGPoint(x: W * 0.86, y: 0), CGPoint(x: W, y: 0), CGPoint(x: W, y: H * 0.40), CGPoint(x: W - t, y: H * 0.40 - d),
                      CGPoint(x: W - t, y: t), CGPoint(x: W * 0.86 + d, y: t)], c2)
                poly([CGPoint(x: 0, y: H * 0.72), CGPoint(x: t, y: H * 0.72 + d), CGPoint(x: t, y: H - t), CGPoint(x: W * 0.20, y: H - t),
                      CGPoint(x: W * 0.20 + d, y: H), CGPoint(x: 0, y: H)], c2)
                poly([CGPoint(x: W * 0.56 + d, y: H - t), CGPoint(x: W * 0.84, y: H - t), CGPoint(x: W * 0.84 + d, y: H), CGPoint(x: W * 0.56, y: H)], c2)
                // 3) colour-3 inner rails with stepped notches (sit just inside the ring)
                let k = t * 0.85
                poly([CGPoint(x: W * 0.12, y: t), CGPoint(x: W * 0.58, y: t), CGPoint(x: W * 0.54, y: t + k), CGPoint(x: W * 0.20, y: t + k),
                      CGPoint(x: W * 0.17, y: t + k * 0.5)], c3)
                poly([CGPoint(x: t, y: H * 0.45), CGPoint(x: t + k, y: H * 0.45 + k), CGPoint(x: t + k, y: H * 0.80), CGPoint(x: t + 2 * k, y: H * 0.80 + k),
                      CGPoint(x: t + 2 * k, y: H - t - k), CGPoint(x: W * 0.55, y: H - t - k), CGPoint(x: W * 0.58, y: H - t),
                      CGPoint(x: t, y: H - t)], c3)
                poly([CGPoint(x: W * 0.60, y: H - t - k), CGPoint(x: W * 0.80, y: H - t - k), CGPoint(x: W * 0.86, y: H - t), CGPoint(x: W * 0.57, y: H - t)], c3)
            case .none, .image:
                break
            }
            _ = inner
        }
        guard let cg = img.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }
}

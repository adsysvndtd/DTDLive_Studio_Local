import AVFoundation
import CoreImage
import SwiftUI
import UIKit

/// One element of a custom (multi-layer) title. Placed in a fixed 1920×1080 design space
/// (origin top-left, y downwards), scaled to the program canvas at render time.
struct TitleLayer: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case text, rect, roundRect, ellipse, line, image
        var id: String { rawValue }
        var label: String {
            switch self {
            case .text: return L("Chữ")
            case .rect: return L("Hình chữ nhật")
            case .roundRect: return L("Chữ nhật bo góc")
            case .ellipse: return L("Hình bầu dục")
            case .line: return L("Đường kẻ")
            case .image: return L("Ảnh / logo")
            }
        }
        var icon: String {
            switch self {
            case .text: return "textformat"
            case .rect: return "rectangle"
            case .roundRect: return "rectangle.roundedtop"
            case .ellipse: return "oval"
            case .line: return "line.diagonal"
            case .image: return "photo"
            }
        }
    }

    var id = UUID()
    var kind: Kind = .text
    var name = ""                       // operator label in the layer list (optional)

    // Frame in 1920×1080 design space (top-left origin).
    var x: CGFloat = 760
    var y: CGFloat = 480
    var w: CGFloat = 400
    var h: CGFloat = 120
    var rotation: CGFloat = 0           // degrees, clockwise
    var opacity: CGFloat = 1
    var hidden = false                  // layer hidden in the design (not the title's on-air state)

    // Text
    var text = ""
    var fontSize: CGFloat = 54
    var bold = true
    var italic = false
    var align = 1                       // 0 left · 1 centre · 2 right
    var textHex = "#FFFFFF"
    var fitText = true                  // size the box to the text (text layers)

    // Fill / stroke (shapes, and background box of a text layer)
    var fillHex: String? = "#000000"
    var fillOpacity: CGFloat = 0.85
    var cornerRadius: CGFloat = 12
    var strokeHex: String? = nil
    var strokeWidth: CGFloat = 0

    // Image (file name in the Logo / Ảnh / Lớp phủ library)
    var imageFile: String? = nil

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
    }

    /// A ready-made lower-third design to start from: dark bar, accent tab, name, role.
    static func starter(accent: String) -> [TitleLayer] {
        var bar = make(.roundRect); bar.name = "Nền"; bar.x = 560; bar.y = 760; bar.w = 820; bar.h = 150; bar.fillHex = "#101418"; bar.fillOpacity = 0.9
        var tab = make(.rect); tab.name = "Vạch nhấn"; tab.x = 560; tab.y = 760; tab.w = 14; tab.h = 150; tab.fillHex = accent; tab.fillOpacity = 1
        var name = make(.text); name.name = "Tên"; name.text = L("Họ và tên"); name.x = 600; name.y = 778; name.w = 760; name.h = 70; name.fontSize = 56; name.align = 0; name.fillHex = nil
        var role = make(.text); role.name = "Chức danh"; role.text = L("Chức danh"); role.x = 600; role.y = 850; role.w = 760; role.h = 46; role.fontSize = 32; role.bold = false; role.align = 0; role.textHex = "#D9D9D9"; role.fillHex = nil
        return [bar, tab, name, role]
    }

    static func make(_ kind: Kind) -> TitleLayer {
        var l = TitleLayer(); l.kind = kind
        switch kind {
        case .text:
            l.text = L("Nội dung"); l.w = 760; l.h = 90; l.x = 580; l.y = 760; l.fillHex = nil; l.fitText = true
        case .rect, .roundRect:
            l.w = 760; l.h = 150; l.x = 580; l.y = 740; l.fillHex = "#101010"; l.fillOpacity = 0.9
            l.cornerRadius = kind == .rect ? 0 : 16
        case .ellipse:
            l.w = 200; l.h = 200; l.x = 860; l.y = 440; l.fillHex = "#E30613"; l.fillOpacity = 1
        case .line:
            l.w = 760; l.h = 6; l.x = 580; l.y = 900; l.fillHex = "#E30613"; l.fillOpacity = 1
        case .image:
            l.w = 220; l.h = 220; l.x = 300; l.y = 720; l.fillHex = nil
        }
        return l
    }
}

extension TitleRenderer {
    /// Resolve a library file name to a readable URL (searched across Logo / Ảnh / Lớp phủ).
    static func libraryImage(_ name: String) -> UIImage? {
        for k in [LibraryKind.logo, .picture, .overlay] {
            let u = MediaLibrary.directory(k).appendingPathComponent(name)
            if let img = UIImage(contentsOfFile: u.path) { return img }
        }
        return nil
    }

    /// Full-canvas transparent image of every visible layer, composited in order (first = back).
    static func drawCustom(_ item: TitleItem, canvas: CGSize) -> UIImage? {
        let layers = item.layers ?? []
        guard !layers.isEmpty else { return nil }
        let k = canvas.width / 1920                 // design space (1920×1080) → canvas
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        return UIGraphicsImageRenderer(size: canvas, format: fmt).image { ctx in
            let g = ctx.cgContext
            for layer in layers where !layer.hidden {
                g.saveGState()
                let box = CGRect(x: layer.x * k, y: layer.y * k, width: layer.w * k, height: max(1, layer.h * k))
                // rotate around the box centre
                if layer.rotation != 0 {
                    let c = CGPoint(x: box.midX, y: box.midY)
                    g.translateBy(x: c.x, y: c.y)
                    g.rotate(by: layer.rotation * .pi / 180)
                    g.translateBy(x: -c.x, y: -c.y)
                }
                g.setAlpha(layer.opacity)
                drawLayer(layer, in: box, k: k, g: g)
                g.restoreGState()
            }
        }
    }

    private static func drawLayer(_ layer: TitleLayer, in box: CGRect, k: CGFloat, g: CGContext) {
        let fill = layer.fillHex.map { UIColor(hex: $0).withAlphaComponent(layer.fillOpacity) }
        let stroke = (layer.strokeWidth > 0 ? layer.strokeHex : nil).map { UIColor(hex: $0) }
        switch layer.kind {
        case .rect, .roundRect, .line, .ellipse:
            let path: UIBezierPath
            switch layer.kind {
            case .ellipse: path = UIBezierPath(ovalIn: box)
            case .roundRect: path = UIBezierPath(roundedRect: box, cornerRadius: layer.cornerRadius * k)
            default: path = UIBezierPath(rect: box)      // rect + line (a thin rect)
            }
            if let fill { fill.setFill(); path.fill() }
            if let stroke { stroke.setStroke(); path.lineWidth = layer.strokeWidth * k; path.stroke() }
        case .image:
            if let name = layer.imageFile, let img = libraryImage(name) {
                img.draw(in: AVMakeRect(aspectRatio: img.size, insideRect: box))
            } else {
                UIColor(white: 0.3, alpha: 0.4).setFill(); UIBezierPath(rect: box).fill()
            }
        case .text:
            if let fill {                               // optional background box behind the text
                let p = layer.cornerRadius > 0 ? UIBezierPath(roundedRect: box, cornerRadius: layer.cornerRadius * k) : UIBezierPath(rect: box)
                fill.setFill(); p.fill()
            }
            if let stroke { stroke.setStroke(); let p = UIBezierPath(rect: box); p.lineWidth = layer.strokeWidth * k; p.stroke() }
            var traits: UIFontDescriptor.SymbolicTraits = []
            if layer.bold { traits.insert(.traitBold) }
            if layer.italic { traits.insert(.traitItalic) }
            let base = UIFont.systemFont(ofSize: layer.fontSize * k, weight: layer.bold ? .bold : .regular)
            let font = (base.fontDescriptor.withSymbolicTraits(traits)).map { UIFont(descriptor: $0, size: layer.fontSize * k) } ?? base
            let para = NSMutableParagraphStyle()
            para.alignment = layer.align == 0 ? .left : layer.align == 2 ? .right : .center
            para.lineBreakMode = .byTruncatingTail
            let a = NSAttributedString(string: layer.text, attributes: [
                .font: font, .foregroundColor: UIColor(hex: layer.textHex), .paragraphStyle: para])
            let pad = 8 * k
            let inner = box.insetBy(dx: pad, dy: 0)
            let th = a.boundingRect(with: CGSize(width: inner.width, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin], context: nil).height
            a.draw(with: CGRect(x: inner.minX, y: box.midY - th / 2, width: inner.width, height: th),
                   options: [.usesLineFragmentOrigin], context: nil)
        }
    }
}

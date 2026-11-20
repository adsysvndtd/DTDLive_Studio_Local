import AVFoundation
import CoreImage
import SwiftUI
import UIKit

/// One element of a custom (multi-layer) title. Placed in a fixed 1920×1080 design space
/// (origin top-left, y downwards), scaled to the program canvas at render time.
struct TitleLayer: Identifiable, Equatable {
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
    var hidden = false                  // hidden in the design (not the title's on-air state)
    var locked = false                  // not picked / moved on the canvas (still editable from the list)
    var lockAspect = false              // corner handles keep the proportions (images: on by default)

    // Text
    var text = ""
    var fontSize: CGFloat = 54
    var weight = 3                      // 0 regular · 1 medium · 2 semibold · 3 bold · 4 heavy · 5 black
    var italic = false
    var uppercase = false
    var fontDesign = 0                  // 0 system · 1 rounded · 2 serif · 3 monospaced
    var fontWidth = 0                   // 0 standard · 1 condensed · 2 compressed · 3 expanded
    var align = 1                       // 0 left · 1 centre · 2 right
    var letterSpacing: CGFloat = 0
    var textHex = "#FFFFFF"
    var fitText = true                  // the box hugs the text (text layers)
    var shadow = false
    var shadowHex = "#000000"
    var shadowBlur: CGFloat = 8
    var textStrokeWidth: CGFloat = 0    // outline around the letters (design px)
    var textStrokeHex = "#000000"

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
    var center: CGPoint { CGPoint(x: x + w / 2, y: y + h / 2) }

    /// Axis-aligned box around the layer as drawn (rotation included).
    var boundingBox: CGRect {
        guard rotation != 0 else { return frame }
        let a: Double = Double(rotation) * Double.pi / 180
        let cs: CGFloat = abs(CGFloat(cos(a)))
        let sn: CGFloat = abs(CGFloat(sin(a)))
        // half extents of the rotated box
        let ex: CGFloat = w / 2 * cs + h / 2 * sn
        let ey: CGFloat = w / 2 * sn + h / 2 * cs
        let m = center
        return CGRect(x: m.x - ex, y: m.y - ey, width: 2 * ex, height: 2 * ey)
    }

    /// Uniform scale of the whole layer (box, position about `a`, lettering, corners, borders, shadow).
    mutating func scale(by f: CGFloat, about a: CGPoint) {
        x = a.x + (x - a.x) * f; y = a.y + (y - a.y) * f
        w *= f; h *= f
        fontSize *= f; letterSpacing *= f; textStrokeWidth *= f; shadowBlur *= f
        cornerRadius *= f; strokeWidth *= f
    }

    // MARK: Whole design (all layers as one lower third)

    /// Box around every visible layer, in design px.
    static func groupBounds(_ layers: [TitleLayer]) -> CGRect? {
        var r: CGRect?
        for l in layers where !l.hidden {
            let b = l.boundingBox
            r = r.map { $0.union(b) } ?? b
        }
        return r
    }

    /// The point the design grows from when resized: the side it sits against
    /// (left / centre / right, bottom for designs in the lower half, top otherwise).
    static func groupAnchor(_ g: CGRect) -> CGPoint {
        let ax: CGFloat = abs(g.midX - 960) < 60 ? g.midX : (g.midX < 960 ? g.minX : g.maxX)
        return CGPoint(x: ax, y: g.midY >= 540 ? g.maxY : g.minY)
    }

    static func moved(_ layers: [TitleLayer], dx: CGFloat, dy: CGFloat) -> [TitleLayer] {
        layers.map { (l: TitleLayer) -> TitleLayer in var m = l; m.x += dx; m.y += dy; return m }
    }

    static func scaled(_ layers: [TitleLayer], by f: CGFloat, about a: CGPoint) -> [TitleLayer] {
        layers.map { (l: TitleLayer) -> TitleLayer in var m = l; m.scale(by: f, about: a); return m }
    }

    /// Longer / shorter without changing the lettering: wide background shapes (bars, rules) stretch,
    /// everything else keeps its size and stays with its side (left items stay, right items follow the
    /// right edge, centred items stay centred). A design centred on the frame stays centred.
    static func stretched(_ layers: [TitleLayer], by f: CGFloat) -> [TitleLayer] {
        guard let g = groupBounds(layers), g.width > 0 else { return layers }
        let shiftAll: CGFloat = abs(g.midX - 960) < 60 ? -(f - 1) * g.width / 2 : 0
        return layers.map { (l: TitleLayer) -> TitleLayer in
            var m = l
            let spanning = (m.kind == .rect || m.kind == .roundRect || m.kind == .line) && m.rotation == 0 && m.w >= 0.3 * g.width
            if spanning {
                m.x = g.minX + (m.x - g.minX) * f
                m.w *= f
            } else {
                let mid = m.x + m.w / 2
                // text follows its own alignment (left text stays left even if its box reaches the middle);
                // other parts follow the side they are on, or stay centred when they sit in the middle
                let side: Int
                if m.kind == .text && m.align != 1 { side = m.align == 2 ? 1 : -1 }
                else if abs(mid - g.midX) < 0.08 * g.width || (m.kind == .text && m.w >= 0.3 * g.width) { side = 0 }
                else { side = mid > g.midX ? 1 : -1 }
                if side == 0 { m.x += (f - 1) * (g.midX - g.minX) } else if side == 1 { m.x += (f - 1) * g.width }
            }
            m.x += shiftAll
            return m
        }
    }

    /// A ready-made lower-third design to start from: dark bar, accent tab, name, role.
    static func starter(accent: String) -> [TitleLayer] {
        var bar = make(.roundRect); bar.name = L("Nền"); bar.x = 560; bar.y = 760; bar.w = 820; bar.h = 150; bar.fillHex = "#101418"; bar.fillOpacity = 0.9
        var tab = make(.rect); tab.name = L("Vạch nhấn"); tab.x = 560; tab.y = 760; tab.w = 14; tab.h = 150; tab.fillHex = accent; tab.fillOpacity = 1
        // text boxes hug the text; placed by their vertical centre so the two lines sit balanced in the 150 px bar
        var name = make(.text); name.name = L("Tên"); name.text = L("Họ và tên"); name.fontSize = 56; name.align = 0; name.x = 600
        TitleRenderer.refit(&name); name.y = (804 - name.h / 2).rounded()
        var role = make(.text); role.name = L("Chức danh"); role.text = L("Chức danh"); role.fontSize = 32; role.weight = 0; role.align = 0
        role.textHex = "#D9D9D9"; role.x = 600
        TitleRenderer.refit(&role); role.y = (868 - role.h / 2).rounded()
        return [bar, tab, name, role]
    }

    /// Richer lower third: accent header tab (uppercase), round logo badge, name with shadow, role, accent rule.
    static func starterHeader(accent: String) -> [TitleLayer] {
        func centred(_ l: inout TitleLayer, cy: CGFloat) { TitleRenderer.refit(&l); l.y = (cy - l.h / 2).rounded() }
        var bar = make(.roundRect); bar.name = L("Nền"); bar.x = 520; bar.y = 770; bar.w = 900; bar.h = 140
        bar.fillHex = "#0E1116"; bar.fillOpacity = 0.92; bar.cornerRadius = 14
        var rule = make(.line); rule.name = L("Vạch nhấn"); rule.x = 520; rule.y = 906; rule.w = 900; rule.h = 4
        rule.fillHex = accent; rule.fillOpacity = 1
        var head = make(.text); head.name = L("Tiêu đề"); head.text = L("CHƯƠNG TRÌNH"); head.uppercase = true
        head.fontSize = 24; head.weight = 4; head.letterSpacing = 3; head.align = 0; head.x = 520
        head.fillHex = accent; head.fillOpacity = 1; head.cornerRadius = 8
        centred(&head, cy: 742)
        var badge = make(.ellipse); badge.name = L("Logo"); badge.x = 544; badge.y = 790; badge.w = 100; badge.h = 100
        badge.fillHex = "#FFFFFF"; badge.fillOpacity = 1
        var mark = make(.text); mark.name = L("Chữ logo"); mark.text = "DTD"; mark.fontSize = 30; mark.weight = 5
        mark.textHex = "#0E1116"; mark.align = 1; mark.fitText = false; mark.x = 544; mark.y = 790; mark.w = 100; mark.h = 100
        var name = make(.text); name.name = L("Tên"); name.text = L("Họ và tên"); name.fontSize = 54; name.weight = 3
        name.align = 0; name.x = 664; name.shadow = true; name.shadowBlur = 8
        centred(&name, cy: 818)
        var role = make(.text); role.name = L("Chức danh"); role.text = L("Chức danh"); role.fontSize = 30; role.weight = 0
        role.align = 0; role.x = 664; role.textHex = "#C9CED6"
        centred(&role, cy: 872)
        return [bar, rule, head, badge, mark, name, role]
    }

    static func make(_ kind: Kind) -> TitleLayer {
        var l = TitleLayer(); l.kind = kind
        switch kind {
        case .text:
            l.text = L("Nội dung"); l.x = 760; l.y = 500; l.fillHex = nil; l.fitText = true
            TitleRenderer.refit(&l)
            l.x = 960 - l.w / 2; l.y = 540 - l.h / 2
        case .rect, .roundRect:
            l.w = 760; l.h = 150; l.x = 580; l.y = 740; l.fillHex = "#101010"; l.fillOpacity = 0.9
            l.cornerRadius = kind == .rect ? 0 : 16
        case .ellipse:
            l.w = 200; l.h = 200; l.x = 860; l.y = 440; l.fillHex = "#E30613"; l.fillOpacity = 1; l.lockAspect = true
        case .line:
            l.w = 760; l.h = 6; l.x = 580; l.y = 900; l.fillHex = "#E30613"; l.fillOpacity = 1
        case .image:
            l.w = 220; l.h = 220; l.x = 300; l.y = 720; l.fillHex = nil; l.lockAspect = true
        }
        return l
    }
}

/// Written by hand so designs saved by older / newer versions always load: a missing key keeps its
/// default (synthesised decoding would fail and the whole title list would fall back to the defaults).
extension TitleLayer: Codable {
    private enum K: String, CodingKey {
        case id, kind, name, x, y, w, h, rotation, opacity, hidden, locked, lockAspect
        case text, fontSize, weight, bold, italic, uppercase, fontDesign, fontWidth, align, letterSpacing, textHex, fitText
        case shadow, shadowHex, shadowBlur, textStrokeWidth, textStrokeHex
        case fillHex, fillOpacity, cornerRadius, strokeHex, strokeWidth, imageFile
    }

    init(from decoder: Decoder) throws {
        self = TitleLayer()
        let c = try decoder.container(keyedBy: K.self)
        func v<T: Decodable>(_ k: K, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        id = v(.id, id); kind = v(.kind, kind); name = v(.name, name)
        x = v(.x, x); y = v(.y, y); w = v(.w, w); h = v(.h, h)
        rotation = v(.rotation, rotation); opacity = v(.opacity, opacity)
        hidden = v(.hidden, hidden); locked = v(.locked, locked)
        lockAspect = v(.lockAspect, kind == .image || kind == .ellipse)
        text = v(.text, text); fontSize = v(.fontSize, fontSize)
        let oldBold: Bool? = try? c.decodeIfPresent(Bool.self, forKey: .bold)
        weight = v(.weight, oldBold == false ? 0 : 3)
        italic = v(.italic, italic); uppercase = v(.uppercase, uppercase)
        fontDesign = v(.fontDesign, fontDesign); fontWidth = v(.fontWidth, fontWidth)
        align = v(.align, align); letterSpacing = v(.letterSpacing, letterSpacing)
        textHex = v(.textHex, textHex); fitText = v(.fitText, fitText)
        shadow = v(.shadow, shadow); shadowHex = v(.shadowHex, shadowHex); shadowBlur = v(.shadowBlur, shadowBlur)
        textStrokeWidth = v(.textStrokeWidth, textStrokeWidth); textStrokeHex = v(.textStrokeHex, textStrokeHex)
        // optionals: a missing key means "none", not the default colour
        fillHex = try? c.decodeIfPresent(String.self, forKey: .fillHex)
        strokeHex = try? c.decodeIfPresent(String.self, forKey: .strokeHex)
        imageFile = try? c.decodeIfPresent(String.self, forKey: .imageFile)
        fillOpacity = v(.fillOpacity, fillOpacity); cornerRadius = v(.cornerRadius, cornerRadius)
        strokeWidth = v(.strokeWidth, strokeWidth)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(name, forKey: .name)
        try c.encode(x, forKey: .x); try c.encode(y, forKey: .y); try c.encode(w, forKey: .w); try c.encode(h, forKey: .h)
        try c.encode(rotation, forKey: .rotation); try c.encode(opacity, forKey: .opacity)
        try c.encode(hidden, forKey: .hidden); try c.encode(locked, forKey: .locked); try c.encode(lockAspect, forKey: .lockAspect)
        try c.encode(text, forKey: .text); try c.encode(fontSize, forKey: .fontSize); try c.encode(weight, forKey: .weight)
        try c.encode(italic, forKey: .italic); try c.encode(uppercase, forKey: .uppercase)
        try c.encode(fontDesign, forKey: .fontDesign); try c.encode(fontWidth, forKey: .fontWidth)
        try c.encode(align, forKey: .align); try c.encode(letterSpacing, forKey: .letterSpacing)
        try c.encode(textHex, forKey: .textHex); try c.encode(fitText, forKey: .fitText)
        try c.encode(shadow, forKey: .shadow); try c.encode(shadowHex, forKey: .shadowHex); try c.encode(shadowBlur, forKey: .shadowBlur)
        try c.encode(textStrokeWidth, forKey: .textStrokeWidth); try c.encode(textStrokeHex, forKey: .textStrokeHex)
        try c.encodeIfPresent(fillHex, forKey: .fillHex); try c.encode(fillOpacity, forKey: .fillOpacity)
        try c.encode(cornerRadius, forKey: .cornerRadius)
        try c.encodeIfPresent(strokeHex, forKey: .strokeHex); try c.encode(strokeWidth, forKey: .strokeWidth)
        try c.encodeIfPresent(imageFile, forKey: .imageFile)
    }
}

extension TitleRenderer {
    /// Resolve a library file name to an image (searched across Logo / Ảnh / Lớp phủ).
    /// Decoded library pictures used by image layers (read from disk once, not on every redraw).
    nonisolated(unsafe) static let libraryImageCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>(); c.countLimit = 40; return c
    }()

    static func libraryImage(_ name: String) -> UIImage? {
        if let img = libraryImageCache.object(forKey: name as NSString) { return img }
        for k in [LibraryKind.logo, .picture, .overlay] {
            let u = MediaLibrary.directory(k).appendingPathComponent(name)
            if let img = UIImage(contentsOfFile: u.path) {
                libraryImageCache.setObject(img, forKey: name as NSString)
                return img
            }
        }
        return nil
    }

    // MARK: Text

    static let fontWeights: [UIFont.Weight] = [.regular, .medium, .semibold, .bold, .heavy, .black]
    private static let fontWidths: [UIFont.Width] = [.standard, .condensed, .compressed, .expanded]
    private static let fontDesigns: [UIFontDescriptor.SystemDesign] = [.default, .rounded, .serif, .monospaced]

    static func font(_ l: TitleLayer, size: CGFloat) -> UIFont {
        let wt = fontWeights[min(max(l.weight, 0), fontWeights.count - 1)]
        let wd = fontWidths[min(max(l.fontWidth, 0), fontWidths.count - 1)]
        var f = UIFont.systemFont(ofSize: size, weight: wt, width: wd)
        if l.fontDesign > 0, l.fontDesign < fontDesigns.count, let d = f.fontDescriptor.withDesign(fontDesigns[l.fontDesign]) {
            f = UIFont(descriptor: d, size: size)
        }
        if l.italic, let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            f = UIFont(descriptor: d, size: size)
        }
        return f
    }

    /// The layer's text with its font, colour, spacing, outline and shadow at scale k (design px → canvas px).
    static func textAttributed(_ l: TitleLayer, k: CGFloat) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = l.align == 0 ? .left : l.align == 2 ? .right : .center
        para.lineBreakMode = .byWordWrapping
        let size = max(4, l.fontSize) * k
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font(l, size: size), .foregroundColor: UIColor(hex: l.textHex), .paragraphStyle: para,
            .kern: l.letterSpacing * k
        ]
        if l.textStrokeWidth > 0 {
            attrs[.strokeColor] = UIColor(hex: l.textStrokeHex)
            attrs[.strokeWidth] = -(l.textStrokeWidth / max(l.fontSize, 1) * 100)   // negative = fill + outline
        }
        if l.shadow {
            let s = NSShadow()
            s.shadowColor = UIColor(hex: l.shadowHex).withAlphaComponent(0.85)
            s.shadowBlurRadius = l.shadowBlur * k
            s.shadowOffset = CGSize(width: 0, height: 3 * k)
            attrs[.shadow] = s
        }
        let t = l.text.isEmpty ? " " : (l.uppercase ? l.text.uppercased() : l.text)
        return NSAttributedString(string: t, attributes: attrs)
    }

    /// Inner padding of a text box (design px): roomier when it has a background box.
    static func textPad(_ l: TitleLayer) -> CGSize {
        l.fillHex != nil ? CGSize(width: 22, height: 10) : CGSize(width: 4, height: 2)
    }

    /// Size of the text in design px, wrapped at `width` (nil = natural, line breaks only where typed).
    static func textSize(_ l: TitleLayer, width: CGFloat?) -> CGSize {
        let r = textAttributed(l, k: 1).boundingRect(
            with: CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// Box hugs the text. Keeps the anchor given by the alignment (left / centre / right) and the vertical centre.
    static func refit(_ l: inout TitleLayer) {
        guard l.kind == .text else { return }
        let pad = textPad(l), sz = textSize(l, width: nil)
        let nw = max(20, sz.width + 2 * pad.width + 2), nh = max(10, sz.height + 2 * pad.height)
        let cy = l.y + l.h / 2
        switch l.align {
        case 0: break
        case 2: l.x += l.w - nw
        default: l.x += (l.w - nw) / 2
        }
        l.w = nw; l.h = nh; l.y = cy - nh / 2
    }

    /// Height that fits the text wrapped inside the current width (used when the width is set by hand).
    static func fittedHeight(_ l: TitleLayer) -> CGFloat {
        let pad = textPad(l)
        return max(10, textSize(l, width: max(10, l.w - 2 * pad.width)).height + 2 * pad.height)
    }

    // MARK: Drawing

    /// How a 16:9 design (1920×1080) is placed on a program frame of another shape: 16:9 exactly as designed;
    /// otherwise the design is sized by `graphicsScale` (never wider / taller than 94 % of the frame), keeps its
    /// relative horizontal position and its bottom margin (top margin for designs in the upper half).
    static func adaptTransform(_ layers: [TitleLayer], canvas: CGSize) -> (k: CGFloat, tx: CGFloat, ty: CGFloat) {
        let W = canvas.width, H = max(canvas.height, 1)
        if abs(W / H - 16.0 / 9.0) < 0.02 { return (W / 1920, 0, 0) }
        guard let g = TitleLayer.groupBounds(layers), g.width > 0, g.height > 0 else { return (min(W / 1920, H / 1080), 0, 0) }
        let k = min(graphicsScale(canvas), 0.94 * W / g.width, 0.94 * H / g.height)
        var left = g.midX / 1920 * W - g.width * k / 2
        left = min(max(left, 0.03 * W), max(0.03 * W, 0.97 * W - g.width * k))
        var top: CGFloat = g.midY >= 540 ? (H - (1080 - g.maxY) / 1080 * H) - g.height * k : g.minY / 1080 * H
        top = min(max(top, 0.02 * H), max(0.02 * H, 0.98 * H - g.height * k))
        return (k, left - g.minX * k, top - g.minY * k)
    }

    /// Size of graphics designed for 1080 lines on this frame: by height on 16:9 / 4:3, limited by the width on
    /// square and vertical frames (so a 900 px lower third still fits a 9:16 frame).
    static func graphicsScale(_ canvas: CGSize) -> CGFloat {
        min(canvas.height / 1080, canvas.width * 0.95 / 1080)
    }

    /// Full-canvas transparent image of every visible layer, composited in order (first = back).
    static func drawCustom(_ item: TitleItem, canvas: CGSize) -> UIImage? {
        let layers = item.layers ?? []
        guard !layers.isEmpty, canvas.width >= 1, canvas.height >= 1 else { return nil }
        let t = adaptTransform(layers, canvas: canvas)  // design space (1920×1080) → canvas
        let k = t.k
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        return UIGraphicsImageRenderer(size: canvas, format: fmt).image { ctx in
            let g = ctx.cgContext
            for layer in layers where !layer.hidden {
                g.saveGState()
                let box = CGRect(x: t.tx + layer.x * k, y: t.ty + layer.y * k, width: max(1, layer.w * k), height: max(1, layer.h * k))
                if layer.rotation != 0 {             // rotate around the box centre
                    g.translateBy(x: box.midX, y: box.midY)
                    g.rotate(by: layer.rotation * .pi / 180)
                    g.translateBy(x: -box.midX, y: -box.midY)
                }
                g.setAlpha(layer.opacity)
                drawLayer(layer, in: box, k: k)
                g.restoreGState()
            }
        }
    }

    private static func drawLayer(_ layer: TitleLayer, in box: CGRect, k: CGFloat) {
        let fill = layer.fillHex.map { UIColor(hex: $0).withAlphaComponent(layer.fillOpacity) }
        let stroke = (layer.strokeWidth > 0 ? layer.strokeHex : nil).map { UIColor(hex: $0) }
        let radius = min(layer.cornerRadius * k, min(box.width, box.height) / 2)
        switch layer.kind {
        case .rect, .roundRect, .line, .ellipse:
            let path: UIBezierPath
            switch layer.kind {
            case .ellipse: path = UIBezierPath(ovalIn: box)
            case .roundRect: path = UIBezierPath(roundedRect: box, cornerRadius: radius)
            default: path = UIBezierPath(rect: box)      // rect, and a line = a thin rect
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
            let bg = radius > 0 ? UIBezierPath(roundedRect: box, cornerRadius: radius) : UIBezierPath(rect: box)
            if let fill { fill.setFill(); bg.fill() }
            if let stroke { stroke.setStroke(); bg.lineWidth = layer.strokeWidth * k; bg.stroke() }
            let a = textAttributed(layer, k: k)
            let pad = textPad(layer)
            let inner = box.insetBy(dx: pad.width * k, dy: pad.height * k)
            let iw = max(1, inner.width)
            let th = a.boundingRect(with: CGSize(width: iw, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
            a.draw(with: CGRect(x: inner.minX, y: box.midY - th / 2, width: iw, height: th + 2),
                   options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }
}

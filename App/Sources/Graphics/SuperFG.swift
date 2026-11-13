import UIKit

/// SuperFG: full-screen animated cards ("READY", "BREAKING NEWS", "GOAL!"…) that play over program
/// with their own transition when SuperFG On is pressed. Designs are DTD Studio's own, drawn procedurally
/// (background and text are separate layers so each can animate); text and accent colour are editable per card.
/// Operators can still use their own PNG (alpha) or video with alpha from the library as a keyed foreground.
struct SuperFGConfig: Codable, Equatable {
    var templateID = "ready"
    /// Per-card text lines and accent colour (falls back to the card's defaults).
    var texts: [String: [String]] = [:]
    var accents: [String: String] = [:]
    /// true: in → hold → out by itself; false: stays until SuperFG is switched off.
    var playOnce = true
    var hold: Double = 3
    /// Cut preview to program while the card covers the screen (stinger transition).
    var takeOnCover = false
    /// A selected card replaces the transition: CUT / AUTO / T-bar switch cameras behind it.
    var asTransition = true
    /// Transition for pictures from the SuperFG library.
    var libraryMotion = SuperFGMotion.zoom.rawValue
    /// Text animation per card id (missing = follows the card).
    var textMotions: [String: String] = [:]
    func textMotion(_ id: String) -> SuperFGTextMotion { SuperFGTextMotion(rawValue: textMotions[id] ?? "") ?? .auto }
    var libraryMotionValue: SuperFGMotion { SuperFGMotion(rawValue: libraryMotion) ?? .zoom }

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        templateID = (try? c.decodeIfPresent(String.self, forKey: .templateID)) ?? "ready"
        texts = (try? c.decodeIfPresent([String: [String]].self, forKey: .texts)) ?? [:]
        accents = (try? c.decodeIfPresent([String: String].self, forKey: .accents)) ?? [:]
        playOnce = (try? c.decodeIfPresent(Bool.self, forKey: .playOnce)) ?? true
        hold = (try? c.decodeIfPresent(Double.self, forKey: .hold)) ?? 3
        takeOnCover = (try? c.decodeIfPresent(Bool.self, forKey: .takeOnCover)) ?? false
        asTransition = (try? c.decodeIfPresent(Bool.self, forKey: .asTransition)) ?? true
        libraryMotion = (try? c.decodeIfPresent(String.self, forKey: .libraryMotion)) ?? SuperFGMotion.zoom.rawValue
        textMotions = (try? c.decodeIfPresent([String: String].self, forKey: .textMotions)) ?? [:]
        if SuperFGTemplate.all.first(where: { $0.id == templateID }) == nil { templateID = "ready" }
    }

    func lines(_ t: SuperFGTemplate) -> [String] { texts[t.id] ?? t.defaultLines }
    func accent(_ t: SuperFGTemplate) -> UIColor { UIColor(hex: accents[t.id] ?? t.defaultAccent) }
    func accentHex(_ t: SuperFGTemplate) -> String { accents[t.id] ?? t.defaultAccent }
}

/// How a card's text enters (out is the reverse); `auto` follows the card's own motion.
enum SuperFGTextMotion: String, CaseIterable, Identifiable, Codable {
    case auto, spin, pop, flip, rise, fade
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return L("Theo thẻ")
        case .spin: return L("Xoay từ giữa")
        case .pop: return L("Bật nảy")
        case .flip: return L("Lật")
        case .rise: return L("Trồi lên")
        case .fade: return L("Mờ dần")
        }
    }
}

/// How a card enters and leaves (out is the reverse).
enum SuperFGMotion: String, CaseIterable, Identifiable {
    case wipe, slide, slideRight, split, splitH, zoom, spin, rise, drop, blinds, flash, iris, fade
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wipe: return L("Quét chéo")
        case .slide: return L("Trượt từ trái")
        case .slideRight: return L("Trượt từ phải")
        case .split: return L("Mở dọc")
        case .splitH: return L("Mở ngang")
        case .zoom: return L("Phóng to")
        case .spin: return L("Xoay")
        case .rise: return L("Trồi lên")
        case .drop: return L("Rơi xuống")
        case .blinds: return L("Rèm")
        case .flash: return L("Chớp sáng")
        case .iris: return L("Vòng tròn")
        case .fade: return L("Mờ dần")
        }
    }
}

struct SuperFGTemplate: Identifiable {
    enum TextLook { case plain, gradient, gold }
    let id: String
    let name: String
    let motion: SuperFGMotion
    let defaultLines: [String]
    let defaultAccent: String
    var look: TextLook = .plain
    let background: (CGContext, CGSize, UIColor) -> Void

    // MARK: Rendering

    private static func renderer(_ size: CGSize, opaque: Bool) -> UIGraphicsImageRenderer {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: fmt)
    }

    func renderBackground(_ c: SuperFGConfig, size: CGSize) -> UIImage {
        Self.renderer(size, opaque: true).image { ctx in background(ctx.cgContext, size, c.accent(self)) }
    }

    func renderText(_ c: SuperFGConfig, size: CGSize) -> UIImage {
        Self.renderer(size, opaque: false).image { ctx in
            Self.drawTitle(c.lines(self), in: ctx.cgContext, size: size, look: look, accent: c.accent(self))
        }
    }

    /// Both layers together (thumbnails).
    func render(_ c: SuperFGConfig, size: CGSize) -> UIImage {
        let bg = renderBackground(c, size: size), tx = renderText(c, size: size)
        return Self.renderer(size, opaque: true).image { _ in
            bg.draw(at: .zero); tx.draw(at: .zero)
        }
    }

    /// Big centred title, one or two lines, with a drop shadow; optional gradient/gold fill.
    static func drawTitle(_ lines: [String], in g: CGContext, size s: CGSize, look: TextLook, accent: UIColor) {
        let ls = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !ls.isEmpty else { return }
        let k = s.height / 1080
        var fontSize = (ls.count == 1 ? 190 : 165) * k
        let maxW = s.width * 0.86
        func font(_ sz: CGFloat) -> UIFont {
            let f = UIFont.systemFont(ofSize: sz, weight: .black)
            return f.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: sz) } ?? f
        }
        var f = font(fontSize)
        let widest = { ls.map { ($0 as NSString).size(withAttributes: [.font: f]).width }.max() ?? 0 }
        while widest() > maxW, fontSize > 40 * k { fontSize -= 6 * k; f = font(fontSize) }
        let lineH = f.lineHeight * 0.92
        let total = lineH * CGFloat(ls.count)
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: UIColor.white, .paragraphStyle: p]
        let rects = ls.indices.map { i in
            CGRect(x: 0, y: (s.height - total) / 2 + CGFloat(i) * lineH - f.lineHeight * 0.04, width: s.width, height: f.lineHeight)
        }
        UIGraphicsPushContext(g)
        for (l, r) in zip(ls, rects) { (l as NSString).draw(in: r, withAttributes: attrs) }
        // Colour the glyphs only (sourceAtop paints where text already is).
        if look != .plain {
            g.saveGState(); g.setBlendMode(.sourceAtop)
            let cols: [CGColor] = look == .gold
                ? [UIColor(hex: "#FFF3C4").cgColor, UIColor(hex: "#F2B233").cgColor, UIColor(hex: "#C47A12").cgColor]
                : [UIColor.white.cgColor, UIColor.white.cgColor, accent.cgColor]
            if let gr = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols as CFArray, locations: [0, 0.45, 1]) {
                g.drawLinearGradient(gr, start: CGPoint(x: s.width * 0.3, y: rects[0].minY),
                                     end: CGPoint(x: s.width * 0.7, y: rects.last!.maxY), options: [])
            }
            g.restoreGState()
        }
        // Shadow and a thin accent outline behind the glyphs.
        g.saveGState(); g.setBlendMode(.destinationOver)
        g.setShadow(offset: CGSize(width: 0, height: 8 * k), blur: 22 * k, color: UIColor.black.withAlphaComponent(0.6).cgColor)
        var outline = attrs
        outline[.strokeWidth] = -14
        outline[.strokeColor] = look == .gradient ? accent : UIColor.black.withAlphaComponent(0.35)
        for (l, r) in zip(ls, rects) { (l as NSString).draw(in: r, withAttributes: outline) }
        g.restoreGState()
        UIGraphicsPopContext()
    }

    // MARK: Drawing helpers

    private static func linear(_ g: CGContext, _ colors: [UIColor], from a: CGPoint, to b: CGPoint, locations: [CGFloat]? = nil) {
        guard let gr = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray,
                                  locations: locations) else { return }
        g.drawLinearGradient(gr, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    private static func radial(_ g: CGContext, _ colors: [UIColor], center: CGPoint, radius: CGFloat) {
        guard let gr = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return }
        g.drawRadialGradient(gr, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
    }
    private static func poly(_ g: CGContext, _ pts: [CGPoint], _ color: UIColor) {
        guard let f = pts.first else { return }
        g.beginPath(); g.move(to: f); pts.dropFirst().forEach { g.addLine(to: $0) }; g.closePath()
        g.setFillColor(color.cgColor); g.fillPath()
    }
    private static func hexagon(_ c: CGPoint, _ r: CGFloat) -> [CGPoint] {
        (0..<6).map { i in let a = CGFloat(i) * .pi / 3; return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)) }
    }
    /// Deterministic pseudo-random sequence so a card always draws the same.
    private static func rng(_ seed: UInt64) -> () -> CGFloat {
        var x = seed
        return { x = x &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((x >> 33) % 10_000) / 10_000 }
    }
    private static func navyPanels(_ g: CGContext, _ s: CGSize, seed: UInt64) {
        linear(g, [UIColor(hex: "#1B2A4A"), UIColor(hex: "#0A1430")], from: .zero, to: CGPoint(x: s.width, y: s.height))
        let r = rng(seed)
        for _ in 0..<6 {
            let x = r() * s.width, w = (0.15 + r() * 0.3) * s.width, tilt = (r() - 0.5) * s.width * 0.5
            poly(g, [CGPoint(x: x, y: 0), CGPoint(x: x + w, y: 0), CGPoint(x: x + w + tilt, y: s.height), CGPoint(x: x + tilt, y: s.height)],
                 UIColor(white: r() > 0.5 ? 1 : 0, alpha: 0.025 + r() * 0.04))
        }
    }
    private static func goldStripe(_ g: CGContext, _ s: CGSize, x: CGFloat, accent: UIColor) {
        let k = s.height / 1080, w = 14 * k
        g.saveGState()
        g.beginPath()
        g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x + w, y: 0))
        g.addLine(to: CGPoint(x: x + w - s.height * 0.42, y: s.height)); g.addLine(to: CGPoint(x: x - s.height * 0.42, y: s.height)); g.closePath()
        g.clip()
        linear(g, [UIColor(hex: "#FFD66B"), accent], from: CGPoint(x: x, y: 0), to: CGPoint(x: x - s.height * 0.42, y: s.height))
        g.restoreGState()
    }

    // MARK: Cards

    /// Computed so names follow a live language switch.
    static var all: [SuperFGTemplate] { [
        SuperFGTemplate(id: "ready", name: L("Sẵn sàng"), motion: .wipe, defaultLines: ["READY"], defaultAccent: "#7B3FF2") { g, s, a in
            linear(g, [UIColor(hex: "#D23AC8"), UIColor(hex: "#58C8F5"), a], from: CGPoint(x: 0, y: s.height), to: CGPoint(x: s.width, y: 0),
                   locations: [0, 0.5, 1])
            let r = rng(7), k = s.height / 1080
            g.setLineCap(.round)
            for _ in 0..<26 {
                let y = r() * s.height * 1.6 - s.height * 0.3
                g.setStrokeColor(UIColor(white: 1, alpha: 0.06 + r() * 0.14).cgColor); g.setLineWidth((2 + r() * 10) * k)
                g.move(to: CGPoint(x: -100 * k, y: y)); g.addLine(to: CGPoint(x: s.width + 100 * k, y: y - s.width * 0.45)); g.strokePath()
            }
            for _ in 0..<9 {
                let c = CGPoint(x: s.width * (0.3 + r() * 0.4), y: r() * s.height)
                radial(g, [UIColor(white: 1, alpha: 0.18), UIColor(white: 1, alpha: 0)], center: c, radius: (60 + r() * 120) * k)
            }
        },
        SuperFGTemplate(id: "premiere", name: L("Ra mắt"), motion: .slide, defaultLines: ["PREMIERE"], defaultAccent: "#C23AF0") { g, s, a in
            linear(g, [UIColor(hex: "#3FA2F7"), a], from: .zero, to: CGPoint(x: s.width, y: 0))
            radial(g, [UIColor(white: 1, alpha: 0.18), UIColor(white: 1, alpha: 0)], center: CGPoint(x: s.width * 0.5, y: s.height * 0.42), radius: s.width * 0.45)
        },
        SuperFGTemplate(id: "breaking", name: L("Tin nóng"), motion: .split, defaultLines: ["BREAKING", "NEWS"], defaultAccent: "#E0242B") { g, s, a in
            radial(g, [UIColor(hex: "#2F6FD6"), UIColor(hex: "#0B1E4D")], center: CGPoint(x: s.width / 2, y: s.height * 0.55), radius: s.width * 0.7)
            let k = s.height / 1080
            for i in 0..<9 {
                let rw = s.width * (0.25 + CGFloat(i) * 0.09), rh = rw * 0.22
                g.setStrokeColor(UIColor(white: 1, alpha: 0.10 + 0.03 * CGFloat(i % 3)).cgColor); g.setLineWidth((3 + CGFloat(i % 4) * 4) * k)
                g.strokeEllipse(in: CGRect(x: s.width / 2 - rw / 2, y: s.height * (0.18 + CGFloat(i % 2) * 0.62) - rh / 2, width: rw, height: rh))
            }
            let band = CGRect(x: 0, y: s.height * 0.31, width: s.width, height: s.height * 0.38)
            g.saveGState(); g.clip(to: band)
            linear(g, [a.withAlphaComponent(0), a, a, a.withAlphaComponent(0)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: s.width, y: 0),
                   locations: [0, 0.18, 0.82, 1])
            g.restoreGState()
            g.setFillColor(UIColor(white: 1, alpha: 0.85).cgColor)
            g.fill(CGRect(x: s.width * 0.1, y: band.minY - 6 * k, width: s.width * 0.8, height: 4 * k))
            g.fill(CGRect(x: s.width * 0.1, y: band.maxY + 2 * k, width: s.width * 0.8, height: 4 * k))
        },
        SuperFGTemplate(id: "perfect", name: L("Tuyệt vời"), motion: .spin, defaultLines: ["PERFECT"], defaultAccent: "#E2C04E") { g, s, a in
            a.setFill(); g.fill(CGRect(origin: .zero, size: s))
            let c = CGPoint(x: s.width / 2, y: s.height / 2), k = s.height / 1080
            poly(g, hexagon(c, s.height * 0.62), UIColor(white: 0.17, alpha: 1))
            g.setStrokeColor(UIColor(white: 1, alpha: 0.85).cgColor); g.setLineWidth(3 * k)
            for r in [0.42, 0.47] as [CGFloat] {
                let pts = hexagon(c, s.height * r)
                g.beginPath(); g.move(to: pts[0]); pts.dropFirst().forEach { g.addLine(to: $0) }; g.closePath(); g.strokePath()
            }
            poly(g, hexagon(c, s.height * 0.18), a)
        },
        SuperFGTemplate(id: "gameon", name: L("Vào trận"), motion: .slideRight, defaultLines: ["GAME ON"], defaultAccent: "#38C6FF") { g, s, a in
            linear(g, [UIColor(hex: "#0B1C8C"), UIColor(hex: "#050C4A")], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: s.height))
            let r = rng(21), k = s.height / 1080
            for i in 0..<14 {
                let x = r() * s.width, tilt = (r() - 0.5) * s.width * 0.6
                g.saveGState()
                g.setShadow(offset: .zero, blur: 24 * k, color: a.cgColor)
                g.setStrokeColor(a.withAlphaComponent(i % 3 == 0 ? 0.9 : 0.25).cgColor); g.setLineWidth((i % 3 == 0 ? 5 : 2) * k)
                g.move(to: CGPoint(x: x, y: -20 * k)); g.addLine(to: CGPoint(x: x + tilt, y: s.height + 20 * k)); g.strokePath()
                g.restoreGState()
            }
            radial(g, [UIColor(white: 1, alpha: 0.10), UIColor(white: 1, alpha: 0)], center: CGPoint(x: s.width / 2, y: s.height / 2), radius: s.width * 0.4)
        },
        SuperFGTemplate(id: "start", name: L("Bắt đầu"), motion: .rise, defaultLines: ["GAME", "STARTS"], defaultAccent: "#7A3CF0") { g, s, a in
            linear(g, [UIColor(hex: "#2B3FD8"), a], from: CGPoint(x: 0, y: s.height), to: CGPoint(x: s.width, y: 0))
            poly(g, [CGPoint(x: s.width * 0.18, y: s.height * 0.25), CGPoint(x: s.width * 0.86, y: s.height * 0.1),
                     CGPoint(x: s.width * 0.8, y: s.height * 0.9), CGPoint(x: s.width * 0.12, y: s.height * 0.8)], UIColor(white: 1, alpha: 0.10))
            poly(g, [CGPoint(x: 0, y: s.height * 0.7), CGPoint(x: s.width, y: s.height * 0.55),
                     CGPoint(x: s.width, y: s.height), CGPoint(x: 0, y: s.height)], UIColor(white: 0, alpha: 0.18))
            let k = s.height / 1080
            g.setStrokeColor(UIColor(hex: "#9FE8FF").withAlphaComponent(0.7).cgColor); g.setLineWidth(4 * k)
            g.move(to: CGPoint(x: 0, y: s.height * 0.86)); g.addCurve(to: CGPoint(x: s.width, y: s.height * 0.78),
                control1: CGPoint(x: s.width * 0.3, y: s.height * 0.7), control2: CGPoint(x: s.width * 0.7, y: s.height * 0.95)); g.strokePath()
        },
        SuperFGTemplate(id: "stream", name: L("Sắp phát sóng"), motion: .blinds, defaultLines: ["STREAM", "STARTING"], defaultAccent: "#5E8FE6") { g, s, a in
            UIColor(hex: "#2C4A86").setFill(); g.fill(CGRect(origin: .zero, size: s))
            poly(g, [CGPoint(x: 0, y: s.height * 0.05), CGPoint(x: s.width, y: s.height * 0.3), CGPoint(x: 0, y: s.height * 0.62)], a)
            poly(g, [CGPoint(x: s.width, y: s.height * 0.3), CGPoint(x: 0, y: s.height * 0.62), CGPoint(x: s.width, y: s.height * 0.8)],
                 a.withAlphaComponent(0.75))
            poly(g, [CGPoint(x: 0, y: s.height * 0.62), CGPoint(x: s.width, y: s.height * 0.8), CGPoint(x: s.width, y: s.height), CGPoint(x: 0, y: s.height)],
                 UIColor(hex: "#BFD3F5"))
        },
        SuperFGTemplate(id: "onair", name: L("Lên sóng"), motion: .flash, defaultLines: ["ON AIR"], defaultAccent: "#EC4D8F", look: .gradient) { g, s, a in
            UIColor.black.setFill(); g.fill(CGRect(origin: .zero, size: s))
            let c = CGPoint(x: s.width / 2, y: s.height / 2)
            for i in 0..<36 {
                let ang = CGFloat(i) / 36 * .pi * 2, w: CGFloat = 0.035
                poly(g, [c, CGPoint(x: c.x + cos(ang - w) * s.width, y: c.y + sin(ang - w) * s.width),
                         CGPoint(x: c.x + cos(ang + w) * s.width, y: c.y + sin(ang + w) * s.width)],
                     a.withAlphaComponent(i % 2 == 0 ? 0.20 : 0.07))
            }
            radial(g, [UIColor.black.withAlphaComponent(0), UIColor.black.withAlphaComponent(0.85)], center: c, radius: s.width * 0.6)
        },
        SuperFGTemplate(id: "itsonair", name: L("Đang lên sóng"), motion: .iris, defaultLines: ["IT'S", "ON AIR"], defaultAccent: "#8B5CF6", look: .gradient) { g, s, a in
            UIColor(hex: "#07060D").setFill(); g.fill(CGRect(origin: .zero, size: s))
            let c = CGPoint(x: s.width / 2, y: s.height * 0.55)
            for i in 0..<48 {
                let ang = CGFloat(i) / 48 * .pi * 2, w: CGFloat = i % 3 == 0 ? 0.02 : 0.008
                poly(g, [c, CGPoint(x: c.x + cos(ang - w) * s.width, y: c.y + sin(ang - w) * s.width),
                         CGPoint(x: c.x + cos(ang + w) * s.width, y: c.y + sin(ang + w) * s.width)],
                     UIColor(white: 1, alpha: i % 3 == 0 ? 0.10 : 0.05))
            }
            radial(g, [a.withAlphaComponent(0.35), a.withAlphaComponent(0)], center: c, radius: s.width * 0.35)
            radial(g, [UIColor.black.withAlphaComponent(0), UIColor.black.withAlphaComponent(0.8)], center: c, radius: s.width * 0.65)
        },
        SuperFGTemplate(id: "goal", name: L("Bàn thắng"), motion: .zoom, defaultLines: ["GOAL!"], defaultAccent: "#E0782A") { g, s, a in
            navyPanels(g, s, seed: 3); goldStripe(g, s, x: s.width * 0.08, accent: a)
        },
        SuperFGTemplate(id: "replay", name: L("Phát lại"), motion: .splitH, defaultLines: ["REPLAY"], defaultAccent: "#E0782A") { g, s, a in
            navyPanels(g, s, seed: 11); goldStripe(g, s, x: s.width * 0.45, accent: a)
            poly(g, [CGPoint(x: s.width * 0.82, y: s.height), CGPoint(x: s.width * 0.86, y: s.height * 0.9), CGPoint(x: s.width * 0.9, y: s.height)],
                 UIColor(hex: "#2BB3A3"))
        },
        SuperFGTemplate(id: "break", name: L("Giải lao"), motion: .drop, defaultLines: ["GIẢI LAO"], defaultAccent: "#F2B233") { g, s, a in
            navyPanels(g, s, seed: 29)
            poly(g, [CGPoint(x: s.width, y: s.height * 0.78), CGPoint(x: s.width, y: s.height), CGPoint(x: s.width * 0.94, y: s.height)], a)
            poly(g, [CGPoint(x: 0, y: 0), CGPoint(x: s.width * 0.05, y: 0), CGPoint(x: 0, y: s.height * 0.12)], a)
        },
        SuperFGTemplate(id: "thanks", name: L("Cảm ơn"), motion: .fade, defaultLines: ["CẢM ƠN", "ĐÃ THEO DÕI"], defaultAccent: "#1FA88E", look: .gold) { g, s, a in
            linear(g, [UIColor(hex: "#0C2A2E"), a.withAlphaComponent(1)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: s.width, y: s.height))
            let r = rng(42), k = s.height / 1080
            for _ in 0..<14 {
                radial(g, [UIColor(white: 1, alpha: 0.10 + r() * 0.1), UIColor(white: 1, alpha: 0)],
                       center: CGPoint(x: r() * s.width, y: r() * s.height), radius: (40 + r() * 160) * k)
            }
        }
    ] }
}

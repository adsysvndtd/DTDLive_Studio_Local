import AVFoundation
import UIKit

/// Scoreboard look, shared with the DTDLive camera app: two team panels (name + sub line on a team-colour
/// bar, optional logo), a trapezoid score box in the middle and the match clock underneath; or a compact
/// two-row corner version. Team names / scores / period live on the TitleItem (line1, line2, scoreA,
/// scoreB, period) so the web remote, OSC and HTTP API keep working.
struct ScoreboardData: Codable, Equatable {
    var homeSub = ""
    var awaySub = ""
    var homeLogo: String? = nil   // file name in Documents/Scoreboard
    var awayLogo: String? = nil
    var homeColor = "#E8641E"     // bar under the home name
    var awayColor = "#E8641E"
    var centerColor = "#D21E2B"   // centre score box
    var nameBg = "#F2F2F2"
    var nameText = "#111111"
    var showClock = true
    var countDown = false
    var clockLimitSec = 45 * 60
    var clockBase: Double = 0     // seconds run before the last start
    var clockStart: Date? = nil   // non-nil: running
    var compact = false           // two-row corner layout instead of the wide strip
    var style = ScoreboardStyle.classic.rawValue   // look of the wide strip
    var banner = "LIVE MATCH DAY"                   // ribbon under the centre (broadcast styles)

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = ScoreboardData()
        func v<T: Decodable>(_ k: CodingKeys, _ dv: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? dv }
        homeSub = v(.homeSub, z.homeSub); awaySub = v(.awaySub, z.awaySub)
        homeLogo = v(.homeLogo, z.homeLogo); awayLogo = v(.awayLogo, z.awayLogo)
        homeColor = v(.homeColor, z.homeColor); awayColor = v(.awayColor, z.awayColor)
        centerColor = v(.centerColor, z.centerColor); nameBg = v(.nameBg, z.nameBg); nameText = v(.nameText, z.nameText)
        showClock = v(.showClock, z.showClock); countDown = v(.countDown, z.countDown)
        clockLimitSec = v(.clockLimitSec, z.clockLimitSec); clockBase = v(.clockBase, z.clockBase); clockStart = v(.clockStart, z.clockStart)
        compact = v(.compact, z.compact)
        style = v(.style, z.style); banner = v(.banner, z.banner)
    }
    enum CodingKeys: String, CodingKey {
        case homeSub, awaySub, homeLogo, awayLogo, homeColor, awayColor, centerColor, nameBg, nameText
        case showClock, countDown, clockLimitSec, clockBase, clockStart, compact, style, banner
    }
    var look: ScoreboardStyle { ScoreboardStyle(rawValue: style) ?? .classic }

    var running: Bool { clockStart != nil }
    func elapsed(_ now: Date = Date()) -> Double { clockBase + (clockStart.map { now.timeIntervalSince($0) } ?? 0) }
    func clockText(_ now: Date = Date()) -> String {
        var s = Int(elapsed(now))
        if countDown { s = max(0, clockLimitSec - s) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
    mutating func toggleClock() {
        if let st = clockStart { clockBase += Date().timeIntervalSince(st); clockStart = nil } else { clockStart = Date() }
    }
    mutating func resetClock() { clockBase = 0; clockStart = nil }
}

/// Wide-strip looks. `classic` is the DTDLive design; the others are broadcast bars
/// (chrome rim, centre glass with the clock, ribbon underneath) — original vector designs.
enum ScoreboardStyle: String, CaseIterable, Identifiable, Codable {
    case classic, chrome, flame, angular, arena
    var id: String { rawValue }
    var label: String {
        switch self {
        case .classic: return L("Cổ điển")
        case .chrome: return L("Chrome xanh")
        case .flame: return L("Lửa đỏ")
        case .angular: return L("Vát góc")
        case .arena: return L("Sân vận động")
        }
    }
    /// Default colours applied when the style is picked: home, away, centre/ribbon.
    var palette: (String, String, String) {
        switch self {
        case .classic: return ("#E8641E", "#E8641E", "#D21E2B")
        case .chrome: return ("#1E4E9C", "#1E4E9C", "#123A7A")
        case .flame: return ("#D8331A", "#D8331A", "#F01E1E")
        case .angular: return ("#9C2A6E", "#9C2A6E", "#1F4FA8")
        case .arena: return ("#1B4F86", "#1B4F86", "#1A5A9E")
        }
    }
}

extension TitleItem {
    /// Scoreboard settings (created on first use; old saved titles have none).
    var sb: ScoreboardData {
        get { board ?? ScoreboardData() }
        set { board = newValue }
    }

    /// Swap teams: names, scores, logos, sub lines and colours.
    mutating func swapScoreboardSides() {
        swap(&line1, &line2); swap(&scoreA, &scoreB)
        var b = sb
        swap(&b.homeLogo, &b.awayLogo); swap(&b.homeSub, &b.awaySub); swap(&b.homeColor, &b.awayColor)
        sb = b
    }
}

/// Team logos picked for the scoreboard (Documents/Scoreboard/<uuid>.png).
enum ScoreboardLogos {
    static var directory: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Scoreboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func save(_ data: Data) -> String? {
        guard let img = UIImage(data: data) else { return nil }
        // keep logos small: 256 px is plenty for a 118 px tall slot at 1080p
        let maxSide: CGFloat = 256, s = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * s, height: img.size.height * s)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        let png = UIGraphicsImageRenderer(size: size, format: fmt).pngData { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        let name = UUID().uuidString + ".png"
        do { try png.write(to: directory.appendingPathComponent(name)); return name } catch { return nil }
    }
    private static let cache = NSCache<NSString, UIImage>()
    static func image(_ name: String?) -> UIImage? {
        guard let name else { return nil }
        if let c = cache.object(forKey: name as NSString) { return c }
        guard let img = UIImage(contentsOfFile: directory.appendingPathComponent(name).path) else { return nil }
        cache.setObject(img, forKey: name as NSString)
        return img
    }
}

enum ScoreboardRenderer {
    /// Drawn at these sizes and scaled to the program (1600 px ≈ 83 % of a 1920 px frame at scale 1).
    static let wideSize = CGSize(width: 1600, height: 250)
    static let compactSize = CGSize(width: 640, height: 232)
    static func size(compact: Bool) -> CGSize { compact ? compactSize : wideSize }

    /// Small sample picture of a style for the style picker (cached).
    private static var previews: [ScoreboardStyle: UIImage] = [:]
    static func preview(_ st: ScoreboardStyle) -> UIImage {
        if let p = previews[st] { return p }
        var t = TitleItem(style: .scoreBug, line1: "HOME", line2: "AWAY", scoreA: 2, scoreB: 1, period: "H2")
        var b = ScoreboardData(); b.style = st.rawValue
        (b.homeColor, b.awayColor, b.centerColor) = st.palette
        b.clockBase = 23 * 60 + 45
        t.board = b
        let img = render(t)
        previews[st] = img
        return img
    }

    /// Changes whenever the drawn picture would change (scores, names, clock seconds, colours…).
    static func signature(_ t: TitleItem, now: Date = Date()) -> String {
        let b = t.sb
        return [t.line1, t.line2, b.homeSub, b.awaySub, "\(t.scoreA)", "\(t.scoreB)", b.homeLogo ?? "", b.awayLogo ?? "",
                b.homeColor, b.awayColor, b.centerColor, b.nameBg, b.nameText, t.period, b.showClock ? b.clockText(now) : "",
                b.compact ? "c" : "w", b.style, b.banner].joined(separator: "|")
    }

    static func render(_ t: TitleItem, now: Date = Date()) -> UIImage {
        let b = t.sb
        if b.compact { return renderCompact(t, b, now: now) }
        if b.look != .classic { return renderBroadcast(t, b, now: now) }
        let size = wideSize
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let g = ctx.cgContext
            let W = size.width
            let barTop: CGFloat = 70, nameH: CGFloat = 78, subH: CGFloat = 40
            let centerW: CGFloat = 380, centerTop: CGFloat = 40, centerH: CGFloat = 150
            let panelW: CGFloat = 520
            let cx = W / 2
            let leftX = cx - centerW / 2 - panelW + 40
            let rightX = cx + centerW / 2 - 40
            let nameBg = UIColor(hex: b.nameBg)
            let nameFg = UIColor(hex: b.nameText)
            let shadow = UIColor.black.withAlphaComponent(0.45).cgColor

            g.setShadow(offset: CGSize(width: 0, height: 6), blur: 14, color: shadow)

            // decorative slats at both ends
            for (x, flip) in [(leftX - 120, false), (rightX + panelW + 10, true)] {
                for k in 0..<2 {
                    let w: CGFloat = k == 0 ? 70 : 40, off: CGFloat = k == 0 ? 0 : (flip ? 80 : -50)
                    let p = parallelogram(x: x + off + (flip ? 0 : 40), y: barTop + 8, w: w, h: 50, slant: flip ? -22 : 22)
                    UIColor(white: 0.82, alpha: 0.95).setFill(); p.fill()
                }
            }

            func panel(x: CGFloat, right: Bool, name: String, sub: String, color: UIColor, logoImg: UIImage?) {
                let slant: CGFloat = right ? -26 : 26
                gradientFill(g, parallelogram(x: x, y: barTop, w: panelW, h: nameH, slant: slant), nameBg.lighter(0.08), nameBg.darker(0.10))
                gradientFill(g, parallelogram(x: x, y: barTop + nameH, w: panelW, h: subH, slant: slant), color.lighter(0.08), color.darker(0.12))
                g.setShadow(offset: .zero, blur: 0, color: nil)
                let logoSize = nameH + subH + 16
                let logoX = right ? x + panelW - 44 - logoSize : x + 44
                let logoRect = CGRect(x: logoX, y: barTop - 8, width: logoSize, height: logoSize)
                let para = NSMutableParagraphStyle()
                para.alignment = right ? .right : .left
                para.lineBreakMode = .byTruncatingTail
                let nameFont = UIFont.systemFont(ofSize: 44, weight: .heavy)
                let textLeft = right ? x + 88 : (logoImg != nil ? logoRect.maxX + 18 : x + 44)
                let textRight = right ? (logoImg != nil ? logoRect.minX - 18 : x + panelW - 44) : x + panelW - 88
                let nameRect = CGRect(x: textLeft, y: barTop + (nameH - nameFont.lineHeight) / 2,
                                      width: max(0, textRight - textLeft), height: nameFont.lineHeight)
                (name.uppercased() as NSString).draw(in: nameRect, withAttributes: [.font: nameFont, .foregroundColor: nameFg, .paragraphStyle: para])
                if !sub.isEmpty {
                    let subFont = UIFont.systemFont(ofSize: 26, weight: .semibold)
                    let subRect = CGRect(x: nameRect.minX, y: barTop + nameH + (subH - subFont.lineHeight) / 2,
                                         width: nameRect.width, height: subFont.lineHeight)
                    (sub.uppercased() as NSString).draw(in: subRect, withAttributes: [.font: subFont, .foregroundColor: UIColor.white, .paragraphStyle: para])
                }
                if let logoImg { logoImg.draw(in: AVMakeRect(aspectRatio: logoImg.size, insideRect: logoRect)) }
                g.setShadow(offset: CGSize(width: 0, height: 6), blur: 14, color: shadow)
            }
            panel(x: leftX, right: false, name: t.line1, sub: b.homeSub, color: UIColor(hex: b.homeColor), logoImg: ScoreboardLogos.image(b.homeLogo))
            panel(x: rightX, right: true, name: t.line2, sub: b.awaySub, color: UIColor(hex: b.awayColor), logoImg: ScoreboardLogos.image(b.awayLogo))

            // trapezoid score box (wide top, narrow bottom) with a light rim
            let center = UIBezierPath()
            center.move(to: CGPoint(x: cx - centerW / 2 - 30, y: centerTop))
            center.addLine(to: CGPoint(x: cx + centerW / 2 + 30, y: centerTop))
            center.addLine(to: CGPoint(x: cx + centerW / 2 - 40, y: centerTop + centerH))
            center.addLine(to: CGPoint(x: cx - centerW / 2 + 40, y: centerTop + centerH))
            center.close()
            let cc = UIColor(hex: b.centerColor)
            gradientFill(g, center, cc.lighter(0.18), cc.darker(0.22))
            g.setShadow(offset: .zero, blur: 0, color: nil)
            g.saveGState()
            center.addClip()
            UIColor.white.withAlphaComponent(0.14).setFill()
            UIRectFill(CGRect(x: 0, y: centerTop, width: W, height: centerH * 0.45))
            g.restoreGState()
            UIColor.white.withAlphaComponent(0.55).setStroke()
            center.lineWidth = 3
            center.stroke()

            let scoreFont = UIFont.monospacedDigitSystemFont(ofSize: 92, weight: .heavy)
            let scorePara = NSMutableParagraphStyle(); scorePara.alignment = .center
            ("\(t.scoreA) - \(t.scoreB)" as NSString).draw(
                in: CGRect(x: cx - centerW / 2, y: centerTop + (centerH - scoreFont.lineHeight) / 2 - (t.period.isEmpty ? 0 : 10),
                           width: centerW, height: scoreFont.lineHeight),
                withAttributes: [.font: scoreFont, .foregroundColor: UIColor.white, .paragraphStyle: scorePara])
            if !t.period.isEmpty {
                let pf = UIFont.systemFont(ofSize: 24, weight: .bold)
                (t.period.uppercased() as NSString).draw(
                    in: CGRect(x: cx - centerW / 2, y: centerTop + centerH - pf.lineHeight - 10, width: centerW, height: pf.lineHeight),
                    withAttributes: [.font: pf, .foregroundColor: UIColor.white.withAlphaComponent(0.9), .paragraphStyle: scorePara])
            }

            if b.showClock {
                let cw: CGFloat = 170, ch: CGFloat = 44, cy = centerTop + centerH - 6
                let clock = UIBezierPath()
                clock.move(to: CGPoint(x: cx - cw / 2, y: cy))
                clock.addLine(to: CGPoint(x: cx + cw / 2, y: cy))
                clock.addLine(to: CGPoint(x: cx + cw / 2 - 14, y: cy + ch))
                clock.addLine(to: CGPoint(x: cx - cw / 2 + 14, y: cy + ch))
                clock.close()
                let hc = UIColor(hex: b.homeColor)
                gradientFill(g, clock, hc.lighter(0.1), hc.darker(0.15))
                let cf = UIFont.monospacedDigitSystemFont(ofSize: 32, weight: .bold)
                (b.clockText(now) as NSString).draw(in: CGRect(x: cx - cw / 2, y: cy + (ch - cf.lineHeight) / 2, width: cw, height: cf.lineHeight),
                                                    withAttributes: [.font: cf, .foregroundColor: UIColor.white, .paragraphStyle: scorePara])
            }
        }
    }

    /// Corner layout: two rows [team colour | logo | name | score], then period + clock.
    private static func renderCompact(_ t: TitleItem, _ b: ScoreboardData, now: Date) -> UIImage {
        let S = compactSize
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: S, format: fmt).image { ctx in
            let g = ctx.cgContext
            let rowH: CGFloat = 84, gap: CGFloat = 4, top: CGFloat = 8
            let scoreW: CGFloat = 132, strip: CGFloat = 14
            let nameBg = UIColor(hex: b.nameBg)
            let nameFg = UIColor(hex: b.nameText)
            let center = UIColor(hex: b.centerColor)
            let shadow = UIColor.black.withAlphaComponent(0.45).cgColor
            g.setShadow(offset: CGSize(width: 0, height: 4), blur: 10, color: shadow)
            func row(_ y: CGFloat, name: String, score: Int, color: UIColor, logoImg: UIImage?) {
                gradientFill(g, UIBezierPath(rect: CGRect(x: strip, y: y, width: S.width - strip - scoreW, height: rowH)),
                             nameBg.lighter(0.08), nameBg.darker(0.10))
                gradientFill(g, UIBezierPath(rect: CGRect(x: 0, y: y, width: strip, height: rowH)), color.lighter(0.1), color.darker(0.15))
                gradientFill(g, UIBezierPath(rect: CGRect(x: S.width - scoreW, y: y, width: scoreW, height: rowH)),
                             center.lighter(0.15), center.darker(0.2))
                g.setShadow(offset: .zero, blur: 0, color: nil)
                var textX = strip + 18
                if let logoImg {
                    let lr = CGRect(x: 0, y: y, width: rowH, height: rowH)
                    logoImg.draw(in: AVMakeRect(aspectRatio: logoImg.size, insideRect: lr))
                    textX = lr.maxX + 14
                }
                let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
                let nf = UIFont.systemFont(ofSize: 40, weight: .heavy)
                (name.uppercased() as NSString).draw(in: CGRect(x: textX, y: y + (rowH - nf.lineHeight) / 2, width: S.width - scoreW - textX - 10, height: nf.lineHeight),
                                                     withAttributes: [.font: nf, .foregroundColor: nameFg, .paragraphStyle: para])
                let sf = UIFont.monospacedDigitSystemFont(ofSize: 58, weight: .heavy)
                let cp = NSMutableParagraphStyle(); cp.alignment = .center
                ("\(score)" as NSString).draw(in: CGRect(x: S.width - scoreW, y: y + (rowH - sf.lineHeight) / 2, width: scoreW, height: sf.lineHeight),
                                              withAttributes: [.font: sf, .foregroundColor: UIColor.white, .paragraphStyle: cp])
                g.setShadow(offset: CGSize(width: 0, height: 4), blur: 10, color: shadow)
            }
            row(top, name: t.line1, score: t.scoreA, color: UIColor(hex: b.homeColor), logoImg: ScoreboardLogos.image(b.homeLogo))
            row(top + rowH + gap, name: t.line2, score: t.scoreB, color: UIColor(hex: b.awayColor), logoImg: ScoreboardLogos.image(b.awayLogo))
            let info = [t.period.uppercased(), b.showClock ? b.clockText(now) : ""].filter { !$0.isEmpty }.joined(separator: "   ")
            if !info.isEmpty {
                let y = top + 2 * rowH + gap + 4
                gradientFill(g, UIBezierPath(rect: CGRect(x: 0, y: y, width: S.width, height: S.height - y - 2)),
                             UIColor(white: 0.12, alpha: 0.92), UIColor(white: 0.04, alpha: 0.92))
                g.setShadow(offset: .zero, blur: 0, color: nil)
                let f = UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .bold)
                let cp = NSMutableParagraphStyle(); cp.alignment = .center
                (info as NSString).draw(in: CGRect(x: 0, y: y + (S.height - y - 2 - f.lineHeight) / 2, width: S.width, height: f.lineHeight),
                                        withAttributes: [.font: f, .foregroundColor: UIColor.white, .paragraphStyle: cp])
            }
        }
    }

    /// Broadcast bars: [team | score] [centre glass + clock] [score | team], chrome rim, ribbon below.
    private static func renderBroadcast(_ t: TitleItem, _ b: ScoreboardData, now: Date) -> UIImage {
        let S = wideSize
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        let look = b.look
        return UIGraphicsImageRenderer(size: S, format: fmt).image { ctx in
            let g = ctx.cgContext
            let W = S.width, cx = W / 2
            let top: CGFloat = 46, h: CGFloat = 104, rim: CGFloat = 10
            let x0: CGFloat = 40, x1 = W - 40
            let glassW: CGFloat = 300, glassTop: CGFloat = 26, glassH: CGFloat = 136
            let scoreW: CGFloat = 120
            let home = UIColor(hex: b.homeColor), away = UIColor(hex: b.awayColor), accent = UIColor(hex: b.centerColor)
            let shadow = UIColor.black.withAlphaComponent(0.45).cgColor
            let center = NSMutableParagraphStyle(); center.alignment = .center

            // 1) outer body (chrome rim) by style
            let outer = CGRect(x: x0, y: top, width: x1 - x0, height: h)
            let body: UIBezierPath
            switch look {
            case .arena: body = UIBezierPath(roundedRect: outer, cornerRadius: h / 2)
            case .angular: body = parallelogramBar(outer, cut: 46)
            case .flame: body = UIBezierPath(rect: outer)
            default: body = chamferBar(outer, cut: 40)
            }
            g.setShadow(offset: CGSize(width: 0, height: 8), blur: 18, color: shadow)
            metalFill(g, body)
            g.setShadow(offset: .zero, blur: 0, color: nil)

            // 2) inner team panels in team colours (glossy)
            let inner = outer.insetBy(dx: rim + 18, dy: rim)
            let leftR = CGRect(x: inner.minX, y: inner.minY, width: cx - glassW / 2 - inner.minX - 6, height: inner.height)
            let rightR = CGRect(x: cx + glassW / 2 + 6, y: inner.minY, width: inner.maxX - cx - glassW / 2 - 6, height: inner.height)
            func panelPath(_ r: CGRect, right: Bool) -> UIBezierPath {
                switch look {
                case .arena: return UIBezierPath(roundedRect: r, byRoundingCorners: right ? [.topRight, .bottomRight] : [.topLeft, .bottomLeft],
                                                 cornerRadii: CGSize(width: r.height / 2, height: r.height / 2))
                case .angular: return parallelogram(x: r.minX, y: r.minY, w: r.width, h: r.height, slant: right ? -30 : 30)
                default: return UIBezierPath(rect: r)
                }
            }
            for (r, c, right) in [(leftR, home, false), (rightR, away, true)] {
                let p = panelPath(r, right: right)
                glossFill(g, p, c)
            }

            // 3) score boxes: inner (next to the glass) or outer (at the ends) by style
            let outerScores = look == .flame || look == .angular
            let sA: CGRect, sB: CGRect
            if outerScores {
                sA = CGRect(x: leftR.minX, y: leftR.minY, width: scoreW, height: leftR.height)
                sB = CGRect(x: rightR.maxX - scoreW, y: rightR.minY, width: scoreW, height: rightR.height)
            } else {
                sA = CGRect(x: leftR.maxX - scoreW, y: leftR.minY - 8, width: scoreW, height: leftR.height + 16)
                sB = CGRect(x: rightR.minX, y: rightR.minY - 8, width: scoreW, height: rightR.height + 16)
            }
            let scoreFont = UIFont.monospacedDigitSystemFont(ofSize: 80, weight: .heavy)
            for (r, v, c) in [(sA, t.scoreA, home), (sB, t.scoreB, away)] {
                let light = look == .angular
                let p: UIBezierPath = look == .arena ? UIBezierPath(roundedRect: r, cornerRadius: 18)
                    : look == .angular ? parallelogram(x: r.minX, y: r.minY, w: r.width, h: r.height, slant: r.minX < cx ? 24 : -24)
                    : UIBezierPath(rect: r)
                if light { gradientFill(g, p, UIColor(white: 0.97, alpha: 1), UIColor(white: 0.78, alpha: 1)) }
                else if look == .flame { gradientFill(g, p, c.darker(0.25), c.darker(0.55)) }
                else { gradientFill(g, p, UIColor(white: 0.96, alpha: 1), UIColor(white: 0.70, alpha: 1)) }
                let fg: UIColor = look == .flame ? .white : UIColor(white: 0.06, alpha: 1)
                ("\(v)" as NSString).draw(in: CGRect(x: r.minX, y: r.midY - scoreFont.lineHeight / 2, width: r.width, height: scoreFont.lineHeight),
                                          withAttributes: [.font: scoreFont, .foregroundColor: fg, .paragraphStyle: center])
            }

            // 4) team names (+ logos) between score box and the ends
            let nameFont = UIFont.systemFont(ofSize: 46, weight: .heavy)
            let nameShadow = NSShadow(); nameShadow.shadowColor = UIColor.black.withAlphaComponent(0.5); nameShadow.shadowOffset = CGSize(width: 0, height: 2); nameShadow.shadowBlurRadius = 3
            func team(_ name: String, _ sub: String, _ logo: UIImage?, in area: CGRect) {
                var a = area.insetBy(dx: 20, dy: 0)
                if let logo {
                    let lr = CGRect(x: a.minX, y: area.midY - 40, width: 80, height: 80)
                    logo.draw(in: AVMakeRect(aspectRatio: logo.size, insideRect: lr))
                    a = CGRect(x: lr.maxX + 12, y: a.minY, width: a.maxX - lr.maxX - 12, height: a.height)
                }
                let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byTruncatingTail
                let y = sub.isEmpty ? area.midY - nameFont.lineHeight / 2 : area.midY - nameFont.lineHeight / 2 - 12
                (name.uppercased() as NSString).draw(in: CGRect(x: a.minX, y: y, width: a.width, height: nameFont.lineHeight),
                    withAttributes: [.font: nameFont, .foregroundColor: UIColor.white, .paragraphStyle: p, .shadow: nameShadow])
                if !sub.isEmpty {
                    let sf = UIFont.systemFont(ofSize: 22, weight: .semibold)
                    (sub.uppercased() as NSString).draw(in: CGRect(x: a.minX, y: y + nameFont.lineHeight - 4, width: a.width, height: sf.lineHeight),
                        withAttributes: [.font: sf, .foregroundColor: UIColor.white.withAlphaComponent(0.85), .paragraphStyle: p])
                }
            }
            let nameA = outerScores ? CGRect(x: sA.maxX, y: leftR.minY, width: leftR.maxX - sA.maxX, height: leftR.height)
                                    : CGRect(x: leftR.minX, y: leftR.minY, width: sA.minX - leftR.minX, height: leftR.height)
            let nameB = outerScores ? CGRect(x: rightR.minX, y: rightR.minY, width: sB.minX - rightR.minX, height: rightR.height)
                                    : CGRect(x: sB.maxX, y: rightR.minY, width: rightR.maxX - sB.maxX, height: rightR.height)
            team(t.line1, b.homeSub, ScoreboardLogos.image(b.homeLogo), in: nameA)
            team(t.line2, b.awaySub, ScoreboardLogos.image(b.awayLogo), in: nameB)

            // 5) ribbon under the centre: starts under the bar, text sits below the glass (the glass overlaps its top)
            if !b.banner.isEmpty {
                let rw: CGFloat = 680
                let glassBottom = glassTop + glassH
                let rr = CGRect(x: cx - rw / 2, y: top + h - 4, width: rw, height: glassBottom + 44 - (top + h - 4))
                let rp = UIBezierPath(roundedRect: rr, byRoundingCorners: [.bottomLeft, .bottomRight], cornerRadii: CGSize(width: 18, height: 18))
                g.setShadow(offset: CGSize(width: 0, height: 4), blur: 8, color: shadow)
                gradientFill(g, rp, accent.lighter(0.12), accent.darker(0.25))
                g.setShadow(offset: .zero, blur: 0, color: nil)
                UIColor.white.withAlphaComponent(0.5).setStroke(); rp.lineWidth = 2; rp.stroke()
                let bf = UIFont.systemFont(ofSize: 25, weight: .bold)
                let ty = glassBottom + (rr.maxY - glassBottom - bf.lineHeight) / 2
                (b.banner.uppercased() as NSString).draw(in: CGRect(x: rr.minX, y: ty, width: rw, height: bf.lineHeight),
                    withAttributes: [.font: bf, .foregroundColor: UIColor.white, .paragraphStyle: center, .kern: 1.5])
            }

            // 6) centre glass: clock + period
            let gr = CGRect(x: cx - glassW / 2, y: glassTop, width: glassW, height: glassH)
            let gp: UIBezierPath
            switch look {
            case .flame, .angular:
                gp = UIBezierPath()
                gp.move(to: CGPoint(x: gr.minX, y: gr.minY)); gp.addLine(to: CGPoint(x: gr.maxX, y: gr.minY))
                gp.addLine(to: CGPoint(x: gr.maxX - 34, y: gr.maxY)); gp.addLine(to: CGPoint(x: gr.minX + 34, y: gr.maxY)); gp.close()
            default:
                gp = UIBezierPath(roundedRect: gr, byRoundingCorners: [.bottomLeft, .bottomRight], cornerRadii: CGSize(width: 26, height: 26))
            }
            g.setShadow(offset: CGSize(width: 0, height: 6), blur: 14, color: shadow)
            metalFill(g, gp)
            g.setShadow(offset: .zero, blur: 0, color: nil)
            let glass = gr.insetBy(dx: 12, dy: 10)
            let glp: UIBezierPath = (look == .flame || look == .angular)
                ? { let p = UIBezierPath()
                    p.move(to: CGPoint(x: glass.minX + 4, y: glass.minY)); p.addLine(to: CGPoint(x: glass.maxX - 4, y: glass.minY))
                    p.addLine(to: CGPoint(x: glass.maxX - 30, y: glass.maxY)); p.addLine(to: CGPoint(x: glass.minX + 30, y: glass.maxY)); p.close(); return p }()
                : UIBezierPath(roundedRect: glass, byRoundingCorners: [.bottomLeft, .bottomRight], cornerRadii: CGSize(width: 18, height: 18))
            let gc: UIColor = look == .flame ? UIColor(white: 0.85, alpha: 1) : accent
            glossFill(g, glp, gc)
            let darkText = look == .flame
            if b.showClock {
                let cf = UIFont.monospacedDigitSystemFont(ofSize: 62, weight: .heavy)
                (b.clockText(now) as NSString).draw(in: CGRect(x: glass.minX, y: glass.midY - cf.lineHeight / 2 - (t.period.isEmpty ? 0 : 12),
                                                               width: glass.width, height: cf.lineHeight),
                    withAttributes: [.font: cf, .foregroundColor: darkText ? UIColor(white: 0.08, alpha: 1) : UIColor.white, .paragraphStyle: center])
            }
            if !t.period.isEmpty {
                let pf = UIFont.systemFont(ofSize: 24, weight: .bold)
                let y = b.showClock ? glass.maxY - pf.lineHeight - 6 : glass.midY - pf.lineHeight / 2
                (t.period.uppercased() as NSString).draw(in: CGRect(x: glass.minX, y: y, width: glass.width, height: pf.lineHeight),
                    withAttributes: [.font: pf, .foregroundColor: darkText ? UIColor(white: 0.15, alpha: 1) : UIColor.white.withAlphaComponent(0.9), .paragraphStyle: center])
            }
        }
    }

    /// Bar with 45° cut corners.
    private static func chamferBar(_ r: CGRect, cut c: CGFloat) -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY + c)); p.close()
        return p
    }

    /// Bar whose ends slant outwards at the top.
    private static func parallelogramBar(_ r: CGRect, cut c: CGFloat) -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY)); p.close()
        return p
    }

    /// Brushed-chrome fill (vertical multi-stop gradient) with a light edge.
    private static func metalFill(_ g: CGContext, _ path: UIBezierPath) {
        g.saveGState()
        UIColor(white: 0.8, alpha: 1).setFill(); path.fill()
        path.addClip()
        let b = path.bounds
        let cols = [UIColor(white: 0.98, alpha: 1), UIColor(white: 0.72, alpha: 1), UIColor(white: 0.90, alpha: 1), UIColor(white: 0.55, alpha: 1)]
        if let gr = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols.map(\.cgColor) as CFArray, locations: [0, 0.45, 0.55, 1]) {
            g.drawLinearGradient(gr, start: CGPoint(x: b.midX, y: b.minY), end: CGPoint(x: b.midX, y: b.maxY), options: [])
        }
        g.restoreGState()
        UIColor.white.withAlphaComponent(0.7).setStroke(); path.lineWidth = 2; path.stroke()
    }

    /// Team-colour fill with a glossy highlight on the upper half.
    private static func glossFill(_ g: CGContext, _ path: UIBezierPath, _ c: UIColor) {
        gradientFill(g, path, c.lighter(0.22), c.darker(0.35))
        g.saveGState()
        path.addClip()
        let b = path.bounds
        UIColor.white.withAlphaComponent(0.16).setFill()
        UIRectFill(CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height * 0.42))
        g.restoreGState()
    }

    private static func parallelogram(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, slant: CGFloat) -> UIBezierPath {
        let p = UIBezierPath()
        if slant >= 0 {
            p.move(to: CGPoint(x: x + slant, y: y))
            p.addLine(to: CGPoint(x: x + w, y: y))
            p.addLine(to: CGPoint(x: x + w, y: y + h))
            p.addLine(to: CGPoint(x: x, y: y + h))
        } else {
            p.move(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x + w + slant, y: y))
            p.addLine(to: CGPoint(x: x + w, y: y + h))
            p.addLine(to: CGPoint(x: x, y: y + h))
        }
        p.close()
        return p
    }

    private static func gradientFill(_ g: CGContext, _ path: UIBezierPath, _ top: UIColor, _ bottom: UIColor) {
        g.saveGState()
        top.setFill(); path.fill()
        path.addClip()
        let b = path.bounds
        if let gr = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
            g.drawLinearGradient(gr, start: CGPoint(x: b.midX, y: b.minY), end: CGPoint(x: b.midX, y: b.maxY), options: [])
        }
        g.restoreGState()
    }
}

private extension UIColor {
    func lighter(_ k: CGFloat) -> UIColor { blend(.white, k) }
    func darker(_ k: CGFloat) -> UIColor { blend(.black, k) }
    func blend(_ o: UIColor, _ k: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        o.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r + (r2 - r) * k, green: g + (g2 - g) * k, blue: b + (b2 - b) * k, alpha: a)
    }
}

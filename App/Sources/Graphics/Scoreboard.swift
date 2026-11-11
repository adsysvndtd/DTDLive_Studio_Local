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
    }
    enum CodingKeys: String, CodingKey {
        case homeSub, awaySub, homeLogo, awayLogo, homeColor, awayColor, centerColor, nameBg, nameText
        case showClock, countDown, clockLimitSec, clockBase, clockStart, compact
    }

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

    /// Changes whenever the drawn picture would change (scores, names, clock seconds, colours…).
    static func signature(_ t: TitleItem, now: Date = Date()) -> String {
        let b = t.sb
        return [t.line1, t.line2, b.homeSub, b.awaySub, "\(t.scoreA)", "\(t.scoreB)", b.homeLogo ?? "", b.awayLogo ?? "",
                b.homeColor, b.awayColor, b.centerColor, b.nameBg, b.nameText, t.period, b.showClock ? b.clockText(now) : "",
                b.compact ? "c" : "w"].joined(separator: "|")
    }

    static func render(_ t: TitleItem, now: Date = Date()) -> UIImage {
        let b = t.sb
        if b.compact { return renderCompact(t, b, now: now) }
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

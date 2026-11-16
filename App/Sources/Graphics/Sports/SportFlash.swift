//
//  SportFlash.swift
//
//  Overlay sự kiện hiện vài giây trên chương trình khi bảng tỉ số đang lên sóng: bàn thắng, phản lưới,
//  thẻ vàng / đỏ, bảng bù giờ, hội ý, hết hiệp, kết thúc trận (bóng đá); thắng ván / set, đổi sân,
//  game / set / match point (cầu lông, pickleball, bóng chuyền); rack (bi-a)…
//  Mỗi môn có màu, biểu tượng riêng. Không hỏi gì thêm — bấm nút là overlay chạy.
//

import UIKit

struct SportFlash: Equatable {
    enum Kind: String {
        case goal, ownGoal, yellowCard, redCard, addedTime, timeout, periodEnd, final
        case gameWon, switchEnds, pressure, rack, foulLimit, info
    }
    enum Sport: String { case football, badminton, pickleball, volleyball, billiards }

    var id = UUID()
    var kind: Kind
    var sport: Sport
    /// Dòng lớn: VÀO!, THẺ VÀNG, BÙ GIỜ, MATCH POINT…
    var headline: String
    var team: String? = nil
    var colorHex: String? = nil
    /// Dòng phụ: phút, cầu thủ, tỉ số các set…
    var detail: String? = nil
    /// Tỉ số trận "2 – 1".
    var score: String? = nil
    /// Số lớn trong ô biểu tượng (bù giờ "+3").
    var big: String? = nil
    var at: Date
    var duration: TimeInterval = 5

    /// Độ trong suốt / trượt tại thời điểm `now`: nil = đã hết.
    func progress(_ now: Date) -> (alpha: CGFloat, slide: CGFloat)? {
        let age = now.timeIntervalSince(at)
        guard age >= 0, age < duration else { return nil }
        let inA = min(1, age / 0.35), outA = min(1, (duration - age) / 0.45)
        return (CGFloat(min(inA, outA)), CGFloat(1 - inA) - CGFloat(1 - outA))
    }
}

extension SportBoard {
    var lastEvent: ScoreEvent {
        switch self {
        case .pickleball(let e): return e.lastEvent
        case .badminton(let e): return e.lastEvent
        case .volleyball(let e): return e.lastEvent
        case .football(let e): return e.lastEvent
        case .billiards(let e): return e.lastEvent
        }
    }

    var flashSport: SportFlash.Sport {
        switch self {
        case .pickleball: return .pickleball
        case .badminton: return .badminton
        case .volleyball: return .volleyball
        case .football: return .football
        case .billiards: return .billiards
        }
    }

    /// Overlay cho thao tác vừa làm (self = trạng thái sau, `before` = trước). nil = không có gì để hiện.
    func flash(before: SportBoard, lang: ScoreLang, at now: Date) -> SportFlash? {
        let d = display(lang: lang, at: now)
        guard d.rows.count == 2 else { return nil }
        let tm = teams
        let sport = flashSport
        let score = "\(d.rows[0].main) – \(d.rows[1].main)"
        func f(_ kind: SportFlash.Kind, _ headline: String, side: Side? = nil, detail: String? = nil,
               score: String? = nil, big: String? = nil, duration: TimeInterval = 5) -> SportFlash {
            SportFlash(kind: kind, sport: sport, headline: headline, team: side.map { tm[$0].name },
                       colorHex: side.map { tm[$0].colorHex }, detail: detail, score: score, big: big,
                       at: now, duration: duration)
        }
        var minute: String? = nil
        var lastCardRedFromYellows = false
        if case .football(let e) = self {
            switch e.lastEvent {
            case .goal, .ownGoal: minute = e.goalLog.last?.minuteLabel
            case .card:
                minute = e.cards.last?.minuteLabel
                let n = e.cards.count
                lastCardRedFromYellows = n >= 2 && e.cards[n - 1].kind == .red && e.cards[n - 2].kind == .yellow
                    && e.cards[n - 1].minuteLabel == e.cards[n - 2].minuteLabel && e.cards[n - 1].player == e.cards[n - 2].player
                    && e.cards[n - 1].player != "?"
            default: break
            }
            if minute?.isEmpty == true { minute = nil }
        }
        let unitVI = sport == .volleyball ? "SET" : "VÁN", unitEN = sport == .volleyball ? "SET" : "GAME"
        let sets = zip(d.rows[0].columns, d.rows[1].columns).map { "\($0)-\($1)" }.joined(separator: "  ")

        switch lastEvent {
        case .goal(let s):
            return f(.goal, lang.t("VÀO!", "GOAL!"), side: s, detail: minute, score: score, duration: 7)
        case .ownGoal(let s):
            let by = tm[s.other].name
            return f(.ownGoal, lang.t("PHẢN LƯỚI", "OWN GOAL"), side: s,
                     detail: [minute, lang.t("Cầu thủ \(by) đá phản", "Scored by \(by)")].compactMap { $0 }.joined(separator: " · "),
                     score: score, duration: 7)
        case .card(let s, let k):
            if k == .red {
                return f(.redCard, lang.t("THẺ ĐỎ", "RED CARD"), side: s,
                         detail: [minute, lastCardRedFromYellows ? lang.t("Thẻ vàng thứ 2", "Second yellow") : nil]
                            .compactMap { $0 }.joined(separator: " · "), duration: 6)
            }
            return f(.yellowCard, lang.t("THẺ VÀNG", "YELLOW CARD"), side: s, detail: minute)
        case .addedTime(let m):
            return f(.addedTime, lang.t("BÙ GIỜ", "ADDED TIME"), detail: lang.t("PHÚT", "MINUTES"), big: "+\(m)", duration: 6)
        case .timeout(let s):
            return f(.timeout, lang.t("HỘI Ý", "TIMEOUT"), side: s, score: score)
        case .technicalTimeout:
            return f(.timeout, lang.t("TẠM DỪNG KỸ THUẬT", "TECHNICAL TIMEOUT"), score: score)
        case .periodEnded:
            return f(.periodEnd, lang.t("HẾT HIỆP", "END OF PERIOD"), detail: d.period, score: score, duration: 7)
        case .matchWon(let s):
            return f(.final, lang.t("CHIẾN THẮNG", "WINNER"), side: s, detail: sets.isEmpty ? d.period : sets,
                     score: score, duration: 10)
        case .draw:
            return f(.final, lang.t("HÒA", "DRAW"), detail: d.period, score: score, duration: 10)
        case .gameWon(let s):
            return f(.gameWon, lang.t("THẮNG \(unitVI)", "\(unitEN) WON"), side: s, detail: sets.isEmpty ? nil : sets, duration: 6)
        case .switchEnds:
            return f(.switchEnds, lang.t("ĐỔI SÂN", "CHANGE ENDS"), score: score)
        case .interval:
            return f(.switchEnds, lang.t("NGHỈ GIỮA \(unitVI)", "INTERVAL"), detail: d.period, score: score)
        case .rackWon(let s):
            return f(.rack, "RACK", side: s, detail: d.period, score: score, duration: 4)
        case .foulLimit(let s):
            return f(.foulLimit, lang.t("ĐỦ LỖI TÍCH LŨY", "FOUL LIMIT"), side: s,
                     detail: lang.t("Lỗi tiếp theo: đá phạt 10 m", "Next foul: 10 m kick"))
        case .finalInning:
            return f(.info, lang.t("LƯỢT CÂN BẰNG", "EQUALIZING INNING"), score: score)
        case .none, .sideOut, .secondServer:
            // GAME / SET / MATCH POINT: hiện một lần khi vừa xuất hiện
            let co = d.callout ?? ""
            let prev = before.display(lang: lang, at: now).callout ?? ""
            if co.hasSuffix("POINT"), co != prev {
                return f(.pressure, co, score: score, duration: 4)
            }
            return nil
        }
    }
}

extension SportAction {
    /// Thao tác sửa sai (bớt bàn, bớt thẻ…): overlay của sự kiện vừa hiện phải tắt ngay.
    var isCorrection: Bool {
        switch self {
        case .football(let a):
            switch a {
            case .cancelGoal, .removeCard, .cancelFoul: return true
            default: return false
            }
        default: return false
        }
    }
}

// MARK: - Renderer

enum SportFlashRenderer {
    /// Vẽ ở khung 1080p (rộng 1920), compositor phóng theo khung chương trình.
    static let size = CGSize(width: 1180, height: 200)

    static func accent(_ s: SportFlash.Sport) -> UIColor {
        switch s {
        case .football: return UIColor(hex: "#22C55E")
        case .badminton: return UIColor(hex: "#22B8F0")
        case .pickleball: return UIColor(hex: "#C6F432")
        case .volleyball: return UIColor(hex: "#FFB020")
        case .billiards: return UIColor(hex: "#16A36A")
        }
    }

    static func sportSymbol(_ s: SportFlash.Sport) -> String {
        switch s {
        case .football: return "soccerball"
        case .badminton: return "figure.badminton"
        case .pickleball: return "figure.pickleball"
        case .volleyball: return "volleyball.fill"
        case .billiards: return "circle.circle.fill"
        }
    }

    static func render(_ fl: SportFlash) -> UIImage {
        let S = size
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        return UIGraphicsImageRenderer(size: S, format: fmt).image { ctx in
            let g = ctx.cgContext
            let sportC = accent(fl.sport)
            let team = fl.colorHex.map { UIColor(hex: $0) } ?? sportC
            let emblemW: CGFloat = 210, r: CGFloat = 22
            let body = CGRect(x: 10, y: 14, width: S.width - 20, height: S.height - 28)
            let shadow = UIColor.black.withAlphaComponent(0.5).cgColor

            // panel
            let panel = UIBezierPath(roundedRect: body, cornerRadius: r)
            g.setShadow(offset: CGSize(width: 0, height: 8), blur: 18, color: shadow)
            gradient(g, panel, UIColor(red: 0.09, green: 0.11, blue: 0.16, alpha: 0.96), UIColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 0.96))
            g.setShadow(offset: .zero, blur: 0, color: nil)
            g.saveGState(); panel.addClip()
            // sport stripe on top, team colour along the bottom
            gradientH(g, CGRect(x: body.minX, y: body.minY, width: body.width, height: 7), sportC, sportC.withAlphaComponent(0.2))
            team.setFill(); UIRectFill(CGRect(x: body.minX, y: body.maxY - 9, width: body.width, height: 9))

            // emblem block
            let em = CGRect(x: body.minX, y: body.minY, width: emblemW, height: body.height)
            let emColor: UIColor
            switch fl.kind {
            case .goal: emColor = team
            case .ownGoal: emColor = UIColor(hex: "#5B6170")
            case .yellowCard: emColor = UIColor(hex: "#2A2A2A")
            case .redCard: emColor = UIColor(hex: "#2A2A2A")
            case .addedTime: emColor = .black
            case .pressure: emColor = UIColor(hex: "#FF6A00")
            case .final: emColor = UIColor(hex: "#E0A800")
            default: emColor = sportC.darker(0.25)
            }
            gradient(g, UIBezierPath(rect: em), emColor.lighter(0.12), emColor.darker(0.2))
            emblem(fl, in: em.insetBy(dx: 26, dy: 22), g: g, sport: sportC)
            g.restoreGState()
            UIColor.white.withAlphaComponent(0.18).setStroke(); panel.lineWidth = 2; panel.stroke()

            // text
            var right = body.maxX - 34
            if let sc = fl.score {
                let sf = UIFont.monospacedDigitSystemFont(ofSize: 58, weight: .heavy)
                let w = max(190, (sc as NSString).size(withAttributes: [.font: sf]).width + 50)
                let box = CGRect(x: body.maxX - 24 - w, y: body.midY - 48, width: w, height: 96)
                let bp = UIBezierPath(roundedRect: box, cornerRadius: 14)
                gradient(g, bp, UIColor.white.withAlphaComponent(0.16), UIColor.white.withAlphaComponent(0.06))
                center(sc, sf, .white, in: box)
                right = box.minX - 24
            }
            let left = em.maxX + 34
            let hf = UIFont.systemFont(ofSize: fl.kind == .goal ? 74 : 60, weight: .black)
            let headColor: UIColor
            switch fl.kind {
            case .goal: headColor = UIColor(hex: "#FFD54A")
            case .yellowCard: headColor = UIColor(hex: "#FFD60A")
            case .redCard: headColor = UIColor(hex: "#FF3B30")
            case .addedTime: headColor = UIColor(hex: "#39FF6A")
            case .pressure: headColor = UIColor(hex: "#FF8A1F")
            case .final: headColor = UIColor(hex: "#FFD54A")
            default: headColor = .white
            }
            let lines: [(String, UIFont, UIColor)] = [
                (fl.headline.uppercased(), hf, headColor),
                (fl.team?.uppercased() ?? "", UIFont.systemFont(ofSize: 38, weight: .heavy), .white),
                (fl.detail ?? "", UIFont.systemFont(ofSize: 28, weight: .semibold), UIColor.white.withAlphaComponent(0.75)),
            ].filter { !$0.0.isEmpty }
            let total = lines.reduce(CGFloat(0)) { $0 + $1.1.lineHeight } + CGFloat(max(0, lines.count - 1)) * 2
            var y = body.midY - total / 2
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            for (txt, font, color) in lines {
                (txt as NSString).draw(in: CGRect(x: left, y: y, width: max(0, right - left), height: font.lineHeight),
                                       withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
                y += font.lineHeight + 2
            }
        }
    }

    private static func emblem(_ fl: SportFlash, in r: CGRect, g: CGContext, sport: UIColor) {
        switch fl.kind {
        case .yellowCard, .redCard:
            // the card itself, tilted
            let c = fl.kind == .yellowCard ? UIColor(hex: "#FFD60A") : UIColor(hex: "#E5161D")
            let h = r.height, w = h * 0.68
            g.saveGState()
            g.translateBy(x: r.midX, y: r.midY); g.rotate(by: -0.18)
            let card = UIBezierPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: 10)
            g.setShadow(offset: CGSize(width: 4, height: 6), blur: 10, color: UIColor.black.withAlphaComponent(0.6).cgColor)
            gradient(g, card, c.lighter(0.15), c.darker(0.12))
            g.restoreGState()
        case .addedTime:
            // fourth-official board: LED digits
            let f = UIFont.monospacedDigitSystemFont(ofSize: 92, weight: .heavy)
            let led = UIColor(hex: "#39FF6A")
            g.saveGState()
            g.setShadow(offset: .zero, blur: 18, color: led.withAlphaComponent(0.9).cgColor)
            center(fl.big ?? "", f, led, in: r)
            g.restoreGState()
        case .rack:
            billiardBall(in: r, number: "8")
        default:
            let name: String
            switch fl.kind {
            case .timeout: name = "timer"
            case .switchEnds: name = "arrow.left.arrow.right"
            case .final: name = "trophy.fill"
            case .periodEnd: name = "flag.checkered"
            case .pressure: name = "flame.fill"
            case .foulLimit: name = "exclamationmark.triangle.fill"
            default: name = sportSymbol(fl.sport)
            }
            if fl.sport == .billiards && name == sportSymbol(.billiards) { billiardBall(in: r, number: "9"); return }
            let cfg = UIImage.SymbolConfiguration(pointSize: r.height * 0.8, weight: .bold)
            let img = (UIImage(systemName: name, withConfiguration: cfg) ?? UIImage(systemName: "sportscourt.fill", withConfiguration: cfg))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            if let img {
                g.saveGState()
                g.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: UIColor.black.withAlphaComponent(0.5).cgColor)
                img.draw(in: fit(img.size, in: r))
                g.restoreGState()
            }
        }
    }

    private static func billiardBall(in r: CGRect, number: String) {
        let d = min(r.width, r.height), b = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
        UIColor(white: 0.06, alpha: 1).setFill(); UIBezierPath(ovalIn: b).fill()
        let w = b.insetBy(dx: d * 0.27, dy: d * 0.27)
        UIColor.white.setFill(); UIBezierPath(ovalIn: w).fill()
        center(number, UIFont.systemFont(ofSize: d * 0.32, weight: .heavy), .black, in: w)
        UIColor.white.withAlphaComponent(0.35).setFill()
        UIBezierPath(ovalIn: CGRect(x: b.minX + d * 0.18, y: b.minY + d * 0.1, width: d * 0.22, height: d * 0.14)).fill()
    }

    private static func fit(_ s: CGSize, in r: CGRect) -> CGRect {
        guard s.width > 0, s.height > 0 else { return r }
        let k = min(r.width / s.width, r.height / s.height)
        let w = s.width * k, h = s.height * k
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    private static func center(_ s: String, _ f: UIFont, _ c: UIColor, in r: CGRect) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        (s as NSString).draw(in: CGRect(x: r.minX, y: r.midY - f.lineHeight / 2, width: r.width, height: f.lineHeight),
                             withAttributes: [.font: f, .foregroundColor: c, .paragraphStyle: p])
    }

    private static func gradient(_ g: CGContext, _ path: UIBezierPath, _ top: UIColor, _ bottom: UIColor) {
        g.saveGState()
        path.addClip()
        let cs = CGColorSpaceCreateDeviceRGB()
        if let gr = CGGradient(colorsSpace: cs, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
            let b = path.bounds
            g.drawLinearGradient(gr, start: CGPoint(x: b.midX, y: b.minY), end: CGPoint(x: b.midX, y: b.maxY), options: [])
        }
        g.restoreGState()
    }

    private static func gradientH(_ g: CGContext, _ r: CGRect, _ a: UIColor, _ b: UIColor) {
        g.saveGState()
        UIBezierPath(rect: r).addClip()
        if let gr = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1]) {
            g.drawLinearGradient(gr, start: CGPoint(x: r.minX, y: r.midY), end: CGPoint(x: r.maxX, y: r.midY), options: [])
        }
        g.restoreGState()
    }
}

private extension UIColor {
    func lighter(_ k: CGFloat) -> UIColor { mix(.white, k) }
    func darker(_ k: CGFloat) -> UIColor { mix(.black, k) }
    func mix(_ o: UIColor, _ k: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a); o.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r + (r2 - r) * k, green: g + (g2 - g) * k, blue: b + (b2 - b) * k, alpha: a)
    }
}

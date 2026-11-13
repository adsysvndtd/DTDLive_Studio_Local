import AVFoundation
import CoreImage
import SwiftUI
import UIKit

enum TitleStyle: String, Codable, CaseIterable, Identifiable {
    case lowerThird, nameStrap, logoStrap, fullScreen, ticker, scoreBug, clock, countdown
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lowerThird: return "Lower third"
        case .nameStrap: return L("Tên + chức danh")
        case .logoStrap: return L("Logo + tên + chức danh")
        case .fullScreen: return L("Toàn màn hình")
        case .ticker: return L("Chữ chạy")
        case .scoreBug: return L("Tỉ số")
        case .clock: return L("Đồng hồ")
        case .countdown: return L("Đếm ngược")
        }
    }
}

/// One graphic item. Text fields meaning depends on style:
///   lowerThird/nameStrap: line1 = name, line2 = role
///   scoreBug: line1 = home team, line2 = away team, scoreA/scoreB, period; look in `board`
///   ticker: line1 = scrolling text
struct TitleItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var style: TitleStyle = .lowerThird
    var line1 = ""
    var line2 = ""
    var scoreA = 0
    var scoreB = 0
    var period = ""
    var accentHex = "#E30613"
    var position = CGPoint(x: 0.05, y: 0.75)  // normalised top-left anchor
    var scale: CGFloat = 1
    var visible = false
    var tickerSpeed: CGFloat = 120 // px/s at 1080p
    /// scoreBug look (logos, colours, match clock, wide/compact) — see Scoreboard.swift
    var board: ScoreboardData? = nil
    /// logoStrap: logo file (Logo library) and a small header line above the name (organisation / programme)
    var logoFile: String? = nil
    var header: String? = nil
}

/// Renders TitleItems to CIImages (cached; re-rendered only when content changes),
/// plus animated fade/slide in-out and ticker scrolling.
final class TitleRenderer: @unchecked Sendable {
    private var cache: [UUID: (TitleItem, CGSize, CIImage)] = [:]
    private var tickCache: [UUID: Int] = [:]
    private var boardCache: [UUID: (String, CGSize, CIImage)] = [:]
    private var shownAt: [UUID: CFTimeInterval] = [:]
    private var hiddenAt: [UUID: CFTimeInterval] = [:]
    private let lock = NSLock()
    let animation: CFTimeInterval = 0.35

    /// True once a visible countdown has run out and its fireworks have finished (engine then hides it).
    func countdownDone(_ item: TitleItem, now: CFTimeInterval) -> Bool {
        guard item.style == .countdown, item.visible else { return false }
        lock.lock(); let shown = shownAt[item.id]; lock.unlock()
        guard let shown else { return false }
        return now - shown >= Double(item.scoreA * 60 + item.scoreB) + Fireworks.duration
    }

    func visibilityChanged(_ item: TitleItem) {
        lock.lock(); defer { lock.unlock() }
        if item.visible { shownAt[item.id] = HostClock.now; hiddenAt[item.id] = nil }
        else { hiddenAt[item.id] = HostClock.now }
    }

    /// Full-frame overlay image for all titles at time `now`.
    func render(_ items: [TitleItem], canvas: CGSize, now: CFTimeInterval) -> CIImage? {
        var out: CIImage?
        for item in items {
            lock.lock()
            let shown = shownAt[item.id], hidden = hiddenAt[item.id]
            lock.unlock()
            var alpha: CGFloat = 1
            if item.visible, let shown { alpha = min(1, (now - shown) / animation) }
            else if !item.visible, let hidden { alpha = max(0, 1 - (now - hidden) / animation); if alpha == 0 { continue } }
            else if !item.visible { continue }

            guard var img = image(for: item, canvas: canvas, now: now) else { continue }
            let slide = (1 - alpha) * 40
            let x = item.position.x * canvas.width - slide
            let y = (1 - item.position.y) * canvas.height - img.extent.height
            if item.style == .ticker {
                let travel = canvas.width + img.extent.width
                let offset = CGFloat((now - (shown ?? now))) * item.tickerSpeed * canvas.width / 1920
                let tx = canvas.width - offset.truncatingRemainder(dividingBy: travel)
                let bar = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.75))
                    .cropped(to: CGRect(x: 0, y: 0, width: canvas.width, height: img.extent.height))
                img = img.transformed(by: .init(translationX: tx, y: 0)).composited(over: bar)
                    .cropped(to: CGRect(x: 0, y: 0, width: canvas.width, height: img.extent.height))
                    .transformed(by: .init(translationX: 0, y: 0.04 * canvas.height))
            } else if item.style == .fullScreen {
                img = img.transformed(by: .init(translationX: (canvas.width - img.extent.width) / 2, y: (canvas.height - img.extent.height) / 2))
            } else {
                img = img.transformed(by: .init(translationX: x, y: y))
            }
            if alpha < 1 {
                img = img.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
            }
            out = out.map { img.composited(over: $0) } ?? img
            // Countdown reached 00:00 → fireworks over the whole frame for a few seconds
            if item.style == .countdown, item.visible, let shown {
                let past = now - shown - Double(item.scoreA * 60 + item.scoreB)
                if past >= 0, past < Fireworks.duration, let fw = Fireworks.frame(t: past, canvas: canvas, seed: item.id.hashValue) {
                    out = out.map { fw.composited(over: $0) } ?? fw
                }
            }
        }
        return out?.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    private func image(for item: TitleItem, canvas: CGSize, now: CFTimeInterval) -> CIImage? {
        if item.style == .scoreBug {
            // Scoreboard: re-drawn only when its signature (scores, names, clock second…) changes.
            let sig = ScoreboardRenderer.signature(item) + "|\(item.scale)"
            lock.lock()
            if let c = boardCache[item.id], c.0 == sig, c.1 == canvas { lock.unlock(); return c.2 }
            lock.unlock()
            guard let cg = ScoreboardRenderer.render(item).cgImage else { return nil }
            let k = canvas.width / 1920 * item.scale
            let ci = CIImage(cgImage: cg).transformed(by: .init(scaleX: k, y: k))
            lock.lock(); boardCache[item.id] = (sig, canvas, ci); lock.unlock()
            return ci
        }
        // Clock / countdown change once a second: redraw only when the shown second changes
        // (drawing text on the CPU every frame made program stutter).
        let k = canvas.height / 1080 * item.scale
        var remaining: Int?
        if item.style == .countdown {
            lock.lock(); let start = shownAt[item.id]; lock.unlock()
            let total = item.scoreA * 60 + item.scoreB
            remaining = max(0, total - Int(now - (start ?? now)))
        }
        let tick: Int = item.style == .clock ? Int(Date().timeIntervalSince1970) : (remaining ?? -1)
        lock.lock()
        if let c = cache[item.id], c.0 == item, c.1 == canvas, tickCache[item.id] == tick { lock.unlock(); return c.2 }
        lock.unlock()
        let ui = Self.draw(item, k: k, remaining: remaining)
        guard let cg = ui.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        lock.lock(); cache[item.id] = (item, canvas, ci); tickCache[item.id] = tick; lock.unlock()
        return ci
    }

    static func draw(_ t: TitleItem, k: CGFloat, remaining: Int? = nil) -> UIImage {
        let accent = UIColor(hex: t.accentHex)
        let big = UIFont.systemFont(ofSize: 44 * k, weight: .bold)
        let small = UIFont.systemFont(ofSize: 30 * k, weight: .medium)
        func attr(_ s: String, _ f: UIFont, _ c: UIColor = .white) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])
        }
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        switch t.style {
        case .lowerThird, .nameStrap:
            let a = attr(t.line1, big), b = attr(t.line2, small)
            let w = max(a.size().width, b.size().width) + 60 * k
            let h1 = a.size().height + 16 * k, h2 = t.line2.isEmpty ? 0 : b.size().height + 12 * k
            return UIGraphicsImageRenderer(size: CGSize(width: w + 12 * k, height: h1 + h2), format: fmt).image { _ in
                accent.setFill(); UIBezierPath(rect: CGRect(x: 0, y: 0, width: 12 * k, height: h1 + h2)).fill()
                UIColor(white: 0.08, alpha: 0.9).setFill(); UIBezierPath(rect: CGRect(x: 12 * k, y: 0, width: w, height: h1)).fill()
                a.draw(at: CGPoint(x: 40 * k, y: 8 * k))
                if h2 > 0 {
                    (t.style == .nameStrap ? accent : UIColor(white: 0.2, alpha: 0.9)).setFill()
                    UIBezierPath(rect: CGRect(x: 12 * k, y: h1, width: w, height: h2)).fill()
                    b.draw(at: CGPoint(x: 40 * k, y: h1 + 6 * k))
                }
            }
        case .logoStrap:
            // [logo] | HEADER (accent, small caps) / NAME (big) / role
            let head = attr((t.header ?? "").uppercased(), UIFont.systemFont(ofSize: 22 * k, weight: .heavy), accent)
            let a = attr(t.line1, big), b = attr(t.line2, small, UIColor(white: 0.85, alpha: 1))
            let logo = t.logoFile.flatMap { UIImage(contentsOfFile: MediaLibrary.directory(.logo).appendingPathComponent($0).path) }
            let textW = max(head.size().width, a.size().width, b.size().width)
            let hHead = (t.header ?? "").isEmpty ? 0 : head.size().height + 2 * k
            let h = hHead + a.size().height + (t.line2.isEmpty ? 0 : b.size().height) + 28 * k
            let logoBox = logo == nil ? 0 : h
            let w = logoBox + 8 * k + textW + 56 * k
            return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { ctx in
                // logo tile (white) + accent divider + dark text panel with a soft gradient
                if let logo {
                    UIColor.white.setFill(); UIBezierPath(rect: CGRect(x: 0, y: 0, width: logoBox, height: h)).fill()
                    let pad = 10 * k
                    let r = CGRect(x: pad, y: pad, width: logoBox - 2 * pad, height: h - 2 * pad)
                    logo.draw(in: AVMakeRect(aspectRatio: logo.size, insideRect: r))
                }
                accent.setFill(); UIBezierPath(rect: CGRect(x: logoBox, y: 0, width: 8 * k, height: h)).fill()
                let panel = CGRect(x: logoBox + 8 * k, y: 0, width: w - logoBox - 8 * k, height: h)
                let cs = CGColorSpaceCreateDeviceRGB()
                if let g = CGGradient(colorsSpace: cs, colors: [UIColor(white: 0.12, alpha: 0.95).cgColor, UIColor(white: 0.04, alpha: 0.85).cgColor] as CFArray, locations: [0, 1]) {
                    ctx.cgContext.saveGState(); ctx.cgContext.clip(to: panel)
                    ctx.cgContext.drawLinearGradient(g, start: CGPoint(x: panel.minX, y: 0), end: CGPoint(x: panel.maxX, y: 0), options: [])
                    ctx.cgContext.restoreGState()
                }
                var y = 12 * k
                let x = panel.minX + 24 * k
                if hHead > 0 { head.draw(at: CGPoint(x: x, y: y)); y += hHead }
                a.draw(at: CGPoint(x: x, y: y)); y += a.size().height
                if !t.line2.isEmpty { b.draw(at: CGPoint(x: x, y: y)) }
            }
        case .fullScreen:
            let a = attr(t.line1, UIFont.systemFont(ofSize: 80 * k, weight: .heavy)), b = attr(t.line2, small)
            let w = max(a.size().width, b.size().width) + 120 * k
            let h = a.size().height + b.size().height + 80 * k
            return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { _ in
                UIColor(white: 0, alpha: 0.7).setFill(); UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 24 * k).fill()
                a.draw(at: CGPoint(x: (w - a.size().width) / 2, y: 30 * k))
                b.draw(at: CGPoint(x: (w - b.size().width) / 2, y: 40 * k + a.size().height))
            }
        case .ticker:
            let a = attr(t.line1, small)
            return UIGraphicsImageRenderer(size: CGSize(width: a.size().width + 40 * k, height: a.size().height + 20 * k), format: fmt).image { _ in
                a.draw(at: CGPoint(x: 20 * k, y: 10 * k))
            }
        case .scoreBug:
            return ScoreboardRenderer.render(t)
        case .countdown:
            let r = remaining ?? (t.scoreA * 60 + t.scoreB)
            let label = attr(t.line1.isEmpty ? L("Bắt đầu sau") : t.line1, small)
            let time = attr(String(format: "%02d:%02d", r / 60, r % 60), UIFont.monospacedDigitSystemFont(ofSize: 64 * k, weight: .heavy),
                            r <= 10 ? UIColor.systemRed : .white)
            let w = max(label.size().width, time.size().width) + 60 * k, h = label.size().height + time.size().height + 30 * k
            return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { _ in
                UIColor(white: 0, alpha: 0.7).setFill(); UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 12 * k).fill()
                accent.setFill(); UIBezierPath(rect: CGRect(x: 0, y: 0, width: w, height: 6 * k)).fill()
                label.draw(at: CGPoint(x: (w - label.size().width) / 2, y: 12 * k))
                time.draw(at: CGPoint(x: (w - time.size().width) / 2, y: 14 * k + label.size().height))
            }
        case .clock:
            let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
            let a = attr(df.string(from: Date()), small)
            return UIGraphicsImageRenderer(size: CGSize(width: a.size().width + 30 * k, height: a.size().height + 14 * k), format: fmt).image { _ in
                UIColor(white: 0, alpha: 0.6).setFill()
                UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: a.size().width + 30 * k, height: a.size().height + 14 * k), cornerRadius: 6 * k).fill()
                a.draw(at: CGPoint(x: 15 * k, y: 7 * k))
            }
        }
    }
}

extension UIColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}


/// Procedural fireworks for the end of a countdown: a few bursts of particles with gravity and fade.
/// Drawn at half resolution and scaled up (cheap enough for the few seconds it runs).
enum Fireworks {
    static let duration: Double = 4

    static func frame(t: Double, canvas: CGSize, seed: Int) -> CIImage? {
        let half = CGSize(width: canvas.width / 2, height: canvas.height / 2)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        var rng = SplitMix(UInt64(bitPattern: Int64(seed)))
        let colors: [UIColor] = [.systemYellow, .systemRed, .systemPink, .systemTeal, .systemOrange, .white, .systemGreen]
        let ui = UIGraphicsImageRenderer(size: half, format: fmt).image { ctx in
            let g = ctx.cgContext
            g.setBlendMode(.plusLighter)
            for b in 0..<7 {
                let start = Double(b) * 0.45
                let life = 1.8
                let lt = t - start
                let cx = half.width * (0.15 + 0.7 * rng.unit()), cy = half.height * (0.15 + 0.4 * rng.unit())
                let col = colors[Int(rng.unit() * Double(colors.count)) % colors.count]
                let speed = half.height * (0.28 + 0.2 * rng.unit())
                let n = 46
                guard lt > 0, lt < life else { for _ in 0..<n { _ = rng.unit() }; continue }
                let alpha = CGFloat(max(0, 1 - lt / life))
                for p in 0..<n {
                    let ang = Double(p) / Double(n) * 2 * .pi + rng.unit() * 0.12
                    let v = speed * (0.75 + 0.25 * rng.unit())
                    let x = cx + CGFloat(cos(ang) * v * lt)
                    let y = cy + CGFloat(sin(ang) * v * lt + 0.5 * Double(half.height) * 0.35 * lt * lt)
                    let r = max(1, half.height * 0.006 * (1 - lt / life * 0.5))
                    col.withAlphaComponent(alpha).setFill()
                    g.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                    // short trail
                    col.withAlphaComponent(alpha * 0.35).setFill()
                    let tx = cx + CGFloat(cos(ang) * v * max(0, lt - 0.08)), ty = cy + CGFloat(sin(ang) * v * max(0, lt - 0.08))
                    g.fillEllipse(in: CGRect(x: tx - r * 0.7, y: ty - r * 0.7, width: 1.4 * r, height: 1.4 * r))
                }
            }
        }
        guard let cg = ui.cgImage else { return nil }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: 2, y: 2))
    }

    struct SplitMix {
        var s: UInt64
        init(_ seed: UInt64) { s = seed }
        mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}

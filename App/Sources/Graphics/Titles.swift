import CoreImage
import SwiftUI
import UIKit

enum TitleStyle: String, Codable, CaseIterable, Identifiable {
    case lowerThird, nameStrap, fullScreen, ticker, scoreBug, clock, countdown
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lowerThird: return "Lower third"
        case .nameStrap: return L("Tên + chức danh")
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
}

/// Renders TitleItems to CIImages (cached; re-rendered only when content changes),
/// plus animated fade/slide in-out and ticker scrolling.
final class TitleRenderer: @unchecked Sendable {
    private var cache: [UUID: (TitleItem, CGSize, CIImage)] = [:]
    private var boardCache: [UUID: (String, CGSize, CIImage)] = [:]
    private var shownAt: [UUID: CFTimeInterval] = [:]
    private var hiddenAt: [UUID: CFTimeInterval] = [:]
    private let lock = NSLock()
    let animation: CFTimeInterval = 0.35

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
        // Clock changes every second; everything else is cached by content.
        let dynamic = item.style == .clock || item.style == .countdown
        lock.lock()
        if !dynamic, let c = cache[item.id], c.0 == item, c.1 == canvas { lock.unlock(); return c.2 }
        lock.unlock()
        let k = canvas.height / 1080 * item.scale
        var remaining: Int?
        if item.style == .countdown {
            lock.lock(); let start = shownAt[item.id]; lock.unlock()
            let total = item.scoreA * 60 + item.scoreB
            remaining = max(0, total - Int(now - (start ?? now)))
        }
        let ui = Self.draw(item, k: k, remaining: remaining)
        guard let cg = ui.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        lock.lock(); cache[item.id] = (item, canvas, ci); lock.unlock()
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
            let label = attr(t.line1.isEmpty ? "Bắt đầu sau" : t.line1, small)
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

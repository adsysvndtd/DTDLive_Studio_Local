import UIKit

/// SuperFG: full-frame foreground graphics keyed over program (frames, news bands, banners, bugs).
/// Built-in templates are DTD Studio's own designs, drawn procedurally with editable text and colour;
/// operators can also use their own PNG (alpha) or video with alpha (HEVC .mov) from the library.
struct SuperFGConfig: Codable, Equatable {
    var templateID = "news"
    var line1 = "DTD STUDIO"
    var line2 = "Trực tiếp từ Hà Nội"
    var accentHex = "#E30613"
}

struct SuperFGTemplate: Identifiable {
    let id: String
    let name: String
    let draw: (CGContext, CGSize, SuperFGConfig) -> Void

    /// Renders at 1920×1080 (or the program aspect) with a transparent background.
    func render(_ c: SuperFGConfig, size: CGSize = CGSize(width: 1920, height: 1080)) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in draw(ctx.cgContext, size, c) }
    }

    // MARK: Built-in designs

    static let all: [SuperFGTemplate] = [
        SuperFGTemplate(id: "news", name: "Bản tin") { g, s, c in
            let k = s.height / 1080, accent = UIColor(hex: c.accentHex)
            let band = CGRect(x: 0, y: s.height - 190 * k, width: s.width, height: 130 * k)
            UIColor(white: 0.06, alpha: 0.88).setFill(); g.fill(band)
            accent.setFill(); g.fill(CGRect(x: 0, y: band.minY, width: 300 * k, height: band.height))
            SuperFGTemplate.text("TIN TỨC", in: CGRect(x: 0, y: band.minY, width: 300 * k, height: band.height), size: 46 * k, weight: .black, align: .center)
            SuperFGTemplate.text(c.line1, in: CGRect(x: 340 * k, y: band.minY + 14 * k, width: s.width - 380 * k, height: 62 * k), size: 50 * k, weight: .heavy)
            SuperFGTemplate.text(c.line2, in: CGRect(x: 340 * k, y: band.minY + 74 * k, width: s.width - 380 * k, height: 44 * k), size: 32 * k, weight: .medium,
                 color: UIColor(white: 0.85, alpha: 1))
            accent.setFill(); g.fill(CGRect(x: 0, y: band.maxY, width: s.width, height: 8 * k))
        },
        SuperFGTemplate(id: "live", name: "Khung LIVE") { g, s, c in
            let k = s.height / 1080, accent = UIColor(hex: c.accentHex)
            g.setStrokeColor(accent.cgColor); g.setLineWidth(10 * k)
            g.stroke(CGRect(origin: .zero, size: s).insetBy(dx: 5 * k, dy: 5 * k))
            let badge = CGRect(x: 60 * k, y: 50 * k, width: 190 * k, height: 70 * k)
            accent.setFill(); UIBezierPath(roundedRect: badge, cornerRadius: 10 * k).fill()
            UIColor.white.setFill(); g.fillEllipse(in: CGRect(x: badge.minX + 22 * k, y: badge.midY - 11 * k, width: 22 * k, height: 22 * k))
            SuperFGTemplate.text("LIVE", in: badge.offsetBy(dx: 26 * k, dy: 0), size: 44 * k, weight: .black, align: .center)
            let tag = CGRect(x: s.width - 760 * k, y: 50 * k, width: 700 * k, height: 70 * k)
            UIColor(white: 0, alpha: 0.6).setFill(); UIBezierPath(roundedRect: tag, cornerRadius: 10 * k).fill()
            SuperFGTemplate.text(c.line1, in: tag.insetBy(dx: 24 * k, dy: 0), size: 36 * k, weight: .bold, align: .right)
        },
        SuperFGTemplate(id: "breaking", name: "Tin nóng") { g, s, c in
            let k = s.height / 1080, accent = UIColor(hex: c.accentHex)
            let y = s.height - 250 * k
            let tag = UIBezierPath()
            tag.move(to: CGPoint(x: 0, y: y)); tag.addLine(to: CGPoint(x: 470 * k, y: y))
            tag.addLine(to: CGPoint(x: 420 * k, y: y + 90 * k)); tag.addLine(to: CGPoint(x: 0, y: y + 90 * k)); tag.close()
            accent.setFill(); tag.fill()
            SuperFGTemplate.text("TIN NÓNG", in: CGRect(x: 40 * k, y: y, width: 380 * k, height: 90 * k), size: 56 * k, weight: .black)
            let bar = CGRect(x: 0, y: y + 90 * k, width: s.width, height: 110 * k)
            UIColor.white.withAlphaComponent(0.95).setFill(); g.fill(bar)
            SuperFGTemplate.text(c.line1, in: bar.insetBy(dx: 40 * k, dy: 0), size: 54 * k, weight: .heavy, color: UIColor(white: 0.08, alpha: 1))
            UIColor(white: 0.08, alpha: 0.9).setFill(); g.fill(CGRect(x: 0, y: bar.maxY, width: s.width, height: 50 * k))
            SuperFGTemplate.text(c.line2, in: CGRect(x: 40 * k, y: bar.maxY, width: s.width - 80 * k, height: 50 * k), size: 28 * k, weight: .semibold)
        },
        SuperFGTemplate(id: "corners", name: "Góc ngắm") { g, s, c in
            let k = s.height / 1080, accent = UIColor(hex: c.accentHex)
            let m = 70 * k, l = 120 * k
            g.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor); g.setLineWidth(8 * k); g.setLineCap(.square)
            let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(m, m, 1, 1), (s.width - m, m, -1, 1), (m, s.height - m, 1, -1), (s.width - m, s.height - m, -1, -1)]
            for (x, y, dx, dy) in corners {
                g.move(to: CGPoint(x: x, y: y + l * dy)); g.addLine(to: CGPoint(x: x, y: y)); g.addLine(to: CGPoint(x: x + l * dx, y: y))
            }
            g.strokePath()
            accent.setFill(); g.fillEllipse(in: CGRect(x: m + 30 * k, y: m + 30 * k, width: 26 * k, height: 26 * k))
            SuperFGTemplate.text("REC", in: CGRect(x: m + 66 * k, y: m + 20 * k, width: 200 * k, height: 46 * k), size: 36 * k, weight: .bold)
            SuperFGTemplate.text(c.line1, in: CGRect(x: 0, y: s.height - m - 90 * k, width: s.width, height: 60 * k), size: 44 * k, weight: .bold, align: .center)
        },
        SuperFGTemplate(id: "event", name: "Sự kiện") { g, s, c in
            let k = s.height / 1080, accent = UIColor(hex: c.accentHex)
            let pill = CGRect(x: 60 * k, y: 50 * k, width: 820 * k, height: 96 * k)
            UIColor(white: 0.05, alpha: 0.75).setFill(); UIBezierPath(roundedRect: pill, cornerRadius: 48 * k).fill()
            accent.setFill(); UIBezierPath(roundedRect: CGRect(x: pill.minX, y: pill.minY, width: 96 * k, height: 96 * k), cornerRadius: 48 * k).fill()
            SuperFGTemplate.text("★", in: CGRect(x: pill.minX, y: pill.minY, width: 96 * k, height: 96 * k), size: 48 * k, weight: .bold, align: .center)
            SuperFGTemplate.text(c.line1, in: CGRect(x: pill.minX + 120 * k, y: pill.minY + 8 * k, width: pill.width - 150 * k, height: 50 * k), size: 38 * k, weight: .heavy)
            SuperFGTemplate.text(c.line2, in: CGRect(x: pill.minX + 120 * k, y: pill.minY + 52 * k, width: pill.width - 150 * k, height: 36 * k), size: 26 * k, weight: .medium,
                 color: UIColor(white: 0.85, alpha: 1))
            accent.setFill(); g.fill(CGRect(x: 0, y: s.height - 12 * k, width: s.width, height: 12 * k))
        },
        SuperFGTemplate(id: "sponsor", name: "Nhà tài trợ") { g, s, c in
            let k = s.height / 1080, accent = UIColor(hex: c.accentHex)
            let box = CGRect(x: s.width - 620 * k, y: s.height - 240 * k, width: 560 * k, height: 170 * k)
            UIColor.white.withAlphaComponent(0.94).setFill(); UIBezierPath(roundedRect: box, cornerRadius: 16 * k).fill()
            accent.setFill(); UIBezierPath(roundedRect: CGRect(x: box.minX, y: box.minY, width: box.width, height: 46 * k),
                                           byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 16 * k, height: 16 * k)).fill()
            SuperFGTemplate.text("ĐỒNG HÀNH CÙNG CHƯƠNG TRÌNH", in: CGRect(x: box.minX, y: box.minY, width: box.width, height: 46 * k), size: 22 * k, weight: .bold, align: .center)
            SuperFGTemplate.text(c.line1, in: CGRect(x: box.minX + 20 * k, y: box.minY + 56 * k, width: box.width - 40 * k, height: 60 * k), size: 46 * k, weight: .black,
                 color: UIColor(white: 0.08, alpha: 1), align: .center)
            SuperFGTemplate.text(c.line2, in: CGRect(x: box.minX + 20 * k, y: box.minY + 116 * k, width: box.width - 40 * k, height: 40 * k), size: 26 * k, weight: .medium,
                 color: UIColor(white: 0.3, alpha: 1), align: .center)
        },
        SuperFGTemplate(id: "letterbox", name: "Điện ảnh") { g, s, c in
            let k = s.height / 1080, h = 130 * k
            UIColor.black.setFill(); g.fill(CGRect(x: 0, y: 0, width: s.width, height: h)); g.fill(CGRect(x: 0, y: s.height - h, width: s.width, height: h))
            SuperFGTemplate.text(c.line1, in: CGRect(x: 80 * k, y: s.height - h, width: s.width - 160 * k, height: h * 0.6), size: 40 * k, weight: .semibold)
            SuperFGTemplate.text(c.line2, in: CGRect(x: 80 * k, y: s.height - h * 0.45, width: s.width - 160 * k, height: h * 0.4), size: 26 * k, weight: .regular,
                 color: UIColor(white: 0.75, alpha: 1))
        },
        SuperFGTemplate(id: "split", name: "Khung đôi") { g, s, c in
            let k = s.height / 1080, accent = UIColor(hex: c.accentHex)
            g.setStrokeColor(accent.cgColor); g.setLineWidth(8 * k)
            g.move(to: CGPoint(x: s.width / 2, y: 140 * k)); g.addLine(to: CGPoint(x: s.width / 2, y: s.height - 140 * k)); g.strokePath()
            for (i, t) in [c.line1, c.line2].enumerated() {
                let r = CGRect(x: (i == 0 ? 60 : s.width / k / 2 + 60) * k, y: s.height - 130 * k, width: s.width / 2 - 120 * k, height: 70 * k)
                UIColor(white: 0, alpha: 0.65).setFill(); UIBezierPath(roundedRect: r, cornerRadius: 10 * k).fill()
                accent.setFill(); g.fill(CGRect(x: r.minX, y: r.minY, width: 10 * k, height: r.height))
                SuperFGTemplate.text(t, in: r.insetBy(dx: 30 * k, dy: 0), size: 36 * k, weight: .bold)
            }
        }
    ]

    private static func text(_ s: String, in r: CGRect, size: CGFloat, weight: UIFont.Weight, color: UIColor = .white,
                             align: NSTextAlignment = .left) {
        let p = NSMutableParagraphStyle(); p.alignment = align; p.lineBreakMode = .byTruncatingTail
        let f = UIFont.systemFont(ofSize: size, weight: weight)
        let y = r.minY + (r.height - f.lineHeight) / 2
        (s as NSString).draw(in: CGRect(x: r.minX, y: y, width: r.width, height: f.lineHeight),
                             withAttributes: [.font: f, .foregroundColor: color, .paragraphStyle: p])
    }
}

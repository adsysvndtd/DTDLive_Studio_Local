import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import UIKit

/// Demo / screenshot mode. Enabled by launch argument `-demo`, e.g.
///   xcrun simctl launch booted vn.com.dtdsolution.DTDStudio -demo -screen outputs -panel audio
/// Adds animated test-pattern sources (no camera or network needed), sample titles,
/// a PiP and a few outputs, so every screen can be reviewed in the Simulator or on CI.
enum DemoMode {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }
    /// UI-test / screenshot run: monitors redraw on a slow timer instead of every display frame,
    /// so XCUITest sees the app idle and the Simulator's main thread isn't saturated.
    static var isUITest: Bool { ProcessInfo.processInfo.arguments.contains("-uitest") }

    /// Value after a launch argument, e.g. `-screen outputs` -> "outputs".
    static func arg(_ name: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    @MainActor
    static func populate(_ engine: StudioEngine) {
        let palette: [(String, CIColor, CIColor)] = [
            ("CAM 1 · Sân khấu", CIColor(red: 0.10, green: 0.30, blue: 0.65), CIColor(red: 0.05, green: 0.10, blue: 0.25)),
            ("CAM 2 · MC", CIColor(red: 0.65, green: 0.25, blue: 0.10), CIColor(red: 0.25, green: 0.08, blue: 0.05)),
            ("CAM 3 · Khán giả", CIColor(red: 0.10, green: 0.55, blue: 0.30), CIColor(red: 0.03, green: 0.20, blue: 0.10)),
            ("SRT · DTDLive", CIColor(red: 0.50, green: 0.20, blue: 0.60), CIColor(red: 0.15, green: 0.05, blue: 0.20)),
            ("RTSP · IP Cam", CIColor(red: 0.55, green: 0.55, blue: 0.10), CIColor(red: 0.20, green: 0.20, blue: 0.03))
        ]
        for (i, p) in palette.enumerated() {
            engine.add(DemoSource(name: p.0, index: i + 1, top: p.1, bottom: p.2))
        }
        engine.injectDemoAudio()
        if engine.sources.count > 2 {
            engine.take(engine.sources[0].id)
            engine.select(engine.sources[1].id)
            engine.setPiP(engine.sources[2].id)
            engine.pipOn = true
        }
        engine.titles = [
            TitleItem(style: .lowerThird, line1: "Nguyễn Văn A", line2: "Giám đốc Trung tâm Truyền hình", visible: true),
            TitleItem(style: .scoreBug, line1: "VNPT", line2: "FPT", scoreA: 2, scoreB: 1, period: "H2",
                      position: CGPoint(x: 0.03, y: 0.03), scale: 0.9, visible: true,
                      board: { var b = ScoreboardData(); b.homeSub = "Hà Nội"; b.awaySub = "TP.HCM"; b.homeColor = "#0A5BD3"
                               b.awayColor = "#E8641E"; b.compact = true; b.clockBase = 23 * 60 + 41; return b }()),
            TitleItem(style: .ticker, line1: "Tin nhanh: DTD Studio — bàn trộn hình nhiều camera và phát trực tiếp RTMP · SRT · RTSP",
                      visible: true),
            TitleItem(style: .clock, position: CGPoint(x: 0.86, y: 0.04), visible: true)
        ]
        for t in engine.titles { engine.titleRenderer.visibilityChanged(t) }
        engine.outputs = [
            OutputConfig(name: "YouTube", proto: .rtmp, url: "rtmp://a.rtmp.youtube.com/live2/xxxx-xxxx-xxxx"),
            OutputConfig(name: "SRT CDN", proto: .srt, url: "srt://cdn.example.vn:9000?mode=caller&streamid=publish:live/demo"),
            OutputConfig(name: "MediaMTX", proto: .rtsp, url: "rtsp://192.168.1.10:8554/live/demo"),
            OutputConfig(name: "Ghi file", proto: .record, url: "")
        ]
        engine.scopesEnabled = DemoMode.arg("-panel") == "scopes"
        engine.favorites = Set(engine.sources.prefix(2).map(\.id))
        seedLibrary(engine)
    }

    /// Generates a few sample library files (logo, overlay frame, pictures) so library screens aren't empty.
    @MainActor
    private static func seedLibrary(_ engine: StudioEngine) {
        let lib = engine.library
        func write(_ img: UIImage, _ k: LibraryKind, _ name: String) {
            let url = MediaLibrary.directory(k).appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path), let d = img.pngData() { try? d.write(to: url) }
        }
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        if let logo = UIImage(named: "Logo") { write(logo, .logo, "DTD Logo.png") }
        let frame = UIGraphicsImageRenderer(size: CGSize(width: 1920, height: 1080), format: fmt).image { ctx in
            UIColor(red: 0.98, green: 0.45, blue: 0.13, alpha: 1).setStroke()
            let p = UIBezierPath(rect: CGRect(x: 20, y: 20, width: 1880, height: 1040)); p.lineWidth = 16; p.stroke()
            UIColor(white: 0, alpha: 0.6).setFill(); UIBezierPath(rect: CGRect(x: 0, y: 980, width: 1920, height: 100)).fill()
            NSAttributedString(string: "Nhà tài trợ: DTD Solution", attributes: [.font: UIFont.systemFont(ofSize: 48, weight: .bold),
                .foregroundColor: UIColor.white]).draw(at: CGPoint(x: 60, y: 1000))
        }
        write(frame, .overlay, "Khung nhà tài trợ.png")
        for (i, c) in [UIColor.systemTeal, .systemIndigo, .systemPink].enumerated() {
            let img = UIGraphicsImageRenderer(size: CGSize(width: 1280, height: 720), format: fmt).image { _ in
                c.setFill(); UIBezierPath(rect: CGRect(x: 0, y: 0, width: 1280, height: 720)).fill()
                NSAttributedString(string: "Slide \(i + 1)", attributes: [.font: UIFont.systemFont(ofSize: 120, weight: .heavy),
                    .foregroundColor: UIColor.white]).draw(at: CGPoint(x: 80, y: 260))
            }
            write(img, .picture, "Slide \(i + 1).png")
        }
        lib.refresh()
        if let l = lib.list(.logo).first { engine.useLogo(l) }
    }
}

/// Animated test pattern: gradient, moving bar, big input number and a running timecode.
@MainActor
final class DemoSource: VideoSource {
    let id = UUID()
    var name: String
    let kind: SourceKind = .file
    let frames = FrameStore()
    private(set) var status: SourceStatus = .idle

    private let index: Int
    private let top: CIColor, bottom: CIColor
    private var timer: DispatchSourceTimer?
    private let renderer = DemoRenderer()
    private let queue = DispatchQueue(label: "demo.source", qos: .userInteractive)

    init(name: String, index: Int, top: CIColor, bottom: CIColor) {
        self.name = name; self.index = index; self.top = top; self.bottom = bottom
    }

    func start() async {
        status = .live
        let r = renderer, store = frames, idx = index, nm = name, tp = top, bt = bottom, t0 = Date()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: DemoMode.isUITest ? 0.5 : 1.0 / 15)
        t.setEventHandler {
            if let pb = r.frame(index: idx, name: nm, top: tp, bottom: bt, t: Date().timeIntervalSince(t0)) { store.put(pb) }
        }
        t.resume()
        timer = t
    }

    func stop() async { timer?.cancel(); timer = nil; frames.clear(); status = .idle }
}

final class DemoRenderer: @unchecked Sendable {
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var cache: [String: CIImage] = [:]
    private let size = CGSize(width: 1280, height: 720)

    func frame(index: Int, name: String, top: CIColor, bottom: CIColor, t: Double) -> CVPixelBuffer? {
        if pool == nil {
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return nil }
        let rect = CGRect(origin: .zero, size: size)

        let g = CIFilter.linearGradient()
        g.point0 = CGPoint(x: 0, y: size.height); g.point1 = CGPoint(x: size.width, y: 0)
        g.color0 = top; g.color1 = bottom
        var img = g.outputImage!.cropped(to: rect)

        // Moving highlight bar so motion is visible on monitors.
        let x = CGFloat((t * 180).truncatingRemainder(dividingBy: Double(size.width + 200))) - 200
        let bar = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.12)).cropped(to: CGRect(x: x, y: 0, width: 120, height: size.height))
        img = bar.composited(over: img).cropped(to: rect)

        let tc = String(format: "%02d:%02d:%02d", Int(t) / 3600, Int(t) / 60 % 60, Int(t) % 60)
        img = text("\(index)", size: 220, weight: .heavy).transformed(by: .init(translationX: 60, y: size.height - 300)).composited(over: img)
        img = text(name, size: 44, weight: .semibold).transformed(by: .init(translationX: 64, y: 70)).composited(over: img)
        img = text(tc, size: 36, weight: .regular, mono: true).transformed(by: .init(translationX: size.width - 260, y: 70)).composited(over: img)
        ci.render(img.cropped(to: rect), to: pb)
        return pb
    }

    private func text(_ s: String, size: CGFloat, weight: UIFont.Weight, mono: Bool = false) -> CIImage {
        let key = "\(s)|\(size)"
        if let c = cache[key] { return c }
        defer { if cache.count > 200 { cache.removeAll() } }
        let font = mono ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : UIFont.systemFont(ofSize: size, weight: weight)
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: UIColor.white])
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        let img = UIGraphicsImageRenderer(size: a.size(), format: fmt).image { _ in a.draw(at: .zero) }
        let ci = img.cgImage.map { CIImage(cgImage: $0) } ?? CIImage.empty()
        cache[key] = ci
        return ci
    }
}

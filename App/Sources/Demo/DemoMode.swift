import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import UIKit

/// Demo / screenshot mode. Enabled by launch argument `-demo`, e.g.
///   xcrun simctl launch booted vn.vnpt.dtd.DTDStudio -demo -screen outputs -panel audio
/// Adds animated test-pattern sources (no camera or network needed), sample titles,
/// a PiP and a few outputs, so every screen can be reviewed in the Simulator or on CI.
enum DemoMode {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

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
            ("SRT · DTD Cam", CIColor(red: 0.50, green: 0.20, blue: 0.60), CIColor(red: 0.15, green: 0.05, blue: 0.20)),
            ("RTSP · IP Cam", CIColor(red: 0.55, green: 0.55, blue: 0.10), CIColor(red: 0.20, green: 0.20, blue: 0.03))
        ]
        for (i, p) in palette.enumerated() {
            engine.add(DemoSource(name: p.0, index: i + 1, top: p.1, bottom: p.2))
        }
        if engine.sources.count > 2 {
            engine.take(engine.sources[0].id)
            engine.select(engine.sources[1].id)
            engine.setPiP(engine.sources[2].id)
        }
        engine.titles = [
            TitleItem(style: .lowerThird, line1: "Nguyễn Văn A", line2: "Giám đốc Trung tâm Truyền hình", visible: true),
            TitleItem(style: .scoreBug, line1: "VNPT", line2: "FPT", scoreA: 2, scoreB: 1, period: "H2",
                      position: CGPoint(x: 0.04, y: 0.04), visible: true),
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
    private var timer: Timer?
    private let renderer = DemoRenderer()
    private let start = Date()

    init(name: String, index: Int, top: CIColor, bottom: CIColor) {
        self.name = name; self.index = index; self.top = top; self.bottom = bottom
    }

    func start() async {
        status = .live
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() async { timer?.invalidate(); timer = nil; frames.clear(); status = .idle }

    private func tick() {
        let t = Date().timeIntervalSince(start)
        if let pb = renderer.frame(index: index, name: name, top: top, bottom: bottom, t: t) { frames.put(pb) }
    }
}

final class DemoRenderer: @unchecked Sendable {
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var label: (String, CIImage)?
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
        let font = mono ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : UIFont.systemFont(ofSize: size, weight: weight)
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: UIColor.white])
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        let img = UIGraphicsImageRenderer(size: a.size(), format: fmt).image { _ in a.draw(at: .zero) }
        return img.cgImage.map { CIImage(cgImage: $0) } ?? CIImage.empty()
    }
}

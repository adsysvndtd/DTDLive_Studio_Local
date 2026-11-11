import Accelerate
import CoreImage
import CoreVideo
import Foundation
import SwiftUI

enum ScopeKind: String, CaseIterable, Identifiable {
    case histogram, waveform, parade, vectorscope
    var id: String { rawValue }
    var label: String {
        switch self {
        case .histogram: return "Histogram"
        case .waveform: return "Waveform"
        case .parade: return "RGB Parade"
        case .vectorscope: return "Vectorscope"
        }
    }
}

/// CPU scopes computed on a downscaled copy of program (~320x180, 5 fps) — cheap and accurate enough.
final class ScopeAnalyzer: @unchecked Sendable {
    struct Result {
        var histogram: [[Float]] = [[], [], [], []]          // R,G,B,Luma, 256 bins normalised
        var waveform: [[Float]] = []                           // columns x 64 rows (luma density)
        var parade: [[[Float]]] = [[], [], []]                 // per channel columns x 64
        var vector: [Float] = []                               // 64x64 density (Cb, Cr)
    }

    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let w = 256, h = 144
    private var rgba: [UInt8]

    init() { rgba = [UInt8](repeating: 0, count: 256 * 144 * 4) }

    func analyze(_ pb: CVPixelBuffer) -> Result {
        let img = CIImage(cvPixelBuffer: pb)
        let s = CGAffineTransform(scaleX: CGFloat(w) / img.extent.width, y: CGFloat(h) / img.extent.height)
        ci.render(img.transformed(by: s), toBitmap: &rgba, rowBytes: w * 4,
                  bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var r = Result()
        var hist = [[Float]](repeating: [Float](repeating: 0, count: 256), count: 4)
        let rows = 64
        var wave = [[Float]](repeating: [Float](repeating: 0, count: rows), count: w)
        var par = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: rows), count: w), count: 3)
        var vec = [Float](repeating: 0, count: 64 * 64)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let R = Float(rgba[i]), G = Float(rgba[i + 1]), B = Float(rgba[i + 2])
                let Y = 0.2126 * R + 0.7152 * G + 0.0722 * B
                hist[0][Int(R)] += 1; hist[1][Int(G)] += 1; hist[2][Int(B)] += 1; hist[3][min(255, Int(Y))] += 1
                wave[x][min(rows - 1, Int(Y) * rows / 256)] += 1
                par[0][x][Int(R) * rows / 256] += 1; par[1][x][Int(G) * rows / 256] += 1; par[2][x][Int(B) * rows / 256] += 1
                let cb = -0.1146 * R - 0.3854 * G + 0.5 * B + 128
                let cr = 0.5 * R - 0.4542 * G - 0.0458 * B + 128
                vec[min(63, Int(cr) / 4) * 64 + min(63, Int(cb) / 4)] += 1
            }
        }
        func norm(_ a: [Float]) -> [Float] { let m = max(a.max() ?? 1, 1); return a.map { $0 / m } }
        r.histogram = hist.map(norm)
        r.waveform = wave.map { col in col.map { min(1, $0 / 6) } }
        r.parade = par.map { ch in ch.map { col in col.map { min(1, $0 / 6) } } }
        r.vector = vec.map { min(1, $0 / 20) }
        return r
    }
}

struct ScopeView: View {
    let kind: ScopeKind
    let result: ScopeAnalyzer.Result

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            switch kind {
            case .histogram:
                let colors: [Color] = [.red, .green, .blue, .white]
                for (c, bins) in result.histogram.enumerated() where !bins.isEmpty {
                    var p = Path(); p.move(to: CGPoint(x: 0, y: size.height))
                    for (i, v) in bins.enumerated() {
                        p.addLine(to: CGPoint(x: size.width * CGFloat(i) / 255, y: size.height * (1 - CGFloat(v))))
                    }
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    ctx.fill(p, with: .color(colors[c].opacity(0.35)))
                }
            case .waveform:
                drawColumns(ctx, size, result.waveform, color: .green, x0: 0, width: size.width)
            case .parade:
                let cw = size.width / 3
                for (c, col) in [Color.red, .green, .blue].enumerated() where c < result.parade.count {
                    drawColumns(ctx, size, result.parade[c], color: col, x0: cw * CGFloat(c), width: cw)
                }
            case .vectorscope:
                let side = min(size.width, size.height)
                let cell = side / 64, ox = (size.width - side) / 2
                for i in 0..<min(result.vector.count, 4096) where result.vector[i] > 0 {
                    let x = i % 64, y = i / 64
                    ctx.fill(Path(CGRect(x: ox + CGFloat(x) * cell, y: side - CGFloat(y + 1) * cell, width: cell, height: cell)),
                             with: .color(.green.opacity(Double(result.vector[i]))))
                }
                ctx.stroke(Path(ellipseIn: CGRect(x: ox, y: 0, width: side, height: side)), with: .color(.gray.opacity(0.5)))
            }
            // 0 / 100 IRE guides
            ctx.stroke(Path { $0.move(to: .init(x: 0, y: 1)); $0.addLine(to: .init(x: size.width, y: 1)) }, with: .color(.gray.opacity(0.4)))
        }
    }

    private func drawColumns(_ ctx: GraphicsContext, _ size: CGSize, _ cols: [[Float]], color: Color, x0: CGFloat, width: CGFloat) {
        guard !cols.isEmpty else { return }
        let cw = width / CGFloat(cols.count), rh = size.height / CGFloat(cols[0].count)
        for (x, col) in cols.enumerated() {
            for (y, v) in col.enumerated() where v > 0 {
                ctx.fill(Path(CGRect(x: x0 + CGFloat(x) * cw, y: size.height - CGFloat(y + 1) * rh, width: max(cw, 1), height: rh)),
                         with: .color(color.opacity(Double(v))))
            }
        }
    }
}

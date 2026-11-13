import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Per-input image pipeline applied before switching:
/// crop/mirror -> color grade -> LUT -> chroma key. All CoreImage, GPU-fused by CI.
struct SourceProcessing: Equatable, Codable {
    // Geometry
    var mirror = false
    var rotate180 = false
    /// Extra clockwise quarter turns (0…3) for sources sent sideways (e.g. a phone streaming 9:16 → 16:9).
    /// Optional so settings saved before it existed still decode.
    var quarterTurns: Int?
    /// Total clockwise rotation in quarter turns.
    var turns: Int { ((quarterTurns ?? 0) + (rotate180 ? 2 : 0)) % 4 }
    var cropTop: CGFloat = 0, cropBottom: CGFloat = 0, cropLeft: CGFloat = 0, cropRight: CGFloat = 0 // 0..0.45

    // Color grade
    var exposure: Float = 0        // EV, -2...2
    var contrast: Float = 1        // 0.5...1.5
    var saturation: Float = 1      // 0...2
    var temperature: Float = 6500  // K, 3000...10000
    var tint: Float = 0            // -100...100
    var lutName: String?           // file in Documents/LUTs

    // Chroma key
    var chromaEnabled = false
    var keyHue: Float = 120        // degrees: 120 green, 240 blue
    var keyTolerance: Float = 30   // degrees around keyHue
    var keySoftness: Float = 10
    var keyMinSaturation: Float = 0.25
    var keyBackgroundID: UUID?     // source/image composited behind the key

    var isIdentity: Bool { self == SourceProcessing() }
}

/// Builds and caches CI filters for SourceProcessing.
final class ProcessingRenderer: @unchecked Sendable {
    private var lutCache: [String: (Int, Data)] = [:]
    private var keyCubeCache: [String: Data] = [:]
    private let lock = NSLock()

    func apply(_ p: SourceProcessing, to input: CIImage, background: CIImage?) -> CIImage {
        var img = input

        switch p.turns {
        case 1: img = img.oriented(.right)
        case 2: img = img.oriented(.down)
        case 3: img = img.oriented(.left)
        default: break
        }
        if p.turns != 0 { img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY)) }
        let e = img.extent
        if p.mirror { img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -e.width, y: 0)) }
        if p.cropTop + p.cropBottom + p.cropLeft + p.cropRight > 0 {
            let r = CGRect(x: e.minX + e.width * p.cropLeft, y: e.minY + e.height * p.cropBottom,
                           width: e.width * (1 - p.cropLeft - p.cropRight), height: e.height * (1 - p.cropTop - p.cropBottom))
            img = img.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        }

        if p.exposure != 0 {
            let f = CIFilter.exposureAdjust(); f.inputImage = img; f.ev = p.exposure; img = f.outputImage ?? img
        }
        if p.contrast != 1 || p.saturation != 1 {
            let f = CIFilter.colorControls(); f.inputImage = img; f.contrast = p.contrast; f.saturation = p.saturation
            img = f.outputImage ?? img
        }
        if p.temperature != 6500 || p.tint != 0 {
            let f = CIFilter.temperatureAndTint(); f.inputImage = img
            f.neutral = CIVector(x: CGFloat(p.temperature), y: CGFloat(p.tint))
            f.targetNeutral = CIVector(x: 6500, y: 0)
            img = f.outputImage ?? img
        }
        if let name = p.lutName, let (dim, data) = lut(named: name) {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = img; f.cubeDimension = Float(dim); f.cubeData = data
            f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            img = f.outputImage ?? img
        }
        if p.chromaEnabled {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = img; f.cubeDimension = 64; f.cubeData = keyCube(p)
            f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            img = f.outputImage ?? img
            if let background { img = img.composited(over: background) }
        }
        return img
    }

    // MARK: LUT (.cube, Adobe/Resolve format)

    static var lutDirectory: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LUTs")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func availableLUTs() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: lutDirectory.path))?.filter { $0.lowercased().hasSuffix(".cube") }.sorted() ?? []
    }

    private func lut(named name: String) -> (Int, Data)? {
        lock.lock(); defer { lock.unlock() }
        if let c = lutCache[name] { return c }
        guard let text = try? String(contentsOf: Self.lutDirectory.appendingPathComponent(name), encoding: .utf8),
              let parsed = Self.parseCube(text) else { return nil }
        lutCache[name] = parsed
        return parsed
    }

    /// Parses a 3D .cube file into RGBA float32 data for CIColorCube (red fastest, as both specs order it).
    static func parseCube(_ text: String) -> (Int, Data)? {
        var size = 0
        var values: [Float] = []
        var domainMin: [Float] = [0, 0, 0], domainMax: [Float] = [1, 1, 1]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            switch parts.first {
            case "LUT_3D_SIZE": size = Int(parts[1]) ?? 0
            case "LUT_1D_SIZE": return nil
            case "DOMAIN_MIN": domainMin = parts.dropFirst().compactMap { Float($0) }
            case "DOMAIN_MAX": domainMax = parts.dropFirst().compactMap { Float($0) }
            default:
                let rgb = parts.compactMap { Float($0) }
                guard rgb.count == 3 else { continue }
                for c in 0..<3 { values.append((rgb[c] - domainMin[c]) / max(domainMax[c] - domainMin[c], 0.0001)) }
                values.append(1)
            }
        }
        guard size >= 2, values.count == size * size * size * 4 else { return nil }
        return (size, values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    // MARK: Chroma key cube (alpha = 0 inside hue band, soft edge, premultiplied)

    private func keyCube(_ p: SourceProcessing) -> Data {
        let key = "\(p.keyHue)-\(p.keyTolerance)-\(p.keySoftness)-\(p.keyMinSaturation)"
        lock.lock(); defer { lock.unlock() }
        if let d = keyCubeCache[key] { return d }
        let n = 64
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let rf = Float(r) / Float(n - 1), gf = Float(g) / Float(n - 1), bf = Float(b) / Float(n - 1)
                    let (h, s, _) = Self.hsv(rf, gf, bf)
                    var d = abs(h - p.keyHue); if d > 180 { d = 360 - d }
                    var alpha: Float = 1
                    if s >= p.keyMinSaturation {
                        if d <= p.keyTolerance { alpha = 0 }
                        else if d <= p.keyTolerance + p.keySoftness { alpha = (d - p.keyTolerance) / max(p.keySoftness, 0.001) }
                    }
                    // Spill suppression: clamp the key channel to the max of the other two near the key.
                    var ro = rf, go = gf, bo = bf
                    if alpha < 1 || d < p.keyTolerance * 2 {
                        if p.keyHue > 60 && p.keyHue < 180 { go = min(gf, max(rf, bf)) }
                        else if p.keyHue >= 180 && p.keyHue < 300 { bo = min(bf, max(rf, gf)) }
                    }
                    cube[i] = ro * alpha; cube[i + 1] = go * alpha; cube[i + 2] = bo * alpha; cube[i + 3] = alpha
                    i += 4
                }
            }
        }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        keyCubeCache[key] = data
        return data
    }

    static func hsv(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h: Float = 0
        if d > 0 {
            if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = 60 * ((b - r) / d + 2) }
            else { h = 60 * ((r - g) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }
}

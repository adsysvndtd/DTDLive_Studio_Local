import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Metal
import os

enum TransitionStyle: String, CaseIterable, Identifiable, Codable {
    case cut, mix, wipeLeft, dip
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cut: return "CUT"
        case .mix: return "MIX"
        case .wipeLeft: return "WIPE"
        case .dip: return "DIP"
        }
    }
}

struct ProgramFormat: Equatable {
    var width = 1920
    var height = 1080
    var fps = 30
    /// Vertical (9:16) output for TikTok/Reels-style platforms.
    static let vertical1080 = ProgramFormat(width: 1080, height: 1920, fps: 30)
}

/// Overlay drawn on top of program: logo / lower third / PiP.
struct OverlayLayer: Identifiable {
    let id = UUID()
    var image: CIImage?               // logo or rendered lower third
    var pipSourceID: UUID?            // picture-in-picture source (gets its own processing/key)
    var cornerRadius: CGFloat = 0
    var borderWidth: CGFloat = 0
    var rect: CGRect                  // normalised 0..1, origin top-left
    var opacity: CGFloat = 1
    var visible = true
}

/// Program/preview switcher. Runs a fixed-rate render clock independent of sources,
/// so program output never stalls when one input freezes (shows "no signal" slate).
final class Switcher: @unchecked Sendable {
    typealias FrameHandler = @Sendable (CVPixelBuffer, CFTimeInterval) -> Void

    private let ciContext: CIContext
    private var pool: CVPixelBufferPool?
    private let queue = DispatchQueue(label: "switcher.render", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var lock = os_unfair_lock()

    private(set) var format = ProgramFormat()
    private var inputs: [UUID: FrameStore] = [:]
    private var programID: UUID?
    private var previewID: UUID?
    private var transition: (style: TransitionStyle, from: UUID?, to: UUID?, start: CFTimeInterval, duration: CFTimeInterval)?
    private var overlays: [OverlayLayer] = []
    private var processing: [UUID: SourceProcessing] = [:]
    private let processor = ProcessingRenderer()
    /// Called once per program frame with the IDs on air (for tally / audio-follow-video).
    var onTally: (@Sendable (_ program: Set<UUID>, _ preview: Set<UUID>) -> Void)?
    private var ftb = false // fade to black

    /// Encoded-path consumer (encoder) and monitor consumers (UI).
    var onProgramFrame: FrameHandler?
    /// Per-frame full-canvas graphics (titles, ticker, clock, Pencil annotations), drawn above overlays.
    var graphicsProvider: (@Sendable (CGSize, CFTimeInterval) -> CIImage?)?
    let programMonitor = FrameStore()
    let previewMonitor = FrameStore()

    init() {
        let device = MTLCreateSystemDefaultDevice()!
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        makePool()
    }

    // MARK: Control (any thread)

    func setFormat(_ f: ProgramFormat) { locked { format = f }; queue.async { self.makePool(); self.restartClock() } }
    func register(_ id: UUID, store: FrameStore) { locked { inputs[id] = store } }
    func unregister(_ id: UUID) { locked { inputs[id] = nil; if programID == id { programID = nil }; if previewID == id { previewID = nil } } }
    func setPreview(_ id: UUID?) { locked { previewID = id } }
    func setOverlays(_ o: [OverlayLayer]) { locked { overlays = o } }
    func setFadeToBlack(_ on: Bool) { locked { ftb = on } }
    func setProcessing(_ id: UUID, _ p: SourceProcessing?) { locked { processing[id] = (p?.isIdentity ?? true) ? nil : p } }
    var state: (program: UUID?, preview: UUID?) { locked { (programID, previewID) } }

    /// CUT: preview goes to program immediately, program goes back to preview.
    func cut() {
        locked {
            let p = programID
            programID = previewID
            previewID = p
            transition = nil
        }
    }

    /// AUTO: animated transition preview -> program.
    func auto(_ style: TransitionStyle, duration: CFTimeInterval = 0.8) {
        guard style != .cut else { cut(); return }
        locked {
            transition = (style, programID, previewID, HostClock.now, duration)
        }
    }

    /// Hot-punch a source straight to program (multiview double-tap).
    func take(_ id: UUID) { locked { previewID = programID; programID = id; transition = nil } }

    // MARK: Render clock

    func start() { queue.async { self.restartClock() } }
    func stop() { timer?.cancel(); timer = nil }

    private func restartClock() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = 1.0 / Double(format.fps)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.renderTick() }
        t.resume()
        timer = t
    }

    private func renderTick() {
        let now = HostClock.now
        let snap = locked { () -> (UUID?, UUID?, (TransitionStyle, UUID?, CFTimeInterval)?, [OverlayLayer], Bool, ProgramFormat) in
            var tr: (TransitionStyle, UUID?, CFTimeInterval)?
            if let t = transition {
                let progress = (now - t.start) / t.duration
                if progress >= 1 {
                    previewID = t.from
                    programID = t.to
                    transition = nil
                } else {
                    tr = (t.style, t.to, progress)
                }
            }
            return (programID, previewID, tr, overlays, ftb, format)
        }
        let tallyPgm = Set([snap.0, snap.2?.1].compactMap { $0 } + snap.3.compactMap { $0.pipSourceID })
        onTally?(tallyPgm, Set([snap.1].compactMap { $0 }))
        let extent = CGRect(x: 0, y: 0, width: snap.5.width, height: snap.5.height)

        var program = image(from: snap.0, fitting: extent)
        if let (style, target, progress) = snap.2 {
            let b = image(from: target, fitting: extent)
            program = blend(program, b, style: style, progress: CGFloat(progress), extent: extent)
        }
        for o in snap.3 where o.visible {
            program = composite(o, over: program, extent: extent)
        }
        if let g = graphicsProvider?(extent.size, now) { program = g.composited(over: program).cropped(to: extent) }
        if snap.4 { program = CIImage(color: .black).cropped(to: extent) }

        guard let out = render(program, extent: extent) else { return }
        programMonitor.put(out)
        onProgramFrame?(out, now)

        // Preview monitor at reduced cost: share the same pool.
        if let pv = render(image(from: snap.1, fitting: extent), extent: extent) {
            previewMonitor.put(pv)
        }
    }

    // MARK: Image ops

    private func image(from id: UUID?, fitting extent: CGRect) -> CIImage {
        let (store, proc) = locked { (id.flatMap { inputs[$0] }, id.flatMap { processing[$0] }) }
        guard let pb = store?.latest() else { return Self.slate(extent) }
        var img = CIImage(cvPixelBuffer: pb)
        if let proc {
            let bg = proc.keyBackgroundID.flatMap { bid in locked { inputs[bid] } }?.latest().map { CIImage(cvPixelBuffer: $0) }
                .map { b in b.transformed(by: CGAffineTransform(scaleX: img.extent.width / b.extent.width, y: img.extent.height / b.extent.height)) }
            img = processor.apply(proc, to: img, background: bg)
        }
        let scale = min(extent.width / img.extent.width, extent.height / img.extent.height)
        let scaled = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (extent.width - scaled.extent.width) / 2 - scaled.extent.minX
        let dy = (extent.height - scaled.extent.height) / 2 - scaled.extent.minY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .composited(over: CIImage(color: .black).cropped(to: extent))
            .cropped(to: extent)
    }

    private func blend(_ a: CIImage, _ b: CIImage, style: TransitionStyle, progress p: CGFloat, extent: CGRect) -> CIImage {
        switch style {
        case .cut:
            return b
        case .mix:
            let f = CIFilter.dissolveTransition()
            f.inputImage = a; f.targetImage = b; f.time = Float(p)
            return f.outputImage?.cropped(to: extent) ?? b
        case .wipeLeft:
            let f = CIFilter.swipeTransition()
            f.inputImage = a; f.targetImage = b; f.time = Float(p)
            f.extent = extent; f.angle = .pi; f.width = 40; f.opacity = 0
            return f.outputImage?.cropped(to: extent) ?? b
        case .dip:
            let black = CIImage(color: .black).cropped(to: extent)
            let f = CIFilter.dissolveTransition()
            if p < 0.5 { f.inputImage = a; f.targetImage = black; f.time = Float(p * 2) }
            else { f.inputImage = black; f.targetImage = b; f.time = Float((p - 0.5) * 2) }
            return f.outputImage?.cropped(to: extent) ?? b
        }
    }

    private func composite(_ o: OverlayLayer, over base: CIImage, extent: CGRect) -> CIImage {
        // Normalised top-left rect -> CoreImage bottom-left pixels.
        let r = CGRect(x: o.rect.minX * extent.width,
                       y: (1 - o.rect.maxY) * extent.height,
                       width: o.rect.width * extent.width,
                       height: o.rect.height * extent.height)
        var src: CIImage?
        if let pipID = o.pipSourceID { src = pipImage(pipID) }
        else { src = o.image }
        guard var img = src else { return base }
        let s = min(r.width / img.extent.width, r.height / img.extent.height)
        img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        img = img.transformed(by: CGAffineTransform(translationX: r.minX - img.extent.minX, y: r.minY - img.extent.minY))
        if o.opacity < 1 {
            img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: o.opacity)])
        }
        return img.composited(over: base).cropped(to: extent)
    }

    private func pipImage(_ id: UUID) -> CIImage? {
        let (store, proc) = locked { (inputs[id], processing[id]) }
        guard let pb = store?.latest() else { return nil }
        let img = CIImage(cvPixelBuffer: pb)
        return proc.map { processor.apply($0, to: img, background: nil) } ?? img
    }

    private static func slate(_ extent: CGRect) -> CIImage {
        let bars = CIFilter.stripesGenerator()
        bars.color0 = CIColor(red: 0.12, green: 0.12, blue: 0.14)
        bars.color1 = CIColor(red: 0.08, green: 0.08, blue: 0.10)
        bars.width = 60
        return (bars.outputImage ?? CIImage(color: .black)).cropped(to: extent)
    }

    private func render(_ img: CIImage, extent: CGRect) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferPoolAllocationThresholdKey: 12] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, attrs, &pb) == kCVReturnSuccess, let pb else {
            return nil // pool exhausted: encoder/network is behind, drop this frame
        }
        ciContext.render(img, to: pb, bounds: extent, colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
        return pb
    }

    private func makePool() {
        let f = locked { format }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: f.width,
            kCVPixelBufferHeightKey as String: f.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary, attrs as CFDictionary, &p)
        pool = p
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
}

import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Metal
import os
import UIKit

enum TransitionStyle: String, CaseIterable, Identifiable, Codable {
    case cut, mix, wipeLeft, dip, flash, push, zoom, pageCurl, ripple, bars, copyMachine, mod, fold
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cut: return "CUT"
        case .mix: return "MIX"
        case .wipeLeft: return "WIPE"
        case .dip: return "DIP"
        case .flash: return "FLASH"
        case .push: return "PUSH"
        case .zoom: return "ZOOM"
        case .pageCurl: return L("LẬT")
        case .ripple: return L("GỢN")
        case .bars: return L("SỌC")
        case .copyMachine: return L("QUÉT")
        case .mod: return "MOD"
        case .fold: return L("GẤP")
        }
    }
    var icon: String {
        switch self {
        case .cut: return "scissors"
        case .mix: return "circle.lefthalf.filled"
        case .wipeLeft: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .dip: return "moon.fill"
        case .flash: return "bolt.fill"
        case .push: return "arrow.left.square"
        case .zoom: return "plus.magnifyingglass"
        case .pageCurl: return "doc.richtext"
        case .ripple: return "drop.circle"
        case .bars: return "rectangle.split.3x1"
        case .copyMachine: return "light.beacon.max"
        case .mod: return "circle.hexagongrid"
        case .fold: return "rectangle.split.3x1.fill"
        }
    }
}

struct ProgramFormat: Equatable, Codable, Hashable {
    var width = 1920
    var height = 1080
    var fps = 30
    /// Vertical (9:16) output for TikTok/Reels-style platforms.
    static let vertical1080 = ProgramFormat(width: 1080, height: 1920, fps: 30)

    struct Resolution: Identifiable, Hashable {
        let id: String; let label: String; let width: Int; let height: Int
    }
    static let resolutions: [Resolution] = [
        .init(id: "720p", label: "1280×720 (HD)", width: 1280, height: 720),
        .init(id: "1080p", label: "1920×1080 (Full HD)", width: 1920, height: 1080),
        .init(id: "2160p", label: "3840×2160 (4K, iPad Pro M-series)", width: 3840, height: 2160),
        .init(id: "v720", label: "720×1280 (dọc)", width: 720, height: 1280),
        .init(id: "v1080", label: "1080×1920 (dọc)", width: 1080, height: 1920)
    ]
    static let frameRates = [25, 30, 50, 60]
    var isVertical: Bool { height > width }
    var resolutionID: String { Self.resolutions.first { $0.width == width && $0.height == height }?.id ?? "1080p" }
}

/// Overlay drawn on top of program: logo / lower third / PiP.
struct OverlayLayer: Identifiable {
    let id = UUID()
    var image: CIImage?               // logo or rendered lower third
    var pipSourceID: UUID?            // picture-in-picture source (gets its own processing/key)
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
    private var ftbChangedAt: CFTimeInterval = 0
    /// Product slate shown by FTB: black with the DTD Studio logo (cached per output size).
    private var ftbSlate: (CGSize, CIImage)?
    var ftbLogo: UIImage? = UIImage(named: "Logo")

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

    // MARK: SuperFG card (full-screen animated graphic)

    struct Card {
        var background: CIImage
        var text: CIImage?
        var motion: SuperFGMotion
        /// Text animation override (nil = follows the card's motion).
        var textMotion: SuperFGTextMotion? = nil
        var inAt: CFTimeInterval
        var outAt: CFTimeInterval?
        /// Held progress 0…1 set by the T-bar (stinger); nil = timed in/out.
        var manual: CGFloat? = nil
    }
    static let cardIn: CFTimeInterval = 0.75
    static let cardOut: CFTimeInterval = 0.6
    private var card: Card?
    // SuperFG stinger (card used as the transition): timed (Auto / Cut) and manual (T-bar).
    private var stingerTo: UUID?
    private var stingerHold: CFTimeInterval = 0.3
    private var stingerOutAt: CFTimeInterval?
    private var stingerManual: (from: UUID?, to: UUID)?
    var stingerBusy: Bool { locked { stingerTo != nil || stingerOutAt != nil || stingerManual != nil } }

    /// Auto / Cut with a SuperFG card: the card plays in, PVW→PGM switches while it covers the
    /// screen, the card stays `hold` seconds, then plays out.
    func stingerAuto(background: CIImage, text: CIImage?, motion: SuperFGMotion, textMotion: SuperFGTextMotion?, hold: CFTimeInterval) {
        let now = HostClock.now
        locked {
            guard let to = previewID, to != programID, transition == nil,
                  stingerTo == nil, stingerOutAt == nil, stingerManual == nil else { return }
            card = Card(background: background, text: text, motion: motion, textMotion: textMotion, inAt: now, outAt: nil)
            stingerTo = to; stingerHold = max(0.05, hold)
        }
    }

    /// T-bar with a SuperFG card: 0…0.5 the card comes in, the cameras switch at the middle
    /// (behind the card), 0.5…1 the card leaves. Fully reversible until the end of the stroke.
    /// Returns true when program/preview changed.
    @discardableResult
    func stingerManual(_ progress: Double, background: CIImage, text: CIImage?, motion: SuperFGMotion, textMotion: SuperFGTextMotion?) -> Bool {
        let p = max(0, min(1, progress))
        let now = HostClock.now
        return locked { () -> Bool in
            let before = (programID, previewID)
            if stingerManual == nil {
                guard p > 0.001, p < 0.999, let to = previewID, to != programID, transition == nil,
                      stingerTo == nil, stingerOutAt == nil else { return false }
                stingerManual = (programID, to)
                card = Card(background: background, text: text, motion: motion, textMotion: textMotion, inAt: now, outAt: nil, manual: 0)
            }
            guard let m = stingerManual else { return false }
            if p >= 0.999 || p <= 0.001 {
                // End of the stroke: finished (B on air) or pulled back (A stays).
                if p >= 0.999 { programID = m.to; previewID = m.from } else { programID = m.from; previewID = m.to }
                card = nil; stingerManual = nil
            } else {
                if p >= 0.5 { programID = m.to; previewID = m.from } else { programID = m.from; previewID = m.to }
                card?.manual = CGFloat(p < 0.5 ? p * 2 : (1 - p) * 2)
            }
            return before != (programID, previewID)
        }
    }

    private func clearStinger() { stingerTo = nil; stingerOutAt = nil; stingerManual = nil }

    /// Starts a card's in-animation (replaces any card on screen).
    func showCard(background: CIImage, text: CIImage?, motion: SuperFGMotion, textMotion: SuperFGTextMotion? = nil) {
        let now = HostClock.now
        locked { clearStinger(); card = Card(background: background, text: text, motion: motion, textMotion: textMotion, inAt: now, outAt: nil) }
    }
    /// Swaps the artwork of the card on screen without restarting its animation (text edits).
    func updateCard(background: CIImage, text: CIImage?, motion: SuperFGMotion, textMotion: SuperFGTextMotion? = nil) {
        locked {
            guard card != nil else { return }
            card?.background = background; card?.text = text; card?.motion = motion; card?.textMotion = textMotion
        }
    }
    /// Plays the out-animation.
    func hideCard() {
        let now = HostClock.now
        locked {
            clearStinger()
            guard let c = card, c.outAt == nil else { return }
            if c.manual != nil { card = nil; return }
            // Leaving during the in-animation: start out from the current position.
            let p = min(1, (now - c.inAt) / Self.cardIn)
            card?.outAt = now - (1 - p) * Self.cardOut
        }
    }

    func setFadeToBlack(_ on: Bool) { locked { if ftb != on { ftb = on; ftbChangedAt = HostClock.now } } }
    func setProcessing(_ id: UUID, _ p: SourceProcessing?) { locked { processing[id] = (p?.isIdentity ?? true) ? nil : p } }
    var state: (program: UUID?, preview: UUID?) { locked { (programID, previewID) } }

    /// CUT: preview goes to program immediately, program goes back to preview.
    func cut() {
        locked {
            let p = programID
            programID = previewID
            previewID = p
            transition = nil
            if stingerManual != nil { card = nil }
            clearStinger()
        }
    }

    /// AUTO: animated transition preview -> program.
    func auto(_ style: TransitionStyle, duration: CFTimeInterval = 0.8) {
        guard style != .cut else { cut(); return }
        locked {
            guard previewID != nil, previewID != programID, transition == nil else { return }
            transition = (style, programID, previewID, HostClock.now, duration)
        }
    }

    /// Manual T-bar. 0 = program only, 1 = transition finished (preview becomes program).
    /// Progress is held (not timed) while the bar is moved.
    func setManual(_ progress: Double, style: TransitionStyle) {
        let p = max(0, min(1, progress))
        locked {
            if p >= 0.999 {
                guard let to = transition?.to ?? previewID else { transition = nil; return }
                previewID = programID; programID = to; transition = nil
                return
            }
            guard p > 0.001, let to = transition?.to ?? previewID, to != programID else { transition = nil; return }
            let hold: CFTimeInterval = 1_000_000 // huge duration -> progress stays put between bar moves
            transition = (style == .cut ? .mix : style, programID, to, HostClock.now - p * hold, hold)
        }
    }

    /// Hot-punch a source straight to program (multiview double-tap).
    func take(_ id: UUID) { locked { previewID = programID; programID = id; transition = nil; if stingerManual != nil { card = nil }; clearStinger() } }

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
            // FTB mix amount: 0…1 over 0.6 s when switching on, 1…0 when switching off
            let k = min(1, (now - ftbChangedAt) / 0.6)
            ftbMix = ftb ? k : 1 - k
            return (programID, previewID, tr, overlays, ftb, format)
        }
        let cardSnap: Card? = locked {
            // Stinger: switch behind the card once it covers the screen, then play it out after the hold.
            if let to = stingerTo, let c = card, c.manual == nil, now - c.inAt >= Self.cardIn {
                previewID = programID; programID = to; stingerTo = nil
                stingerOutAt = now + stingerHold
            }
            if let t = stingerOutAt, now >= t {
                if card?.outAt == nil { card?.outAt = now }
                stingerOutAt = nil
            }
            if let c = card, let o = c.outAt, now - o >= Self.cardOut { card = nil }
            return card
        }
        let tallyPgm = Set([snap.0, snap.2?.1].compactMap { $0 } + snap.3.compactMap { $0.pipSourceID })
        onTally?(tallyPgm, Set([snap.1].compactMap { $0 }))
        let extent = CGRect(x: 0, y: 0, width: snap.5.width, height: snap.5.height)

        var program = image(from: snap.0, fitting: extent)
        if let (style, target, progress) = snap.2 {
            let b = image(from: target, fitting: extent)
            program = Self.blend(program, b, style: style, progress: CGFloat(progress), extent: extent)
        }
        for o in snap.3 where o.visible {
            program = composite(o, over: program, extent: extent)
        }
        if let g = graphicsProvider?(extent.size, now) { program = g.composited(over: program).cropped(to: extent) }
        if let c = cardSnap { program = Self.cardFrame(c, now: now, over: program, extent: extent) }
        if ftbMix > 0.001 {
            let slate = productSlate(extent.size)
            program = ftbMix >= 0.999 ? slate
                : program.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": slate, "inputTime": ftbMix]).cropped(to: extent)
        }

        guard let out = render(program, extent: extent) else { return }
        renderedFrames.add(1)
        programMonitor.put(out)
        onProgramFrame?(out, cadencePTS(now, fps: Double(snap.5.fps)))

        // Preview monitor is only for the operator: half resolution, every other frame.
        previewTick &+= 1
        if previewTick % 2 == 0 {
            let half = CGRect(x: 0, y: 0, width: (extent.width / 2).rounded(), height: (extent.height / 2).rounded())
            let pv = image(from: snap.1, fitting: extent).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)).cropped(to: half)
            if let pb = renderPreview(pv, extent: half) { previewMonitor.put(pb) }
        }
        let ms = (HostClock.now - now) * 1000
        renderStats.record(ms, budget: 1000 / Double(snap.5.fps))
    }

    // MARK: Timing

    private var previewTick = 0
    private var previewPool: (CGSize, CVPixelBufferPool)?
    private var ptsBase: CFTimeInterval = 0
    private var ptsIndex: Int64 = 0
    private var ptsFPS: Double = 0

    /// Encoder timestamps on an exact frame grid (the timer fires a few ms early/late; jittered PTS makes
    /// players stutter). Re-anchors to the host clock if it drifts more than two frames, so audio stays in sync.
    private var lastPTS: CFTimeInterval = 0

    private func cadencePTS(_ now: CFTimeInterval, fps: Double) -> CFTimeInterval {
        if fps != ptsFPS { ptsFPS = fps; ptsBase = now; ptsIndex = 0 }
        let ideal = ptsBase + Double(ptsIndex) / fps
        if abs(now - ideal) > 2 / fps { ptsBase = now; ptsIndex = 0 }
        // Never go backwards (or repeat): VideoToolbox rejects a decreasing PTS and the session has to be rebuilt.
        let pts = max(ptsBase + Double(ptsIndex) / fps, lastPTS + 0.25 / fps)
        if pts != ptsBase + Double(ptsIndex) / fps { ptsBase = pts; ptsIndex = 0 }
        ptsIndex += 1
        lastPTS = pts
        return pts
    }

    /// Render time per program frame, for the on-air log ("dựng TB/max ms, trễ").
    final class RenderStats: @unchecked Sendable {
        private let lock = NSLock()
        private var sum = 0.0, count = 0, maxMs = 0.0, over = 0
        func record(_ ms: Double, budget: Double) {
            lock.lock(); sum += ms; count += 1; maxMs = max(maxMs, ms); if ms > budget { over += 1 }; lock.unlock()
        }
        /// Average ms, max ms, frames over budget — and resets.
        func take() -> (avg: Double, max: Double, over: Int) {
            lock.lock(); defer { sum = 0; count = 0; maxMs = 0; over = 0; lock.unlock() }
            return (count > 0 ? sum / Double(count) : 0, maxMs, over)
        }
    }
    let renderStats = RenderStats()

    private func renderPreview(_ img: CIImage, extent: CGRect) -> CVPixelBuffer? {
        if previewPool?.0 != extent.size {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: Int(extent.width), kCVPixelBufferHeightKey as String: Int(extent.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attrs as CFDictionary, &p)
            previewPool = p.map { (extent.size, $0) }
        }
        guard let pool = previewPool?.1 else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return nil }
        ciContext.render(img, to: pb, bounds: extent, colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
        Self.tag709(pb)
        return pb
    }

    private var ftbMix: Double = 0

    /// Black frame with the product logo + name, centred.
    private func productSlate(_ size: CGSize) -> CIImage {
        if let c = ftbSlate, c.0 == size { return c.1 }
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let ui = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let h = size.height * 0.26
            if let logo = ftbLogo {
                let w = h * logo.size.width / max(logo.size.height, 1)
                logo.draw(in: CGRect(x: (size.width - w) / 2, y: size.height * 0.5 - h * 0.72, width: w, height: h))
            }
            let p = NSMutableParagraphStyle(); p.alignment = .center
            let f = UIFont.systemFont(ofSize: size.height * 0.05, weight: .heavy)
            ("DTD STUDIO" as NSString).draw(in: CGRect(x: 0, y: size.height * 0.5 + h * 0.38, width: size.width, height: f.lineHeight),
                withAttributes: [.font: f, .foregroundColor: UIColor.white, .paragraphStyle: p, .kern: size.height * 0.008])
        }
        let ci = ui.cgImage.map { CIImage(cgImage: $0) } ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        ftbSlate = (size, ci)
        return ci
    }

    // MARK: Image ops

    private func image(from id: UUID?, fitting extent: CGRect) -> CIImage {
        let (store, proc) = locked { (id.flatMap { inputs[$0] }, id.flatMap { processing[$0] }) }
        // No source / no signal: the same product slate as FTB (black + DTD Studio logo) on PGM and PVW.
        guard let pb = store?.latest() else { return productSlate(extent.size).cropped(to: extent) }
        var img = CIImage(cvPixelBuffer: pb)
        if let proc {
            let bg = proc.keyBackgroundID.flatMap { bid in locked { inputs[bid] } }?.latest().map { CIImage(cvPixelBuffer: $0) }
                .map { b in b.transformed(by: CGAffineTransform(scaleX: img.extent.width / b.extent.width, y: img.extent.height / b.extent.height)) }
            img = processor.apply(proc, to: img, background: bg)
        }
        let scale = min(extent.width / img.extent.width, extent.height / img.extent.height)
        let scaled = Self.scaleSharp(img, scale)
        let dx = (extent.width - scaled.extent.width) / 2 - scaled.extent.minX
        let dy = (extent.height - scaled.extent.height) / 2 - scaled.extent.minY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .composited(over: CIImage(color: .black).cropped(to: extent))
            .cropped(to: extent)
    }

    static func blend(_ a: CIImage, _ b: CIImage, style: TransitionStyle, progress p: CGFloat, extent: CGRect) -> CIImage {
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
        case .flash:
            let f = CIFilter.flashTransition()
            f.inputImage = a; f.targetImage = b; f.time = Float(p)
            f.center = CGPoint(x: extent.midX, y: extent.midY); f.extent = extent
            f.color = CIColor(red: 1, green: 1, blue: 1); f.maxStriationRadius = 2.58
            f.striationStrength = 0.5; f.striationContrast = 1.375; f.fadeThreshold = 0.85
            return f.outputImage?.cropped(to: extent) ?? b
        case .push:
            let dx = extent.width * p
            let outA = a.transformed(by: CGAffineTransform(translationX: -dx, y: 0))
            let inB = b.transformed(by: CGAffineTransform(translationX: extent.width - dx, y: 0))
            return inB.composited(over: outA).cropped(to: extent)
        case .zoom:
            let s = 1 + 0.6 * p
            let za = a.transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: extent.midX, y: extent.midY)))
            let f = CIFilter.dissolveTransition()
            f.inputImage = za.cropped(to: extent); f.targetImage = b; f.time = Float(p)
            return f.outputImage?.cropped(to: extent) ?? b
        case .pageCurl:
            let f = CIFilter.pageCurlTransition()
            f.inputImage = a; f.targetImage = b; f.time = Float(p)
            f.extent = extent; f.angle = Float.pi * 0.8; f.radius = Float(extent.width / 8)
            f.backsideImage = a; f.shadingImage = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5)).cropped(to: extent)
            return f.outputImage?.cropped(to: extent) ?? b
        case .ripple:
            let f = CIFilter.rippleTransition()
            f.inputImage = a; f.targetImage = b; f.time = Float(p)
            f.center = CGPoint(x: extent.midX, y: extent.midY); f.extent = extent
            f.width = Float(extent.width / 20); f.scale = 40
            f.shadingImage = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.3)).cropped(to: extent)
            return f.outputImage?.cropped(to: extent) ?? b
        case .bars:
            let f = CIFilter.barsSwipeTransition()
            f.inputImage = a; f.targetImage = b; f.time = Float(p)
            f.angle = Float.pi; f.width = Float(extent.width / 12); f.barOffset = 10
            return f.outputImage?.cropped(to: extent) ?? b
        case .copyMachine:
            let f = CIFilter.copyMachineTransition()
            f.inputImage = a; f.targetImage = b; f.time = Float(p)
            f.extent = extent; f.color = CIColor(red: 0.6, green: 1, blue: 0.8); f.angle = 0
            f.width = Float(extent.width / 6); f.opacity = 1.3
            return f.outputImage?.cropped(to: extent) ?? b
        case .mod:
            let f = CIFilter.modTransition()
            f.inputImage = a; f.targetImage = b; f.time = Float(p)
            f.center = CGPoint(x: extent.midX, y: extent.midY); f.angle = 2; f.radius = Float(extent.width / 12); f.compression = 300
            return f.outputImage?.cropped(to: extent) ?? b
        case .fold:
            let f = CIFilter.accordionFoldTransition()
            f.inputImage = a; f.targetImage = b; f.time = Float(p)
            f.bottomHeight = 0; f.numberOfFolds = 3; f.foldShadowAmount = 0.1
            return f.outputImage?.cropped(to: extent) ?? b
        }
    }

    private static func easeInOut(_ t: CGFloat) -> CGFloat { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    private static func easeOutBack(_ t: CGFloat) -> CGFloat { let c1: CGFloat = 1.7, c3 = c1 + 1; return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2) }

    private static func fade(_ img: CIImage, _ a: CGFloat) -> CIImage {
        a >= 0.999 ? img : img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, a))])
    }

    /// Scales an image about the extent centre.
    private static func scaled(_ img: CIImage, _ k: CGFloat, extent: CGRect) -> CIImage {
        guard abs(k - 1) > 0.0005 else { return img }
        let t = CGAffineTransform(translationX: extent.midX, y: extent.midY).scaledBy(x: k, y: k).translatedBy(x: -extent.midX, y: -extent.midY)
        return img.transformed(by: t)
    }

    /// One frame of a SuperFG card: background reveal by motion, text arriving after it (leaving before it).
    private static func cardFrame(_ c: Card, now: CFTimeInterval, over base: CIImage, extent: CGRect) -> CIImage {
        var raw = min(1, CGFloat((now - c.inAt) / cardIn))
        if let o = c.outAt { raw = min(raw, 1 - min(1, CGFloat((now - o) / cardOut))) }
        if let m = c.manual { raw = max(0, min(1, m)) }
        let p = easeInOut(max(0, raw))
        let tp = max(0, min(1, (raw - 0.3) / 0.7))           // text progress, lags the background
        let held = CGFloat(now - c.inAt)
        // Fit artwork rendered for another format.
        func fit(_ i: CIImage) -> CIImage {
            guard i.extent.size != extent.size, i.extent.width > 0 else { return i }
            return i.transformed(by: CGAffineTransform(scaleX: extent.width / i.extent.width, y: extent.height / i.extent.height))
        }
        let w = extent.width, h = extent.height
        // Slow push-in while on screen keeps the card alive.
        var bg = scaled(fit(c.background), 1 + 0.04 * min(held / 10, 1), extent: extent).cropped(to: extent)
        var tx = c.text.map(fit)
        if var t = tx {
            let e = easeInOut(tp)
            if let tm = c.textMotion, tm != .auto {
                switch tm {
                case .spin:
                    // spins about the frame centre while growing in (and back out when leaving)
                    let k = max(0.001, 0.15 + 0.85 * easeOutBack(tp))
                    let rot = CGAffineTransform(translationX: extent.midX, y: extent.midY)
                        .rotated(by: -(1 - e) * .pi * 2).scaledBy(x: k, y: k)
                        .translatedBy(x: -extent.midX, y: -extent.midY)
                    t = t.transformed(by: rot)
                case .pop: t = scaled(t, max(0.001, easeOutBack(tp)), extent: extent)
                case .flip:
                    // squeezes horizontally like a card turning over
                    let sx = max(0.01, abs(cos((1 - e) * .pi / 2)))
                    t = t.transformed(by: CGAffineTransform(translationX: extent.midX, y: 0).scaledBy(x: sx, y: 1).translatedBy(x: -extent.midX, y: 0))
                case .rise: t = t.transformed(by: CGAffineTransform(translationX: 0, y: -h * 0.3 * (1 - e)))
                case .fade, .auto: break
                }
                tx = fade(t, tp)
            } else {
            switch c.motion {
            case .zoom, .spin: t = scaled(t, 0.4 + 0.6 * easeOutBack(tp), extent: extent)
            case .slide: t = t.transformed(by: CGAffineTransform(translationX: w * 0.35 * (1 - e), y: 0))
            case .slideRight: t = t.transformed(by: CGAffineTransform(translationX: -w * 0.35 * (1 - e), y: 0))
            case .rise: t = t.transformed(by: CGAffineTransform(translationX: 0, y: -h * 0.25 * (1 - e)))
            case .drop: t = t.transformed(by: CGAffineTransform(translationX: 0, y: h * 0.25 * (1 - e)))
            case .flash, .iris: t = scaled(t, 0.85 + 0.15 * easeOutBack(tp), extent: extent)
            case .fade: t = scaled(t, 1.08 - 0.08 * e, extent: extent)
            case .wipe, .split, .splitH, .blinds: t = scaled(t, 1.25 - 0.25 * e, extent: extent)
            }
            tx = fade(t, tp)
            }
        }
        var mask: CIImage?
        switch c.motion {
        case .slide: bg = bg.transformed(by: CGAffineTransform(translationX: -w * (1 - p), y: 0))
        case .slideRight: bg = bg.transformed(by: CGAffineTransform(translationX: w * (1 - p), y: 0))
        case .rise: bg = bg.transformed(by: CGAffineTransform(translationX: 0, y: -h * (1 - p)))
        case .drop: bg = bg.transformed(by: CGAffineTransform(translationX: 0, y: h * (1 - p)))
        case .zoom: bg = fade(scaled(bg, 1.3 - 0.3 * p, extent: extent), p)
        case .fade: bg = fade(scaled(bg, 1.06 - 0.06 * p, extent: extent), p)
        case .spin:
            let t = CGAffineTransform(translationX: extent.midX, y: extent.midY)
                .rotated(by: -(1 - p) * .pi * 0.6).scaledBy(x: 0.2 + 0.8 * p, y: 0.2 + 0.8 * p)
                .translatedBy(x: -extent.midX, y: -extent.midY)
            bg = fade(bg.transformed(by: t), min(1, p * 1.6))
        case .split:
            let open = h * p
            bg = bg.cropped(to: CGRect(x: 0, y: (h - open) / 2, width: w, height: open))
        case .splitH:
            let open = w * p
            bg = bg.cropped(to: CGRect(x: (w - open) / 2, y: 0, width: open, height: h))
        case .blinds:
            // Eight bands opening one after another, top to bottom.
            let n = 8, bh = h / CGFloat(n)
            var out = CIImage.empty()
            for i in 0..<n {
                let local = max(0, min(1, p * 1.6 - CGFloat(i) * 0.6 / CGFloat(n - 1)))
                let y = h - CGFloat(i + 1) * bh
                out = bg.cropped(to: CGRect(x: 0, y: y + bh * (1 - local) / 2, width: w, height: bh * local)).composited(over: out)
            }
            bg = out
        case .flash:
            bg = fade(bg, p)
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent)
            let f = sin(min(1, raw * 1.4) * .pi) * 0.85
            if f > 0.01 { bg = fade(white, f).composited(over: bg) }
        case .iris:
            let r = hypot(w, h) / 2 * p
            mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: extent.midX, y: extent.midY), "inputRadius0": max(0, r - 30), "inputRadius1": r + 1,
                "inputColor0": CIColor.white, "inputColor1": CIColor.black])?.outputImage?.cropped(to: extent)
        case .wipe: break
        }
        var cardImg = bg
        if let t = tx { cardImg = t.composited(over: cardImg) }
        cardImg = cardImg.cropped(to: extent)
        if c.motion == .wipe {
            // Slanted soft edge sweeping left → right.
            let v = CGVector(dx: 0.94, dy: -0.34), L = w + h
            let cx = extent.midX + v.dx * (p * 2 - 1) * L * 0.62, cy = extent.midY + v.dy * (p * 2 - 1) * L * 0.62
            let soft: CGFloat = 40
            mask = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: cx - v.dx * soft, y: cy - v.dy * soft), "inputColor0": CIColor.white,
                "inputPoint1": CIVector(x: cx + v.dx * soft, y: cy + v.dy * soft), "inputColor1": CIColor.black])?.outputImage?.cropped(to: extent)
        }
        if let mask {
            return cardImg.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: mask])
                .cropped(to: extent)
        }
        return cardImg.composited(over: base).cropped(to: extent)
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

    /// Consecutive frames dropped because the pool was exhausted, and how often the pool was rebuilt.
    /// Program frames rendered (for the on-air rate log).
    let renderedFrames = Counter()
    private var poolMisses = 0
    private(set) var poolRebuilds = 0
    var onPoolRebuilt: (() -> Void)?

    private func render(_ img: CIImage, extent: CGRect) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferPoolAllocationThresholdKey: 24] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, attrs, &pb) == kCVReturnSuccess, let pb else {
            // Pool exhausted: buffers are held downstream (encoder stalled / leaked). Dropping a few frames is
            // fine, but never freeze for good — after ~0.5 s start a fresh pool; the old buffers free as holders let go.
            poolMisses += 1
            if poolMisses >= 15 { poolMisses = 0; poolRebuilds += 1; makePool(); onPoolRebuilt?() }
            return nil
        }
        poolMisses = 0
        ciContext.render(img, to: pb, bounds: extent, colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
        Self.tag709(pb)
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
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 8] as CFDictionary, attrs as CFDictionary, &p)
        pool = p
    }

    /// Marks a program frame as Rec.709 (primaries, transfer, matrix) so the encoder writes matching
    /// colour info into the stream; untagged HD video is often decoded as 601 → shifted, washed-out colours.
    private static func tag709(_ pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    /// Resizes a source to the program frame. Lanczos keeps detail (720p cameras upscaled to 1080p,
    /// 4K cameras downscaled) instead of the soft bilinear default.
    private static func scaleSharp(_ img: CIImage, _ scale: CGFloat) -> CIImage {
        guard abs(scale - 1) > 0.01 else { return img }
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = img; f.scale = Float(scale); f.aspectRatio = 1
        return f.outputImage ?? img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
}

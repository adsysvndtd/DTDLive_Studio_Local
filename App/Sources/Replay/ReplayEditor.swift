import AVFoundation
import CoreImage
import CoreMedia
import SwiftUI
import UIKit

/// A marked clip (in/out) ready to replay. Buffer clips keep their own encoded samples,
/// so they survive the rolling buffer moving on.
struct ReplayClip: Identifiable {
    let id = UUID()
    var name: String
    var material: ReplayEditor.Material
    var inT: Double            // seconds in material time
    var outT: Double
    var samples: [CMSampleBuffer] = []
    var basePTS: Double = 0    // buffer clips: material time 0 == this PTS
    var duration: Double { outT - inT }
}

/// Frame-accurate clip editor for instant replay and recorded files:
/// scrub with a thumbnail strip, step frames, MARK IN / MARK OUT, play the range
/// slow-motion (optionally looped), keep clips and export them to MP4.
@MainActor
final class ReplayEditor: ObservableObject {
    enum Material: Equatable {
        case buffer
        case file(URL)
        var label: String {
            switch self {
            case .buffer: return L("Bộ đệm replay")
            case .file(let u): return u.deletingPathExtension().lastPathComponent
            }
        }
    }

    @Published private(set) var material: Material = .buffer
    @Published private(set) var duration: Double = 0
    @Published var playhead: Double = 0
    @Published var markIn: Double?
    @Published var markOut: Double?
    @Published private(set) var preview: UIImage?
    @Published private(set) var thumbnails: [UIImage] = []
    @Published var speed: Double = 0.5
    @Published var loop = false
    @Published var clips: [ReplayClip] = []
    @Published private(set) var busy = false
    @Published var message: String?

    /// Buffer material is a frozen snapshot of the rolling program buffer.
    private var snapshot: [CMSampleBuffer] = []
    private var basePTS: Double = 0
    private var frameDuration: Double = 1.0 / 30
    private var asset: AVURLAsset?
    private var previewTask: Task<Void, Never>?
    private static let ci = CIContext(options: [.cacheIntermediates: false])

    // MARK: Loading

    func loadBuffer(_ buffer: ReplayBuffer) {
        material = .buffer
        snapshot = buffer.snapshot()
        asset = nil
        guard let first = snapshot.first, let last = snapshot.last else {
            duration = 0; preview = nil; thumbnails = []
            message = L("Bộ đệm trống — replay ghi lại tín hiệu Program khi app đang mã hoá (đang phát hoặc ghi).")
            return
        }
        message = nil
        basePTS = first.presentationTimeStamp.seconds
        duration = max(0, last.presentationTimeStamp.seconds - basePTS)
        if snapshot.count > 1 { frameDuration = max(1.0 / 120, duration / Double(snapshot.count - 1)) }
        resetMarks(playheadAtEnd: true)
        buildThumbnails()
    }

    func loadFile(_ url: URL) {
        material = .file(url)
        snapshot = []
        let a = AVURLAsset(url: url)
        asset = a
        message = nil
        Task {
            let d = (try? await a.load(.duration).seconds) ?? 0
            let fps = (try? await a.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)) ?? 30
            duration = d.isFinite ? d : 0
            frameDuration = 1.0 / Double(fps > 0 ? fps : 30)
            resetMarks(playheadAtEnd: false)
            buildThumbnails()
        }
    }

    private func resetMarks(playheadAtEnd: Bool) {
        markIn = nil; markOut = nil
        playhead = playheadAtEnd ? max(0, duration - 0.001) : 0
        requestPreview()
    }

    // MARK: Scrubbing

    func scrub(to t: Double) {
        playhead = min(max(0, t), duration)
        requestPreview()
    }

    func step(_ frames: Int) { scrub(to: playhead + Double(frames) * frameDuration) }

    func setIn() { markIn = playhead; if let o = markOut, o <= playhead { markOut = nil } }
    func setOut() { markOut = playhead; if let i = markIn, i >= playhead { markIn = nil } }
    func clearMarks() { markIn = nil; markOut = nil }

    /// In/out to use: marks if set, otherwise the last 8 s up to the playhead.
    var effectiveRange: ClosedRange<Double> {
        let o = markOut ?? (markIn == nil ? playhead : duration)
        let i = markIn ?? max(0, o - 8)
        return min(i, o)...max(i, o)
    }

    private func requestPreview() {
        previewTask?.cancel()
        let t = playhead
        switch material {
        case .buffer:
            let samples = snapshot, base = basePTS
            previewTask = Task.detached(priority: .userInitiated) { [weak self] in
                let img = Self.decodeFrame(samples, at: base + t, maxWidth: 960)
                if Task.isCancelled { return }
                await MainActor.run { self?.preview = img }
            }
        case .file:
            guard let asset else { return }
            previewTask = Task.detached(priority: .userInitiated) { [weak self] in
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.requestedTimeToleranceBefore = .zero
                gen.requestedTimeToleranceAfter = .zero
                gen.maximumSize = CGSize(width: 960, height: 540)
                let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
                if Task.isCancelled { return }
                await MainActor.run { self?.preview = cg.map(UIImage.init(cgImage:)) }
            }
        }
    }

    private func buildThumbnails(count: Int = 12) {
        let d = duration
        guard d > 0 else { thumbnails = []; return }
        let times = (0..<count).map { d * (Double($0) + 0.5) / Double(count) }
        switch material {
        case .buffer:
            let samples = snapshot, base = basePTS
            Task.detached(priority: .utility) { [weak self] in
                // Keyframes only: one decode each, fast enough for a strip.
                let imgs = times.compactMap { t -> UIImage? in
                    guard let i = samples.lastIndex(where: { $0.isKeyframe && $0.presentationTimeStamp.seconds <= base + t }),
                          let fd = samples[i].formatDescription,
                          let pb = FrameDecoder(format: fd).decode(samples[i]) else { return nil }
                    return Self.image(pb, maxWidth: 200)
                }
                await MainActor.run { self?.thumbnails = imgs }
            }
        case .file:
            guard let asset else { return }
            Task.detached(priority: .utility) { [weak self] in
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 200, height: 112)
                var imgs: [UIImage] = []
                for t in times {
                    if let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { imgs.append(UIImage(cgImage: cg)) }
                }
                await MainActor.run { self?.thumbnails = imgs }
            }
        }
    }

    /// Samples + absolute PTS range for the current marks (buffer material).
    func bufferRange() -> (samples: [CMSampleBuffer], inPTS: Double, outPTS: Double) {
        let r = effectiveRange
        return (snapshot, basePTS + r.lowerBound, basePTS + r.upperBound)
    }

    // MARK: Clips

    func saveClip() {
        let r = effectiveRange
        guard r.upperBound - r.lowerBound > 0.05 else { message = L("Đoạn quá ngắn — đặt MARK IN và MARK OUT"); return }
        var c = ReplayClip(name: "Clip \(clips.count + 1)", material: material, inT: r.lowerBound, outT: r.upperBound)
        if material == .buffer {
            let inPTS = basePTS + r.lowerBound, outPTS = basePTS + r.upperBound
            let start = snapshot.lastIndex { $0.isKeyframe && $0.presentationTimeStamp.seconds <= inPTS } ?? 0
            c.samples = snapshot[start...].filter { $0.presentationTimeStamp.seconds <= outPTS }
            c.basePTS = basePTS
        }
        clips.insert(c, at: 0)
        message = LF("Đã lưu %@ (%@ s)", c.name, String(format: "%.1f", c.duration))
    }

    func deleteClip(_ c: ReplayClip) { clips.removeAll { $0.id == c.id } }

    /// Writes a buffer clip to Library/Video as MP4 (passthrough, no re-encode); file clips are trimmed with AVAssetExportSession.
    func export(_ c: ReplayClip, library: MediaLibrary) {
        busy = true
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let url = MediaLibrary.directory(.movie).appendingPathComponent("Replay-\(df.string(from: Date())).mp4")
        Task {
            defer { busy = false }
            do {
                switch c.material {
                case .buffer:
                    try await Self.writeSamples(c.samples, from: c.basePTS + c.inT, to: c.basePTS + c.outT, url: url)
                case .file(let src):
                    guard let s = AVAssetExportSession(asset: AVURLAsset(url: src), presetName: AVAssetExportPresetPassthrough) else { return }
                    s.outputURL = url; s.outputFileType = .mp4
                    s.timeRange = CMTimeRange(start: CMTime(seconds: c.inT, preferredTimescale: 600),
                                              end: CMTime(seconds: c.outT, preferredTimescale: 600))
                    await s.export()
                    if let e = s.error { throw e }
                }
                library.refresh()
                message = LF("Đã xuất %@ vào thư viện Video", "\(url.lastPathComponent)")
            } catch {
                message = LF("Xuất thất bại: %@", "\(error.localizedDescription)")
            }
        }
    }

    // MARK: Helpers (nonisolated, used off the main actor)

    nonisolated static func decodeFrame(_ samples: [CMSampleBuffer], at pts: Double, maxWidth: CGFloat) -> UIImage? {
        guard let k = samples.lastIndex(where: { $0.isKeyframe && $0.presentationTimeStamp.seconds <= pts + 0.0005 }),
              let fd = samples[k].formatDescription else { return nil }
        let decoder = FrameDecoder(format: fd)
        var last: CVPixelBuffer?
        for sb in samples[k...] {
            if sb.presentationTimeStamp.seconds > pts + 0.0005 { break }
            if let pb = decoder.decode(sb) { last = pb }
        }
        return last.flatMap { image($0, maxWidth: maxWidth) }
    }

    nonisolated static func image(_ pb: CVPixelBuffer, maxWidth: CGFloat) -> UIImage? {
        var img = CIImage(cvPixelBuffer: pb)
        let s = min(1, maxWidth / img.extent.width)
        img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        return ci.createCGImage(img, from: img.extent).map(UIImage.init(cgImage:))
    }

    nonisolated static func writeSamples(_ samples: [CMSampleBuffer], from inPTS: Double, to outPTS: Double, url: URL) async throws {
        guard let fd = samples.first?.formatDescription else { return }
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fd)
        input.expectsMediaDataInRealTime = false
        w.add(input)
        w.startWriting()
        // Start at the clip's keyframe so the file decodes; the edit list trims to MARK IN.
        w.startSession(atSourceTime: samples[0].presentationTimeStamp)
        for sb in samples {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            input.append(sb)
        }
        input.markAsFinished()
        w.endSession(atSourceTime: CMTime(seconds: outPTS, preferredTimescale: 90_000))
        await w.finishWriting()
        if let e = w.error { throw e }
    }
}

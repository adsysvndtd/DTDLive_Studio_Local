import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import CoreVideo
import Foundation
import UIKit

/// Files the operator has imported for use in the show, stored in Documents/Library/<kind>
/// (also visible/manageable in the Files app).
enum LibraryKind: String, CaseIterable, Identifiable {
    case movie, picture, overlay, logo, music, sound
    var id: String { rawValue }
    var folder: String {
        switch self {
        case .movie: return "Video"
        case .picture: return L("Ảnh")
        case .overlay: return L("Lớp phủ")
        case .logo: return "Logo"
        case .music: return L("Nhạc")
        case .sound: return L("Hiệu ứng âm thanh")
        }
    }
}

@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var items: [LibraryKind: [URL]] = [:]

    init() { refresh() }

    nonisolated static func directory(_ k: LibraryKind) -> URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library").appendingPathComponent(k.folder)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func refresh() {
        var out: [LibraryKind: [URL]] = [:]
        for k in LibraryKind.allCases {
            let urls = (try? FileManager.default.contentsOfDirectory(at: Self.directory(k), includingPropertiesForKeys: [.creationDateKey])) ?? []
            out[k] = urls.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        items = out
    }

    func list(_ k: LibraryKind) -> [URL] { items[k] ?? [] }

    /// Direct listing (for views that don't hold the library object).
    nonisolated static func listFiles(_ k: LibraryKind) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory(k), includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Copies picked files into the library (security-scoped URLs from the document picker).
    /// Returns an error line for files that could not be copied.
    @discardableResult
    func importFiles(_ urls: [URL], into k: LibraryKind) -> String? {
        let failed = urls.filter { copyIn($0, into: k) == nil }.map(\.lastPathComponent)
        refresh()
        return failed.isEmpty ? nil : "Không nhập được: " + failed.joined(separator: ", ")
    }

    /// Copies one file into the library and returns its new location (nil on failure).
    func importFile(_ u: URL, into k: LibraryKind) -> URL? {
        let dest = copyIn(u, into: k)
        refresh()
        return dest
    }

    private func copyIn(_ u: URL, into k: LibraryKind) -> URL? {
        let scoped = u.startAccessingSecurityScopedResource()
        defer { if scoped { u.stopAccessingSecurityScopedResource() } }
        var dest = Self.directory(k).appendingPathComponent(u.lastPathComponent)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = Self.directory(k).appendingPathComponent("\(u.deletingPathExtension().lastPathComponent)-\(n).\(u.pathExtension)")
            n += 1
        }
        // iCloud/Drive files may not be downloaded yet: coordinate the read so the system fetches them
        var err: NSError?
        var copyErr: Error?
        NSFileCoordinator().coordinate(readingItemAt: u, options: .forUploading, error: &err) { src in
            do { try FileManager.default.copyItem(at: src, to: dest) } catch { copyErr = error }
        }
        return (err == nil && copyErr == nil) ? dest : nil
    }

    /// A picture from Photos (main-actor convenience; the work itself runs off the main thread).
    @discardableResult
    func importImage(_ data: Data, into k: LibraryKind, name: String = "Ảnh") async -> URL? {
        let base = "\(name)-\(Self.stamp())"
        let url = await Task.detached(priority: .userInitiated) { Self.storeImage(data, into: k, base: base) }.value
        refresh()
        return url
    }

    /// Decodes, scales and saves one picture — call off the main thread. ImageIO decodes straight to at most
    /// 3840×2160 (the most a picture input ever uses) with the EXIF rotation applied, instead of decoding the
    /// full 12–48 MP photo, redrawing it upright and PNG-encoding it on the main thread (seconds per photo).
    /// Opaque pictures in "Ảnh" are saved as JPEG; logos / overlays and pictures with transparency as PNG.
    nonisolated static func storeImage(_ data: Data, into k: LibraryKind, base: String) -> URL? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = PictureIO.downsample(src, maxWidth: 3840, maxHeight: 2160) else { return nil }
        let jpeg = k == .picture && !PictureIO.hasAlpha(cg)
        guard let out = PictureIO.encode(cg, jpeg: jpeg) else { return nil }
        let url = uniqueURL(in: k, base: base, ext: jpeg ? "jpg" : "png")
        guard (try? out.write(to: url, options: .withoutOverwriting)) != nil else { return nil }
        thumbCache.removeObject(forKey: url as NSURL)
        return url
    }

    /// Moves a video Photos handed over (already a private temporary copy) into the Video library —
    /// a rename on the same volume, instead of a second coordinated copy of a multi-GB file on the main thread.
    nonisolated static func adoptMovie(_ tmp: URL) -> URL? {
        let base = tmp.deletingPathExtension().lastPathComponent
        let url = uniqueURL(in: .movie, base: base, ext: tmp.pathExtension.isEmpty ? "mov" : tmp.pathExtension)
        do { try FileManager.default.moveItem(at: tmp, to: url) } catch {
            guard (try? FileManager.default.copyItem(at: tmp, to: url)) != nil else { return nil }
            try? FileManager.default.removeItem(at: tmp)
        }
        removeTempFolder(of: tmp)
        return url
    }

    /// Removes the per-pick folder a Photos transfer was put in (only inside the app's temporary directory).
    nonisolated static func removeTempFolder(of tmp: URL) {
        let dir = tmp.deletingLastPathComponent()
        guard dir.deletingLastPathComponent().standardizedFileURL.path
                == FileManager.default.temporaryDirectory.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// The sound of a video (e.g. one from Photos) saved as an .m4a in Nhạc / Hiệu ứng âm thanh.
    /// Returns nil when the video has no sound or it could not be converted.
    func importAudio(fromMovie src: URL, into k: LibraryKind, name: String) async -> URL? {
        let asset = AVURLAsset(url: src)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let url = Self.uniqueURL(in: k, base: name, ext: "m4a")
        ex.outputURL = url
        ex.outputFileType = .m4a
        await ex.export()
        guard ex.status == .completed else { try? FileManager.default.removeItem(at: url); return nil }
        refresh()
        return url
    }

    nonisolated static func stamp() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        return df.string(from: Date())
    }

    nonisolated static func uniqueURL(in k: LibraryKind, base: String, ext: String) -> URL {
        var url = Self.directory(k).appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Self.directory(k).appendingPathComponent("\(base)-\(n).\(ext)"); n += 1
        }
        return url
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        Self.thumbCache.removeObject(forKey: url as NSURL)
        refresh()
    }

    /// Grid thumbnails, kept so switching categories does not decode every picture / video again.
    nonisolated(unsafe) static let thumbCache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>(); c.countLimit = 300; return c
    }()

    /// Small thumbnail for grids (pictures via ImageIO at thumbnail size; videos via an early frame). Cached.
    nonisolated static func thumbnail(_ url: URL, kind: LibraryKind) -> UIImage? {
        if let t = thumbCache.object(forKey: url as NSURL) { return t }
        var out: UIImage?
        switch kind {
        case .picture, .overlay, .logo:
            if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let cg = PictureIO.downsample(src, maxWidth: 480, maxHeight: 270) { out = UIImage(cgImage: cg) }
        case .movie:
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 480, height: 270)
            gen.requestedTimeToleranceBefore = .positiveInfinity
            gen.requestedTimeToleranceAfter = .positiveInfinity
            out = (try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)).map(UIImage.init(cgImage:))
        case .music, .sound:
            return nil
        }
        if let out { thumbCache.setObject(out, forKey: url as NSURL) }
        return out
    }
}

/// Still picture as a switcher input.
@MainActor
final class ImageSource: VideoSource {
    let id = UUID()
    var name: String
    let kind: SourceKind = .file
    let frames = FrameStore()
    private(set) var status: SourceStatus = .idle
    let url: URL
    private var timer: Timer?
    private var buffer: CVPixelBuffer?

    init(url: URL) { self.url = url; name = url.deletingPathExtension().lastPathComponent }

    func start() async {
        // Decode + scale + upload off the main thread (a 12–48 MP photo took the UI with it for a moment).
        let u = url
        guard let pb = await Task.detached(priority: .userInitiated, operation: { PictureIO.frame(u).map(FrameBox.init) }).value?.pb else {
            status = .error("Không đọc được ảnh"); return
        }
        buffer = pb
        frames.put(pb)
        // FrameStore treats sources silent for >2 s as "no signal"; refresh the still once a second.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in if let b = self?.buffer { self?.frames.put(b) } }
        }
        status = .live
    }

    func stop() async { timer?.invalidate(); timer = nil; frames.clear(); status = .idle }
}

/// Hands a freshly made frame from a background task to the main actor (nothing else holds it).
struct FrameBox: @unchecked Sendable { let pb: CVPixelBuffer }

/// Picture decoding without the main thread: ImageIO thumbnails (decode at the target size, EXIF rotation applied).
enum PictureIO {
    private static let ci = CIContext(options: [.cacheIntermediates: false])

    /// Size in pixels after the EXIF rotation.
    static func orientedSize(_ src: CGImageSource) -> CGSize? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Upright picture no larger than maxWidth × maxHeight (never enlarged).
    static func downsample(_ src: CGImageSource, maxWidth: CGFloat, maxHeight: CGFloat) -> CGImage? {
        guard let sz = orientedSize(src), sz.width > 0, sz.height > 0 else { return nil }
        let k = min(1, maxWidth / sz.width, maxHeight / sz.height)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((max(sz.width, sz.height) * k).rounded(.up))
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func hasAlpha(_ cg: CGImage) -> Bool {
        switch cg.alphaInfo { case .none, .noneSkipFirst, .noneSkipLast: return false; default: return true }
    }

    static func encode(_ cg: CGImage, jpeg: Bool) -> Data? {
        let d = NSMutableData()
        let type = (jpeg ? UTType.jpeg : UTType.png).identifier as CFString
        guard let dst = CGImageDestinationCreateWithData(d, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : nil)
        return CGImageDestinationFinalize(dst) ? d as Data : nil
    }

    /// A library picture as a switcher frame (≤ 3840×2160, upright, BGRA).
    static func frame(_ url: URL) -> CVPixelBuffer? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = downsample(src, maxWidth: 3840, maxHeight: 2160) else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, cg.width, cg.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return nil }
        ci.render(CIImage(cgImage: cg), to: pb)
        return pb
    }

    /// Whether the file is a picture ImageIO can read (header only, no decode).
    static func isReadable(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 0
    }
}

extension UIImage {
    /// Pixels rotated to .up (photos from the camera carry an EXIF orientation that CIImage(cgImage:) ignores).
    func normalized() -> UIImage {
        guard imageOrientation != .up else { return self }
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: px, format: fmt).image { _ in draw(in: CGRect(origin: .zero, size: px)) }
    }
}

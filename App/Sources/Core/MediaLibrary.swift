import AVFoundation
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

    @discardableResult
    func importImage(_ data: Data, into k: LibraryKind, name: String = "Ảnh") -> URL? {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let url = Self.directory(k).appendingPathComponent("\(name)-\(df.string(from: Date())).png")
        guard let img = UIImage(data: data), let png = img.normalized().pngData(), (try? png.write(to: url)) != nil else { return nil }
        refresh()
        return url
    }

    func delete(_ url: URL) { try? FileManager.default.removeItem(at: url); refresh() }

    /// Small thumbnail for grids (images directly; videos via first frame).
    nonisolated static func thumbnail(_ url: URL, kind: LibraryKind) -> UIImage? {
        switch kind {
        case .picture, .overlay, .logo:
            return UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 320, height: 180))
        case .movie:
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 320, height: 180)
            return (try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)).map(UIImage.init(cgImage:))
        case .music, .sound:
            return nil
        }
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
    private static let ci = CIContext(options: [.cacheIntermediates: false])

    func start() async {
        guard let img = UIImage(contentsOfFile: url.path)?.normalized(), let cg = img.cgImage else { status = .error("Không đọc được ảnh"); return }
        // A 12 MP photo kept as a full-size BGRA frame is ~48 MB per picture input; the program is at most
        // 1080p (4K pictures still look sharp scaled from 2× that), so keep it no larger than 3840 px wide.
        var ci = CIImage(cgImage: cg)
        let k = min(1, 3840 / CGFloat(cg.width), 2160 / CGFloat(cg.height))
        if k < 1 { ci = ci.transformed(by: CGAffineTransform(scaleX: k, y: k)) }
        let w = Int((CGFloat(cg.width) * k).rounded()), h = Int((CGFloat(cg.height) * k).rounded())
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return }
        Self.ci.render(ci, to: pb)
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

extension UIImage {
    /// Pixels rotated to .up (photos from the camera carry an EXIF orientation that CIImage(cgImage:) ignores).
    func normalized() -> UIImage {
        guard imageOrientation != .up else { return self }
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: px, format: fmt).image { _ in draw(in: CGRect(origin: .zero, size: px)) }
    }
}

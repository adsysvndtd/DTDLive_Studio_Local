import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import UIKit

/// Files the operator has imported for use in the show, stored in Documents/Library/<kind>
/// (also visible/manageable in the Files app).
enum LibraryKind: String, CaseIterable, Identifiable {
    case movie, picture, overlay, logo, music
    var id: String { rawValue }
    var folder: String {
        switch self {
        case .movie: return "Video"
        case .picture: return "Ảnh"
        case .overlay: return "Lớp phủ"
        case .logo: return "Logo"
        case .music: return "Nhạc"
        }
    }
}

@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var items: [LibraryKind: [URL]] = [:]

    init() { refresh() }

    static func directory(_ k: LibraryKind) -> URL {
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

    /// Copies picked files into the library (security-scoped URLs from the document picker).
    func importFiles(_ urls: [URL], into k: LibraryKind) {
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            var dest = Self.directory(k).appendingPathComponent(u.lastPathComponent)
            var n = 1
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = Self.directory(k).appendingPathComponent("\(u.deletingPathExtension().lastPathComponent)-\(n).\(u.pathExtension)")
                n += 1
            }
            try? FileManager.default.copyItem(at: u, to: dest)
        }
        refresh()
    }

    func importImage(_ data: Data, into k: LibraryKind, name: String = "Ảnh") {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let url = Self.directory(k).appendingPathComponent("\(name)-\(df.string(from: Date())).png")
        if let img = UIImage(data: data), let png = img.pngData() { try? png.write(to: url) }
        refresh()
    }

    func delete(_ url: URL) { try? FileManager.default.removeItem(at: url); refresh() }

    /// Small thumbnail for grids (images directly; videos via first frame).
    static func thumbnail(_ url: URL, kind: LibraryKind) -> UIImage? {
        switch kind {
        case .picture, .overlay, .logo:
            return UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 320, height: 180))
        case .movie:
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 320, height: 180)
            return (try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)).map(UIImage.init(cgImage:))
        case .music:
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

    func start() async {
        guard let img = UIImage(contentsOfFile: url.path), let cg = img.cgImage else { status = .error("Không đọc được ảnh"); return }
        let ci = CIImage(cgImage: cg)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, cg.width, cg.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return }
        CIContext().render(ci, to: pb)
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

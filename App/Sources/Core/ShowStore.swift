import AVFoundation
import Foundation

/// A complete production setup ("show"): inputs, outputs, graphics, per-source processing,
/// PTZ, transition and encoder settings. Saved as JSON in Documents/Shows (visible in Files app).
struct ShowFile: Codable {
    struct SourceConfig: Codable {
        enum Kind: String, Codable { case camera, srt, rtmpPull, rtsp, file }
        var kind: Kind
        var name: String
        var url: String?          // network sources / file path (Documents-relative for files)
        var deviceID: String?     // cameras
        var processing: SourceProcessing?
        var ptz: PTZConfig?
    }

    var version = 1
    var name: String
    var savedAt = Date()
    var sources: [SourceConfig]
    var outputs: [OutputConfig]
    var titles: [TitleItem]
    var transition: TransitionStyle
    var transitionDuration: Double
    var encoder: EncoderSettings
    var vertical: Bool
    var programIndex: Int?
    var previewIndex: Int?
}

enum ShowStore {
    static var directory: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Shows")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func list() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".dtdshow") }.map { String($0.dropLast(8)) }.sorted()
    }

    static func save(_ show: ShowFile) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        try e.encode(show).write(to: directory.appendingPathComponent(safe(show.name) + ".dtdshow"), options: .atomic)
    }

    static func load(_ name: String) throws -> ShowFile {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(ShowFile.self, from: Data(contentsOf: directory.appendingPathComponent(safe(name) + ".dtdshow")))
    }

    static func delete(_ name: String) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(safe(name) + ".dtdshow")) }

    private static func safe(_ s: String) -> String {
        String(s.map { "/\\:?*\"<>|".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces)
    }
}

extension StudioEngine {
    func makeShow(named name: String) -> ShowFile {
        let src: [ShowFile.SourceConfig] = sources.compactMap { s in
            guard s.id != replay.id else { return nil }
            var c: ShowFile.SourceConfig
            switch s {
            case let x as CameraSource: c = .init(kind: .camera, name: x.name, deviceID: x.deviceID)
            case let x as SRTInputSource: c = .init(kind: .srt, name: x.name, url: x.url.absoluteString)
            case let x as RTMPInputSource: c = .init(kind: .rtmpPull, name: x.name, url: x.url.absoluteString)
            case let x as RTSPInputSource: c = .init(kind: .rtsp, name: x.name, url: x.url.absoluteString)
            case let x as FileSource: c = .init(kind: .file, name: x.name, url: x.url.absoluteString)
            default: return nil
            }
            c.processing = processing[s.id]
            c.ptz = ptz[s.id]
            return c
        }
        let ids = sources.map(\.id)
        return ShowFile(name: name, sources: src, outputs: outputs, titles: titles.map { var t = $0; t.visible = false; return t },
                        transition: transition, transitionDuration: transitionDuration, encoder: encoder,
                        vertical: format == .vertical1080,
                        programIndex: programID.flatMap { ids.firstIndex(of: $0) }, previewIndex: previewID.flatMap { ids.firstIndex(of: $0) })
    }

    func saveShow(named name: String) throws { try ShowStore.save(makeShow(named: name)) }

    /// Replaces the current setup with a saved show. Live outputs are stopped first.
    func loadShow(named name: String) throws {
        let show = try ShowStore.load(name)
        stopAll()
        for s in sources { remove(s) }
        format = show.vertical ? .vertical1080 : ProgramFormat()
        encoder = show.encoder
        transition = show.transition
        transitionDuration = show.transitionDuration
        outputs = show.outputs
        titles = show.titles
        var added: [any VideoSource] = []
        for c in show.sources {
            let source: (any VideoSource)?
            switch c.kind {
            case .camera:
                source = c.deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }.map { CameraSource(device: $0) }
            case .srt: source = c.url.flatMap(URL.init(string:)).map { SRTInputSource(name: c.name, url: $0) }
            case .rtmpPull: source = c.url.flatMap(URL.init(string:)).map { RTMPInputSource(name: c.name, url: $0) }
            case .rtsp: source = c.url.flatMap(URL.init(string:)).map { RTSPInputSource(name: c.name, url: $0) }
            case .file: source = c.url.flatMap(URL.init(string:)).map { FileSource(name: c.name, url: $0) }
            }
            guard let source else { continue } // camera not plugged in / file missing
            source.name = c.name
            add(source)
            if let p = c.processing { setProcessing(source.id, p, undoable: false) }
            if let z = c.ptz { setPTZ(source.id, z) }
            added.append(source)
        }
        if let i = show.programIndex, i < added.count { take(added[i].id) }
        if let i = show.previewIndex, i < added.count { select(added[i].id) }
    }
}

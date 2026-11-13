import CoreImage
import Foundation
import UIKit
import WebKit

// MARK: - Template catalogue (Documents/Graphics, synced from Git)

struct HTMLTemplate: Codable, Identifiable, Equatable {
    struct Field: Codable, Equatable, Identifiable {
        let id: String
        let label: String
        var `default`: String?
        var type: String?
        var isColor: Bool { type == "color" }
    }
    let id: String
    let name: String
    let entry: String
    var fields: [Field]
}

struct HTMLManifest: Codable {
    var version: Int
    var templates: [HTMLTemplate]
}

enum HTMLGraphicsStore {
    static var directory: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Graphics", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// First launch: copy the templates shipped in the app (Graphics/ folder) so it works before any sync.
    static func seedIfNeeded() {
        let dst = directory
        guard !FileManager.default.fileExists(atPath: dst.appendingPathComponent("manifest.json").path),
              let src = Bundle.main.url(forResource: "Graphics", withExtension: nil) else { return }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: src.path)) ?? [] {
            try? FileManager.default.copyItem(at: src.appendingPathComponent(name), to: dst.appendingPathComponent(name))
        }
    }

    static func manifest() -> HTMLManifest? {
        guard let d = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(HTMLManifest.self, from: d)
    }
}

// MARK: - Git (GitHub) sync

/// Downloads the graphics folder of a GitHub repo (public, or private with a token) into Documents/Graphics.
/// Only re-downloads when the branch head commit changed.
@MainActor
final class GraphicsRepo: ObservableObject {
    struct Settings: Codable, Equatable {
        var owner = "adsysvndtd"
        var repo = "DTDLive_Studio_Local"
        var branch = "main"
        var path = "Graphics"
    }

    @Published var settings: Settings {
        didSet { if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "dtd.graphicsrepo.v1") } }
    }
    @Published private(set) var status = ""
    @Published private(set) var syncing = false
    @Published private(set) var lastCommit: String? = UserDefaults.standard.string(forKey: "dtd.graphicsrepo.sha")
    /// Optional token for private repos (kept in the Keychain, never in UserDefaults).
    var token: String {
        get { Keychain.get("dtd.graphicsrepo.token") ?? "" }
        set { Keychain.set(newValue, for: "dtd.graphicsrepo.token"); objectWillChange.send() }
    }
    var onUpdated: (() -> Void)?

    init() {
        settings = UserDefaults.standard.data(forKey: "dtd.graphicsrepo.v1")
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    private struct Item: Decodable { let name: String; let path: String; let type: String; let download_url: String? }
    private struct Commit: Decodable { let sha: String }

    func sync(force: Bool = false) async {
        guard !syncing else { return }
        syncing = true; defer { syncing = false }
        let s = settings
        do {
            status = LF("Đang kiểm tra %@/%@…", "\(s.owner)", "\(s.repo)")
            let head: Commit = try await get("https://api.github.com/repos/\(s.owner)/\(s.repo)/commits/\(s.branch)")
            if !force, head.sha == lastCommit, HTMLGraphicsStore.manifest() != nil {
                status = LF("Đã mới nhất (%@)", "\(head.sha.prefix(7))")
                return
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("graphics-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            var count = 0
            try await download(path: s.path, ref: head.sha, into: tmp, root: s.path, count: &count)
            guard FileManager.default.fileExists(atPath: tmp.appendingPathComponent("manifest.json").path) else {
                throw NSError(domain: "dtd", code: 1, userInfo: [NSLocalizedDescriptionKey: LF("Thư mục %@ không có manifest.json", s.path)])
            }
            let dst = HTMLGraphicsStore.directory
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            lastCommit = head.sha
            UserDefaults.standard.set(head.sha, forKey: "dtd.graphicsrepo.sha")
            status = LF("Đã cập nhật %@ tệp (%@)", "\(count)", "\(head.sha.prefix(7))")
            onUpdated?()
        } catch {
            status = LF("Lỗi: %@", "\(error.localizedDescription)")
        }
    }

    private func download(path: String, ref: String, into dir: URL, root: String, count: inout Int) async throws {
        let s = settings
        let enc = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let items: [Item] = try await get("https://api.github.com/repos/\(s.owner)/\(s.repo)/contents/\(enc)?ref=\(ref)")
        for it in items {
            let rel = String(it.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let local = dir.appendingPathComponent(rel)
            if it.type == "dir" {
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                try await download(path: it.path, ref: ref, into: dir, root: root, count: &count)
            } else if it.type == "file", let u = it.download_url, let url = URL(string: u) {
                var req = URLRequest(url: url)
                if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: local)
                count += 1
            }
        }
    }

    private func get<T: Decodable>(_ s: String) async throws -> T {
        guard let url = URL(string: s) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = code == 404 ? L("không tìm thấy repo/nhánh/thư mục (repo private cần token)") : code == 403 ? L("GitHub giới hạn lượt gọi, thử lại sau") : "HTTP \(code)"
            throw NSError(domain: "dtd", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Minimal Keychain wrapper for the Git token.
enum Keychain {
    static func set(_ v: String, for key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard !v.isEmpty else { return }
        var add = q; add[kSecValueData as String] = Data(v.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

// MARK: - Renderer: off-screen WKWebView → CIImage keyed on program

/// Latest rendered HTML frame, read by the switcher's render queue.
final class HTMLFrameBox: @unchecked Sendable {
    static let shared = HTMLFrameBox()
    private let lock = NSLock()
    private var img: CIImage?
    var image: CIImage? { lock.lock(); defer { lock.unlock() }; return img }
    func set(_ i: CIImage?) { lock.lock(); img = i; lock.unlock() }
}

@MainActor
final class HTMLGraphics: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var templates: [HTMLTemplate] = []
    @Published private(set) var loadedID: String?
    @Published private(set) var onAir = false
    /// Field values per template (kept between launches).
    @Published var values: [String: [String: String]] = [:] {
        didSet {
            if let d = try? JSONEncoder().encode(values) { UserDefaults.standard.set(d, forKey: "dtd.htmlvalues.v1") }
        }
    }

    private var web: WKWebView?
    private var link: CADisplayLink?
    private var capturing = false
    private var stopDeadline: Date?
    private var pageReady = false
    /// Rendered at half 1080p and scaled up — WKWebView snapshots at full HD cost too much per frame.
    private let renderSize = CGSize(width: 960, height: 540)

    override init() {
        super.init()
        values = UserDefaults.standard.data(forKey: "dtd.htmlvalues.v1")
            .flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
        HTMLGraphicsStore.seedIfNeeded()
        reload()
    }

    func reload() {
        templates = HTMLGraphicsStore.manifest()?.templates ?? []
        if let id = loadedID { load(id) }
    }

    func value(_ t: HTMLTemplate, _ f: HTMLTemplate.Field) -> String { values[t.id]?[f.id] ?? f.default ?? "" }

    func setValue(_ t: HTMLTemplate, _ f: HTMLTemplate.Field, _ v: String) {
        values[t.id, default: [:]][f.id] = v
        if loadedID == t.id { pushData(t) }
    }

    /// Loads (arms) a template; it goes on air with the "HTML On" key.
    func load(_ id: String) {
        guard let t = templates.first(where: { $0.id == id }) else { return }
        if onAir { stop() }
        let w = ensureWebView()
        let dir = HTMLGraphicsStore.directory
        pageReady = false
        w.loadFileURL(dir.appendingPathComponent(t.entry), allowingReadAccessTo: dir)
        loadedID = id
    }

    func toggle() { onAir ? stop() : play() }

    func play() {
        guard loadedID != nil, pageReady else { return }
        web?.evaluateJavaScript("play()")
        onAir = true; stopDeadline = nil
        startCapture()
    }

    func stop() {
        guard onAir else { return }
        web?.evaluateJavaScript("stop()")
        onAir = false
        stopDeadline = Date().addingTimeInterval(1.2)   // let the out-animation finish on air
    }

    func next() { web?.evaluateJavaScript("next()") }

    // WKNavigationDelegate
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.pageReady = true
            if let t = self.templates.first(where: { $0.id == self.loadedID }) { self.pushData(t) }
        }
    }

    private func pushData(_ t: HTMLTemplate) {
        var d: [String: String] = [:]
        for f in t.fields { d[f.id] = value(t, f) }
        guard let json = try? JSONSerialization.data(withJSONObject: d), let s = String(data: json, encoding: .utf8) else { return }
        web?.evaluateJavaScript("typeof update==='function' && update(\(s))")
    }

    private func ensureWebView() -> WKWebView {
        if let w = web { return w }
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsInlineMediaPlayback = true
        let w = WKWebView(frame: CGRect(origin: .zero, size: renderSize), configuration: cfg)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        w.scrollView.isScrollEnabled = false
        w.isUserInteractionEnabled = false
        w.navigationDelegate = self
        // The page is laid out at 1920×1080 and scaled to the view.
        w.pageZoom = renderSize.width / 1920
        // Must be in a window to render; kept behind the app's (opaque) root view.
        if let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            win.insertSubview(w, at: 0)
        }
        web = w
        return w
    }

    private func startCapture() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 25)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() {
        if let d = stopDeadline, Date() > d {
            link?.invalidate(); link = nil; stopDeadline = nil
            HTMLFrameBox.shared.set(nil)
            return
        }
        guard !capturing, let w = web else { return }
        capturing = true
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = false
        w.takeSnapshot(with: cfg) { [weak self] img, _ in
            Task { @MainActor in
                self?.capturing = false
                guard let img, let cg = img.cgImage else { return }
                HTMLFrameBox.shared.set(CIImage(cgImage: cg))
            }
        }
    }
}

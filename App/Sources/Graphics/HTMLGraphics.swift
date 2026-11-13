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
        var isImage: Bool { type == "image" }
    }
    let id: String
    var name: String
    let entry: String
    var fields: [Field]
    /// Imported / edited by the operator (kept in Documents/GraphicsUser, survives Git sync).
    var user: Bool? = nil
    var isUser: Bool { user == true }
}

struct HTMLManifest: Codable {
    var version: Int
    var templates: [HTMLTemplate]
}

/// Size / position of a whole HTML graphic on the 1920×1080 page (Resize in the panel).
struct HTMLLayout: Equatable {
    var scale: Double = 1
    var x: Double = 0          // px, + = right
    var y: Double = 0          // px, + = down
    var anchor = "left bottom" // CSS transform-origin: the point that stays put when scaling
    var isIdentity: Bool { abs(scale - 1) < 0.001 && abs(x) < 0.5 && abs(y) < 0.5 }
    var transform: String { "translate(\(Int(x.rounded()))px,\(Int(y.rounded()))px) scale(\(String(format: "%.3f", scale)))" }
    func cssRule(for id: String) -> String { "body[data-dtd=\"\(id)\"]{transform-origin:\(anchor);transform:\(transform)}" }
    static let anchors: [(String, String)] = [
        ("left top", "↖"), ("center top", "↑"), ("right top", "↗"),
        ("left center", "←"), ("center center", "•"), ("right center", "→"),
        ("left bottom", "↙"), ("center bottom", "↓"), ("right bottom", "↘")]
}

enum HTMLGraphicsStore {
    static var directory: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Graphics", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Copies the templates shipped in the app (Graphics/ folder) so it works before any sync,
    /// and merges in bundled templates that a later app version added.
    static func seedIfNeeded() {
        let fm = FileManager.default
        let dst = directory
        guard let src = Bundle.main.url(forResource: "Graphics", withExtension: nil) else { return }
        let mURL = dst.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: mURL.path), var local = manifest() else {
            for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] {
                try? fm.removeItem(at: dst.appendingPathComponent(name))
                try? fm.copyItem(at: src.appendingPathComponent(name), to: dst.appendingPathComponent(name))
            }
            return
        }
        guard let d = try? Data(contentsOf: src.appendingPathComponent("manifest.json")),
              let bundled = try? JSONDecoder().decode(HTMLManifest.self, from: d) else { return }
        var changed = false
        for t in bundled.templates where !local.templates.contains(where: { $0.id == t.id }) {
            let folder = (t.entry as NSString).pathComponents.first ?? ""
            if !folder.isEmpty, !fm.fileExists(atPath: dst.appendingPathComponent(folder).path) {
                try? fm.copyItem(at: src.appendingPathComponent(folder), to: dst.appendingPathComponent(folder))
            }
            local.templates.append(t); changed = true
        }
        if changed {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try? enc.encode(local).write(to: mURL)
        }
    }

    static func manifest() -> HTMLManifest? {
        guard let d = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(HTMLManifest.self, from: d)
    }

    // MARK: Operator templates (imported HTML files, edited copies)

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static var userDirectory: URL {
        let d = documents.appendingPathComponent("GraphicsUser", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func userTemplates() -> [HTMLTemplate] {
        guard let d = try? Data(contentsOf: userDirectory.appendingPathComponent("user.json")),
              let m = try? JSONDecoder().decode(HTMLManifest.self, from: d) else { return [] }
        return m.templates.map { var t = $0; t.user = true; return t }
    }

    static func saveUserTemplates(_ list: [HTMLTemplate]) {
        let m = HTMLManifest(version: 1, templates: list)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let d = try? enc.encode(m) { try? d.write(to: userDirectory.appendingPathComponent("user.json")) }
    }

    static func entryURL(_ t: HTMLTemplate) -> URL {
        (t.isUser ? userDirectory : directory).appendingPathComponent(t.entry)
    }

    /// Finds the editable parts of a page:
    /// 1. `<script type="application/json" id="dtd-fields">[{"id":…,"label":…}]</script>`
    /// 2. elements with `data-field="key"` (optional `data-label`, `data-default`, `data-type`; `<img>` → image)
    /// 3. colour CSS variables (`--accent: #f26b1d`) → colour pickers
    /// 4. if 1–2 found nothing: elements with an `id` that hold plain text.
    static func detectFields(_ html: String) -> [HTMLTemplate.Field] {
        var out: [HTMLTemplate.Field] = []
        func add(_ f: HTMLTemplate.Field) { if !out.contains(where: { $0.id == f.id }) { out.append(f) } }
        func matches(_ pattern: String) -> [[String]] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
            let ns = html as NSString
            return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { m in
                (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
            }
        }
        func attr(_ name: String, in tag: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: name + #"\s*=\s*["']([^"']*)["']"#, options: .caseInsensitive),
                  let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
            return (tag as NSString).substring(with: m.range(at: 1))
        }
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let js = matches(#"<script[^>]*id=["']dtd-fields["'][^>]*>(.*?)</script>"#).first?[1],
           let list = try? JSONDecoder().decode([HTMLTemplate.Field].self, from: Data(js.utf8)) {
            list.forEach(add)
        }
        for m in matches(#"<(\w+)([^>]*\bdata-field\s*=\s*["'][^"']+["'][^>]*)>([^<]*)"#) {
            let tag = m[2]
            guard let key = attr("data-field", in: tag) else { continue }
            let isImg = m[1].lowercased() == "img"
            add(.init(id: key, label: attr("data-label", in: tag) ?? key,
                      default: attr("data-default", in: tag) ?? (isImg ? (attr("src", in: tag) ?? "") : clean(m[3])),
                      type: attr("data-type", in: tag) ?? (isImg ? "image" : nil)))
        }
        if out.isEmpty {
            for m in matches(#"<(\w+)[^>]*\bid\s*=\s*["']([\w-]+)["'][^>]*>([^<]{1,120})</\1>"#) {
                let tag = m[1].lowercased(), text = clean(m[3])
                guard !["script", "style", "title"].contains(tag), !text.isEmpty else { continue }
                add(.init(id: m[2], label: m[2], default: text, type: nil))
            }
        }
        for m in matches(#"(--[\w-]+)\s*:\s*(#[0-9a-fA-F]{3,8})\b"#) {
            add(.init(id: m[1], label: L("Màu") + " " + String(m[1].dropFirst(2)), default: m[2], type: "color"))
        }
        return out
    }

    /// Copies an .html file, or a folder holding one, into GraphicsUser and registers it.
    static func importHTML(_ url: URL) throws -> HTMLTemplate {
        let fm = FileManager.default
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        let base = url.deletingPathExtension().lastPathComponent
        let slug = base.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let id = "u-\(slug.isEmpty ? "html" : slug)-\(UUID().uuidString.prefix(4).lowercased())"
        let folder = userDirectory.appendingPathComponent(id, isDirectory: true)
        let entry: String
        if isDir.boolValue {
            try fm.copyItem(at: url, to: folder)
            let files = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            guard let page = files.first(where: { $0.lowercased() == "index.html" })
                    ?? files.sorted().first(where: { ["html", "htm"].contains(($0 as NSString).pathExtension.lowercased()) }) else {
                try? fm.removeItem(at: folder)
                throw NSError(domain: "dtd", code: 2, userInfo: [NSLocalizedDescriptionKey: L("Thư mục không có file .html")])
            }
            entry = "\(id)/\(page)"
        } else {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: folder.appendingPathComponent("index.html"))
            entry = "\(id)/index.html"
        }
        let html = (try? String(contentsOf: userDirectory.appendingPathComponent(entry), encoding: .utf8)) ?? ""
        var name = base
        if let r = html.range(of: #"(?<=<title>)[^<]+"#, options: [.regularExpression, .caseInsensitive]) {
            let t = html[r].trimmingCharacters(in: .whitespaces); if !t.isEmpty { name = t }
        }
        let t = HTMLTemplate(id: id, name: name, entry: entry, fields: detectFields(html), user: true)
        saveUserTemplates(userTemplates() + [t])
        return t
    }

    /// Makes an editable copy of any template (built-in ones are replaced by Git sync).
    static func duplicate(_ t: HTMLTemplate) throws -> HTMLTemplate {
        let fm = FileManager.default
        let srcFolder = entryURL(t).deletingLastPathComponent()
        let id = "u-\(t.id.replacingOccurrences(of: "u-", with: ""))-\(UUID().uuidString.prefix(4).lowercased())"
        let folder = userDirectory.appendingPathComponent(id, isDirectory: true)
        try fm.copyItem(at: srcFolder, to: folder)
        let c = HTMLTemplate(id: id, name: t.name + " " + L("(bản sao)"),
                         entry: "\(id)/\(entryURL(t).lastPathComponent)", fields: t.fields, user: true)
        saveUserTemplates(userTemplates() + [c])
        return c
    }

    static func deleteUser(_ t: HTMLTemplate) {
        guard t.isUser else { return }
        try? FileManager.default.removeItem(at: entryURL(t).deletingLastPathComponent())
        saveUserTemplates(userTemplates().filter { $0.id != t.id })
    }

    static func updateUser(_ t: HTMLTemplate) {
        saveUserTemplates(userTemplates().map { $0.id == t.id ? t : $0 })
    }

    /// Saves edited HTML; fields are re-detected but ones still used by the page are kept.
    static func saveSource(_ t: HTMLTemplate, html: String) throws -> HTMLTemplate {
        try html.write(to: entryURL(t), atomically: true, encoding: .utf8)
        var c = t
        let found = detectFields(html)
        var fields = t.fields.filter { f in found.contains(where: { $0.id == f.id }) || html.contains(f.id) || f.id == "accent" }
        for f in found where !fields.contains(where: { $0.id == f.id }) { fields.append(f) }
        c.fields = fields
        updateUser(c)
        return c
    }

    /// Fallback API for pages that only mark editable parts (no update/play/stop of their own).
    static let shimJS = """
    (function(){
      function setv(k,v){
        if(k.indexOf('--')===0){document.documentElement.style.setProperty(k,v);return;}
        var els=document.querySelectorAll('[data-field="'+k+'"]');
        if(!els.length){var e=document.getElementById(k);if(e)els=[e];}
        Array.prototype.forEach.call(els,function(e){
          if(e.tagName==='IMG'){e.src=v;}else{e.textContent=v;}
        });
      }
      if(typeof window.update!=='function'){window.update=function(d){if(typeof d==='string')d=JSON.parse(d);for(var k in d)setv(k,d[k]);};}
      if(typeof window.play!=='function'){
        var st=document.createElement('style');
        st.textContent='body.dtd-in{animation:dtdIn .45s ease-out both}body.dtd-out{animation:dtdOut .4s ease-in both}@keyframes dtdIn{from{opacity:0;transform:translateY(24px)}}@keyframes dtdOut{to{opacity:0;transform:translateY(24px)}}';
        document.head.appendChild(st);
        window.play=function(){document.body.classList.remove('dtd-out');void document.body.offsetWidth;document.body.classList.add('dtd-in');};
      }
      if(typeof window.stop!=='function'){window.stop=function(){document.body.classList.remove('dtd-in');document.body.classList.add('dtd-out');};}
      if(typeof window.next!=='function'){window.next=function(){};}
    })();
    """

    static func webConfiguration() -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsInlineMediaPlayback = true
        cfg.userContentController.addUserScript(WKUserScript(source: shimJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        return cfg
    }

    // MARK: Layout (size / position), saved inside the template's HTML file

    /// Rule per template id in one <style id="dtd-layout"> block, e.g.
    /// body[data-dtd="lt-news-red"]{transform-origin:left bottom;transform:translate(0px,0px) scale(1.2)}
    /// (several templates can share one file — the colour variants — each keeps its own rule).
    static func readLayout(_ t: HTMLTemplate) -> HTMLLayout {
        guard let html = try? String(contentsOf: entryURL(t), encoding: .utf8) else { return HTMLLayout() }
        let id = NSRegularExpression.escapedPattern(for: t.id)
        let pattern = #"body\[data-dtd=""# + id + #""\]\{transform-origin:([a-z ]+);transform:translate\((-?[\d.]+)px,(-?[\d.]+)px\) scale\(([\d.]+)\)\}"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) else { return HTMLLayout() }
        let ns = html as NSString
        return HTMLLayout(scale: Double(ns.substring(with: m.range(at: 4))) ?? 1,
                          x: Double(ns.substring(with: m.range(at: 2))) ?? 0,
                          y: Double(ns.substring(with: m.range(at: 3))) ?? 0,
                          anchor: ns.substring(with: m.range(at: 1)))
    }

    static func writeLayout(_ t: HTMLTemplate, _ l: HTMLLayout) {
        let url = entryURL(t)
        guard var html = try? String(contentsOf: url, encoding: .utf8) else { return }
        let ns = html as NSString
        let id = NSRegularExpression.escapedPattern(for: t.id)
        // drop this template's old rule
        if let re = try? NSRegularExpression(pattern: #"\s*body\[data-dtd=""# + id + #""\]\{[^}]*\}"#) {
            html = re.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        if !l.isIdentity {
            let rule = "\n  " + l.cssRule(for: t.id)
            if let r = html.range(of: #"<style id="dtd-layout">"#) {
                html.insert(contentsOf: rule, at: r.upperBound)
            } else if let r = html.range(of: "</head>", options: .caseInsensitive) {
                html.insert(contentsOf: "<style id=\"dtd-layout\">" + rule + "\n</style>\n", at: r.lowerBound)
            } else {
                html = "<style id=\"dtd-layout\">" + rule + "\n</style>\n" + html
            }
        }
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Image values are stored as "logo:<file>" (the container path changes between installs).
    static func resolve(_ v: String, _ f: HTMLTemplate.Field) -> String {
        guard f.isImage, v.hasPrefix("logo:") else { return v }
        return MediaLibrary.directory(.logo).appendingPathComponent(String(v.dropFirst(5))).absoluteString
    }

    /// JS that pushes values to a page (also sets CSS variables directly for pages whose update() ignores them).
    static func pushJS(_ t: HTMLTemplate, values: [String: String], layout: HTMLLayout? = nil) -> String? {
        var d: [String: String] = [:]
        for f in t.fields { d[f.id] = resolve(values[f.id] ?? f.default ?? "", f) }
        guard let json = try? JSONSerialization.data(withJSONObject: d), let s = String(data: json, encoding: .utf8) else { return nil }
        let lay = layout.map { layoutJS($0) } ?? ""
        return "document.body.dataset.dtd='\(t.id)';\(lay)(function(d){try{if(typeof update==='function')update(d);}catch(e){}for(var k in d){if(k.indexOf('--')===0)document.documentElement.style.setProperty(k,d[k]);}})(\(s))"
    }

    /// Applies a layout straight away (inline style beats the saved rule while editing).
    static func layoutJS(_ l: HTMLLayout) -> String {
        "document.body.style.transformOrigin='\(l.anchor)';document.body.style.transform='\(l.transform)';"
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
        templates = HTMLGraphicsStore.userTemplates() + (HTMLGraphicsStore.manifest()?.templates ?? [])
        if let id = loadedID {
            if templates.contains(where: { $0.id == id }) { load(id) } else { if onAir { stop() }; loadedID = nil }
        }
    }

    // Operator templates
    @discardableResult
    func importHTML(_ url: URL) throws -> HTMLTemplate {
        let t = try HTMLGraphicsStore.importHTML(url); reload(); return t
    }
    @discardableResult
    func duplicate(_ t: HTMLTemplate) throws -> HTMLTemplate {
        let c = try HTMLGraphicsStore.duplicate(t)
        values[c.id] = values[t.id]
        reload(); return c
    }
    func delete(_ t: HTMLTemplate) {
        if loadedID == t.id { if onAir { stop() }; loadedID = nil }
        HTMLGraphicsStore.deleteUser(t); values[t.id] = nil; reload()
    }
    func rename(_ t: HTMLTemplate, _ name: String) {
        var c = t; c.name = name; HTMLGraphicsStore.updateUser(c); reload()
    }
    func saveSource(_ t: HTMLTemplate, html: String) throws {
        _ = try HTMLGraphicsStore.saveSource(t, html: html)
        layouts[t.id] = nil
        reload()
    }
    func values(for t: HTMLTemplate) -> [String: String] { values[t.id] ?? [:] }

    // Resize: per-template layout, read from / written into the template's HTML file.
    @Published private(set) var layouts: [String: HTMLLayout] = [:]
    private var layoutSave: [String: Task<Void, Never>] = [:]

    func layout(_ t: HTMLTemplate) -> HTMLLayout {
        if let l = layouts[t.id] { return l }
        let l = HTMLGraphicsStore.readLayout(t)
        DispatchQueue.main.async { self.layouts[t.id] = l }
        return l
    }

    func setLayout(_ t: HTMLTemplate, _ l: HTMLLayout) {
        layouts[t.id] = l
        if loadedID == t.id { web?.evaluateJavaScript("document.body.dataset.dtd='\(t.id)';" + HTMLGraphicsStore.layoutJS(l)) }
        // write into the HTML file once the slider settles
        layoutSave[t.id]?.cancel()
        layoutSave[t.id] = Task { [t, l] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            HTMLGraphicsStore.writeLayout(t, l)
        }
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
        pageReady = false
        // Read access to all of Documents so pages can show images from the Logo library.
        w.loadFileURL(HTMLGraphicsStore.entryURL(t), allowingReadAccessTo: HTMLGraphicsStore.documents)
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
        guard let js = HTMLGraphicsStore.pushJS(t, values: values[t.id] ?? [:], layout: layout(t)) else { return }
        web?.evaluateJavaScript(js)
    }

    private func ensureWebView() -> WKWebView {
        if let w = web { return w }
        let w = WKWebView(frame: CGRect(origin: .zero, size: renderSize), configuration: HTMLGraphicsStore.webConfiguration())
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        w.scrollView.isScrollEnabled = false
        // The view sits in the app window: without this, safe-area insets (status/home bar) shift the page
        // down and cut off whatever sits at the bottom (ticker).
        w.scrollView.contentInsetAdjustmentBehavior = .never
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

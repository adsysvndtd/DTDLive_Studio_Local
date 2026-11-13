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
struct HTMLLayout: Codable, Equatable {
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

/// Look of one layer (block or text) of an HTML graphic: `[data-layer=k]`, `[data-field=k]` or `#k`.
struct HTMLLayerStyle: Codable, Equatable {
    var hidden = false
    var x: Double = 0, y: Double = 0, scale: Double = 1, opacity: Double = 1
    var fontFamily: String? = nil
    var fontSize: Double? = nil        // px; nil = template's size
    var weight: Int? = nil
    var italic = false
    var uppercase: Bool? = nil         // nil = template default
    var letterSpacing: Double? = nil   // px
    var color: String? = nil           // text colour
    var background: String? = nil
    var bgAlpha: Double = 1
    var isDefault: Bool { self == HTMLLayerStyle() }

    /// `translate` / `scale` / `filter` compose with the template's own transform animations instead of fighting them.
    func css(_ base: String) -> String {
        var own: [String] = [], text: [String] = []
        if hidden { own.append("visibility:hidden!important") }
        if abs(x) > 0.5 || abs(y) > 0.5 { own.append("translate:\(Int(x.rounded()))px \(Int(y.rounded()))px") }
        if abs(scale - 1) > 0.001 { own.append("scale:\(String(format: "%.3f", scale))") }
        if opacity < 0.999 { own.append("filter:opacity(\(String(format: "%.2f", opacity)))") }
        if let fontSize { own.append("font-size:\(Int(fontSize))px!important") }
        if let background {
            let c = UIColor(hex: background); var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            own.append("background:rgba(\(Int(r * 255)),\(Int(g * 255)),\(Int(b * 255)),\(String(format: "%.2f", bgAlpha)))!important")
        }
        if let fontFamily { text.append("font-family:\(fontFamily)!important") }
        if let weight { text.append("font-weight:\(weight)!important") }
        if italic { text.append("font-style:italic!important") }
        if let uppercase { text.append("text-transform:\(uppercase ? "uppercase" : "none")!important") }
        if let letterSpacing { text.append("letter-spacing:\(String(format: "%.1f", letterSpacing))px!important") }
        if let color { text.append("color:\(color)!important;-webkit-text-fill-color:\(color)!important") }
        var out = ""
        if !own.isEmpty { out += "\(base){\(own.joined(separator: ";"))}\n" }
        if !text.isEmpty { out += "\(base),\(base) *{\(text.joined(separator: ";"))}\n" }
        return out
    }

    static let fonts: [(String, String)] = [
        ("-apple-system,sans-serif", "SF (hệ thống)"), ("'Avenir Next',sans-serif", "Avenir Next"),
        ("'Helvetica Neue',sans-serif", "Helvetica Neue"), ("Futura,sans-serif", "Futura"), ("'Gill Sans',sans-serif", "Gill Sans"),
        ("'Trebuchet MS',sans-serif", "Trebuchet"), ("Verdana,sans-serif", "Verdana"), ("Arial,sans-serif", "Arial"),
        ("Georgia,serif", "Georgia"), ("'Times New Roman',serif", "Times New Roman"), ("Didot,serif", "Didot"),
        ("'American Typewriter',serif", "American Typewriter"), ("Menlo,monospace", "Menlo"),
        ("'Marker Felt',cursive", "Marker Felt"), ("'Chalkboard SE',cursive", "Chalkboard")]
}

/// Everything the operator designs for one template, stored in its HTML file (see writeDesign).
/// A styleable layer of a template (shown as a chip in Design › Layers).
struct HTMLLayerRef: Identifiable, Equatable {
    let key: String
    let label: String
    var id: String { key }
}

struct HTMLDesign: Codable, Equatable {
    var layout = HTMLLayout()
    var fx = "none"               // in/out effect on the whole graphic (keyframes in shimJS)
    var fxDuration: Double = 0.6
    var shine = false             // light sweep after it comes in
    var layers: [String: HTMLLayerStyle] = [:]

    static let effects: [(String, String)] = [
        ("none", "Theo mẫu"), ("fade", "Mờ dần"), ("slideL", "Trượt từ trái"), ("slideR", "Trượt từ phải"),
        ("slideU", "Trồi lên"), ("drop", "Rơi xuống"), ("zoom", "Phóng to"), ("pop", "Bật nảy"), ("flip", "Lật"),
        ("wipe", "Quét ngang"), ("wipeV", "Quét dọc"), ("blur", "Mờ nét"), ("glitch", "Nhiễu")]

    /// CSS for this template id (layout + effect variables + layers).
    func css(for id: String) -> String {
        let body = "body[data-dtd=\"\(id)\"]"
        var b = "--dtd-fx:\(fx);--dtd-fxd:\(String(format: "%.2f", fxDuration))s;--dtd-shine:\(shine ? 1 : 0);"
        if !layout.isIdentity { b += "transform-origin:\(layout.anchor);transform:\(layout.transform);" }
        var out = "\(body){\(b)}\n"
        for (k, st) in layers.sorted(by: { $0.key < $1.key }) where !st.isDefault {
            let safe = k.replacingOccurrences(of: "\"", with: "")
            var sel = "\(body) :is([data-layer=\"\(safe)\"],[data-field=\"\(safe)\"]"
            if let f = safe.first, f.isLetter, safe.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) { sel += ",#\(safe)" }
            sel += ")"
            out += st.css(sel)
        }
        return out
    }
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
      // Everything goes in one wrapper: the app's layout transform sits on <body>, effects animate the wrapper.
      var w=document.getElementById('dtd-fx');
      if(!w){
        w=document.createElement('div');w.id='dtd-fx';
        w.style.cssText='position:absolute;left:0;top:0;width:1920px;height:1080px;overflow:visible';
        while(document.body.firstChild){w.appendChild(document.body.firstChild);}
        document.body.appendChild(w);
      }
      var st=document.createElement('style');
      st.textContent=[
        '@keyframes dtd-fade{from{opacity:0}to{opacity:1}}',
        '@keyframes dtd-slideL{from{transform:translateX(-110%);opacity:0}to{transform:none;opacity:1}}',
        '@keyframes dtd-slideR{from{transform:translateX(110%);opacity:0}to{transform:none;opacity:1}}',
        '@keyframes dtd-slideU{from{transform:translateY(40%);opacity:0}to{transform:none;opacity:1}}',
        '@keyframes dtd-drop{from{transform:translateY(-40%);opacity:0}to{transform:none;opacity:1}}',
        '@keyframes dtd-zoom{from{transform:scale(.5);opacity:0}to{transform:none;opacity:1}}',
        '@keyframes dtd-pop{0%{transform:scale(0);opacity:0}60%{transform:scale(1.08);opacity:1}80%{transform:scale(.97)}100%{transform:none;opacity:1}}',
        '@keyframes dtd-flip{from{transform:perspective(1400px) rotateX(90deg);opacity:0}to{transform:none;opacity:1}}',
        '@keyframes dtd-wipe{from{clip-path:inset(0 100% 0 0)}to{clip-path:inset(0 0 0 0)}}',
        '@keyframes dtd-wipeV{from{clip-path:inset(100% 0 0 0)}to{clip-path:inset(0 0 0 0)}}',
        '@keyframes dtd-blur{from{filter:blur(24px);opacity:0}to{filter:none;opacity:1}}',
        '@keyframes dtd-glitch{0%{opacity:0;transform:translate(-30px,0) skewX(20deg)}20%{opacity:1;transform:translate(20px,0) skewX(-12deg)}40%{transform:translate(-10px,0)}60%{transform:translate(6px,0) skewX(4deg)}80%{transform:translate(-2px,0)}100%{transform:none;opacity:1}}',
        '#dtd-fx.dtd-shine::after{content:"";position:absolute;inset:0;pointer-events:none;background:linear-gradient(105deg,transparent 40%,rgba(255,255,255,.45) 50%,transparent 60%);background-size:250% 100%;mix-blend-mode:screen;animation:dtd-sweep 1.1s ease-in-out both}',
        '@keyframes dtd-sweep{from{background-position:120% 0}to{background-position:-30% 0}}',
        'body.dtd-in #dtd-fx.dtd-plain{animation:dtd-fade .45s ease-out both}',
        'body.dtd-out #dtd-fx.dtd-plain{animation:dtd-fade .4s ease-in reverse both}'
      ].join('\\n');
      document.head.appendChild(st);
      if(typeof window.update!=='function'){window.update=function(d){if(typeof d==='string')d=JSON.parse(d);for(var k in d)setv(k,d[k]);};}
      // pages without their own animation: plain fade in/out of the wrapper
      if(typeof window.play!=='function'){
        w.classList.add('dtd-plain');
        window.play=function(){document.body.classList.remove('dtd-out');void w.offsetWidth;document.body.classList.add('dtd-in');};
      }
      if(typeof window.stop!=='function'){window.stop=function(){document.body.classList.remove('dtd-in');document.body.classList.add('dtd-out');};}
      if(typeof window.next!=='function'){window.next=function(){};}
      function v(n){return getComputedStyle(document.body).getPropertyValue(n).trim();}
      // In/out effect chosen in the app (on top of the template's own animation).
      window.dtdPlay=function(){
        var fx=v('--dtd-fx')||'none', d=v('--dtd-fxd')||'0.6s';
        w.classList.remove('dtd-shine'); w.style.animation='none'; void w.offsetWidth;
        if(fx!=='none'){w.style.animation='dtd-'+fx+' '+d+' cubic-bezier(.2,.8,.2,1) both';}
        if(v('--dtd-shine')==='1'){setTimeout(function(){w.classList.add('dtd-shine');},(parseFloat(d)||0.6)*1000);}
        try{play();}catch(e){}
      };
      window.dtdStop=function(){
        var fx=v('--dtd-fx')||'none', d=v('--dtd-fxd')||'0.6s';
        w.classList.remove('dtd-shine');
        if(fx!=='none'){w.style.animation='none';void w.offsetWidth;w.style.animation='dtd-'+fx+' '+d+' cubic-bezier(.6,0,.8,.2) reverse both';}
        try{stop();}catch(e){}
      };
    })();
    """

    static func webConfiguration() -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsInlineMediaPlayback = true
        cfg.userContentController.addUserScript(WKUserScript(source: shimJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        return cfg
    }

    // MARK: Design (layout, layers, effect), saved inside the template's HTML file

    /// In the page's <style id="dtd-layout"> block, one section per template id (colour variants share a file):
    ///   /*<dtd id="lt-news-red">{json}*/ …generated CSS… /*</dtd>*/
    static func readDesign(_ t: HTMLTemplate) -> HTMLDesign {
        guard let html = try? String(contentsOf: entryURL(t), encoding: .utf8) else { return HTMLDesign() }
        let id = NSRegularExpression.escapedPattern(for: t.id)
        guard let re = try? NSRegularExpression(pattern: #"/\*<dtd id=""# + id + #"">(.*?)\*/"#, options: .dotMatchesLineSeparators),
              let m = re.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) else { return HTMLDesign() }
        let json = (html as NSString).substring(with: m.range(at: 1))
        return (try? JSONDecoder().decode(HTMLDesign.self, from: Data(json.utf8))) ?? HTMLDesign()
    }

    static func writeDesign(_ t: HTMLTemplate, _ d: HTMLDesign) {
        let url = entryURL(t)
        guard var html = try? String(contentsOf: url, encoding: .utf8) else { return }
        let id = NSRegularExpression.escapedPattern(for: t.id)
        for pattern in [#"\s*/\*<dtd id=""# + id + #"">.*?/\*</dtd>\*/"#,
                        #"\s*body\[data-dtd=""# + id + #""\]\{transform-origin:[^}]*\}"#] {   // this section / older single rule
            if let re = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) {
                html = re.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length), withTemplate: "")
            }
        }
        if d != HTMLDesign() {
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = (try? enc.encode(d)).flatMap { String(data: $0, encoding: .utf8) }?.replacingOccurrences(of: "*/", with: "* /") ?? "{}"
            let section = "\n/*<dtd id=\"\(t.id)\">\(json)*/\n\(d.css(for: t.id))/*</dtd>*/"
            if let r = html.range(of: #"<style id="dtd-layout">"#) {
                html.insert(contentsOf: section, at: r.upperBound)
            } else if let r = html.range(of: "</head>", options: .caseInsensitive) {
                html.insert(contentsOf: "<style id=\"dtd-layout\">" + section + "\n</style>\n", at: r.lowerBound)
            } else {
                html = "<style id=\"dtd-layout\">" + section + "\n</style>\n" + html
            }
        }
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Layers the operator can style: blocks marked `data-layer` (+ `data-label`), then the template's text/image fields.
    static func layers(_ t: HTMLTemplate) -> [HTMLLayerRef] {
        var out: [HTMLLayerRef] = []
        if let html = try? String(contentsOf: entryURL(t), encoding: .utf8),
           let re = try? NSRegularExpression(pattern: #"<[^>]*\bdata-layer\s*=\s*["']([^"']+)["'][^>]*>"#),
           let lre = try? NSRegularExpression(pattern: #"data-label\s*=\s*["']([^"']+)["']"#) {
            let ns = html as NSString
            for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 1)), tag = ns.substring(with: m.range(at: 0))
                var label = key
                if let lm = lre.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) {
                    label = (tag as NSString).substring(with: lm.range(at: 1))
                }
                if !out.contains(where: { $0.key == key }) { out.append(HTMLLayerRef(key: key, label: label)) }
            }
        }
        for f in t.fields where !f.isColor && !f.id.hasPrefix("--") && !out.contains(where: { $0.key == f.id }) {
            out.append(HTMLLayerRef(key: f.id, label: f.label))
        }
        return out
    }

    /// JS that applies a design straight away (a <style id="dtd-live"> after the saved one).
    static func designJS(_ t: HTMLTemplate, _ d: HTMLDesign) -> String {
        let css = d.css(for: t.id)
        let lit = (try? JSONSerialization.data(withJSONObject: [css])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return "document.body.dataset.dtd='\(t.id)';(function(c){var s=document.getElementById('dtd-live');if(!s){s=document.createElement('style');s.id='dtd-live';document.head.appendChild(s);}s.textContent=c;})(\(lit)[0]);"
    }

    /// Image values are stored as "logo:<file>" (the container path changes between installs).
    static func resolve(_ v: String, _ f: HTMLTemplate.Field) -> String {
        guard f.isImage, v.hasPrefix("logo:") else { return v }
        return MediaLibrary.directory(.logo).appendingPathComponent(String(v.dropFirst(5))).absoluteString
    }

    /// JS that pushes values to a page (also sets CSS variables directly for pages whose update() ignores them).
    static func pushJS(_ t: HTMLTemplate, values: [String: String], design: HTMLDesign? = nil) -> String? {
        var d: [String: String] = [:]
        for f in t.fields { d[f.id] = resolve(values[f.id] ?? f.default ?? "", f) }
        guard let json = try? JSONSerialization.data(withJSONObject: d), let s = String(data: json, encoding: .utf8) else { return nil }
        let des = design.map { designJS(t, $0) } ?? "document.body.dataset.dtd='\(t.id)';"
        return "\(des)(function(d){try{if(typeof update==='function')update(d);}catch(e){}for(var k in d){if(k.indexOf('--')===0)document.documentElement.style.setProperty(k,d[k]);}})(\(s))"
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
        designs[t.id] = nil; layerCache[t.id] = nil
        reload()
    }
    func values(for t: HTMLTemplate) -> [String: String] { values[t.id] ?? [:] }

    // Design (Resize / layers / effect): per template, read from / written into its HTML file.
    @Published private(set) var designs: [String: HTMLDesign] = [:]
    private var designSave: [String: Task<Void, Never>] = [:]
    private var layerCache: [String: [HTMLLayerRef]] = [:]

    func design(_ t: HTMLTemplate) -> HTMLDesign {
        if let d = designs[t.id] { return d }
        let d = HTMLGraphicsStore.readDesign(t)
        DispatchQueue.main.async { if self.designs[t.id] == nil { self.designs[t.id] = d } }
        return d
    }

    func setDesign(_ t: HTMLTemplate, _ d: HTMLDesign) {
        designs[t.id] = d
        if loadedID == t.id { web?.evaluateJavaScript(HTMLGraphicsStore.designJS(t, d)) }
        // written into the HTML file once the control settles
        designSave[t.id]?.cancel()
        designSave[t.id] = Task { [t, d] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            HTMLGraphicsStore.writeDesign(t, d)
        }
    }

    func layout(_ t: HTMLTemplate) -> HTMLLayout { design(t).layout }
    func setLayout(_ t: HTMLTemplate, _ l: HTMLLayout) { var d = design(t); d.layout = l; setDesign(t, d) }

    func layers(_ t: HTMLTemplate) -> [HTMLLayerRef] {
        if let l = layerCache[t.id] { return l }
        let l = HTMLGraphicsStore.layers(t)
        layerCache[t.id] = l
        return l
    }

    /// Plays the graphic's in-effect on air again (to check a new effect).
    func replay() {
        guard onAir else { return }
        web?.evaluateJavaScript("window.dtdPlay?dtdPlay():play()")
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
        web?.evaluateJavaScript("window.dtdPlay?dtdPlay():play()")
        onAir = true; stopDeadline = nil
        startCapture()
    }

    func stop() {
        guard onAir else { return }
        web?.evaluateJavaScript("window.dtdStop?dtdStop():stop()")
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
        guard let js = HTMLGraphicsStore.pushJS(t, values: values[t.id] ?? [:], design: design(t)) else { return }
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

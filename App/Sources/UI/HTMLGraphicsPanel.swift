import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// HTML5 graphics: pick a template (arms it), edit its fields live, update from Git.
/// It goes on air with the "HTML On" key in the right column.
struct HTMLGraphicsPanel: View {
    @ObservedObject var html: HTMLGraphics
    @ObservedObject var repo: GraphicsRepo
    var compact = false
    @AppStorage("ui.htmlPanelOpen") private var open = true
    @State private var pickHTML = false
    @State private var editing: HTMLTemplate?
    @State private var renaming: HTMLTemplate?
    @State private var newName = ""
    @State private var message: String?

    var body: some View {
        SectionCard("Đồ hoạ HTML5", systemImage: "chevron.left.forwardslash.chevron.right",
                    trailing: AnyView(Button { open.toggle() } label: {
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(DS.fBodyBold)
                            .frame(width: 28, height: 22).foregroundStyle(DS.text2)
                    }.buttonStyle(.plain))) {
          if open {
            HStack(spacing: 6) {
                smallButton(repo.syncing ? "Đang tải…" : "Cập nhật từ Git", "arrow.triangle.2.circlepath") { Task { await repo.sync() } }
                    .disabled(repo.syncing)
                smallButton("Nhập HTML", "square.and.arrow.down") { pickHTML = true }
                Text(message ?? (repo.status.isEmpty ? "\(repo.settings.owner)/\(repo.settings.repo) › \(repo.settings.path)" : repo.status))
                    .font(.caption2).foregroundStyle(DS.text3).lineLimit(1)
                Spacer()
                if let t = html.templates.first(where: { $0.id == html.loadedID }) {
                    smallButton("Sửa", "pencil") { edit(t) }
                    smallButton("Next", "forward.frame") { html.next() }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(html.templates) { t in
                        let loaded = html.loadedID == t.id
                        Button { html.load(t.id) } label: {
                            HStack(spacing: 4) {
                                if t.isUser { Image(systemName: "person.crop.square").font(.system(size: 10)) }
                                Text(t.name).lineLimit(1)
                            }
                            .font(.system(size: compact ? 12 : 13, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: compact ? 30 : 36)
                            .foregroundStyle(loaded ? .black : .white)
                            .background(loaded ? (html.onAir ? DS.pgm : DS.accent) : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { edit(t) } label: { Label(t.isUser ? "Sửa mã HTML" : "Nhân bản để sửa", systemImage: "pencil") }
                            Button { dup(t) } label: { Label("Nhân bản", systemImage: "plus.square.on.square") }
                            if t.isUser {
                                Button { newName = t.name; renaming = t } label: { Label("Đổi tên", systemImage: "character.cursor.ibeam") }
                                Button(role: .destructive) { html.delete(t) } label: { Label("Xoá", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            if let t = html.templates.first(where: { $0.id == html.loadedID }) {
                HTMLFieldRows(html: html, template: t, compact: compact)
            }
          }
        }
        .fileImporter(isPresented: $pickHTML, allowedContentTypes: [.html, .folder], allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            var names: [String] = []
            for u in urls {
                do { let t = try html.importHTML(u); names.append(t.name); html.load(t.id) }
                catch { message = LF("Lỗi: %@", error.localizedDescription) }
            }
            if !names.isEmpty { message = LF("Đã nhập: %@", names.joined(separator: ", ")) }
        }
        .sheet(item: $editing) { t in HTMLEditorSheet(html: html, template: t) }
        .alert("Đổi tên", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Tên", text: $newName)
            Button("Huỷ", role: .cancel) { renaming = nil }
            Button("Lưu") { if let t = renaming { html.rename(t, newName) }; renaming = nil }
        }
    }

    private func smallButton(_ title: LocalizedStringKey, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: compact ? 12 : 13, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 10).frame(height: compact ? 28 : 32)
                .foregroundStyle(.white).background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
    }

    /// Built-in templates are replaced by Git sync, so editing works on a copy.
    private func edit(_ t: HTMLTemplate) {
        if t.isUser { editing = t; return }
        do { let c = try html.duplicate(t); html.load(c.id); editing = c }
        catch { message = LF("Lỗi: %@", error.localizedDescription) }
    }

    private func dup(_ t: HTMLTemplate) {
        do { let c = try html.duplicate(t); html.load(c.id) } catch { message = LF("Lỗi: %@", error.localizedDescription) }
    }
}

/// Editable values of one template: text, colours (with broadcast presets) and logo images.
struct HTMLFieldRows: View {
    @ObservedObject var html: HTMLGraphics
    let template: HTMLTemplate
    var compact = false
    static let presets = ["#5172BE", "#3E5068", "#D98A2B", "#C84B33", "#2E9E6A", "#7A4FC2", "#111418"]

    var body: some View {
        let t = template
        ForEach(t.fields) { f in
            if f.isColor {
                HStack(spacing: 6) {
                    Text(f.label).font(DS.fBodyBold).foregroundStyle(DS.text2).lineLimit(1)
                    Spacer(minLength: 4)
                    ForEach(Self.presets, id: \.self) { hex in
                        let on = html.value(t, f).uppercased() == hex
                        Button { html.setValue(t, f, hex) } label: {
                            RoundedRectangle(cornerRadius: 4).fill(Color(UIColor(hex: hex)))
                                .frame(width: 22, height: 22)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white, lineWidth: on ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                    ColorPicker("", selection: Binding(get: { Color(UIColor(hex: html.value(t, f))) },
                                                       set: { html.setValue(t, f, UIColor($0).hexString) }),
                                supportsOpacity: false).labelsHidden()
                }
            } else if f.isImage {
                HStack {
                    Text(f.label).font(DS.fBodyBold).foregroundStyle(DS.text2).lineLimit(1)
                    Spacer()
                    Menu {
                        Button("Không dùng") { html.setValue(t, f, "") }
                        ForEach(MediaLibrary.listFiles(.logo), id: \.self) { u in
                            Button(u.lastPathComponent) { html.setValue(t, f, "logo:" + u.lastPathComponent) }
                        }
                    } label: {
                        let v = html.value(t, f)
                        Text(v.isEmpty ? L("Chọn từ thư viện Logo") : String(v.split(separator: "/").last ?? "").replacingOccurrences(of: "logo:", with: ""))
                            .font(DS.fBodyBold).lineLimit(1).padding(.horizontal, 10).frame(height: compact ? 28 : 32)
                            .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                    }
                }
            } else {
                TextField(f.label, text: Binding(get: { html.value(t, f) }, set: { html.setValue(t, f, $0) }))
                    .font(.system(size: compact ? 12 : 14, weight: .semibold))
                    .padding(.horizontal, 8).frame(height: compact ? 28 : 34)
                    .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
            }
        }
    }
}

/// Edit an operator template: live preview, field values and the HTML source.
struct HTMLEditorSheet: View {
    @ObservedObject var html: HTMLGraphics
    let template: HTMLTemplate
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var tab = 0
    @State private var previewSource = ""
    @State private var playToken = 0
    @State private var error: String?

    private var current: HTMLTemplate { html.templates.first(where: { $0.id == template.id }) ?? template }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                ZStack {
                    CheckerBackground()
                    HTMLPreviewView(template: current, source: previewSource, values: html.values(for: current), playToken: playToken)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.radius))
                HStack(spacing: 8) {
                    Button { playToken += 1 } label: { Label("Chạy hiệu ứng", systemImage: "play.fill") }
                    Button { previewSource = source; playToken += 1 } label: { Label("Xem mã đang sửa", systemImage: "eye") }
                    Spacer()
                    Picker("", selection: $tab) {
                        Text("Nội dung").tag(0)
                        Text("Mã HTML").tag(1)
                    }
                    .pickerStyle(.segmented).frame(width: 220)
                }
                .font(DS.fBodyBold).buttonStyle(.bordered)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if tab == 0 {
                    ScrollView { VStack(spacing: 6) { HTMLFieldRows(html: html, template: current) } }
                } else {
                    TextEditor(text: $source)
                        .font(.system(size: 12, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .scrollContentBackground(.hidden).background(DS.surface2)
                        .clipShape(RoundedRectangle(cornerRadius: DS.radius))
                    Text("Phần tử có data-field=\"tên\" sẽ thành ô sửa chữ; biến màu CSS (--accent: #…) thành ô chọn màu.")
                        .font(.caption2).foregroundStyle(DS.text3)
                }
            }
            .padding(12)
            .background(DS.bg)
            .navigationTitle(current.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        do { try html.saveSource(current, html: source); previewSource = ""; error = nil; playToken += 1 }
                        catch { self.error = error.localizedDescription }
                    }
                    .disabled(tab != 1)
                }
            }
            .onAppear { source = (try? String(contentsOf: HTMLGraphicsStore.entryURL(template), encoding: .utf8)) ?? "" }
        }
    }
}

private struct CheckerBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 12
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.white.opacity(0.08)))
                }
            }
        }
        .background(Color(white: 0.35))
    }
}

/// Live WKWebView preview of a template (1920×1080 page scaled to fit).
struct HTMLPreviewView: UIViewRepresentable {
    let template: HTMLTemplate
    /// Unsaved source to preview; empty = the saved file.
    let source: String
    let values: [String: String]
    let playToken: Int

    final class Box: UIView, WKNavigationDelegate {
        let web = WKWebView(frame: .zero, configuration: HTMLGraphicsStore.webConfiguration())
        var template: HTMLTemplate?
        var values: [String: String] = [:]
        var loadedKey = ""
        var playToken = -1
        override init(frame: CGRect) {
            super.init(frame: frame)
            web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
            web.scrollView.isScrollEnabled = false; web.isUserInteractionEnabled = false
            web.navigationDelegate = self
            addSubview(web)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() {
            super.layoutSubviews()
            web.frame = bounds
            if bounds.width > 0 { web.pageZoom = bounds.width / 1920 }
        }
        func push(play: Bool) {
            guard let t = template, let js = HTMLGraphicsStore.pushJS(t, values: values) else { return }
            web.evaluateJavaScript(js + (play ? ";typeof play==='function'&&play()" : ""))
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { push(play: true) }
    }

    func makeUIView(context: Context) -> Box { Box() }

    func updateUIView(_ v: Box, context: Context) {
        v.template = template
        v.values = values
        let key = template.id + "|" + String(source.hashValue)
        if key != v.loadedKey {
            v.loadedKey = key
            v.playToken = playToken
            var url = HTMLGraphicsStore.entryURL(template)
            if !source.isEmpty {
                // Unsaved edits: written next to the page so relative assets still load.
                let tmp = url.deletingLastPathComponent().appendingPathComponent(".dtd-preview.html")
                try? source.write(to: tmp, atomically: true, encoding: .utf8)
                url = tmp
            }
            v.web.loadFileURL(url, allowingReadAccessTo: HTMLGraphicsStore.documents)
        } else if playToken != v.playToken {
            v.playToken = playToken
            v.push(play: true)
        } else {
            v.push(play: false)
        }
    }
}

/// Git source for HTML5 graphics (Settings).
struct GraphicsRepoRows: View {
    @ObservedObject var repo: GraphicsRepo
    @State private var token = ""

    var body: some View {
        Group {
            TextField("Chủ repo (owner)", text: $repo.settings.owner).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Repo", text: $repo.settings.repo).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Nhánh", text: $repo.settings.branch).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Thư mục đồ hoạ", text: $repo.settings.path).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Token (chỉ cần cho repo private)", text: $token)
                .onSubmit { repo.token = token }
                .onAppear { token = repo.token }
            HStack {
                Button(repo.syncing ? "Đang tải…" : "Cập nhật từ Git") { repo.token = token; Task { await repo.sync(force: true) } }
                    .disabled(repo.syncing)
                Spacer()
                Text(repo.status).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

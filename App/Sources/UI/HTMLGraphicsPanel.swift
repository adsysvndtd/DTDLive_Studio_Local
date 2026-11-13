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
        HTMLResizeRows(html: html, template: t, compact: compact)
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

/// Design: Resize (whole graphic), per-layer look (font, colours, position, size) and the in/out effect.
/// Everything is saved into the template's HTML file.
struct HTMLResizeRows: View {
    @ObservedObject var html: HTMLGraphics
    let template: HTMLTemplate
    var compact = false
    @State private var open = false
    @State private var tab = 0
    @State private var layerKey: String?

    var body: some View {
        let t = template
        let d = html.design(t)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { open.toggle() } label: {
                    Label("Thiết kế", systemImage: "paintbrush.pointed")
                        .font(DS.fBodyBold).padding(.horizontal, 10).frame(height: compact ? 28 : 32)
                        .foregroundStyle(.white).background(open ? DS.accent.opacity(0.35) : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                }
                .buttonStyle(.plain)
                Text(verbatim: "\(Int((d.layout.scale * 100).rounded()))% · " + L(HTMLDesign.effects.first(where: { $0.0 == d.fx })?.1 ?? "Theo mẫu"))
                    .font(.caption.monospacedDigit()).foregroundStyle(DS.text3)
                Spacer()
                if d != HTMLDesign() {
                    Button("Về gốc") { html.setDesign(t, HTMLDesign()) }.font(DS.fBody).buttonStyle(.borderless)
                }
            }
            if open {
                Picker("", selection: $tab) {
                    Text("Bố cục").tag(0)
                    Text("Lớp").tag(1)
                    Text("Hiệu ứng").tag(2)
                }
                .pickerStyle(.segmented)
                switch tab {
                case 0: layoutRows(t, d)
                case 1: layerRows(t, d)
                default: effectRows(t, d)
                }
            }
        }
    }

    // MARK: Layout (whole graphic)

    @ViewBuilder private func layoutRows(_ t: HTMLTemplate, _ d: HTMLDesign) -> some View {
        let l = d.layout
        row("Kích thước", Binding(get: { l.scale }, set: { var n = html.layout(t); n.scale = $0; html.setLayout(t, n) }), 0.3...2.5) { "\(Int(($0 * 100).rounded()))%" }
        row("Ngang", Binding(get: { l.x }, set: { var n = html.layout(t); n.x = $0; html.setLayout(t, n) }), -1200...1200) { "\(Int($0)) px" }
        row("Dọc", Binding(get: { l.y }, set: { var n = html.layout(t); n.y = $0; html.setLayout(t, n) }), -800...800) { "\(Int($0)) px" }
        HStack(spacing: 8) {
            label("Điểm neo")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 3), count: 3), spacing: 3) {
                ForEach(HTMLLayout.anchors, id: \.0) { a in
                    Button { var n = html.layout(t); n.anchor = a.0; html.setLayout(t, n) } label: {
                        Text(a.1).font(.system(size: 12, weight: .bold)).frame(width: 26, height: 22)
                            .foregroundStyle(l.anchor == a.0 ? .black : .white)
                            .background(l.anchor == a.0 ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 84)
            Text("Điểm đứng yên khi phóng to/thu nhỏ.").font(.caption2).foregroundStyle(DS.text3)
            Spacer(minLength: 0)
        }
    }

    // MARK: Layers (header / title / logo / blocks…)

    @ViewBuilder private func layerRows(_ t: HTMLTemplate, _ d: HTMLDesign) -> some View {
        let layers = html.layers(t)
        let key = layerKey ?? layers.first?.key
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(layers) { ly in
                    let on = ly.key == key
                    Button { layerKey = ly.key } label: {
                        HStack(spacing: 3) {
                            if !(d.layers[ly.key]?.isDefault ?? true) { Circle().fill(DS.accent).frame(width: 5, height: 5) }
                            Text(ly.label).lineLimit(1)
                        }
                        .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10).frame(height: 26)
                        .foregroundStyle(on ? .black : .white)
                        .background(on ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if let key {
            let st = d.layers[key] ?? HTMLLayerStyle()
            let set: (@escaping (inout HTMLLayerStyle) -> Void) -> Void = { change in
                var n = html.design(t); var s = n.layers[key] ?? HTMLLayerStyle(); change(&s)
                n.layers[key] = s.isDefault ? nil : s; html.setDesign(t, n)
            }
            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { !st.hidden }, set: { v in set { $0.hidden = !v } })) { Text("Hiện").font(DS.fBody) }.fixedSize()
                Spacer()
                if !st.isDefault { Button("Về mặc định lớp") { set { $0 = HTMLLayerStyle() } }.font(DS.fBody).buttonStyle(.borderless) }
            }
            row("Ngang", Binding(get: { st.x }, set: { v in set { $0.x = v } }), -800...800) { "\(Int($0)) px" }
            row("Dọc", Binding(get: { st.y }, set: { v in set { $0.y = v } }), -500...500) { "\(Int($0)) px" }
            row("Kích thước", Binding(get: { st.scale }, set: { v in set { $0.scale = v } }), 0.3...3) { "\(Int(($0 * 100).rounded()))%" }
            row("Độ đậm", Binding(get: { st.opacity }, set: { v in set { $0.opacity = v } }), 0...1) { "\(Int($0 * 100))%" }
            HStack(spacing: 8) {
                label("Font")
                Menu {
                    Button("Theo mẫu") { set { $0.fontFamily = nil } }
                    ForEach(HTMLLayerStyle.fonts, id: \.0) { f in Button(f.1) { set { $0.fontFamily = f.0 } } }
                } label: {
                    Text(HTMLLayerStyle.fonts.first { $0.0 == st.fontFamily }?.1 ?? L("Theo mẫu"))
                        .font(DS.fBodyBold).lineLimit(1).padding(.horizontal, 10).frame(height: 28)
                        .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                }
                Menu {
                    Button("Theo mẫu") { set { $0.weight = nil } }
                    ForEach([300, 400, 500, 600, 700, 800, 900], id: \.self) { w in Button("\(w)") { set { $0.weight = w } } }
                } label: {
                    Text(st.weight.map { LF("Đậm %@", "\($0)") } ?? L("Độ đậm chữ"))
                        .font(DS.fBodyBold).padding(.horizontal, 10).frame(height: 28)
                        .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                }
                Button { set { $0.italic.toggle() } } label: {
                    Image(systemName: "italic").frame(width: 30, height: 28)
                        .background(st.italic ? DS.accent.opacity(0.4) : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                }.buttonStyle(.plain)
                Menu {
                    Button("Theo mẫu") { set { $0.uppercase = nil } }
                    Button("IN HOA") { set { $0.uppercase = true } }
                    Button("Như đã gõ") { set { $0.uppercase = false } }
                } label: {
                    Text(verbatim: st.uppercase == nil ? "Aa" : (st.uppercase! ? "AA" : "aa")).font(DS.fBodyBold).frame(width: 36, height: 28)
                        .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                }
                Spacer(minLength: 0)
            }
            row("Cỡ chữ", Binding(get: { st.fontSize ?? 0 }, set: { v in set { $0.fontSize = v < 8 ? nil : v.rounded() } }), 0...200) { $0 < 8 ? L("Theo mẫu") : "\(Int($0)) px" }
            row("Giãn chữ", Binding(get: { st.letterSpacing ?? 0 }, set: { v in set { $0.letterSpacing = abs(v) < 0.2 ? nil : v } }), -5...20) { String(format: "%.1f", $0) }
            colorRow("Màu chữ", st.color) { c in set { $0.color = c } }
            colorRow("Màu nền", st.background) { c in set { $0.background = c } }
            if st.background != nil {
                row("Độ đậm nền", Binding(get: { st.bgAlpha }, set: { v in set { $0.bgAlpha = v } }), 0...1) { "\(Int($0 * 100))%" }
            }
            HStack(spacing: 8) {
                label("Hiệu ứng màu")
                Menu {
                    Button("Phẳng (theo mẫu)") { set { $0.finish = nil } }
                    ForEach(HTMLLayerStyle.finishes, id: \.0) { f in Button(L(f.1)) { set { $0.finish = f.0 } } }
                } label: {
                    Text(L(HTMLLayerStyle.finishes.first(where: { $0.0 == st.finish })?.1 ?? "Phẳng (theo mẫu)"))
                        .font(DS.fBodyBold).lineLimit(1).padding(.horizontal, 10).frame(height: 28)
                        .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                }
                if st.finish == "gradient" || st.finish == "vgradient" {
                    ColorPicker("", selection: Binding(get: { Color(UIColor(hex: st.color2 ?? "#000000")) },
                                                       set: { c in set { $0.color2 = UIColor(c).hexString } }), supportsOpacity: false).labelsHidden()
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                label("Hiệu ứng chữ")
                Menu {
                    Button("Không") { set { $0.textFx = nil } }
                    ForEach(HTMLLayerStyle.textEffects, id: \.0) { f in Button(L(f.1)) { set { $0.textFx = f.0 } } }
                } label: {
                    Text(L(HTMLLayerStyle.textEffects.first(where: { $0.0 == st.textFx })?.1 ?? "Không"))
                        .font(DS.fBodyBold).lineLimit(1).padding(.horizontal, 10).frame(height: 28)
                        .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                }
                if st.textFx == "glow" || st.textFx == "outline" {
                    ColorPicker("", selection: Binding(get: { Color(UIColor(hex: st.fxColor ?? (st.textFx == "outline" ? "#000000" : "#FFFFFF"))) },
                                                       set: { c in set { $0.fxColor = UIColor(c).hexString } }), supportsOpacity: false).labelsHidden()
                }
                Spacer(minLength: 0)
            }
        } else {
            Text("Mẫu này chưa có lớp nào: đánh dấu khối bằng data-layer=\"tên\" trong HTML.").font(.caption2).foregroundStyle(DS.text3)
        }
    }

    // MARK: Effect

    @ViewBuilder private func effectRows(_ t: HTMLTemplate, _ d: HTMLDesign) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 5)], spacing: 5) {
            ForEach(HTMLDesign.effects, id: \.0) { e in
                let on = d.fx == e.0
                Button { var n = html.design(t); n.fx = e.0; html.setDesign(t, n); html.replay() } label: {
                    Text(L(e.1)).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity).frame(height: 28)
                        .foregroundStyle(on ? .black : .white)
                        .background(on ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                }
                .buttonStyle(.plain)
            }
        }
        row("Thời gian", Binding(get: { d.fxDuration }, set: { v in var n = html.design(t); n.fxDuration = v; html.setDesign(t, n) }), 0.2...2) { String(format: "%.1f s", $0) }
        HStack {
            Toggle(isOn: Binding(get: { d.shine }, set: { v in var n = html.design(t); n.shine = v; html.setDesign(t, n) })) {
                Text("Vệt sáng lướt qua sau khi vào").font(DS.fBody)
            }
            .fixedSize()
            Spacer()
            Button { html.replay() } label: { Label("Chạy lại", systemImage: "play.fill") }
                .font(DS.fBody).buttonStyle(.bordered).disabled(!html.onAir)
        }
        Text("Hiệu ứng chạy cùng chuyển động sẵn có của mẫu; ra bằng hiệu ứng ngược lại.").font(.caption2).foregroundStyle(DS.text3)
    }

    // MARK: Rows

    private func label(_ s: LocalizedStringKey) -> some View {
        Text(s).font(DS.fBody).foregroundStyle(DS.text2).frame(width: 84, alignment: .leading)
    }

    private func row(_ title: LocalizedStringKey, _ value: Binding<Double>, _ range: ClosedRange<Double>, fmt: @escaping (Double) -> String) -> some View {
        HStack(spacing: 8) {
            label(title)
            Slider(value: value, in: range).tint(DS.accent).controlSize(.small)
            Text(verbatim: fmt(value.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(DS.text3).frame(width: 64, alignment: .trailing)
        }
        .frame(height: 28)
    }

    private func colorRow(_ title: LocalizedStringKey, _ hex: String?, _ set: @escaping (String?) -> Void) -> some View {
        HStack(spacing: 8) {
            label(title)
            ColorPicker("", selection: Binding(get: { Color(UIColor(hex: hex ?? "#FFFFFF")) }, set: { set(UIColor($0).hexString) }),
                        supportsOpacity: false).labelsHidden()
            if hex != nil {
                Button { set(nil) } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 11)) }.buttonStyle(.borderless)
            } else {
                Text("Theo mẫu").font(.caption2).foregroundStyle(DS.text3)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 30)
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
                    HTMLCheckerBackground()
                    HTMLPreviewView(template: current, source: previewSource, values: html.values(for: current),
                                    design: html.design(current), playToken: playToken)
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

private struct HTMLCheckerBackground: View {
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
    var design = HTMLDesign()
    let playToken: Int

    final class Box: UIView, WKNavigationDelegate {
        let web = WKWebView(frame: .zero, configuration: HTMLGraphicsStore.webConfiguration())
        var template: HTMLTemplate?
        var values: [String: String] = [:]
        var design = HTMLDesign()
        var loadedKey = ""
        var playToken = -1
        override init(frame: CGRect) {
            super.init(frame: frame)
            web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
            web.scrollView.isScrollEnabled = false; web.isUserInteractionEnabled = false
            web.scrollView.contentInsetAdjustmentBehavior = .never
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
            guard let t = template, let js = HTMLGraphicsStore.pushJS(t, values: values, design: design) else { return }
            web.evaluateJavaScript(js + (play ? ";window.dtdPlay?dtdPlay():(typeof play==='function'&&play())" : ""))
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { push(play: true) }
    }

    func makeUIView(context: Context) -> Box { Box() }

    func updateUIView(_ v: Box, context: Context) {
        v.template = template
        v.values = values
        v.design = design
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

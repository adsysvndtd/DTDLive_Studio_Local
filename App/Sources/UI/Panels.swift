import PencilKit
import SwiftUI
import UniformTypeIdentifiers

enum PanelTab: String, CaseIterable, Identifiable {
    case titles, audio, source, scopes, auto, replay
    var id: String { rawValue }
    var label: String {
        switch self {
        case .titles: return "Title"
        case .audio: return L("Âm thanh")
        case .source: return L("Nguồn")
        case .scopes: return "Scopes"
        case .auto: return L("Tự động")
        case .replay: return "Replay"
        }
    }
    var icon: String {
        switch self {
        case .titles: return "textformat"
        case .audio: return "slider.vertical.3"
        case .source: return "camera.filters"
        case .scopes: return "waveform.path.ecg"
        case .auto: return "arrow.triangle.2.circlepath"
        case .replay: return "gobackward"
        }
    }
}

struct SidePanel: View {
    @ObservedObject var engine: StudioEngine
    @State private var tab: PanelTab = PanelTab(rawValue: DemoMode.arg("-panel") ?? "") ?? .titles

    var body: some View {
        VStack(spacing: 0) {
            // Icon + label tabs (never icon-only, never wrapping)
            HStack(spacing: 2) {
                ForEach(PanelTab.allCases) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.icon).font(.system(size: 15, weight: .semibold))
                            Text(t.label).font(.system(size: 9.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(tab == t ? DS.accent : DS.text2)
                        .background(tab == t ? DS.surface2 : .clear, in: RoundedRectangle(cornerRadius: DS.radius))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(DS.surface)
            Divider().overlay(DS.stroke)
            ScrollView {
                VStack(spacing: DS.gap) {
                    switch tab {
                    case .titles: TitlesPanel(engine: engine)
                    case .audio: AudioPanel(engine: engine)
                    case .source: SourcePanel(engine: engine)
                    case .scopes: ScopesPanel(engine: engine)
                    case .auto: AutoPanel(auto: engine.autoSwitcher, engine: engine)
                    case .replay: ReplayPanel(engine: engine)
                    }
                }
                .padding(DS.gap)
            }
        }
        .background(DS.bg)
        .clipShape(Rectangle())
        .overlay(Rectangle().stroke(DS.stroke))
    }
}

// MARK: Titles

struct TitlesPanel: View {
    @ObservedObject var engine: StudioEngine
    /// Title open in the editor (the panel's "Thêm" opens a new title here straight away).
    var editing: Binding<UUID?>? = nil
    @State private var ownEditing: UUID?
    @State private var deleting: TitleItem?

    private var editingID: Binding<UUID?> { editing ?? $ownEditing }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(engine.titles.enumerated().filter { $0.offset != engine.scoreboardIndex }.map(\.element)) { item in
                titleRow(item)
            }
        }
        // built-in styles: the form editor in a sheet
        .sheet(item: Binding(get: { editingID.wrappedValue.flatMap { isCustom($0) ? nil : IDBox(id: $0) } },
                             set: { editingID.wrappedValue = $0?.id })) { box in
            if let i = engine.titles.firstIndex(where: { $0.id == box.id }) {
                TitleEditorSheet(item: $engine.titles[i], program: engine.switcher.programMonitor) {
                    editingID.wrappedValue = nil; engine.removeTitle(box.id)
                }
            }
        }
        // custom (multi-layer) titles: the designer, full screen
        .fullScreenCover(item: Binding(get: { editingID.wrappedValue.flatMap { isCustom($0) ? IDBox(id: $0) : nil } },
                                       set: { editingID.wrappedValue = $0?.id })) { box in
            TitleDesignerSheet(item: titleBinding(box.id), program: engine.switcher.programMonitor,
                               programAspect: CGFloat(engine.format.width) / CGFloat(max(engine.format.height, 1))) {
                editingID.wrappedValue = nil; engine.removeTitle(box.id)
            }
        }
        .confirmationDialog(LF("Xoá title “%@”?", deleting.map(preview) ?? ""), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Xoá", role: .destructive) { if let d = deleting { engine.removeTitle(d.id) }; deleting = nil }
        }
    }

    /// One title: name / style · T1 / T2 (which title the Title On keys take on air) · Sửa · FX · ⋯ (nhân bản) · Xoá
    private func titleRow(_ item: TitleItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(item.style)).font(.system(size: 12)).foregroundStyle(DS.accent).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: preview(item)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(verbatim: item.style.label + " · " + (item.fx ?? .fadeSlide).label).font(.system(size: 10)).foregroundStyle(DS.text3).lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.visible { Circle().fill(DS.pgm).frame(width: 7, height: 7) }
            // on air with the Title On / Title 2 On keys (transition column), like before
            assignChip("T1", on: (engine.armedTitleID ?? engine.titles.first?.id) == item.id) { engine.armedTitleID = item.id }
            assignChip("T2", on: engine.secondTitle?.id == item.id) { engine.armedTitle2ID = item.id }
            rowButton("pencil", "Sửa") { editingID.wrappedValue = item.id }
            Menu {
                Picker("Hiệu ứng vào / ra", selection: Binding(get: { item.fx ?? .fadeSlide }, set: { v in
                    var t = item; t.fx = v; engine.upsertTitle(t) })) {
                    ForEach(TitleFX.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                }
                Picker("Thời gian", selection: Binding(get: { item.fxDuration ?? 0.35 }, set: { v in
                    var t = item; t.fxDuration = v; engine.upsertTitle(t) })) {
                    ForEach([0.2, 0.35, 0.6, 1.0, 1.5], id: \.self) { Text(verbatim: String(format: "%.2g s", $0)).tag($0) }
                }
            } label: { rowLabel("sparkles", "FX") }
            Menu {
                Button {
                    var t = item; t.id = UUID(); t.visible = false; engine.upsertTitle(t)
                } label: { Label("Nhân bản", systemImage: "plus.square.on.square") }
            } label: { rowLabel("ellipsis", "Thêm thao tác") }
            rowButton("trash", "Xoá", tint: DS.pgm) { deleting = item }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radius))
        .overlay(RoundedRectangle(cornerRadius: DS.radius).stroke(item.visible ? DS.pgm : DS.stroke, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editingID.wrappedValue = item.id }
    }

    private func assignChip(_ t: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: t).font(.system(size: 10, weight: .bold)).frame(width: 26, height: 26)
                .foregroundStyle(on ? .black : DS.text2)
                .background(on ? Color.white : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
    }

    private func rowButton(_ icon: String, _ label: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(icon, label, tint: tint) }.buttonStyle(.plain)
    }

    private func rowLabel(_ icon: String, _ label: String, tint: Color = .white) -> some View {
        Image(systemName: icon).font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 26)
            .foregroundStyle(tint).background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
            .accessibilityLabel(Text(LocalizedStringKey(label)))
    }

    private func isCustom(_ id: UUID) -> Bool { engine.titles.first { $0.id == id }?.style == .custom }

    /// Binding by id (not by index): safe if the list changes or the title is deleted while it is open.
    private func titleBinding(_ id: UUID) -> Binding<TitleItem> {
        Binding(get: { engine.titles.first { $0.id == id } ?? TitleItem(style: .custom) },
                set: { nv in
                    guard let i = engine.titles.firstIndex(where: { $0.id == id }) else { return }
                    // the designer never changes on-air state: keep the live value (Title On / remote may change it meanwhile)
                    var v = nv; v.visible = engine.titles[i].visible
                    if engine.titles[i] != v { engine.titles[i] = v }
                })
    }

    private func preview(_ t: TitleItem) -> String {
        if t.style == .custom {
            let txt = (t.layers ?? []).first { $0.kind == .text && !$0.text.isEmpty }?.text
            return txt ?? L("Thiết kế nhiều lớp")
        }
        if t.style == .clock { return "00:00:00" }
        if t.style == .countdown { return "\(t.line1) \(t.scoreA):" + String(format: "%02d", t.scoreB) }
        return t.line2.isEmpty ? t.line1 : "\(t.line1) · \(t.line2)"
    }

    private func icon(_ s: TitleStyle) -> String {
        switch s {
        case .ticker: return "text.alignleft"
        case .clock: return "clock"
        case .countdown: return "timer"
        case .logoStrap: return "person.text.rectangle"
        case .fullScreen: return "rectangle.inset.filled"
        default: return "text.below.photo"
        }
    }

}

private struct IDBox: Identifiable { let id: UUID }

/// N-Title: use an NDI source that carries an alpha channel (a CG machine, vMix, OBS… on the LAN)
/// as a title layer over Program. Picked here, faded on / off with its own key.
struct NTitlePanel: View {
    @ObservedObject var engine: StudioEngine
    @State private var searching = false
    @State private var found: [String] = []
    @State private var picking = false

    var body: some View {
        SectionCard("N-Title (NDI có alpha)", systemImage: "square.stack.3d.up") {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(engine.nTitleName != nil ? DS.accent : DS.text3)
                Text(verbatim: engine.nTitleName ?? L("Chưa chọn nguồn NDI")).font(DS.fBody).lineLimit(1)
                Spacer()
                Button { picking = true; searching = true; Task { found = await engine.findNDISources(); searching = false } } label: {
                    Label("Chọn nguồn", systemImage: "magnifyingglass").font(.system(size: 12))
                }
                if engine.nTitleName != nil {
                    Button { engine.setNTitleVisible(false); engine.setNTitleSource(nil) } label: {
                        Image(systemName: "xmark.circle").font(.system(size: 14)).foregroundStyle(DS.text3)
                    }.buttonStyle(.plain)
                }
            }
            Button { engine.toggleNTitle() } label: {
                Text(engine.nTitleVisible ? "N-Title đang trên PGM — bấm để hạ" : "Đưa N-Title lên PGM")
                    .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 36)
                    .background(engine.nTitleVisible ? DS.pgm : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                    .foregroundStyle(engine.nTitleVisible ? .black : .white)
            }
            .buttonStyle(.plain).disabled(engine.nTitleName == nil)
            Text("Nguồn NDI phải có kênh alpha (nền trong suốt). Phần trong suốt cho thấy Program, phần có hình là lớp chữ.")
                .font(.caption2).foregroundStyle(DS.text3)
        }
        .sheet(isPresented: $picking) {
            NavigationStack {
                List {
                    if searching { HStack { ProgressView().controlSize(.small); Text("Đang tìm nguồn NDI…") } }
                    ForEach(found, id: \.self) { n in
                        Button { engine.setNTitleSource(n); picking = false } label: {
                            HStack { Text(verbatim: n); Spacer(); if engine.nTitleName == n { Image(systemName: "checkmark") } }
                        }
                    }
                    if !searching && found.isEmpty { Text("Không thấy nguồn NDI nào trên mạng").foregroundStyle(DS.text3) }
                }
                .navigationTitle("Nguồn NDI cho N-Title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Đóng") { picking = false } }
                    ToolbarItem(placement: .primaryAction) {
                        Button { searching = true; Task { found = await engine.findNDISources(); searching = false } } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

/// Full editor for one title / lower third.
struct TitleEditorSheet: View {
    @Binding var item: TitleItem
    var program: FrameStore?
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // Live preview on top of the current Program picture: see position / size while adjusting
                Section {
                    let movable = item.style != .ticker && item.style != .fullScreen
                    TitlePreview(item: item, program: program,
                                 position: movable ? $item.position : nil, scale: $item.scale)
                        .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
                    Text(LocalizedStringKey(movable ? "Kéo title trên khung để đặt vị trí · chụm 2 ngón để đổi cỡ" : "Chụm 2 ngón trên khung để đổi cỡ"))
                        .font(.caption2).foregroundStyle(DS.text3)
                }
                Section {
                    Picker("Kiểu", selection: $item.style) {
                        ForEach(TitleStyle.allCases.filter { $0 != .scoreBug && $0 != .custom }) { Text($0.label).tag($0) }
                    }
                    if item.style != .clock {
                        TextField(LocalizedStringKey(item.style == .ticker ? "Nội dung chữ chạy" : item.style == .countdown ? "Nhãn" : "Dòng 1"), text: $item.line1)
                    }
                    if item.style == .logoStrap {
                        TextField("Tiêu đề trên (tổ chức / chương trình)", text: Binding(get: { item.header ?? "" }, set: { item.header = $0 }))
                    }
                    if [.lowerThird, .nameStrap, .fullScreen, .logoStrap].contains(item.style) {
                        TextField(item.style == .logoStrap ? "Chức danh" : "Dòng 2", text: $item.line2)
                    }
                    if item.style == .logoStrap { logoPicker }
                    if item.style == .countdown {
                        Stepper("Phút \(item.scoreA)", value: $item.scoreA, in: 0...180).monospacedDigit()
                        Stepper("Giây \(item.scoreB)", value: $item.scoreB, in: 0...59).monospacedDigit()
                    }
                }
                Section(header: Text("Vị trí & cỡ")) {
                    if item.style != .ticker && item.style != .fullScreen {
                        compactSlider("Ngang", Binding(get: { Double(item.position.x) }, set: { item.position.x = $0 }), 0...0.9) { "\(Int($0 * 100))%" }
                        compactSlider("Dọc", Binding(get: { Double(item.position.y) }, set: { item.position.y = $0 }), 0...0.95) { "\(Int($0 * 100))%" }
                    }
                    compactSlider("Cỡ chữ", Binding(get: { Double(item.scale) }, set: { item.scale = $0 }), 0.5...2) { String(format: "%.1f×", $0) }
                    if item.style == .ticker {
                        compactSlider("Tốc độ chạy", Binding(get: { Double(item.tickerSpeed) }, set: { item.tickerSpeed = $0 }), 40...400) { "\(Int($0))" }
                    } else {
                        // 0 = fit the text
                        compactSlider("Rộng", Binding(get: { Double(item.boxWidth ?? 0) }, set: { item.boxWidth = $0 < 20 ? nil : CGFloat($0.rounded()) }),
                                      0...1900) { $0 < 20 ? L("Tự động") : "\(Int($0))" }
                        compactSlider("Cao", Binding(get: { Double(item.boxHeight ?? 0) }, set: { item.boxHeight = $0 < 10 ? nil : CGFloat($0.rounded()) }),
                                      0...700) { $0 < 10 ? L("Tự động") : "\(Int($0))" }
                    }
                }
                Section(header: Text("Màu")) {
                    colorRow("Màu nhấn", Binding(get: { item.accentHex }, set: { item.accentHex = $0 ?? item.accentHex }), fallback: item.accentHex)
                    colorRow(item.style == .countdown ? "Chữ số giờ" : "Chữ dòng 1", $item.text1Hex, fallback: "#FFFFFF")
                    if [.lowerThird, .nameStrap, .fullScreen, .logoStrap, .countdown].contains(item.style) {
                        colorRow(item.style == .countdown ? "Chữ nhãn" : "Chữ dòng 2", $item.text2Hex, fallback: item.style == .logoStrap ? "#D9D9D9" : "#FFFFFF")
                    }
                    colorRow(item.style == .ticker ? "Nền thanh chạy" : "Nền dòng 1", $item.bg1Hex, fallback: "#141414")
                    if [.lowerThird, .nameStrap, .fullScreen, .logoStrap].contains(item.style) {
                        colorRow("Nền dòng 2", $item.bg2Hex, fallback: item.style == .nameStrap ? item.accentHex : "#333333")
                    }
                    compactSlider("Độ đậm nền", Binding(get: { Double(item.bgOpacity ?? 0.9) }, set: { item.bgOpacity = CGFloat($0) }), 0...1) { "\(Int($0 * 100))%" }
                    Button("Về màu mặc định của kiểu") {
                        item.text1Hex = nil; item.text2Hex = nil; item.bg1Hex = nil; item.bg2Hex = nil; item.bgOpacity = nil
                    }
                    .font(.system(size: 13))
                }
                Section {
                    Button("Xoá title", role: .destructive) { onDelete(); dismiss() }
                }
            }
            .environment(\.defaultMinListRowHeight, 32)
            .navigationTitle(item.style.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }
        .presentationDetents([.large, .medium])
    }

    /// Logos from the Logo library as tappable tiles (plus "none").
    private var logoPicker: some View {
        let files = (try? FileManager.default.contentsOfDirectory(at: MediaLibrary.directory(.logo), includingPropertiesForKeys: nil))?
            .filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { item.logoFile = nil } label: {
                    Text("Không").font(.system(size: 11, weight: .semibold)).frame(width: 56, height: 44)
                        .foregroundStyle(item.logoFile == nil ? .black : .white)
                        .background(item.logoFile == nil ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                }.buttonStyle(.plain)
                ForEach(files, id: \.self) { u in
                    let on = item.logoFile == u.lastPathComponent
                    Button { item.logoFile = u.lastPathComponent } label: {
                        Group {
                            if let img = UIImage(contentsOfFile: u.path) { Image(uiImage: img).resizable().scaledToFit().padding(4) }
                            else { Image(systemName: "photo") }
                        }
                        .frame(width: 56, height: 44).background(Color.white, in: RoundedRectangle(cornerRadius: DS.radius))
                        .overlay(RoundedRectangle(cornerRadius: DS.radius).stroke(on ? DS.accent : .clear, lineWidth: 3))
                    }.buttonStyle(.plain)
                }
                if files.isEmpty { Text("Nhập logo ở mục Logo").font(.system(size: 12)).foregroundStyle(DS.text3) }
            }
        }
    }

    /// Colour row; a nil value means the style's own colour (shown as `fallback`, with a reset button once changed).
    private func colorRow(_ title: String, _ hex: Binding<String?>, fallback: String) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title)).font(.system(size: 13)).foregroundStyle(DS.text2)
            Spacer()
            if hex.wrappedValue != nil, title != "Màu nhấn" {
                Button { hex.wrappedValue = nil } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 11)) }
                    .buttonStyle(.borderless)
            }
            ColorPicker("", selection: Binding(get: { Color(UIColor(hex: hex.wrappedValue ?? fallback)) },
                                               set: { hex.wrappedValue = UIColor($0).hexString }), supportsOpacity: false)
                .labelsHidden()
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
        .frame(height: 32)
    }

    /// One-line slider row: label · slider · value (instead of a two-line block).
    private func compactSlider(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>,
                               _ fmt: @escaping (Double) -> String) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title)).font(.system(size: 13)).foregroundStyle(DS.text2).frame(width: 78, alignment: .leading)
            Slider(value: v, in: r).tint(DS.accent).controlSize(.small)
            Text(verbatim: fmt(v.wrappedValue)).font(.system(size: 12).monospacedDigit()).foregroundStyle(DS.text3).frame(width: 40, alignment: .trailing)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
        .frame(height: 30)
    }
}

/// 16:9 preview of one title over the live Program, laid out exactly like the renderer
/// (top-left at position · frame size, text scaled by height/1080 · scale; ticker at the bottom, full-screen centred).
struct TitlePreview: View {
    let item: TitleItem
    var program: FrameStore?
    /// When set, the title can be dragged on the preview (position) and pinched (size).
    var position: Binding<CGPoint>? = nil
    var scale: Binding<CGFloat>? = nil
    @State private var dragStart: CGPoint?
    @State private var scaleStart: CGFloat?

    var body: some View {
        GeometryReader { g in
            let W = g.size.width, H = g.size.height
            let img = TitleRenderer.draw(item, k: H / 1080 * item.scale,
                                         remaining: item.style == .countdown ? item.scoreA * 60 + item.scoreB : nil)
            ZStack(alignment: .topLeading) {
                if let program { MonitorView(store: program, maxFPS: 10) } else { Color.black }
                // safe-area guides (90 % title safe)
                Rectangle().stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: W * 0.9, height: H * 0.9).offset(x: W * 0.05, y: H * 0.05)
                switch item.style {
                case .ticker:
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.75)
                        Image(uiImage: img).resizable().frame(width: img.size.width, height: img.size.height).padding(.leading, W * 0.1)
                    }
                    .frame(width: W, height: img.size.height).clipped()
                    .offset(y: H - img.size.height - 0.04 * H)
                case .fullScreen:
                    Image(uiImage: img).resizable().frame(width: img.size.width, height: img.size.height)
                        .offset(x: (W - img.size.width) / 2, y: (H - img.size.height) / 2)
                case .custom:
                    Image(uiImage: img).resizable().frame(width: W, height: H)   // full-frame design
                default:
                    Image(uiImage: img).resizable().frame(width: img.size.width, height: img.size.height)
                        .offset(x: item.position.x * W, y: item.position.y * H)
                }
            }
            .frame(width: W, height: H).clipped()
            .contentShape(Rectangle())
            .gesture(moveGesture(W: W, H: H), including: position == nil ? .none : .all)
            .simultaneousGesture(pinchGesture, including: scale == nil ? .none : .all)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(Rectangle().stroke(DS.stroke))
    }

    private func moveGesture(W: CGFloat, H: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                guard let position else { return }
                if dragStart == nil { dragStart = position.wrappedValue }
                guard let p = dragStart, W > 0, H > 0 else { return }
                let x = min(max(p.x + v.translation.width / W, 0), 0.95)
                let y = min(max(p.y + v.translation.height / H, 0), 0.95)
                position.wrappedValue = CGPoint(x: (x * 200).rounded() / 200, y: (y * 200).rounded() / 200)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                guard let scale else { return }
                if scaleStart == nil { scaleStart = scale.wrappedValue }
                let k = (scaleStart ?? 1) * v.magnification
                scale.wrappedValue = min(max((k * 20).rounded() / 20, 0.5), 2)
            }
            .onEnded { _ in scaleStart = nil }
    }
}

extension UIColor {
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: Audio mixer

struct AudioPanel: View {
    @ObservedObject var engine: StudioEngine
    @State private var pickMusic = false
    @State private var pickEffect = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            SectionCard("Kênh âm thanh", systemImage: "slider.horizontal.3") {
                if engine.audioChannels.isEmpty {
                    Text("Chưa có kênh nào").font(DS.fBody).foregroundStyle(DS.text3)
                }
                ForEach(engine.audioChannels) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(c.name).font(DS.fBodyBold).lineLimit(1)
                            Spacer()
                            chip("AFV", on: c.followVideo) { var n = c; n.followVideo.toggle(); engine.updateAudioChannel(n) }
                            chip(c.muted ? "TẮT" : "BẬT", on: !c.muted, onColor: DS.pvw) { var n = c; n.muted.toggle(); engine.updateAudioChannel(n) }
                        }
                        LabeledSlider(title: "Âm lượng", value: Binding(get: { Double(c.gain) }, set: { var n = c; n.gain = Float($0); engine.updateAudioChannel(n) }),
                                      range: 0...2) { String(format: "%+.0f dB", 20 * log10(max($0, 0.001))) }
                        LiveLevel(meters: engine.meters, id: c.id) { LevelMeter(db: $0) }.frame(height: 6)
                    }
                    .padding(.vertical, 4)
                    if c.id != engine.audioChannels.last?.id { Divider().overlay(DS.stroke) }
                }
            }
            SectionCard("Nhạc nền & hiệu ứng", systemImage: "music.note") {
                HStack {
                    Button { pickMusic = true } label: { Label("Nhạc nền", systemImage: "music.note.list") }
                    Button { engine.stopMusic() } label: { Label("Dừng", systemImage: "stop.fill") }
                    Button { pickEffect = true } label: { Label("Hiệu ứng", systemImage: "sparkles") }
                }
                .buttonStyle(.bordered).font(DS.fBody)
            }
        }
        .fileImporter(isPresented: $pickMusic, allowedContentTypes: [.audio]) { r in
            if case .success(let u) = r, u.startAccessingSecurityScopedResource() { engine.playMusic(u) }
        }
        .fileImporter(isPresented: $pickEffect, allowedContentTypes: [.audio]) { r in
            if case .success(let u) = r, u.startAccessingSecurityScopedResource() { engine.playEffect(u) }
        }
    }

    private func chip(_ text: String, on: Bool, onColor: Color = DS.accent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(text)).font(.caption2.weight(.heavy))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(on ? .black : DS.text2)
                .background(on ? onColor : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Per-source: color, LUT, chroma key, geometry, PTZ

struct SourcePanel: View {
    @ObservedObject var engine: StudioEngine
    var fixedSource: UUID? = nil
    @State private var selected: UUID?
    @State private var importLUT = false
    @AppStorage("ui.adjustTab") private var tabRaw = AdjustTab.color.rawValue

    /// One group of settings at a time instead of a long column of cards.
    enum AdjustTab: String, CaseIterable, Identifiable {
        case color, key, geometry, camera, ptz
        var id: String { rawValue }
        var label: String {
            switch self {
            case .color: return L("Màu sắc")
            case .key: return "Key"
            case .geometry: return L("Hình học")
            case .camera: return "Camera"
            case .ptz: return "PTZ"
            }
        }
        var icon: String {
            switch self {
            case .color: return "camera.filters"
            case .key: return "person.crop.rectangle"
            case .geometry: return "crop.rotate"
            case .camera: return "camera.aperture"
            case .ptz: return "move.3d"
            }
        }
    }

    var body: some View {
        let id = fixedSource ?? selected ?? engine.previewID
        VStack(alignment: .leading, spacing: 8) {
            if fixedSource == nil { sourceStrip(current: id) }
            if let id {
                let cam = engine.sources.first(where: { $0.id == id }) as? CameraSource
                let tabs = AdjustTab.allCases.filter { $0 != .camera || cam != nil }
                let tab = tabs.first { $0.rawValue == tabRaw } ?? .color
                // preview beside the controls (stacked when the panel is narrow)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        preview(id).frame(width: 240)
                        controls(id, tab: tab, tabs: tabs, cam: cam).frame(minWidth: 340, maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        preview(id).frame(maxWidth: 320)
                        controls(id, tab: tab, tabs: tabs, cam: cam)
                    }
                }
            } else {
                Text("Chọn một nguồn ở hàng PREVIEW để chỉnh").font(DS.fBody).foregroundStyle(DS.text3)
            }
        }
        .fileImporter(isPresented: $importLUT, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]) { r in
            guard case .success(let u) = r, u.startAccessingSecurityScopedResource() else { return }
            try? FileManager.default.copyItem(at: u, to: ProcessingRenderer.lutDirectory.appendingPathComponent(u.lastPathComponent))
        }
    }

    /// Inputs as chips (tally colours); tap one to adjust it.
    private func sourceStrip(current: UUID?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(engine.sources, id: \.id) { s in
                    let on = s.id == current
                    let tally: Color = engine.programID == s.id ? DS.pgm : engine.previewID == s.id ? DS.pvw : .clear
                    Button { selected = s.id } label: {
                        HStack(spacing: 5) {
                            Circle().fill(tally == .clear ? DS.text3.opacity(0.4) : tally).frame(width: 7, height: 7)
                            Text(verbatim: s.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        }
                        .padding(.horizontal, 10).frame(height: 28)
                        .foregroundStyle(on ? .black : .white)
                        .background(on ? Color.white : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                        .overlay(RoundedRectangle(cornerRadius: DS.radius).stroke(tally == .clear ? DS.stroke : tally, lineWidth: tally == .clear ? 1 : 2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Processed picture: PVW / PGM monitor when the input is there, otherwise the input itself.
    private func preview(_ id: UUID) -> some View {
        let store = id == engine.previewID ? engine.switcher.previewMonitor
            : id == engine.programID ? engine.switcher.programMonitor
            : engine.sources.first { $0.id == id }?.frames
        return ZStack {
            Color.black
            if let store { MonitorView(store: store, maxFPS: 15) }
        }
        .aspectRatio(CGFloat(engine.format.width) / CGFloat(max(engine.format.height, 1)), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: DS.radius))
        .overlay(alignment: .topLeading) {
            let label = id == engine.programID ? "PGM" : id == engine.previewID ? "PVW" : L("Nguồn")
            Text(verbatim: label).font(.system(size: 10, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2)
                .background(id == engine.programID ? DS.pgm : id == engine.previewID ? DS.pvw : Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                .padding(4)
        }
    }

    @ViewBuilder private func controls(_ id: UUID, tab: AdjustTab, tabs: [AdjustTab], cam: CameraSource?) -> some View {
        let p = engine.processingFor(id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(tabs) { t in
                    Button { tabRaw = t.rawValue } label: {
                        Label(t.label, systemImage: t.icon).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            .padding(.horizontal, 8).frame(height: 28)
                            .foregroundStyle(t == tab ? .black : DS.text2)
                            .background(t == tab ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if tab == .color || tab == .geometry || tab == .key {
                    Button("Đặt lại") {
                        var n = p
                        switch tab {
                        case .color: let d = SourceProcessing(); n.exposure = d.exposure; n.contrast = d.contrast; n.saturation = d.saturation
                            n.temperature = d.temperature; n.tint = d.tint; n.lutName = nil
                        case .key: n.chromaEnabled = false
                        default: n.mirror = false; n.rotate180 = false; n.quarterTurns = nil
                        }
                        engine.setProcessing(id, n)
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
            }
            switch tab {
            case .color:
                slider(id, "Phơi sáng", Double(p.exposure), -2...2, { String(format: "%+.1f EV", $0) }) { var n = p; n.exposure = Float($0); return n }
                slider(id, "Tương phản", Double(p.contrast), 0.5...1.5, { String(format: "%.2f", $0) }) { var n = p; n.contrast = Float($0); return n }
                slider(id, "Bão hoà", Double(p.saturation), 0...2, { String(format: "%.2f", $0) }) { var n = p; n.saturation = Float($0); return n }
                slider(id, "Nhiệt độ màu", Double(p.temperature), 3000...10000, { "\(Int($0)) K" }) { var n = p; n.temperature = Float($0); return n }
                slider(id, "Tint", Double(p.tint), -100...100, { "\(Int($0))" }) { var n = p; n.tint = Float($0); return n }
                HStack {
                    Text("LUT").font(DS.fBody).foregroundStyle(DS.text2).frame(width: 96, alignment: .leading)
                    Picker("LUT", selection: Binding(get: { p.lutName }, set: { var n = p; n.lutName = $0; engine.setProcessing(id, n) })) {
                        Text("Không").tag(String?.none)
                        ForEach(ProcessingRenderer.availableLUTs(), id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                    Button("Nạp .cube") { importLUT = true }.font(DS.fBody)
                }
            case .key:
                Toggle("Chroma key", isOn: Binding(get: { p.chromaEnabled }, set: { var n = p; n.chromaEnabled = $0; engine.setProcessing(id, n) }))
                    .font(DS.fBodyBold)
                if p.chromaEnabled {
                    Picker("Màu nền", selection: Binding(get: { p.keyHue }, set: { var n = p; n.keyHue = $0; engine.setProcessing(id, n) })) {
                        Text("Xanh lá").tag(Float(120)); Text("Xanh dương").tag(Float(240))
                    }.pickerStyle(.segmented)
                    slider(id, "Dung sai", Double(p.keyTolerance), 5...80, { "\(Int($0))°" }) { var n = p; n.keyTolerance = Float($0); return n }
                    slider(id, "Mềm biên", Double(p.keySoftness), 0...40, { "\(Int($0))°" }) { var n = p; n.keySoftness = Float($0); return n }
                    KeyBackgroundRow(engine: engine, id: id, p: p)
                } else {
                    Text("Bật để xoá phông xanh lá / xanh dương").font(DS.fBody).foregroundStyle(DS.text3)
                }
            case .geometry:
                Toggle("Lật gương", isOn: Binding(get: { p.mirror }, set: { var n = p; n.mirror = $0; engine.setProcessing(id, n) })).font(DS.fBody)
                Picker("Xoay", selection: Binding(get: { p.turns }, set: { var n = p; n.rotate180 = false; n.quarterTurns = $0 == 0 ? nil : $0; engine.setProcessing(id, n) })) {
                    Text(verbatim: "0°").tag(0); Text(verbatim: "90°").tag(1); Text(verbatim: "180°").tag(2); Text(verbatim: "270°").tag(3)
                }
                .pickerStyle(.segmented)
            case .camera:
                if let cam { CameraControlRows(camera: cam).id(cam.id) }
            case .ptz:
                PTZPanel(engine: engine, sourceID: id)
            }
        }
    }

    /// One-line slider row: label · slider · value.
    private func slider(_ id: UUID, _ title: String, _ v: Double, _ range: ClosedRange<Double>,
                        _ fmt: @escaping (Double) -> String, _ make: @escaping (Double) -> SourceProcessing) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title)).font(.system(size: 13)).foregroundStyle(DS.text2).frame(width: 96, alignment: .leading)
            Slider(value: Binding(get: { v }, set: { engine.setProcessing(id, make($0), undoable: false) }), in: range)
                .tint(DS.accent).controlSize(.small)
            Text(verbatim: fmt(v)).font(.system(size: 12).monospacedDigit()).foregroundStyle(DS.text3).frame(width: 64, alignment: .trailing)
        }
        .frame(height: 30)
    }
}

struct PTZPanel: View {
    @ObservedObject var engine: StudioEngine
    let sourceID: UUID
    @State private var host = ""
    @State private var transport: PTZConfig.Transport = .viscaUDP

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if engine.ptz[sourceID] != nil {
                Text("VISCA over IP").font(DS.fBody).foregroundStyle(DS.text3)
                controls(ndi: false)
                Button("Ngắt PTZ", role: .destructive) { engine.setPTZ(sourceID, nil) }.font(DS.fBody)
            } else if engine.isNDISource(sourceID) {
                // PTZ support is reported by the camera once connected: re-check every second.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if engine.ndiPTZSupported(sourceID) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("PTZ qua NDI®", systemImage: "dot.radiowaves.left.and.right")
                                .font(DS.fBodyBold).foregroundStyle(DS.accent)
                            controls(ndi: true)
                        }
                    } else {
                        Text("Camera NDI chưa báo hỗ trợ PTZ (đang kết nối, hoặc camera không có PTZ qua NDI). Có thể điều khiển bằng VISCA ở dưới.")
                            .font(.system(size: 12)).foregroundStyle(DS.text3)
                    }
                }
                DisclosureGroup("Điều khiển bằng VISCA (IP)") { viscaForm }.font(DS.fBody)
            } else {
                Text("VISCA over IP").font(DS.fBody).foregroundStyle(DS.text3)
                viscaForm
            }
        }
    }

    private var viscaForm: some View {
        HStack {
            TextField("IP camera", text: $host).textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
            Picker("", selection: $transport) { Text("UDP 52381").tag(PTZConfig.Transport.viscaUDP); Text("TCP 5678").tag(PTZConfig.Transport.viscaTCP) }
            Button("Kết nối") {
                engine.setPTZ(sourceID, PTZConfig(host: host, port: transport == .viscaUDP ? 52381 : 5678, transport: transport))
            }
            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder private func controls(ndi: Bool) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Joystick { x, y in engine.ptzMove(sourceID, pan: x, tilt: y, zoom: 0) }
                .frame(width: 110, height: 110)
            VStack(spacing: 6) {
                holdButton("plus.magnifyingglass") { engine.ptzMove(sourceID, pan: 0, tilt: 0, zoom: $0 ? 0.6 : 0) }
                holdButton("minus.magnifyingglass") { engine.ptzMove(sourceID, pan: 0, tilt: 0, zoom: $0 ? -0.6 : 0) }
            }
            if ndi {
                VStack(spacing: 6) {
                    holdButton("camera.macro") { engine.ptzFocus(sourceID, speed: $0 ? -0.5 : 0) }
                    holdButton("mountain.2") { engine.ptzFocus(sourceID, speed: $0 ? 0.5 : 0) }
                    Button("AF") { engine.ptzFocus(sourceID, speed: nil) }.buttonStyle(.bordered).font(.system(size: 12, weight: .bold))
                }
            }
        }
        Text("Preset: chạm = gọi, giữ = lưu").font(.caption2)
        HStack {
            ForEach(1...8, id: \.self) { n in
                Text(verbatim: "\(n)").frame(width: 34, height: 30).background(Color(white: 0.2), in: Rectangle())
                    .onTapGesture { engine.ptzPreset(sourceID, n, store: false) }
                    .onLongPressGesture { engine.ptzPreset(sourceID, n, store: true) }
            }
        }
    }

    /// Button that acts while held (true on press, false on release).
    private func holdButton(_ icon: String, _ action: @escaping (Bool) -> Void) -> some View {
        Button { } label: { Image(systemName: icon).frame(width: 22, height: 18) }
            .buttonStyle(.bordered)
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in action(true) }
                .onEnded { _ in action(false) })
    }
}

struct Joystick: View {
    var onChange: (Double, Double) -> Void
    @State private var offset: CGSize = .zero

    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2
            ZStack {
                Circle().fill(Color(white: 0.15))
                Circle().fill(Color.accentColor).frame(width: r * 0.6, height: r * 0.6).offset(offset)
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    var d = CGSize(width: v.location.x - r, height: v.location.y - r)
                    let len = hypot(d.width, d.height)
                    if len > r { d = CGSize(width: d.width / len * r, height: d.height / len * r) }
                    offset = d
                    onChange(Double(d.width / r), Double(-d.height / r))
                }
                .onEnded { _ in offset = .zero; onChange(0, 0) })
        }
    }
}

// MARK: Scopes

struct ScopesPanel: View {
    @ObservedObject var engine: StudioEngine
    var body: some View {
        SectionCard("Scopes (Program)", systemImage: "waveform.path.ecg") {
            Toggle("Bật scopes (Program)", isOn: $engine.scopesEnabled)
            Picker("", selection: $engine.scopeKind) { ForEach(ScopeKind.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented)
            if engine.scopesEnabled {
                LiveScope(meters: engine.meters, kind: engine.scopeKind).frame(height: 200)
            }
        }
    }
}

// MARK: Auto switching

struct AutoPanel: View {
    @ObservedObject var auto: AutoSwitcher
    @ObservedObject var engine: StudioEngine
    var body: some View {
        SectionCard("Tự động chuyển cảnh", systemImage: "arrow.triangle.2.circlepath") {
            Toggle("Tự động chuyển cảnh", isOn: $auto.enabled)
            Picker("Chế độ", selection: $auto.mode) { ForEach(AutoSwitcher.Mode.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented)
            if auto.mode != .audio {
                Stepper("Mỗi \(Int(auto.interval)) giây", value: $auto.interval, in: 2...120)
            }
            Text("Nguồn tham gia").font(DS.fBodyBold)
            ForEach(engine.sources, id: \.id) { s in
                Toggle(s.name, isOn: Binding(
                    get: { auto.inputs.contains(s.id) },
                    set: { on in if on { auto.inputs.append(s.id) } else { auto.inputs.removeAll { $0 == s.id } } }))
            }
        }
    }
}

// MARK: Replay

struct ReplayPanel: View {
    @ObservedObject var engine: StudioEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Bật bộ đệm replay (60 giây gần nhất)", isOn: $engine.replayArmed)
                .font(DS.fBodyBold)
            Text("Tắt khi không dùng replay để đỡ nóng máy và tiết kiệm pin.").font(DS.fBody).foregroundStyle(DS.text3)
            ReplayEditorView(engine: engine, editor: engine.replayEditor)
        }
    }
}

/// Clip editor: frame preview, thumbnail strip with playhead + in/out, frame stepping,
/// MARK IN / MARK OUT, slow-motion replay to air, clip list with export.
struct ReplayEditorView: View {
    @ObservedObject var engine: StudioEngine
    @ObservedObject var editor: ReplayEditor
    @ObservedObject var library: MediaLibrary
    @State private var pickFile = false

    init(engine: StudioEngine, editor: ReplayEditor) {
        self.engine = engine; self.editor = editor; self.library = engine.library
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            // Preview (smaller) + list of recordings to the right
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack {
                        Color.black
                        if let img = editor.preview { Image(uiImage: img).resizable().scaledToFit() }
                        else { Text(editor.duration > 0 ? "Đang giải mã…" : "Chưa có hình").font(DS.fBody).foregroundStyle(DS.text3) }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(Rectangle())
                    .overlay(alignment: .bottomLeading) {
                        Text(timeLabel(editor.playhead)).font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(4).background(.black.opacity(0.65), in: Rectangle()).padding(5)
                    }
                    .overlay(alignment: .topLeading) {
                        Text(verbatim: editor.material.label).font(.system(size: 10, weight: .bold)).lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.65), in: Rectangle()).padding(5)
                    }
                }
                .frame(maxWidth: 420)
                recordingsList
                    .frame(maxWidth: .infinity, maxHeight: 236)
            }

            // Thumbnail strip with in/out and playhead; drag to scrub
            TimelineStrip(editor: editor).frame(height: 50)

            // Transport + marks
            HStack(spacing: 6) {
                transport("backward.end.fill") { editor.scrub(to: editor.markIn ?? 0) }
                // while a replay is on air the arrow keys step the replay on air (VAR), otherwise the editor
                transport("backward.frame.fill") { engine.replayOnAir ? engine.replayStep(-1) : editor.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                transport("forward.frame.fill") { engine.replayOnAir ? engine.replayStep(1) : editor.step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                transport("forward.end.fill") { editor.scrub(to: editor.markOut ?? editor.duration) }
                Spacer(minLength: 8)
                markKey("MARK IN", value: editor.markIn, color: DS.pvw) { editor.setIn() }.keyboardShortcut("i", modifiers: [])
                markKey("MARK OUT", value: editor.markOut, color: DS.pgm) { editor.setOut() }.keyboardShortcut("o", modifiers: [])
                Button { editor.clearMarks() } label: { Image(systemName: "xmark.circle") }.foregroundStyle(DS.text2)
            }

            HStack(spacing: 10) {
                Picker("Tốc độ", selection: $editor.speed) {
                    Text(verbatim: "0.25×").tag(0.25); Text(verbatim: "0.5×").tag(0.5); Text(verbatim: "0.75×").tag(0.75); Text(verbatim: "1×").tag(1.0)
                }
                .pickerStyle(.segmented).frame(maxWidth: 240)
                Toggle("Lặp", isOn: $editor.loop).fixedSize()
                Spacer()
                let r = editor.effectiveRange
                Text(String(format: L("Đoạn %.1f s"), r.upperBound - r.lowerBound)).font(DS.fSmall.monospacedDigit()).foregroundStyle(DS.text2)
            }

            HStack(spacing: 6) {
                // PLAY REPLAY ⇄ STOP: shows the on-air state, stop returns to the previous source
                Button { engine.replayOnAir ? engine.stopReplay() : engine.playEditorRange(toAir: true) } label: {
                    Label(engine.replayOnAir ? "ĐANG REPLAY · DỪNG" : "PHÁT REPLAY",
                          systemImage: engine.replayOnAir ? "stop.fill" : "play.fill")
                        .font(.system(size: 12, weight: .heavy))
                        .padding(.horizontal, 12).frame(height: 30)
                        .foregroundStyle(engine.replayOnAir ? .white : .black)
                        .background(engine.replayOnAir ? DS.pgm : DS.accent, in: RoundedRectangle(cornerRadius: DS.radius))
                }
                .buttonStyle(.plain)
                smallButton("Lên Preview", "rectangle.on.rectangle") { engine.playEditorRange(toAir: false) }
                smallButton("Lưu clip", "plus.rectangle.on.rectangle") { editor.saveClip() }
                Spacer()
            }

            if let m = editor.message { Text(m).font(DS.fBody).foregroundStyle(DS.text2) }

            ReplayVARSection(engine: engine)

            SectionCard("Clip đã lưu", systemImage: "film.stack") {
                if editor.clips.isEmpty { Text("Đặt MARK IN / MARK OUT rồi bấm Lưu clip").font(DS.fBody).foregroundStyle(DS.text3) }
                ForEach(editor.clips) { c in
                    HStack(spacing: 6) {
                        Image(systemName: c.material == .buffer ? "gobackward" : "film").foregroundStyle(DS.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: c.name).font(DS.fBodyBold)
                            Text(verbatim: "\(c.material.label) · \(timeLabel(c.inT)) → \(timeLabel(c.outT)) · \(String(format: "%.1f s", c.duration))")
                                .font(.caption2.monospacedDigit()).foregroundStyle(DS.text3).lineLimit(1)
                        }
                        Spacer()
                        iconKey("play.fill", "Phát lên PGM", tint: DS.accent) { engine.playClip(c) }
                        iconKey("rectangle.on.rectangle", "Lên Preview") { engine.playClip(c, toAir: false) }
                        iconKey("square.and.arrow.down", "Xuất MP4 vào thư viện") { editor.export(c, library: engine.library) }
                        iconKey("trash", "Xoá", tint: DS.pgm) { editor.deleteClip(c) }
                    }
                }
            }
        }
        .onAppear { if editor.duration == 0 && editor.material == .buffer { editor.loadBuffer(engine.replayBuffer) } }
    }

    /// Replay buffer + recorded / imported videos; tap to load into the preview and frame strip.
    private var recordingsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bản ghi").textCase(.uppercase).font(DS.fHeader).foregroundStyle(DS.text2)
            ScrollView {
                VStack(spacing: 3) {
                    recordRow(icon: "dot.radiowaves.left.and.right", title: L("Bộ đệm replay (Program)"),
                              selected: editor.material == .buffer) { editor.loadBuffer(engine.replayBuffer) }
                    ForEach(library.list(.movie), id: \.self) { u in
                        recordRow(icon: "film", title: u.deletingPathExtension().lastPathComponent,
                                  selected: editor.material == .file(u)) { editor.loadFile(u) }
                    }
                }
            }
        }
        .padding(6)
        .background(DS.surface, in: Rectangle())
        .overlay(Rectangle().stroke(DS.stroke))
    }

    private func recordRow(icon: String, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).frame(width: 14)
                Text(verbatim: title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).frame(height: 26)
            .foregroundStyle(selected ? .black : .white)
            .background(selected ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
    }

    private func smallButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(title), systemImage: icon).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 30)
                .foregroundStyle(.white).background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                .overlay(RoundedRectangle(cornerRadius: DS.radius).stroke(DS.stroke))
        }
        .buttonStyle(.plain)
    }

    private func iconKey(_ icon: String, _ help: String, tint: Color = DS.surface2, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 26)
                .foregroundStyle(tint == DS.surface2 ? .white : .black)
                .background(tint, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(help)))
    }

    private func timeLabel(_ t: Double) -> String {
        let f = Int((t - floor(t)) * 30)
        return String(format: "%02d:%02d:%02d", Int(t) / 60, Int(t) % 60, f)
    }

    private func transport(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 30, height: 28)
                .foregroundStyle(.white).background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
    }

    private func markKey(_ title: String, value: Double?, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(LocalizedStringKey(title)).font(.system(size: 11, weight: .heavy))
                Text(value.map(timeLabel) ?? "--:--:--").font(.system(size: 10, design: .monospaced))
            }
            .frame(width: 78, height: 32)
            .foregroundStyle(value != nil ? .black : .white)
            .background(value != nil ? color : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
    }
}

/// Thumbnail strip: in/out region highlighted, playhead line; tap/drag to scrub.
struct TimelineStrip: View {
    @ObservedObject var editor: ReplayEditor

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, d = max(editor.duration, 0.001)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if editor.thumbnails.isEmpty {
                        Rectangle().fill(DS.surface2)
                    } else {
                        ForEach(Array(editor.thumbnails.enumerated()), id: \.offset) { _, img in
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: w / CGFloat(editor.thumbnails.count), height: g.size.height).clipped()
                        }
                    }
                }
                .opacity(0.85)
                if editor.markIn != nil || editor.markOut != nil {
                    let r = editor.effectiveRange
                    Rectangle().fill(DS.accent.opacity(0.28))
                        .overlay(Rectangle().stroke(DS.accent, lineWidth: 2))
                        .frame(width: max(2, w * CGFloat((r.upperBound - r.lowerBound) / d)))
                        .offset(x: w * CGFloat(r.lowerBound / d))
                }
                Rectangle().fill(Color.white).frame(width: 2)
                    .offset(x: w * CGFloat(editor.playhead / d) - 1)
                    .shadow(radius: 2)
            }
            .clipShape(Rectangle())
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                editor.scrub(to: Double(max(0, min(w, v.location.x)) / w) * d)
            })
        }
    }
}


/// Built-in / USB camera controls.
struct CameraControlCard: View {
    let camera: CameraSource
    var body: some View {
        SectionCard("Điều khiển camera", systemImage: "camera.aperture") { CameraControlRows(camera: camera) }
    }
}

struct CameraControlRows: View {
    let camera: CameraSource
    @State private var c = CameraSource.Controls()

    var body: some View {
        Group {
            if c.maxZoom > 1 {
                LabeledSlider(title: "Zoom", value: Binding(get: { c.zoom }, set: { c.zoom = $0; camera.setZoom($0) }),
                              range: 1...c.maxZoom) { String(format: "%.1f×", $0) }
            }
            Toggle("Lấy nét tự động", isOn: Binding(get: { c.autoFocus }, set: { c.autoFocus = $0; camera.setAutoFocus($0) }))
            if !c.autoFocus {
                LabeledSlider(title: "Lấy nét (gần → xa)", value: Binding(get: { Double(c.lensPosition) }, set: { c.lensPosition = Float($0); camera.setLensPosition(Float($0)) }),
                              range: 0...1) { String(format: "%.2f", $0) }
            }
            LabeledSlider(title: "Bù phơi sáng", value: Binding(get: { Double(c.exposureBias) }, set: { c.exposureBias = Float($0); camera.setExposureBias(Float($0)) }),
                          range: Double(c.minBias)...Double(c.maxBias)) { String(format: "%+.1f EV", $0) }
            Toggle("Khoá cân bằng trắng", isOn: Binding(get: { c.whiteBalanceLocked }, set: { c.whiteBalanceLocked = $0; camera.setWhiteBalanceLocked($0) }))
            Toggle("Chống rung", isOn: Binding(get: { c.stabilization }, set: { c.stabilization = $0; camera.setStabilization($0) }))
            if c.hasTorch {
                Toggle("Đèn", isOn: Binding(get: { c.torch }, set: { c.torch = $0; camera.setTorch($0) }))
            }
        }
        .font(DS.fBody)
        .onAppear { camera.refreshControls(); c = camera.controls }
    }
}

/// VAR: where the replay goes on air (whole frame or one window of a PiP layout — it comes down by itself
/// when the replay ends) and frame-accurate control while it is on air.
struct ReplayVARSection: View {
    @ObservedObject var engine: StudioEngine
    @State private var selectedSlot = 0

    var body: some View {
        SectionCard("Khung replay (VAR)", systemImage: "rectangle.inset.topright.filled") {
            Picker("", selection: $engine.replayPlacement.mode) {
                Text("Toàn màn hình").tag(StudioEngine.ReplayPlacement.Mode.full)
                Text("PiP replay").tag(StudioEngine.ReplayPlacement.Mode.pip)
                Text("Theo layout").tag(StudioEngine.ReplayPlacement.Mode.layout)
            }
            .pickerStyle(.segmented)
            .disabled(engine.replayOnAir)
            if engine.replayPlacement.mode == .pip {
                pipSettings
            }
            if engine.replayPlacement.mode == .layout {
                let tpl = LayoutTemplate.all.first { $0.id == engine.replayPlacement.layoutID } ?? LayoutTemplate.all[0]
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Menu {
                            ForEach(LayoutTemplate.all) { t in
                                Button(t.name) {
                                    engine.replayPlacement.layoutID = t.id
                                    engine.replayPlacement.slot = 0
                                    engine.replayPlacement.sourcesBySlot = [:]
                                    selectedSlot = t.slots.count > 1 ? 1 : 0
                                }
                            }
                        } label: {
                            Label(tpl.name, systemImage: "rectangle.split.2x1").font(DS.fBodyBold).lineLimit(1)
                                .padding(.horizontal, 10).frame(height: 30)
                                .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                        }
                        Text("Chọn khung Replay, sau đó chọn source lần lượt cho các khung còn lại. Hết replay, layout trước đó trở lại.")
                            .font(.caption2).foregroundStyle(DS.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    slotPicker(tpl).frame(width: 200)
                }
                .disabled(engine.replayOnAir)
                layoutSourcePickers(tpl).disabled(engine.replayOnAir)
            }
            if engine.replayOnAir { varControls }
        }
    }

    /// Replay PiP: the live picture stays full frame; a PiP column holds the replay (16:9) and below it an
    /// optional second 16:9 window with an input or a picture.
    private var pipSettings: some View {
        let p = engine.replayPlacement
        let usable = engine.sources.filter { $0.id != engine.layoutSource.id && $0.id != engine.replay.id }
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Vị trí", selection: $engine.replayPlacement.corner) {
                    Text("Phải trên").tag(StudioEngine.ReplayPlacement.Corner.topRight)
                    Text("Phải dưới").tag(StudioEngine.ReplayPlacement.Corner.bottomRight)
                    Text("Trái trên").tag(StudioEngine.ReplayPlacement.Corner.topLeft)
                    Text("Trái dưới").tag(StudioEngine.ReplayPlacement.Corner.bottomLeft)
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Cỡ khung PiP").font(DS.fBody)
                    Slider(value: $engine.replayPlacement.pipWidth, in: 0.18...0.48)
                    Text(verbatim: "\(Int(p.pipWidth * 100))%").font(.caption.monospacedDigit()).frame(width: 36)
                }
                HStack(spacing: 8) {
                    Text("Khung dưới replay").font(DS.fBody)
                    Picker("", selection: $engine.replayPlacement.below) {
                        Text("Không").tag(StudioEngine.ReplayPlacement.Below.none)
                        Text("Input").tag(StudioEngine.ReplayPlacement.Below.input)
                        Text("Ảnh").tag(StudioEngine.ReplayPlacement.Below.image)
                    }
                    .pickerStyle(.segmented)
                }
                if p.below == .input {
                    Menu {
                        Button("Nguồn đang ở PVW") { engine.replayPlacement.belowInputID = nil }
                        ForEach(usable, id: \.id) { s in Button(s.name) { engine.replayPlacement.belowInputID = s.id } }
                    } label: {
                        Label(p.belowInputID.flatMap { c in usable.first { $0.id == c }?.name } ?? L("Input: nguồn đang ở PVW"),
                              systemImage: "video").font(DS.fBody).lineLimit(1)
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                    }
                } else if p.below == .image {
                    Menu {
                        ForEach(engine.library.list(.picture), id: \.self) { u in
                            Button(u.deletingPathExtension().lastPathComponent) { engine.replayPlacement.belowPicture = u.lastPathComponent }
                        }
                    } label: {
                        Label(p.belowPicture.map { ($0 as NSString).deletingPathExtension } ?? L("Chọn ảnh trong thư viện"),
                              systemImage: "photo").font(DS.fBody).lineLimit(1)
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                    }
                }
                Text("Hình đang phát vẫn toàn khung; replay hiện trong khung PiP 16:9, bên dưới có thể thêm một input hoặc ảnh 16:9. Hết replay, khung PiP tự hạ.")
                    .font(.caption2).foregroundStyle(DS.text3).fixedSize(horizontal: false, vertical: true)
            }
            pipDiagram(p).frame(width: 200)
        }
    }

    private func pipDiagram(_ p: StudioEngine.ReplayPlacement) -> some View {
        let a = CGFloat(engine.format.width) / CGFloat(max(engine.format.height, 1))
        let rects = p.rects(canvasAspect: a)
        let pic = p.below == .image ? p.belowPicture.flatMap { UIImage(contentsOfFile: MediaLibrary.directory(.picture).appendingPathComponent($0).path) } : nil
        return GeometryReader { g in
            ZStack(alignment: .topLeading) {
                ZStack { Color(white: 0.16); Text("PGM").font(.system(size: 10, weight: .heavy)).foregroundStyle(DS.text3) }
                ForEach(Array(rects.enumerated()).filter { $0.offset > 0 }, id: \.offset) { i, r in
                    ZStack {
                        if i == 2, let pic { Image(uiImage: pic).resizable().scaledToFill() }
                        else { Rectangle().fill(i == 1 ? DS.pgm.opacity(0.85) : DS.pvw.opacity(0.8)) }
                        Text(i == 1 ? "REPLAY" : (p.below == .image ? "ẢNH" : "INPUT")).font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                    }
                    .frame(width: r.width * g.size.width, height: r.height * g.size.height).clipped()
                    .overlay(Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    .offset(x: r.minX * g.size.width, y: r.minY * g.size.height)
                }
            }
        }
        .aspectRatio(a, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func sourceLabel(for slot: Int) -> String {
        if slot == engine.replayPlacement.slot { return "REPLAY" }
        guard let id = engine.replayPlacement.sourcesBySlot[slot] else { return L("Chọn source") }
        return engine.sources.first { $0.id == id }?.name ?? L("Nguồn không còn tồn tại")
    }

    private func layoutSourcePickers(_ template: LayoutTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(template.slots.indices, id: \.self) { i in
                HStack {
                    Text("Khung \(i + 1)").font(DS.fBodyBold)
                    Menu {
                        Button("REPLAY") {
                            engine.replayPlacement.slot = i
                            advanceSlot(after: i, in: template)
                        }
                        if i != engine.replayPlacement.slot {
                            ForEach(engine.sources.filter { $0.id != engine.layoutSource.id && $0.id != engine.replay.id }, id: \.id) { source in
                                Button(source.name) {
                                    engine.replayPlacement.sourcesBySlot[i] = source.id
                                    advanceSlot(after: i, in: template)
                                }
                            }
                        }
                    } label: {
                        Label(sourceLabel(for: i), systemImage: i == engine.replayPlacement.slot ? "backward.end.fill" : "video")
                            .font(DS.fBody).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                    }
                    .accessibilityIdentifier("replay.layout.source.\(i)")
                }
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: DS.radius)
                    .stroke(selectedSlot == i ? DS.pvw : Color.clear, lineWidth: 1))
            }
        }
    }

    private func advanceSlot(after slot: Int, in template: LayoutTemplate) {
        let ordered = Array(template.slots.indices.filter { $0 > slot }) + Array(template.slots.indices.filter { $0 <= slot })
        selectedSlot = ordered.first { $0 != engine.replayPlacement.slot && engine.replayPlacement.sourcesBySlot[$0] == nil }
            ?? ordered.first { $0 != engine.replayPlacement.slot } ?? slot
    }

    /// Mini diagram of the layout; tap a window to put the replay there.
    private func slotPicker(_ t: LayoutTemplate) -> some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(Array(t.slots.enumerated()), id: \.offset) { i, s in
                    let on = engine.replayPlacement.slot == i
                    Button { selectedSlot = i } label: {
                        ZStack {
                            Rectangle().fill(on ? DS.pgm.opacity(0.75) : DS.surface2)
                            Rectangle().stroke(selectedSlot == i ? DS.pvw : (on ? DS.pgm : Color.white.opacity(0.35)), lineWidth: selectedSlot == i || on ? 2 : 1)
                            Text("\(i + 1) · \(sourceLabel(for: i))").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: s.rect.width * g.size.width, height: s.rect.height * g.size.height)
                    .offset(x: s.rect.minX * g.size.width, y: s.rect.minY * g.size.height)
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// On air: hold / play on, step 1 or 5 frames, stop (back to the previous source and layout).
    private var varControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(engine.replayHeld ? "VAR · ĐANG GIỮ HÌNH" : "VAR · ĐANG PHÁT").font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(engine.replayHeld ? .orange : DS.pvw)
                Spacer()
            }
            HStack(spacing: 6) {
                key("backward.end.alt", "−5 khung") { engine.replayStep(-5) }
                key("backward.frame", "−1 khung") { engine.replayStep(-1) }
                Button { engine.replayHoldToggle() } label: {
                    Image(systemName: engine.replayHeld ? "play.fill" : "pause.fill").font(.system(size: 16, weight: .bold))
                        .frame(width: 56, height: 36).foregroundStyle(.black)
                        .background(engine.replayHeld ? DS.pvw : Color.orange, in: RoundedRectangle(cornerRadius: DS.radius))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(engine.replayHeld ? "Phát tiếp" : "Giữ hình"))
                key("forward.frame", "+1 khung") { engine.replayStep(1) }
                key("forward.end.alt", "+5 khung") { engine.replayStep(5) }
                Spacer(minLength: 8)
                Button { engine.stopReplay() } label: {
                    Label("Hạ replay", systemImage: "stop.fill").font(.system(size: 12, weight: .heavy))
                        .padding(.horizontal, 12).frame(height: 36).foregroundStyle(.white)
                        .background(DS.pgm, in: RoundedRectangle(cornerRadius: DS.radius))
                }
                .buttonStyle(.plain)
            }
            Text("Giữ hình rồi bước từng khung để soi tình huống; ‹ › trên bàn phím cũng bước 1 khung.")
                .font(.caption2).foregroundStyle(DS.text3)
        }
        .padding(.top, 4)
    }

    private func key(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .bold)).frame(width: 44, height: 36)
                .foregroundStyle(.white).background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(label)))
    }
}

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
                        .background(tab == t ? DS.surface2 : .clear, in: Rectangle())
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
    @State private var editingID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(engine.titles.enumerated().filter { $0.offset != engine.scoreboardIndex }.map(\.element)) { item in
                titleRow(item)
            }
        }
        .sheet(item: Binding(get: { editingID.map { IDBox(id: $0) } }, set: { editingID = $0?.id })) { box in
            if let i = engine.titles.firstIndex(where: { $0.id == box.id }) {
                TitleEditorSheet(item: $engine.titles[i], program: engine.switcher.programMonitor) {
                    editingID = nil; engine.removeTitle(box.id)
                }
            }
        }
    }

    private func titleRow(_ item: TitleItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(item.style)).font(.system(size: 12)).foregroundStyle(DS.accent).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: preview(item)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(item.style.label).font(.system(size: 10)).foregroundStyle(DS.text3).lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.visible { Circle().fill(DS.pgm).frame(width: 7, height: 7) }
            assignChip("T1", on: (engine.armedTitleID ?? engine.titles.first?.id) == item.id) { engine.armedTitleID = item.id }
            assignChip("T2", on: engine.secondTitle?.id == item.id) { engine.armedTitle2ID = item.id }
            Button { editingID = item.id } label: {
                Image(systemName: "pencil").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 24)
                    .foregroundStyle(.white).background(DS.surface2, in: Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(DS.surface, in: Rectangle())
        .overlay(Rectangle().stroke(item.visible ? DS.pgm : DS.stroke, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editingID = item.id }
    }

    private func preview(_ t: TitleItem) -> String {
        if t.style == .clock { return "00:00:00" }
        if t.style == .countdown { return "\(t.line1) \(t.scoreA):" + String(format: "%02d", t.scoreB) }
        return t.line2.isEmpty ? t.line1 : "\(t.line1) · \(t.line2)"
    }

    private func icon(_ s: TitleStyle) -> String {
        switch s {
        case .ticker: return "text.alignleft"
        case .clock: return "clock"
        case .countdown: return "timer"
        case .fullScreen: return "rectangle.inset.filled"
        default: return "text.below.photo"
        }
    }

    private func assignChip(_ t: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: t).font(.system(size: 10, weight: .bold)).frame(width: 26, height: 24)
                .foregroundStyle(on ? .black : DS.text2)
                .background(on ? Color.white : DS.surface2, in: Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct IDBox: Identifiable { let id: UUID }

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
                    TitlePreview(item: item, program: program)
                        .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
                }
                Section {
                    Picker("Kiểu", selection: $item.style) {
                        ForEach(TitleStyle.allCases.filter { $0 != .scoreBug }) { Text($0.label).tag($0) }
                    }
                    if item.style != .clock {
                        TextField(LocalizedStringKey(item.style == .ticker ? "Nội dung chữ chạy" : item.style == .countdown ? "Nhãn" : "Dòng 1"), text: $item.line1)
                    }
                    if [.lowerThird, .nameStrap, .fullScreen].contains(item.style) {
                        TextField("Dòng 2", text: $item.line2)
                    }
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
                    }
                    ColorPicker("Màu nhấn", selection: Binding(
                        get: { Color(UIColor(hex: item.accentHex)) },
                        set: { item.accentHex = UIColor($0).hexString }), supportsOpacity: false)
                        .font(.system(size: 13))
                        .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
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
                default:
                    Image(uiImage: img).resizable().frame(width: img.size.width, height: img.size.height)
                        .offset(x: item.position.x * W, y: item.position.y * H)
                }
            }
            .frame(width: W, height: H).clipped()
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(Rectangle().stroke(DS.stroke))
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
                        LevelMeter(db: c.level).frame(height: 6)
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
                .background(on ? onColor : DS.surface2, in: Rectangle())
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

    var body: some View {
        let id = fixedSource ?? selected ?? engine.previewID
        VStack(alignment: .leading, spacing: DS.gap) {
            if fixedSource == nil {
            SectionCard("Nguồn đang chỉnh", systemImage: "camera") {
                Picker("Nguồn", selection: Binding(get: { id }, set: { selected = $0 })) {
                    ForEach(engine.sources, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            if let id {
                let p = engine.processingFor(id)
                SectionCard("Màu sắc", systemImage: "camera.filters",
                            trailing: AnyView(Button("Đặt lại") { engine.setProcessing(id, SourceProcessing()) }.font(DS.fBody))) {
                    slider(id, "Phơi sáng", Double(p.exposure), -2...2, { String(format: "%+.1f EV", $0) }) { var n = p; n.exposure = Float($0); return n }
                    slider(id, "Tương phản", Double(p.contrast), 0.5...1.5, { String(format: "%.2f", $0) }) { var n = p; n.contrast = Float($0); return n }
                    slider(id, "Bão hoà", Double(p.saturation), 0...2, { String(format: "%.2f", $0) }) { var n = p; n.saturation = Float($0); return n }
                    slider(id, "Nhiệt độ màu", Double(p.temperature), 3000...10000, { "\(Int($0)) K" }) { var n = p; n.temperature = Float($0); return n }
                    slider(id, "Tint", Double(p.tint), -100...100, { "\(Int($0))" }) { var n = p; n.tint = Float($0); return n }
                    HStack {
                        Text("LUT").font(DS.fBody).foregroundStyle(DS.text2)
                        Picker("LUT", selection: Binding(get: { p.lutName }, set: { var n = p; n.lutName = $0; engine.setProcessing(id, n) })) {
                            Text("Không").tag(String?.none)
                            ForEach(ProcessingRenderer.availableLUTs(), id: \.self) { Text($0).tag(Optional($0)) }
                        }
                        .pickerStyle(.menu)
                        Spacer()
                        Button("Nạp .cube") { importLUT = true }.font(DS.fBody)
                    }
                }
                SectionCard("Chroma key", systemImage: "person.crop.rectangle",
                            trailing: AnyView(Toggle("", isOn: Binding(get: { p.chromaEnabled }, set: { var n = p; n.chromaEnabled = $0; engine.setProcessing(id, n) })).labelsHidden())) {
                    if p.chromaEnabled {
                        Picker("Màu nền", selection: Binding(get: { p.keyHue }, set: { var n = p; n.keyHue = $0; engine.setProcessing(id, n) })) {
                            Text("Xanh lá").tag(Float(120)); Text("Xanh dương").tag(Float(240))
                        }.pickerStyle(.segmented)
                        slider(id, "Dung sai", Double(p.keyTolerance), 5...80, { "\(Int($0))°" }) { var n = p; n.keyTolerance = Float($0); return n }
                        slider(id, "Mềm biên", Double(p.keySoftness), 0...40, { "\(Int($0))°" }) { var n = p; n.keySoftness = Float($0); return n }
                        HStack {
                            Text("Nền thay thế").font(DS.fBody).foregroundStyle(DS.text2)
                            Spacer()
                            Picker("Nền", selection: Binding(get: { p.keyBackgroundID }, set: { var n = p; n.keyBackgroundID = $0; engine.setProcessing(id, n) })) {
                                Text("Trong suốt").tag(UUID?.none)
                                ForEach(engine.sources.filter { $0.id != id }, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                            }
                            .pickerStyle(.menu)
                        }
                    } else {
                        Text("Bật để xoá phông xanh lá / xanh dương").font(DS.fBody).foregroundStyle(DS.text3)
                    }
                }
                SectionCard("Hình học", systemImage: "crop.rotate") {
                    Toggle("Lật gương", isOn: Binding(get: { p.mirror }, set: { var n = p; n.mirror = $0; engine.setProcessing(id, n) }))
                    Toggle("Xoay 180°", isOn: Binding(get: { p.rotate180 }, set: { var n = p; n.rotate180 = $0; engine.setProcessing(id, n) }))
                }
                .font(DS.fBody)
                if let cam = engine.sources.first(where: { $0.id == id }) as? CameraSource {
                    CameraControlCard(camera: cam)
                }
                SectionCard("Điều khiển PTZ", systemImage: "move.3d") {
                    PTZPanel(engine: engine, sourceID: id)
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

    private func slider(_ id: UUID, _ title: String, _ v: Double, _ range: ClosedRange<Double>,
                        _ fmt: @escaping (Double) -> String, _ make: @escaping (Double) -> SourceProcessing) -> some View {
        LabeledSlider(title: title, value: Binding(get: { v }, set: { engine.setProcessing(id, make($0), undoable: false) }),
                      range: range, format: fmt)
    }
}

struct PTZPanel: View {
    @ObservedObject var engine: StudioEngine
    let sourceID: UUID
    @State private var host = ""
    @State private var transport: PTZConfig.Transport = .viscaUDP

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VISCA over IP").font(DS.fBody).foregroundStyle(DS.text3)
            if engine.ptz[sourceID] == nil {
                HStack {
                    TextField("IP camera", text: $host).textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
                    Picker("", selection: $transport) { Text("UDP 52381").tag(PTZConfig.Transport.viscaUDP); Text("TCP 5678").tag(PTZConfig.Transport.viscaTCP) }
                    Button("Kết nối") {
                        engine.setPTZ(sourceID, PTZConfig(host: host, port: transport == .viscaUDP ? 52381 : 5678, transport: transport))
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    Joystick { x, y in engine.ptzMove(sourceID, pan: x, tilt: y, zoom: 0) }
                        .frame(width: 110, height: 110)
                    VStack {
                        Button { } label: { Image(systemName: "plus.magnifyingglass") }
                            .simultaneousGesture(DragGesture(minimumDistance: 0)
                                .onChanged { _ in engine.ptzMove(sourceID, pan: 0, tilt: 0, zoom: 0.6) }
                                .onEnded { _ in engine.ptzMove(sourceID, pan: 0, tilt: 0, zoom: 0) })
                        Button { } label: { Image(systemName: "minus.magnifyingglass") }
                            .simultaneousGesture(DragGesture(minimumDistance: 0)
                                .onChanged { _ in engine.ptzMove(sourceID, pan: 0, tilt: 0, zoom: -0.6) }
                                .onEnded { _ in engine.ptzMove(sourceID, pan: 0, tilt: 0, zoom: 0) })
                    }
                    .buttonStyle(.bordered)
                }
                Text("Preset: chạm = gọi, giữ = lưu").font(.caption2)
                HStack {
                    ForEach(1...6, id: \.self) { n in
                        Text("\(n)").frame(width: 34, height: 30).background(Color(white: 0.2), in: Rectangle())
                            .onTapGesture { engine.ptzPreset(sourceID, n, store: false) }
                            .onLongPressGesture { engine.ptzPreset(sourceID, n, store: true) }
                    }
                }
                Button("Ngắt PTZ", role: .destructive) { engine.setPTZ(sourceID, nil) }.font(DS.fBody)
            }
        }
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
                ScopeView(kind: engine.scopeKind, result: engine.scopeResult).frame(height: 200)
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
                transport("backward.frame.fill") { editor.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                transport("forward.frame.fill") { editor.step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
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
                        .background(engine.replayOnAir ? DS.pgm : DS.accent, in: Rectangle())
                }
                .buttonStyle(.plain)
                smallButton("Lên Preview", "rectangle.on.rectangle") { engine.playEditorRange(toAir: false) }
                smallButton("Lưu clip", "plus.rectangle.on.rectangle") { editor.saveClip() }
                Spacer()
            }

            if let m = editor.message { Text(m).font(DS.fBody).foregroundStyle(DS.text2) }

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
            .background(selected ? DS.accent : DS.surface2, in: Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func smallButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(title), systemImage: icon).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 30)
                .foregroundStyle(.white).background(DS.surface2, in: Rectangle())
                .overlay(Rectangle().stroke(DS.stroke))
        }
        .buttonStyle(.plain)
    }

    private func iconKey(_ icon: String, _ help: String, tint: Color = DS.surface2, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 26)
                .foregroundStyle(tint == DS.surface2 ? .white : .black)
                .background(tint, in: Rectangle())
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
                .foregroundStyle(.white).background(DS.surface2, in: Rectangle())
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
            .background(value != nil ? color : DS.surface2, in: Rectangle())
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
    @State private var c = CameraSource.Controls()

    var body: some View {
        SectionCard("Điều khiển camera", systemImage: "camera.aperture") {
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

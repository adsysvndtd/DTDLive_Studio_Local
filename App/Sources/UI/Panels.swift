import PencilKit
import SwiftUI
import UniformTypeIdentifiers

enum PanelTab: String, CaseIterable, Identifiable {
    case titles, audio, source, scopes, auto, replay
    var id: String { rawValue }
    var label: String {
        switch self {
        case .titles: return "Title"
        case .audio: return "Âm thanh"
        case .source: return "Nguồn"
        case .scopes: return "Scopes"
        case .auto: return "Tự động"
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
            HStack {
                Text("Title").textCase(.uppercase).font(.caption2.weight(.bold)).foregroundStyle(DS.text3).tracking(0.6)
                Spacer()
                Button { engine.setTitleVisible(nil, false) } label: {
                    Text("Ẩn tất cả").font(.caption2.weight(.semibold)).padding(.horizontal, 8).frame(height: 24)
                        .foregroundStyle(DS.text2).background(DS.surface2, in: Rectangle())
                }.buttonStyle(.plain)
            }
            ForEach(engine.titles.enumerated().filter { $0.offset != engine.scoreboardIndex }.map(\.element)) { item in
                titleRow(item)
            }
        }
        .sheet(item: Binding(get: { editingID.map { IDBox(id: $0) } }, set: { editingID = $0?.id })) { box in
            if let i = engine.titles.firstIndex(where: { $0.id == box.id }) {
                TitleEditorSheet(item: $engine.titles[i]) {
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
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kiểu", selection: $item.style) {
                        ForEach(TitleStyle.allCases.filter { $0 != .scoreBug }) { Text($0.label).tag($0) }
                    }
                    if item.style != .clock {
                        TextField(item.style == .ticker ? "Nội dung chữ chạy" : item.style == .countdown ? "Nhãn" : "Dòng 1", text: $item.line1)
                    }
                    if [.lowerThird, .nameStrap, .fullScreen].contains(item.style) {
                        TextField("Dòng 2", text: $item.line2)
                    }
                    if item.style == .countdown {
                        Stepper("Phút \(item.scoreA)", value: $item.scoreA, in: 0...180).monospacedDigit()
                        Stepper("Giây \(item.scoreB)", value: $item.scoreB, in: 0...59).monospacedDigit()
                    }
                }
                Section("Vị trí & cỡ") {
                    LabeledSlider(title: "Ngang", value: Binding(get: { Double(item.position.x) }, set: { item.position.x = $0 }),
                                  range: 0...0.9) { "\(Int($0 * 100))%" }
                    LabeledSlider(title: "Dọc", value: Binding(get: { Double(item.position.y) }, set: { item.position.y = $0 }),
                                  range: 0...0.95) { "\(Int($0 * 100))%" }
                    LabeledSlider(title: "Cỡ chữ", value: Binding(get: { Double(item.scale) }, set: { item.scale = $0 }),
                                  range: 0.5...2) { String(format: "%.1f×", $0) }
                    if item.style == .ticker {
                        LabeledSlider(title: "Tốc độ chạy", value: Binding(get: { Double(item.tickerSpeed) }, set: { item.tickerSpeed = $0 }),
                                      range: 40...400) { "\(Int($0))" }
                    }
                    ColorPicker("Màu nhấn", selection: Binding(
                        get: { Color(UIColor(hex: item.accentHex)) },
                        set: { item.accentHex = UIColor($0).hexString }), supportsOpacity: false)
                }
                Section {
                    Button("Xoá title", role: .destructive) { onDelete(); dismiss() }
                }
            }
            .navigationTitle(item.style.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
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
                    Text("Chưa có kênh nào").font(.caption).foregroundStyle(DS.text3)
                }
                ForEach(engine.audioChannels) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(c.name).font(.subheadline.weight(.semibold)).lineLimit(1)
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
                .buttonStyle(.bordered).font(.caption)
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
                            trailing: AnyView(Button("Đặt lại") { engine.setProcessing(id, SourceProcessing()) }.font(.caption))) {
                    slider(id, "Phơi sáng", Double(p.exposure), -2...2, { String(format: "%+.1f EV", $0) }) { var n = p; n.exposure = Float($0); return n }
                    slider(id, "Tương phản", Double(p.contrast), 0.5...1.5, { String(format: "%.2f", $0) }) { var n = p; n.contrast = Float($0); return n }
                    slider(id, "Bão hoà", Double(p.saturation), 0...2, { String(format: "%.2f", $0) }) { var n = p; n.saturation = Float($0); return n }
                    slider(id, "Nhiệt độ màu", Double(p.temperature), 3000...10000, { "\(Int($0)) K" }) { var n = p; n.temperature = Float($0); return n }
                    slider(id, "Tint", Double(p.tint), -100...100, { "\(Int($0))" }) { var n = p; n.tint = Float($0); return n }
                    HStack {
                        Text("LUT").font(.caption).foregroundStyle(DS.text2)
                        Picker("LUT", selection: Binding(get: { p.lutName }, set: { var n = p; n.lutName = $0; engine.setProcessing(id, n) })) {
                            Text("Không").tag(String?.none)
                            ForEach(ProcessingRenderer.availableLUTs(), id: \.self) { Text($0).tag(Optional($0)) }
                        }
                        .pickerStyle(.menu)
                        Spacer()
                        Button("Nạp .cube") { importLUT = true }.font(.caption)
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
                            Text("Nền thay thế").font(.caption).foregroundStyle(DS.text2)
                            Spacer()
                            Picker("Nền", selection: Binding(get: { p.keyBackgroundID }, set: { var n = p; n.keyBackgroundID = $0; engine.setProcessing(id, n) })) {
                                Text("Trong suốt").tag(UUID?.none)
                                ForEach(engine.sources.filter { $0.id != id }, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                            }
                            .pickerStyle(.menu)
                        }
                    } else {
                        Text("Bật để xoá phông xanh lá / xanh dương").font(.caption).foregroundStyle(DS.text3)
                    }
                }
                SectionCard("Hình học", systemImage: "crop.rotate") {
                    Toggle("Lật gương", isOn: Binding(get: { p.mirror }, set: { var n = p; n.mirror = $0; engine.setProcessing(id, n) }))
                    Toggle("Xoay 180°", isOn: Binding(get: { p.rotate180 }, set: { var n = p; n.rotate180 = $0; engine.setProcessing(id, n) }))
                }
                .font(.subheadline)
                if let cam = engine.sources.first(where: { $0.id == id }) as? CameraSource {
                    CameraControlCard(camera: cam)
                }
                SectionCard("Điều khiển PTZ", systemImage: "move.3d") {
                    PTZPanel(engine: engine, sourceID: id)
                }
            } else {
                Text("Chọn một nguồn ở hàng PREVIEW để chỉnh").font(.caption).foregroundStyle(DS.text3)
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
            Text("VISCA over IP").font(.caption).foregroundStyle(DS.text3)
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
                Button("Ngắt PTZ", role: .destructive) { engine.setPTZ(sourceID, nil) }.font(.caption)
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
            Text("Nguồn tham gia").font(.caption.bold())
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
                .font(.subheadline.weight(.semibold))
            Text("Tắt khi không dùng replay để đỡ nóng máy và tiết kiệm pin.").font(.caption).foregroundStyle(DS.text3)
            ReplayEditorView(engine: engine, editor: engine.replayEditor)
        }
    }
}

/// Clip editor: frame preview, thumbnail strip with playhead + in/out, frame stepping,
/// MARK IN / MARK OUT, slow-motion replay to air, clip list with export.
struct ReplayEditorView: View {
    @ObservedObject var engine: StudioEngine
    @ObservedObject var editor: ReplayEditor
    @State private var pickFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            HStack(spacing: 8) {
                Menu {
                    Button { editor.loadBuffer(engine.replayBuffer) } label: { Label("Bộ đệm replay (Program)", systemImage: "dot.radiowaves.left.and.right") }
                    Section("Video đã ghi / thư viện") {
                        ForEach(engine.library.list(.movie), id: \.self) { u in
                            Button(u.deletingPathExtension().lastPathComponent) { editor.loadFile(u) }
                        }
                    }
                } label: {
                    Label(editor.material.label, systemImage: editor.material == .buffer ? "gobackward" : "film")
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                if editor.material == .buffer {
                    Button { editor.loadBuffer(engine.replayBuffer) } label: { Label("Lấy mới", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered).font(.caption)
                }
            }

            // Frame preview
            ZStack {
                Color.black
                if let img = editor.preview { Image(uiImage: img).resizable().scaledToFit() }
                else { Text(editor.duration > 0 ? "Đang giải mã…" : "Chưa có hình").font(.caption).foregroundStyle(DS.text3) }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(Rectangle())
            .overlay(alignment: .bottomLeading) {
                Text(timeLabel(editor.playhead)).font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(5).background(.black.opacity(0.65), in: Rectangle()).padding(6)
            }
            .frame(maxWidth: 640)

            // Thumbnail strip with in/out and playhead; drag to scrub
            TimelineStrip(editor: editor).frame(height: 54)

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
                    Text("0.25×").tag(0.25); Text("0.5×").tag(0.5); Text("0.75×").tag(0.75); Text("1×").tag(1.0)
                }
                .pickerStyle(.segmented).frame(maxWidth: 260)
                Toggle("Lặp", isOn: $editor.loop).fixedSize()
                Spacer()
                let r = editor.effectiveRange
                Text(String(format: "Đoạn %.1f s", r.upperBound - r.lowerBound)).font(.caption.monospacedDigit()).foregroundStyle(DS.text2)
            }

            HStack(spacing: 8) {
                Button { engine.playEditorRange(toAir: true) } label: {
                    Label("PHÁT REPLAY", systemImage: "play.fill").font(.subheadline.weight(.heavy))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent).tint(DS.accent)
                Button { engine.playEditorRange(toAir: false) } label: { Label("Lên Preview", systemImage: "rectangle.on.rectangle").frame(minHeight: 40) }
                    .buttonStyle(.bordered)
                Button { engine.stopReplay() } label: { Image(systemName: "stop.fill").frame(minWidth: 30, minHeight: 40) }
                    .buttonStyle(.bordered)
                Button { editor.saveClip() } label: { Label("Lưu clip", systemImage: "plus.rectangle.on.rectangle").frame(minHeight: 40) }
                    .buttonStyle(.bordered)
            }

            if let m = editor.message { Text(m).font(.caption).foregroundStyle(DS.text2) }

            SectionCard("Clip đã lưu", systemImage: "film.stack") {
                if editor.clips.isEmpty { Text("Đặt MARK IN / MARK OUT rồi bấm Lưu clip").font(.caption).foregroundStyle(DS.text3) }
                ForEach(editor.clips) { c in
                    HStack(spacing: 8) {
                        Image(systemName: c.material == .buffer ? "gobackward" : "film").foregroundStyle(DS.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name).font(.subheadline.weight(.semibold))
                            Text("\(c.material.label) · \(timeLabel(c.inT)) → \(timeLabel(c.outT)) · \(String(format: "%.1f s", c.duration))")
                                .font(.caption2.monospacedDigit()).foregroundStyle(DS.text3).lineLimit(1)
                        }
                        Spacer()
                        Button { engine.playClip(c) } label: { Image(systemName: "play.fill") }.buttonStyle(.borderedProminent).tint(DS.accent)
                        Menu {
                            Button { engine.playClip(c, toAir: false) } label: { Label("Lên Preview", systemImage: "rectangle.on.rectangle") }
                            Button { editor.export(c, library: engine.library) } label: { Label("Xuất MP4 vào thư viện", systemImage: "square.and.arrow.down") }
                            Button(role: .destructive) { editor.deleteClip(c) } label: { Label("Xoá", systemImage: "trash") }
                        } label: { Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(DS.text2) }
                    }
                }
            }
        }
        .onAppear { if editor.duration == 0 && editor.material == .buffer { editor.loadBuffer(engine.replayBuffer) } }
    }

    private func timeLabel(_ t: Double) -> String {
        let f = Int((t - floor(t)) * 30)
        return String(format: "%02d:%02d:%02d", Int(t) / 60, Int(t) % 60, f)
    }

    private func transport(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 34, height: 32) }
            .buttonStyle(.bordered)
    }

    private func markKey(_ title: String, value: Double?, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(LocalizedStringKey(title)).font(.system(size: 11, weight: .heavy))
                Text(value.map(timeLabel) ?? "--:--:--").font(.system(size: 10, design: .monospaced))
            }
            .frame(width: 86, height: 38)
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
        .font(.subheadline)
        .onAppear { camera.refreshControls(); c = camera.controls }
    }
}

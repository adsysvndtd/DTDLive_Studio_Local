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
    @State private var tab: PanelTab = .titles

    var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: $tab) {
                ForEach(PanelTab.allCases) { Image(systemName: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(tab.label).font(.caption.bold()).frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                switch tab {
                case .titles: TitlesPanel(engine: engine)
                case .audio: AudioPanel(engine: engine)
                case .source: SourcePanel(engine: engine)
                case .scopes: ScopesPanel(engine: engine)
                case .auto: AutoPanel(auto: engine.autoSwitcher, engine: engine)
                case .replay: ReplayPanel(engine: engine)
                }
            }
        }
        .padding(8)
        .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: Titles

struct TitlesPanel: View {
    @ObservedObject var engine: StudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($engine.titles) { $t in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Picker("", selection: $t.style) { ForEach(TitleStyle.allCases) { Text($0.label).tag($0) } }
                            .labelsHidden()
                        Spacer()
                        Button(t.visible ? "ẨN" : "HIỆN") { engine.setTitleVisible(t.id, !t.visible) }
                            .buttonStyle(.borderedProminent).tint(t.visible ? .red : .gray)
                        Button(role: .destructive) { engine.removeTitle(t.id) } label: { Image(systemName: "trash") }
                    }
                    if t.style != .clock {
                        TextField("Dòng 1", text: $t.line1).textFieldStyle(.roundedBorder)
                    }
                    if [.lowerThird, .nameStrap, .fullScreen, .scoreBug].contains(t.style) {
                        TextField("Dòng 2", text: $t.line2).textFieldStyle(.roundedBorder)
                    }
                    if t.style == .scoreBug {
                        HStack {
                            Stepper("A: \(t.scoreA)", value: $t.scoreA, in: 0...999)
                            Stepper("B: \(t.scoreB)", value: $t.scoreB, in: 0...999)
                        }
                        TextField("Hiệp", text: $t.period).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Vị trí").font(.caption)
                        Slider(value: $t.position.x, in: 0...0.9)
                        Slider(value: $t.position.y, in: 0...0.95)
                        Slider(value: $t.scale, in: 0.5...2).frame(width: 70)
                    }
                    ColorPicker("Màu nhấn", selection: Binding(
                        get: { Color(UIColor(hex: t.accentHex)) },
                        set: { t.accentHex = UIColor($0).hexString })).font(.caption)
                }
                .padding(8)
                .background(t.visible ? Color.red.opacity(0.15) : Color(white: 0.13), in: RoundedRectangle(cornerRadius: 8))
            }
            Menu("+ Thêm title") {
                ForEach(TitleStyle.allCases) { s in
                    Button(s.label) { engine.upsertTitle(TitleItem(style: s, line1: s == .clock ? "" : s.label)) }
                }
            }
            Button("Ẩn tất cả") { engine.setTitleVisible(nil, false) }
            Text("Điều khiển title từ điện thoại/laptop: mở http://<IP iPad>:8080").font(.caption2).foregroundStyle(.secondary)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(engine.audioChannels) { c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(c.name).font(.caption.bold()).lineLimit(1)
                        Spacer()
                        Toggle("AFV", isOn: bind(c, \.followVideo)).toggleStyle(.button).font(.caption2)
                        Toggle(isOn: bind(c, \.muted)) { Image(systemName: c.muted ? "speaker.slash" : "speaker.wave.2") }
                            .toggleStyle(.button)
                    }
                    Slider(value: bind(c, \.gain), in: 0...2)
                    LevelMeter(db: c.level).frame(height: 5)
                }
                .padding(6).background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button("Nhạc nền…") { pickMusic = true }
                Button("Dừng nhạc") { engine.stopMusic() }
                Button("Hiệu ứng…") { pickEffect = true }
            }
            .buttonStyle(.bordered)
        }
        .fileImporter(isPresented: $pickMusic, allowedContentTypes: [.audio]) { r in
            if case .success(let u) = r, u.startAccessingSecurityScopedResource() { engine.playMusic(u) }
        }
        .fileImporter(isPresented: $pickEffect, allowedContentTypes: [.audio]) { r in
            if case .success(let u) = r, u.startAccessingSecurityScopedResource() { engine.playEffect(u) }
        }
    }

    private func bind<T>(_ c: AudioChannelState, _ kp: WritableKeyPath<AudioChannelState, T>) -> Binding<T> {
        Binding(get: { c[keyPath: kp] }, set: { var n = c; n[keyPath: kp] = $0; engine.updateAudioChannel(n) })
    }
}

// MARK: Per-source: color, LUT, chroma key, geometry, PTZ

struct SourcePanel: View {
    @ObservedObject var engine: StudioEngine
    @State private var selected: UUID?
    @State private var importLUT = false

    var body: some View {
        let id = selected ?? engine.previewID
        VStack(alignment: .leading, spacing: 8) {
            Picker("Nguồn", selection: Binding(get: { id }, set: { selected = $0 })) {
                ForEach(engine.sources, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }
            if let id {
                let p = engine.processingFor(id)
                Group {
                    Text("Màu").font(.caption.bold())
                    slider("Phơi sáng", p.exposure, -2...2) { var n = p; n.exposure = $0; return n }
                    slider("Tương phản", p.contrast, 0.5...1.5) { var n = p; n.contrast = $0; return n }
                    slider("Bão hoà", p.saturation, 0...2) { var n = p; n.saturation = $0; return n }
                    slider("Nhiệt độ", p.temperature, 3000...10000) { var n = p; n.temperature = $0; return n }
                    slider("Tint", p.tint, -100...100) { var n = p; n.tint = $0; return n }
                    HStack {
                        Picker("LUT", selection: Binding(get: { p.lutName }, set: { var n = p; n.lutName = $0; engine.setProcessing(id, n) })) {
                            Text("Không").tag(String?.none)
                            ForEach(ProcessingRenderer.availableLUTs(), id: \.self) { Text($0).tag(Optional($0)) }
                        }
                        Button("Nạp .cube") { importLUT = true }
                    }
                }
                Group {
                    Text("Chroma key").font(.caption.bold())
                    Toggle("Bật", isOn: Binding(get: { p.chromaEnabled }, set: { var n = p; n.chromaEnabled = $0; engine.setProcessing(id, n) }))
                    Picker("Màu nền", selection: Binding(get: { p.keyHue }, set: { var n = p; n.keyHue = $0; engine.setProcessing(id, n) })) {
                        Text("Xanh lá").tag(Float(120)); Text("Xanh dương").tag(Float(240))
                    }.pickerStyle(.segmented)
                    slider("Dung sai", p.keyTolerance, 5...80) { var n = p; n.keyTolerance = $0; return n }
                    slider("Mềm biên", p.keySoftness, 0...40) { var n = p; n.keySoftness = $0; return n }
                    Picker("Nền thay thế", selection: Binding(get: { p.keyBackgroundID }, set: { var n = p; n.keyBackgroundID = $0; engine.setProcessing(id, n) })) {
                        Text("Trong suốt").tag(UUID?.none)
                        ForEach(engine.sources.filter { $0.id != id }, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Group {
                    Text("Hình học").font(.caption.bold())
                    Toggle("Lật gương", isOn: Binding(get: { p.mirror }, set: { var n = p; n.mirror = $0; engine.setProcessing(id, n) }))
                    Toggle("Xoay 180°", isOn: Binding(get: { p.rotate180 }, set: { var n = p; n.rotate180 = $0; engine.setProcessing(id, n) }))
                    Button("Đặt lại tất cả") { engine.setProcessing(id, SourceProcessing()) }
                }
                PTZPanel(engine: engine, sourceID: id)
            }
        }
        .fileImporter(isPresented: $importLUT, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]) { r in
            guard case .success(let u) = r, u.startAccessingSecurityScopedResource() else { return }
            try? FileManager.default.copyItem(at: u, to: ProcessingRenderer.lutDirectory.appendingPathComponent(u.lastPathComponent))
        }
    }

    private func slider(_ title: String, _ v: Float, _ range: ClosedRange<Float>, _ make: @escaping (Float) -> SourceProcessing) -> some View {
        let id = selected ?? engine.previewID
        return HStack {
            Text(title).font(.caption).frame(width: 80, alignment: .leading)
            Slider(value: Binding(get: { v }, set: { if let id { engine.setProcessing(id, make($0), undoable: false) } }), in: range)
        }
    }
}

struct PTZPanel: View {
    @ObservedObject var engine: StudioEngine
    let sourceID: UUID
    @State private var host = ""
    @State private var transport: PTZConfig.Transport = .viscaUDP

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PTZ (VISCA over IP)").font(.caption.bold())
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
                        Text("\(n)").frame(width: 34, height: 30).background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 6))
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
        VStack(alignment: .leading) {
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
        VStack(alignment: .leading, spacing: 8) {
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
    @State private var speed = 0.5
    @State private var length = 8.0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Tốc độ", selection: $speed) {
                Text("0.25×").tag(0.25); Text("0.5×").tag(0.5); Text("0.75×").tag(0.75); Text("1×").tag(1.0)
            }.pickerStyle(.segmented)
            Stepper("Độ dài: \(Int(length)) giây", value: $length, in: 3...15)
            HStack {
                Button("REPLAY") { engine.startReplay(speed: speed, length: length) }
                    .buttonStyle(.borderedProminent).tint(.orange)
                Button("Dừng") { engine.stopReplay() }.buttonStyle(.bordered)
            }
            Text("Phát lại vài giây cuối của Program dạng slow-motion như một nguồn riêng. Có thể gọi từ web remote hoặc OSC /dtd/replay.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

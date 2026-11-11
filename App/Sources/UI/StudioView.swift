import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct StudioView: View {
    @StateObject private var engine = StudioEngine()
    @State private var showAddSource = false
    @State private var showOutputs = false
    @State private var drawing = false
    @State private var clearDrawing = 0
    @State private var showShows = false
    @State private var tbarValue = 0.0
    @State private var category: ProdCategory = ProdCategory(rawValue: DemoMode.arg("-category") ?? "") ?? .camera
    @State private var scopesOnPreview = false
    @Environment(\.verticalSizeClass) private var vSize

    /// iPhone (or any height-compact window): smaller chrome, same structure.
    private var compact: Bool { vSize == .compact || UIDevice.current.userInterfaceIdiom == .phone }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
                monitorStrip
                    .frame(height: geo.size.height * (compact ? 0.46 : 0.44))
                Divider().overlay(DS.stroke)
                HStack(spacing: 0) {
                    CategoryList(selection: $category, compact: compact)
                        .frame(width: compact ? 74 : 168)
                    Divider().overlay(DS.stroke)
                    CategoryContent(engine: engine, library: engine.library, category: category,
                                    compact: compact, showAddSource: $showAddSource)
                    Divider().overlay(DS.stroke)
                    TransitionColumn(engine: engine, tbarValue: $tbarValue, compact: compact)
                        .frame(width: compact ? 96 : 150)
                }
            }
        }
        .background(DS.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(DS.accent)
        .onChange(of: engine.requestedCategory) { _, c in
            if let c { category = c; engine.requestedCategory = nil }
        }
        .sheet(isPresented: $showAddSource) { AddSourceSheet(engine: engine) }
        .sheet(isPresented: $showOutputs) { OutputsSheet(engine: engine) }
        .sheet(isPresented: $showShows) { ShowsSheet(engine: engine) }
        .task {
            guard DemoMode.isOn else { return }
            DemoMode.populate(engine)
            try? await Task.sleep(nanoseconds: 1_500_000_000) // let monitors fill before opening sheets
            switch DemoMode.arg("-screen") {
            case "outputs": showOutputs = true
            case "shows": showShows = true
            case "addsource": showAddSource = true
            default: break
            }
        }
    }

    // MARK: Top bar (slim)

    private var topBar: some View {
        HStack(spacing: 8) {
            Image("Logo").resizable().scaledToFit().frame(width: compact ? 20 : 24, height: compact ? 20 : 24)
            Text("DTD Studio").font(compact ? .caption.weight(.bold) : .subheadline.weight(.bold)).fixedSize()
            if !compact {
                Text("\(engine.format.width)×\(engine.format.height) · \(engine.format.fps)p · \(engine.encoder.codec.label)")
                    .font(.caption2).foregroundStyle(DS.text3).fixedSize()
            }
            if engine.isAnyLive { Pill(text: "LIVE", color: DS.pgm, dot: .white) }
            if engine.isRecording { Pill(text: "REC", color: DS.pgm.opacity(0.25), dot: DS.pgm) }
            Spacer(minLength: 4)
            if !compact { Pill(text: String(format: "%.1f Mbps", Double(engine.currentBitrate) / 1e6)) }
            LevelMeter(db: engine.audioLevel).frame(width: compact ? 50 : 90, height: 5)
            barButton("arrow.uturn.backward", "Hoàn tác") { engine.undo() }.disabled(!engine.canUndo).opacity(engine.canUndo ? 1 : 0.4)
                .keyboardShortcut("z", modifiers: .command)
            barButton("arrow.uturn.forward", "Làm lại") { engine.redo() }.disabled(!engine.canRedo).opacity(engine.canRedo ? 1 : 0.4)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            barButton(engine.isRecording ? "record.circle.fill" : "record.circle", "Ghi", tint: engine.isRecording ? DS.pgm : .white) { engine.toggleRecording() }
            barButton("folder", "Show") { showShows = true }
            if engine.externalDisplayConnected {
                Menu {
                    Picker("Màn ngoài", selection: $engine.externalMode) {
                        Text("Program").tag(StudioEngine.ExternalMode.program)
                        Text("Multiview").tag(StudioEngine.ExternalMode.multiview)
                    }
                } label: { barLabel("tv", "Màn ngoài") }
            }
            Button { showOutputs = true } label: {
                Label(engine.isAnyLive ? "Đang phát" : (compact ? "Phát" : "Phát trực tiếp"), systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.bold)).lineLimit(1).fixedSize()
                    .padding(.horizontal, 10).frame(height: compact ? 28 : 32)
                    .foregroundStyle(.white)
                    .background(engine.isAnyLive ? DS.pgm : DS.accent, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).frame(height: compact ? 36 : 44)
        .background(DS.surface)
    }

    private func barButton(_ icon: String, _ title: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) { barLabel(icon, title, tint: tint) }.buttonStyle(.plain)
    }

    private func barLabel(_ icon: String, _ title: String, tint: Color = .white) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            if !compact { Text(title).font(.caption.weight(.semibold)).lineLimit(1).fixedSize() }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 8 : 10).frame(height: compact ? 28 : 32)
        .background(DS.surface2, in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: Monitors (PVW | info | PGM)

    private var monitorStrip: some View {
        HStack(spacing: compact ? 6 : 12) {
            monitorPane(title: "PVW", color: DS.pvw, store: engine.switcher.previewMonitor, isProgram: false)
            monitorPane(title: "PGM", color: DS.pgm, store: engine.switcher.programMonitor, isProgram: true)
        }
        .padding(.horizontal, compact ? 6 : 12).padding(.vertical, compact ? 4 : 8)
        .background(Color.black)
    }

    private func name(_ id: UUID?) -> String { engine.sources.first { $0.id == id }?.name ?? "—" }

    private func monitorPane(title: String, color: Color, store: FrameStore, isProgram: Bool) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: compact ? 10 : 12, weight: .heavy))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color, in: RoundedRectangle(cornerRadius: 3))
                Text(name(isProgram ? engine.programID : engine.previewID))
                    .font(.system(size: compact ? 10 : 12, weight: .semibold)).lineLimit(1)
                Spacer()
                if isProgram {
                    monitorChip(engine.isAnyLive ? "ON AIR" : "OFF AIR", on: engine.isAnyLive, onColor: DS.pgm) { showOutputs = true }
                    if !compact { monitorChip("Thông số", on: engine.showMonitorInfo) { engine.showMonitorInfo.toggle() } }
                    monitorChip("Vẽ", on: drawing) { drawing.toggle() }
                    if drawing { monitorChip("Xoá nét", on: false) { clearDrawing += 1 } }
                } else {
                    monitorChip("Scopes", on: scopesOnPreview) {
                        scopesOnPreview.toggle(); engine.scopesEnabled = scopesOnPreview
                    }
                    monitorChip("Khung an toàn", on: engine.showSafeGuides) { engine.showSafeGuides.toggle() }
                }
            }
            ZStack {
                MonitorView(store: store)
                if engine.showSafeGuides { SafeGuides() }
                if isProgram {
                    if engine.showMonitorInfo && !compact { monitorInfo.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) }
                    if drawing {
                        AnnotationCanvas(layer: engine.annotation,
                                         programSize: CGSize(width: engine.format.width, height: engine.format.height),
                                         clearToken: $clearDrawing)
                    }
                } else if scopesOnPreview {
                    ScopeView(kind: engine.scopeKind, result: engine.scopeResult)
                        .frame(width: compact ? 130 : 200, height: compact ? 70 : 110)
                        .opacity(0.9)
                        .overlay(alignment: .topTrailing) {
                            Menu { Picker("", selection: $engine.scopeKind) { ForEach(ScopeKind.allCases) { Text($0.label).tag($0) } } }
                            label: { Image(systemName: "chevron.down.circle.fill").foregroundStyle(.white) }.padding(3)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(6)
                }
            }
            .aspectRatio(CGFloat(engine.format.width) / CGFloat(engine.format.height), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 2))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func monitorChip(_ t: String, on: Bool, onColor: Color = DS.accent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: compact ? 9 : 11, weight: .bold)).lineLimit(1).fixedSize()
                .padding(.horizontal, 7).padding(.vertical, 3)
                .foregroundStyle(on ? .white : DS.text2)
                .background(on ? onColor.opacity(0.85) : DS.surface2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var monitorInfo: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(engine.format.width)×\(engine.format.height) · \(engine.format.fps) fps · \(engine.encoder.codec.label)")
            Text(String(format: "%.1f Mbps · Âm thanh %.0f dBFS", Double(engine.currentBitrate) / 1e6, engine.audioLevel))
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(5).background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
        .padding(6)
    }
}

/// Action-safe (93%) and title-safe (90%) guides plus centre marks.
struct SafeGuides: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            Path { p in
                p.addRect(CGRect(x: w * 0.035, y: h * 0.035, width: w * 0.93, height: h * 0.93))
            }.stroke(Color.red.opacity(0.55), lineWidth: 1)
            Path { p in
                p.addRect(CGRect(x: w * 0.05, y: h * 0.05, width: w * 0.90, height: h * 0.90))
            }.stroke(Color.green.opacity(0.55), lineWidth: 1)
            Path { p in
                let c = 8.0
                p.move(to: CGPoint(x: w / 2, y: h * 0.035)); p.addLine(to: CGPoint(x: w / 2, y: h * 0.035 + c))
                p.move(to: CGPoint(x: w / 2, y: h * 0.965)); p.addLine(to: CGPoint(x: w / 2, y: h * 0.965 - c))
                p.move(to: CGPoint(x: w * 0.035, y: h / 2)); p.addLine(to: CGPoint(x: w * 0.035 + c * 2, y: h / 2))
                p.move(to: CGPoint(x: w * 0.965, y: h / 2)); p.addLine(to: CGPoint(x: w * 0.965 - c * 2, y: h / 2))
            }.stroke(Color.red.opacity(0.55), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// Label used inside toolbar Menus (same look as ToolButton).
struct ToolButtonLabel: View {
    let title: String
    let systemImage: String
    var active = false
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
            Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 58, height: 40)
        .foregroundStyle(active ? .black : .white)
        .background(active ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Vertical T-bar: drag down to transition; snaps back to the top when released.
struct TBar: View {
    @Binding var value: Double
    var onChange: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6).fill(DS.surface2)
                RoundedRectangle(cornerRadius: 6).fill(DS.accent.opacity(0.35))
                    .frame(height: max(0, h * value))
                RoundedRectangle(cornerRadius: 4).fill(Color.white)
                    .frame(height: 14).padding(.horizontal, 3)
                    .offset(y: (h - 14) * value)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    value = min(1, max(0, g.location.y / h))
                    onChange(value)
                }
                .onEnded { _ in
                    onChange(value >= 0.95 ? 1 : 0)
                    withAnimation(.easeOut(duration: 0.15)) { value = 0 }
                })
        }
        .overlay(alignment: .bottom) { Text("T").font(.caption2.weight(.heavy)).foregroundStyle(DS.text3).offset(y: 14) }
    }
}

struct LevelMeter: View {
    let db: Float
    var body: some View {
        GeometryReader { g in
            let f = CGFloat(max(0, min(1, (db + 60) / 60)))
            ZStack(alignment: .leading) {
                Capsule().fill(.gray.opacity(0.3))
                Capsule().fill(db > -6 ? .red : db > -18 ? .yellow : .green).frame(width: g.size.width * f)
            }
        }
    }
}

struct AddSourceSheet: View {
    @ObservedObject var engine: StudioEngine
    @Environment(\.dismiss) private var dismiss
    @State private var kind: SourceKind = .camera
    @State private var name = ""
    @State private var url = ""
    @State private var showFile = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Loại", selection: $kind) { ForEach(SourceKind.allCases) { Text($0.label).tag($0) } }
                switch kind {
                case .camera:
                    ForEach(CameraSource.availableDevices(), id: \.uniqueID) { d in
                        Button(d.localizedName) { engine.add(CameraSource(device: d)); dismiss() }
                    }
                case .srt, .rtmpPull, .rtsp:
                    TextField("Tên", text: $name)
                    TextField(kind == .srt ? "srt://0.0.0.0:9001?mode=listener"
                              : kind == .rtsp ? "rtsp://user:pass@192.168.1.64:554/stream1" : "rtmp://host/live/key", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Thêm") {
                        guard let u = URL(string: url) else { return }
                        let n = name.isEmpty ? kind.label : name
                        switch kind {
                        case .srt: engine.add(SRTInputSource(name: n, url: u))
                        case .rtsp: engine.add(RTSPInputSource(name: n, url: u))
                        default: engine.add(RTMPInputSource(name: n, url: u))
                        }
                        dismiss()
                    }
                case .file:
                    Button("Chọn video…") { showFile = true }
                }
            }
            .navigationTitle("Thêm nguồn")
            .toolbar { Button("Đóng") { dismiss() } }
            .fileImporter(isPresented: $showFile, allowedContentTypes: [.movie]) { result in
                guard case .success(let u) = result, u.startAccessingSecurityScopedResource() else { return }
                engine.add(FileSource(name: u.lastPathComponent, url: u)); dismiss()
            }
        }
    }
}

struct OutputsSheet: View {
    @ObservedObject var engine: StudioEngine
    @Environment(\.dismiss) private var dismiss
    @State private var draft = OutputConfig(name: "", proto: .rtmp, url: "")
    @StateObject private var platform = PlatformLive()
    @State private var liveTitle = "DTD Studio Live"
    @State private var platformBusy = false
    @State private var platformMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Đích phát (chạy song song, encode 1 lần)") {
                    ForEach($engine.outputs) { $o in
                        let st = engine.outputStatus[o.id] ?? .idle
                        HStack {
                            VStack(alignment: .leading) {
                                Text(o.name.isEmpty ? o.proto.label : o.name).bold()
                                Text(o.proto == .record ? o.proto.label : o.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(st.text).font(.caption2).foregroundStyle(st == .live ? .red : .secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $o.enabled).labelsHidden()
                            if st == .idle || { if case .error = st { return true }; return false }() {
                                Button("Phát") { engine.startOutput(o) }.buttonStyle(.borderedProminent)
                            } else {
                                Button("Dừng") { engine.stopOutput(o) }.buttonStyle(.bordered).tint(.red)
                            }
                        }
                    }
                    .onDelete { engine.outputs.remove(atOffsets: $0) }
                }
                Section("Tạo phiên live tự động") {
                    TextField("Tiêu đề buổi live", text: $liveTitle)
                    HStack {
                        Button("YouTube Live") { createLive(.youtube) }
                        Button("Facebook Live") { createLive(.facebook) }
                        if platformBusy { ProgressView() }
                    }
                    .buttonStyle(.bordered).disabled(platformBusy)
                    if let platformMessage { Text(platformMessage).font(.caption).textSelection(.enabled) }
                }
                Section("Thêm đích") {
                    Picker("Giao thức", selection: $draft.proto) {
                        ForEach(OutputProtocol.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Tên", text: $draft.name)
                    if draft.proto != .record {
                        TextField(draft.proto.placeholder, text: $draft.url)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Button("Thêm") {
                        engine.outputs.append(draft)
                        draft = OutputConfig(name: "", proto: draft.proto, url: "")
                    }
                    .disabled(draft.proto != .record && URL(string: draft.url)?.scheme == nil)
                }
                Section("Encoder") {
                    Picker("Codec", selection: $engine.encoder.codec) {
                        ForEach(VideoCodecChoice.allCases) { Text($0.label).tag($0) }
                    }
                    if engine.encoder.codec == .hevc {
                        Text("HEVC: YouTube/RTMP cần máy chủ hỗ trợ Enhanced RTMP; Facebook chỉ nhận H.264. SRT/RTSP/ghi file dùng được.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Stepper(String(format: "Bitrate: %.1f Mbps", Double(engine.encoder.bitrate) / 1e6), value: $engine.encoder.bitrate, in: 1_000_000...20_000_000, step: 500_000)
                    Toggle("Bitrate thích ứng", isOn: $engine.encoder.adaptive)
                    if engine.encoder.adaptive {
                        Stepper(String(format: "Tối thiểu: %.1f Mbps", Double(engine.encoder.minBitrate) / 1e6), value: $engine.encoder.minBitrate, in: 500_000...10_000_000, step: 250_000)
                        Text(String(format: "Đang dùng: %.1f Mbps", Double(engine.currentBitrate) / 1e6)).font(.caption)
                    }
                    Picker("Khung hình", selection: Binding(
                        get: { engine.format == .vertical1080 ? 1 : 0 },
                        set: { engine.format = $0 == 1 ? .vertical1080 : ProgramFormat() })) {
                        Text("1920×1080 (ngang)").tag(0)
                        Text("1080×1920 (dọc)").tag(1)
                    }
                }
            }
            .navigationTitle("Đầu ra")
            .toolbar {
                ToolbarItemGroup {
                    Button("Phát tất cả") { engine.startAll() }
                    Button("Dừng tất cả", role: .destructive) { engine.stopAll() }
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }
}


extension OutputsSheet {
    func createLive(_ p: PlatformLive.Platform) {
        platformBusy = true; platformMessage = nil
        Task {
            defer { platformBusy = false }
            do {
                let d = p == .youtube
                    ? try await platform.createYouTube(title: liveTitle, vertical: engine.format == .vertical1080)
                    : try await platform.createFacebook(title: liveTitle)
                var cfg = OutputConfig(name: d.name, proto: .rtmp, url: d.url)
                cfg.enabled = true
                engine.outputs.append(cfg)
                platformMessage = "Đã tạo đích \(d.name)" + (d.watchURL.map { ". Xem: \($0)" } ?? "")
            } catch {
                platformMessage = error.localizedDescription
            }
        }
    }
}

struct ShowsSheet: View {
    @ObservedObject var engine: StudioEngine
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var shows = ShowStore.list()
    @State private var error: String?
    @State private var confirmLoad: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Lưu cấu hình hiện tại") {
                    TextField("Tên show", text: $name)
                    Button("Lưu") {
                        do { try engine.saveShow(named: name); shows = ShowStore.list() } catch { self.error = "\(error)" }
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section("Show đã lưu (Files › DTD Studio › Shows)") {
                    ForEach(shows, id: \.self) { s in
                        Button(s) { confirmLoad = s }
                    }
                    .onDelete { idx in idx.forEach { ShowStore.delete(shows[$0]) }; shows = ShowStore.list() }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Show")
            .toolbar { Button("Đóng") { dismiss() } }
            .confirmationDialog("Nạp show sẽ dừng phát và thay toàn bộ nguồn, đầu ra, title.",
                                isPresented: Binding(get: { confirmLoad != nil }, set: { if !$0 { confirmLoad = nil } }),
                                titleVisibility: .visible) {
                Button("Nạp \(confirmLoad ?? "")", role: .destructive) {
                    if let n = confirmLoad {
                        do { try engine.loadShow(named: n); dismiss() } catch { self.error = "\(error)" }
                    }
                }
            }
        }
    }
}

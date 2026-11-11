import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct StudioView: View {
    @StateObject private var engine = StudioEngine()
    @State private var showAddSource = false
    @State private var showOutputs = false
    @State private var showLogoPicker = false
    @State private var logoItem: PhotosPickerItem?
    @State private var drawing = false
    @State private var clearDrawing = 0
    @State private var showPanel = true
    @State private var showShows = false
    @State private var tbarValue = 0.0
    @State private var showPanelSheet = false
    @Environment(\.verticalSizeClass) private var vSize

    /// iPhone (or any height-compact window): icon toolbar, inspector as a sheet, monitors get the space.
    private var compact: Bool { vSize == .compact || UIDevice.current.userInterfaceIdiom == .phone }

    var body: some View {
        Group {
            if compact { compactLayout } else { regularLayout }
        }
        .background(DS.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(DS.accent)
        .sheet(isPresented: $showPanelSheet) {
            SidePanel(engine: engine).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
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
            case "nopanel": showPanel = false
            default: break
            }
        }
        .photosPicker(isPresented: $showLogoPicker, selection: $logoItem, matching: .images)
        .onChange(of: logoItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) { engine.setLogo(UIImage(data: data)) }
            }
        }
    }

    // MARK: Compact (iPhone)

    private var compactLayout: some View {
        VStack(spacing: 6) {
            compactTopBar
            HStack(spacing: 8) {
                monitor("PVW", name: name(engine.previewID), store: engine.switcher.previewMonitor, color: DS.pvw)
                monitor("PGM", name: name(engine.programID), store: engine.switcher.programMonitor, color: DS.pgm)
                    .overlay { annotationOverlay }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 8)
            compactDeck.padding(.horizontal, 8).padding(.bottom, 6)
        }
    }

    private var compactTopBar: some View {
        HStack(spacing: 8) {
            Image("Logo").resizable().scaledToFit().frame(width: 22, height: 22)
            Text("DTD Studio").font(.subheadline.weight(.bold)).lineLimit(1).fixedSize()
            if engine.isAnyLive { Pill(text: "LIVE", color: DS.pgm, dot: .white) }
            if engine.isRecording { Pill(text: "REC", color: DS.pgm.opacity(0.25), dot: DS.pgm) }
            LevelMeter(db: engine.audioLevel).frame(width: 60, height: 5)
            Spacer(minLength: 4)
            iconButton("arrow.uturn.backward") { engine.undo() }.disabled(!engine.canUndo).opacity(engine.canUndo ? 1 : 0.4)
            iconButton("pencil.tip", active: drawing) { drawing.toggle() }
            if drawing { iconButton("eraser") { clearDrawing += 1 } }
            iconButton("slider.horizontal.3") { showPanelSheet = true }
            Menu {
                Button { engine.toggleRecording() } label: { Label(engine.isRecording ? "Dừng ghi" : "Ghi file", systemImage: "record.circle") }
                Button { showShows = true } label: { Label("Show", systemImage: "folder") }
                Divider()
                Button { showLogoPicker = true } label: { Label("Chọn logo…", systemImage: "photo") }
                if engine.logo != nil { Button("Bỏ logo", role: .destructive) { engine.setLogo(nil) } }
                Menu("PiP") {
                    Button("Tắt PiP") { engine.setPiP(nil) }
                    ForEach(engine.sources, id: \.id) { s in Button(s.name) { engine.setPiP(s.id) } }
                }
                Button { engine.fadeToBlack.toggle() } label: { Label(engine.fadeToBlack ? "Bỏ FTB" : "Fade to black", systemImage: "moon") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 34).background(DS.surface2, in: RoundedRectangle(cornerRadius: 8))
            }
            Button { showOutputs = true } label: {
                Label(engine.isAnyLive ? "Đang phát" : "Phát", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.bold)).lineLimit(1).fixedSize()
                    .padding(.horizontal, 10).frame(height: 34)
                    .foregroundStyle(.white)
                    .background(engine.isAnyLive ? DS.pgm : DS.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.top, 4)
    }

    private func iconButton(_ icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 34)
                .foregroundStyle(active ? .black : .white)
                .background(active ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var compactDeck: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(engine.sources.enumerated()), id: \.element.id) { i, s in
                        let pgm = s.id == engine.programID, pvw = s.id == engine.previewID
                        ZStack(alignment: .bottomLeading) {
                            MonitorView(store: s.frames, maxFPS: 8).aspectRatio(16 / 9, contentMode: .fit).frame(height: 50)
                            Text("\(i + 1)").font(.caption2.weight(.heavy)).frame(width: 16, height: 16)
                                .background(pgm ? DS.pgm : pvw ? DS.pvw : Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                                .padding(3)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(pgm ? DS.pgm : pvw ? DS.pvw : DS.stroke, lineWidth: pgm || pvw ? 2.5 : 1))
                        .onTapGesture(count: 2) { engine.take(s.id) }
                        .onTapGesture { engine.select(s.id) }
                        .contextMenu { Button("Xoá nguồn", role: .destructive) { engine.remove(s) } }
                    }
                    Button { showAddSource = true } label: {
                        Image(systemName: "plus").frame(width: 50, height: 50)
                            .background(DS.surface2, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
            Menu {
                Picker("Hiệu ứng", selection: $engine.transition) {
                    ForEach(TransitionStyle.allCases.filter { $0 != .cut }) { Text($0.label).tag($0) }
                }
                Stepper(String(format: "Thời gian %.1fs", engine.transitionDuration), value: $engine.transitionDuration, in: 0.2...3, step: 0.1)
            } label: {
                VStack(spacing: 0) {
                    Text(engine.transition.label).font(.caption.weight(.bold))
                    Text(String(format: "%.1fs", engine.transitionDuration)).font(.caption2).foregroundStyle(DS.text2)
                }
                .frame(width: 52, height: 50).background(DS.surface2, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
            }
            KeyButton(title: "CUT", width: 54, height: 50) { engine.cut() }
            KeyButton(title: "AUTO", color: DS.accent, textColor: .black, width: 64, height: 50) { engine.autoTransition() }
        }
    }

    @ViewBuilder private var annotationOverlay: some View {
        if drawing {
            AnnotationCanvas(layer: engine.annotation,
                             programSize: CGSize(width: engine.format.width, height: engine.format.height),
                             clearToken: $clearDrawing)
        }
    }

    // MARK: Regular (iPad)

    private var regularLayout: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(DS.stroke)
            HStack(alignment: .top, spacing: DS.gap) {
                VStack(spacing: DS.gap) {
                    monitors
                    controlDeck
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showPanel {
                    SidePanel(engine: engine)
                        .frame(width: 330)
                        .transition(.move(edge: .trailing))
                }
            }
            .padding(DS.gap)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Image("Logo").resizable().scaledToFit().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("DTD Studio").font(.headline)
                Text("\(engine.format.width)×\(engine.format.height) · \(engine.format.fps)p · \(engine.encoder.codec.label)")
                    .font(.caption2).foregroundStyle(DS.text3)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if engine.isAnyLive { Pill(text: "LIVE", color: DS.pgm.opacity(0.9), dot: .white) }
                if engine.isRecording { Pill(text: "REC", color: DS.pgm.opacity(0.25), dot: DS.pgm) }
                Pill(text: String(format: "%.1f Mbps", Double(engine.currentBitrate) / 1e6))
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(DS.text2)
                    LevelMeter(db: engine.audioLevel).frame(width: 90, height: 6)
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(DS.surface2, in: Capsule())
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                ToolButton(title: "Hoàn tác", systemImage: "arrow.uturn.backward") { engine.undo() }
                    .disabled(!engine.canUndo).opacity(engine.canUndo ? 1 : 0.4)
                    .keyboardShortcut("z", modifiers: .command)
                ToolButton(title: "Làm lại", systemImage: "arrow.uturn.forward") { engine.redo() }
                    .disabled(!engine.canRedo).opacity(engine.canRedo ? 1 : 0.4)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                ToolButton(title: "Vẽ", systemImage: "pencil.tip", active: drawing) { drawing.toggle() }
                if drawing { ToolButton(title: "Xoá nét", systemImage: "eraser") { clearDrawing += 1 } }
                Menu {
                    Button("Chọn ảnh logo…") { showLogoPicker = true }
                    if engine.logo != nil { Button("Bỏ logo", role: .destructive) { engine.setLogo(nil) } }
                    Divider()
                    Button("Tắt PiP") { engine.setPiP(nil) }
                    ForEach(engine.sources, id: \.id) { s in Button("PiP: \(s.name)") { engine.setPiP(s.id) } }
                } label: {
                    ToolButtonLabel(title: "Lớp phủ", systemImage: "square.on.square", active: engine.logo != nil || engine.pip != nil)
                }
                ToolButton(title: "Ghi", systemImage: engine.isRecording ? "record.circle.fill" : "record.circle",
                           tint: engine.isRecording ? DS.pgm : .white) { engine.toggleRecording() }
                ToolButton(title: "Show", systemImage: "folder") { showShows = true }
                if engine.externalDisplayConnected {
                    Menu {
                        Picker("Màn ngoài", selection: $engine.externalMode) {
                            Text("Program").tag(StudioEngine.ExternalMode.program)
                            Text("Multiview").tag(StudioEngine.ExternalMode.multiview)
                        }
                    } label: { ToolButtonLabel(title: "Màn ngoài", systemImage: "tv") }
                }
                ToolButton(title: "Panel", systemImage: "sidebar.right", active: showPanel) {
                    withAnimation(.easeInOut(duration: 0.2)) { showPanel.toggle() }
                }
                Button { showOutputs = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text(engine.isAnyLive ? "Đang phát" : "Phát trực tiếp").font(.subheadline.weight(.bold))
                    }
                    .padding(.horizontal, 14).frame(height: 40)
                    .foregroundStyle(.white)
                    .background(engine.isAnyLive ? DS.pgm : DS.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(DS.surface)
    }

    // MARK: Monitors

    private var monitors: some View {
        HStack(spacing: DS.gap) {
            monitor("PREVIEW", name: name(engine.previewID), store: engine.switcher.previewMonitor, color: DS.pvw)
            monitor("PROGRAM", name: name(engine.programID), store: engine.switcher.programMonitor, color: DS.pgm)
                .overlay { annotationOverlay }
        }
        .frame(maxHeight: .infinity)
    }

    private func name(_ id: UUID?) -> String { engine.sources.first { $0.id == id }?.name ?? "—" }

    @ViewBuilder
    private func monitor(_ title: String, name: String, store: FrameStore, color: Color) -> some View {
        if compact {
            MonitorView(store: store)
                .aspectRatio(CGFloat(engine.format.width) / CGFloat(engine.format.height), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 2))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        Text(title).font(.system(size: 10, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(color, in: RoundedRectangle(cornerRadius: 3))
                        Text(name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                            .padding(.horizontal, 4).padding(.vertical, 2).background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                    }
                    .padding(5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.caption.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(color, in: RoundedRectangle(cornerRadius: 4))
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if title == "PROGRAM", engine.fadeToBlack { Pill(text: "FTB", color: DS.pgm.opacity(0.3)) }
            }
            MonitorView(store: store)
                .aspectRatio(CGFloat(engine.format.width) / CGFloat(engine.format.height), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 2))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Control deck (bus rows + transition)

    private var controlDeck: some View {
        HStack(alignment: .top, spacing: DS.gap) {
            VStack(alignment: .leading, spacing: 8) {
                busRow(label: "PROGRAM", color: DS.pgm, selected: engine.programID) { engine.take($0) }
                busRow(label: "PREVIEW", color: DS.pvw, selected: engine.previewID, showAdd: true) { engine.select($0) }
            }
            .padding(10)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radius))
            transitionBlock
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func busRow(label: String, color: Color, selected: UUID?, showAdd: Bool = false,
                        action: @escaping (UUID) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10, weight: .heavy)).foregroundStyle(color)
                .rotationEffect(.degrees(-90)).fixedSize().frame(width: 14)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(engine.sources.enumerated()), id: \.element.id) { i, s in
                        let on = s.id == selected
                        Button { action(s.id) } label: {
                            ZStack(alignment: .bottomLeading) {
                                MonitorView(store: s.frames, maxFPS: 10)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .frame(height: 62)
                                    .opacity(on ? 1 : 0.75)
                                HStack(spacing: 4) {
                                    Text("\(i + 1)").font(.caption.weight(.heavy))
                                        .frame(width: 18, height: 18)
                                        .background(on ? color : Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                                    Text(s.name).font(.caption2.weight(.semibold)).lineLimit(1)
                                }
                                .padding(4)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? color : DS.stroke, lineWidth: on ? 3 : 1))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(i < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: label == "PROGRAM" ? [.shift] : []) : nil)
                        .contextMenu { Button("Xoá nguồn", role: .destructive) { engine.remove(s) } }
                    }
                    if showAdd {
                        Button { showAddSource = true } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "plus").font(.title3.weight(.semibold))
                                Text("Thêm nguồn").font(.caption2)
                            }
                            .frame(width: 110, height: 62)
                            .foregroundStyle(DS.text2)
                            .background(DS.surface2, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(DS.text3))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var transitionBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CHUYỂN CẢNH").font(.caption.weight(.bold)).foregroundStyle(DS.text2)
                Picker("", selection: $engine.transition) {
                    ForEach(TransitionStyle.allCases.filter { $0 != .cut }) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 190)
                HStack {
                    Text("Thời gian").font(.caption).foregroundStyle(DS.text2)
                    Spacer()
                    Stepper(String(format: "%.1fs", engine.transitionDuration), value: $engine.transitionDuration, in: 0.2...3, step: 0.1)
                        .font(.caption.monospacedDigit()).fixedSize()
                }
                .frame(width: 190)
                HStack(spacing: 8) {
                    KeyButton(title: "CUT", width: 56, height: 50) { engine.cut() }
                        .keyboardShortcut(.space, modifiers: [])
                    KeyButton(title: "AUTO", color: DS.accent, textColor: .black, width: 72, height: 50) { engine.autoTransition() }
                        .keyboardShortcut(.return, modifiers: [])
                    KeyButton(title: "FTB", color: engine.fadeToBlack ? DS.pgm : DS.surface2, width: 50, height: 50) {
                        engine.fadeToBlack.toggle()
                    }
                }
            }
            TBar(value: $tbarValue) { engine.tbar($0) }
                .frame(width: 34, height: 130)
        }
        .padding(10)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radius))
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

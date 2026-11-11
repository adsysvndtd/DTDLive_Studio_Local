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

    var body: some View {
        VStack(spacing: 8) {
            header
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        monitor("PREVIEW", store: engine.switcher.previewMonitor, color: .green)
                        monitor("PROGRAM", store: engine.switcher.programMonitor, color: .red)
                            .overlay {
                                if drawing {
                                    AnnotationCanvas(layer: engine.annotation,
                                                     programSize: CGSize(width: engine.format.width, height: engine.format.height),
                                                     clearToken: $clearDrawing)
                                }
                            }
                    }
                    .frame(maxHeight: .infinity)
                    transitionBar
                    multiview
                }
                if showPanel { SidePanel(engine: engine).frame(width: 340) }
            }
        }
        .padding(8)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAddSource) { AddSourceSheet(engine: engine) }
        .sheet(isPresented: $showOutputs) { OutputsSheet(engine: engine) }
        .sheet(isPresented: $showShows) { ShowsSheet(engine: engine) }
        .photosPicker(isPresented: $showLogoPicker, selection: $logoItem, matching: .images)
        .onChange(of: logoItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) { engine.setLogo(UIImage(data: data)) }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("DTD Studio").font(.headline)
            Spacer()
            LevelMeter(db: engine.audioLevel).frame(width: 120, height: 8)
            Button { engine.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!engine.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button { engine.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!engine.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Toggle(isOn: $drawing) { Image(systemName: "pencil.tip") }.toggleStyle(.button)
            if drawing { Button("Xoá nét") { clearDrawing += 1 } }
            Button { engine.toggleRecording() } label: {
                Label("REC", systemImage: engine.isRecording ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(engine.isRecording ? .red : .primary)
            }
            if engine.externalDisplayConnected {
                Picker("", selection: $engine.externalMode) {
                    Text("Màn ngoài: PGM").tag(StudioEngine.ExternalMode.program)
                    Text("Màn ngoài: Multiview").tag(StudioEngine.ExternalMode.multiview)
                }
            }
            Button { showShows = true } label: { Label("Show", systemImage: "folder") }
            Button { showPanel.toggle() } label: { Image(systemName: "sidebar.right") }
            Button { showLogoPicker = true } label: { Label("Logo", systemImage: "photo") }
            if engine.logo != nil { Button("Bỏ logo") { engine.setLogo(nil) } }
            Menu {
                Button("Tắt PiP") { engine.setPiP(nil) }
                ForEach(engine.sources, id: \.id) { s in Button(s.name) { engine.setPiP(s.id) } }
            } label: { Label("PiP", systemImage: "pip") }
            Button { showOutputs = true } label: {
                Label(engine.isAnyLive ? "ĐANG PHÁT" : "Đầu ra", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(engine.isAnyLive ? .red : .primary)
            }
        }
        .buttonStyle(.bordered)
    }

    private func monitor(_ title: String, store: FrameStore, color: Color) -> some View {
        MonitorView(store: store)
            .aspectRatio(CGFloat(engine.format.width) / CGFloat(engine.format.height), contentMode: .fit)
            .overlay(alignment: .topLeading) {
                Text(title).font(.caption.bold()).padding(4).background(color.opacity(0.8)).padding(6)
            }
            .border(color, width: 2)
            .frame(maxWidth: .infinity)
    }

    private var transitionBar: some View {
        HStack {
            Picker("", selection: $engine.transition) {
                ForEach(TransitionStyle.allCases.filter { $0 != .cut }) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 280)
            Stepper(String(format: "%.1fs", engine.transitionDuration), value: $engine.transitionDuration, in: 0.2...3, step: 0.1)
                .frame(maxWidth: 160)
            Spacer()
            Toggle("FTB", isOn: $engine.fadeToBlack).toggleStyle(.button)
            Button("CUT") { engine.cut() }.keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.borderedProminent).tint(.gray)
            Button("AUTO") { engine.autoTransition() }.keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent).tint(.orange)
        }
    }

    private var multiview: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(engine.sources.enumerated()), id: \.element.id) { index, s in
                    let isPgm = engine.programID == s.id, isPvw = engine.previewID == s.id
                    MonitorView(store: s.frames, maxFPS: 15)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(height: 110)
                        .overlay(alignment: .bottomLeading) {
                            Text("\(index + 1) · \(s.name)").font(.caption2).padding(3).background(.black.opacity(0.6))
                        }
                        .border(isPgm ? Color.red : isPvw ? Color.green : Color.gray, width: isPgm || isPvw ? 3 : 1)
                        .onTapGesture(count: 2) { engine.take(s.id) }
                        .onTapGesture { engine.select(s.id) }
                        .contextMenu { Button("Xoá nguồn", role: .destructive) { engine.remove(s) } }
                }
                Button { showAddSource = true } label: {
                    Image(systemName: "plus").frame(width: 120, height: 110)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(height: 120)
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

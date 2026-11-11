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

    var body: some View {
        VStack(spacing: 8) {
            header
            HStack(spacing: 8) {
                monitor("PREVIEW", store: engine.switcher.previewMonitor, color: .green)
                monitor("PROGRAM", store: engine.switcher.programMonitor, color: .red)
            }
            .frame(maxHeight: .infinity)
            transitionBar
            multiview
        }
        .padding(8)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAddSource) { AddSourceSheet(engine: engine) }
        .sheet(isPresented: $showOutputs) { OutputsSheet(engine: engine) }
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
                case .srt, .rtmpPull:
                    TextField("Tên", text: $name)
                    TextField(kind == .srt ? "srt://0.0.0.0:9000?mode=listener" : "rtmp://host/live/key", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Thêm") {
                        guard let u = URL(string: url) else { return }
                        let n = name.isEmpty ? kind.label : name
                        engine.add(kind == .srt ? SRTInputSource(name: n, url: u) : RTMPInputSource(name: n, url: u))
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
                    Stepper("Bitrate: \(engine.encoder.bitrate / 1_000_000) Mbps", value: $engine.encoder.bitrate, in: 1_000_000...20_000_000, step: 500_000)
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

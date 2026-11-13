import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct StudioView: View {
    @ObservedObject var engine: StudioEngine
    @State private var showAddSource = false
    @State private var showOutputs = false
    @State private var drawing = false
    @State private var clearDrawing = 0
    @State private var showShows = false
    @State private var tbarValue = 0.0
    // SceneStorage: survives the root rebuild done on a language switch
    @SceneStorage("ui.category") private var category: ProdCategory = ProdCategory(rawValue: DemoMode.arg("-category") ?? "") ?? .camera
    @State private var scopesOnPreview = false
    @State private var arranging = false
    @State private var showSettings = false
    @Environment(\.verticalSizeClass) private var vSize

    /// iPhone (or any height-compact window): smaller chrome, same structure.
    private var compact: Bool { vSize == .compact || UIDevice.current.userInterfaceIdiom == .phone }

    var body: some View {
        GeometryReader { geo in
            if compact {
                // iPhone landscape: the key column runs the full height (CUT/AUTO/T-bar always reachable),
                // monitors get half the height so PVW/PGM fill their width without black side bars.
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        topBar
                        monitorStrip
                            .frame(height: max(150, (geo.size.height - 32) * 0.52))
                        Divider().overlay(DS.stroke)
                        HStack(spacing: 0) {
                            CategoryList(selection: $category, compact: true)
                                .frame(width: 56)
                            Divider().overlay(DS.stroke)
                            CategoryContent(engine: engine, library: engine.library, category: category,
                                            compact: true, showAddSource: $showAddSource)
                        }
                    }
                    Divider().overlay(DS.stroke)
                    TransitionColumn(engine: engine, tbarValue: $tbarValue, compact: true)
                        .frame(width: 80)
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    monitorStrip
                        .frame(height: geo.size.height * 0.44)
                    Divider().overlay(DS.stroke)
                    HStack(spacing: 0) {
                        CategoryList(selection: $category, compact: false)
                            .frame(width: 140)
                        Divider().overlay(DS.stroke)
                        CategoryContent(engine: engine, library: engine.library, category: category,
                                        compact: false, showAddSource: $showAddSource)
                        Divider().overlay(DS.stroke)
                        TransitionColumn(engine: engine, tbarValue: $tbarValue, compact: false)
                            .frame(width: 128)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            PairingBanner(pairing: engine.pairing, compact: compact)
                .padding(.top, compact ? 40 : 60)
                .animation(.spring(duration: 0.3), value: engine.pairing.pending)
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
        .sheet(isPresented: $showSettings) { SettingsSheet(engine: engine) }
        .alert(engine.message ?? "", isPresented: Binding(get: { engine.message != nil }, set: { if !$0 { engine.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .task {
            guard DemoMode.isOn else { return }
            DemoMode.populate(engine)
            try? await Task.sleep(nanoseconds: 1_500_000_000) // let monitors fill before opening sheets
            switch DemoMode.arg("-screen") {
            case "outputs": showOutputs = true
            case "shows": showShows = true
            case "addsource": showAddSource = true
            case "pairing": engine.pairing.injectDemoRequest()
            case "settings": showSettings = true
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
            barButton("gearshape", "Cài đặt") { showSettings = true }
            if engine.externalDisplayConnected {
                Menu {
                    Picker("Màn ngoài", selection: $engine.externalMode) {
                        Text("Program").tag(StudioEngine.ExternalMode.program)
                        Text("Multiview").tag(StudioEngine.ExternalMode.multiview)
                    }
                } label: { barLabel("tv", "Màn ngoài") }
            }
            Button { showOutputs = true } label: {
                Label(LocalizedStringKey(engine.isAnyLive ? "Đang phát" : (compact ? "Phát" : "Phát trực tiếp")), systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.bold)).lineLimit(1).fixedSize()
                    .padding(.horizontal, 10).frame(height: compact ? 28 : 32)
                    .foregroundStyle(.white)
                    .background(engine.isAnyLive ? DS.pgm : DS.accent, in: RoundedRectangle(cornerRadius: DS.radius))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).frame(height: compact ? 32 : 44)
        .background(DS.surface)
    }

    private func barButton(_ icon: String, _ title: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) { barLabel(icon, title, tint: tint) }.buttonStyle(.plain)
    }

    private func barLabel(_ icon: String, _ title: String, tint: Color = .white) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            if !compact { Text(LocalizedStringKey(title)).font(.caption.weight(.semibold)).lineLimit(1).fixedSize() }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 8 : 10).frame(height: compact ? 28 : 32)
        .background(DS.surface2, in: Rectangle())
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

    /// Short label for a source: "CAM 1 · Sân khấu" → "CAM 1", "intro_final.mp4" → "intro_final".
    static func shortName(_ full: String) -> String {
        var n = full
        if let r = n.range(of: " · ") { n = String(n[..<r.lowerBound]) }
        let ext = (n as NSString).pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "png", "jpg", "jpeg", "heic", "gif"].contains(ext) { n = (n as NSString).deletingPathExtension }
        return n.count > 16 ? String(n.prefix(15)) + "…" : n
    }

    /// Source name at the foot of PVW / PGM.
    private func sourceCaption(_ id: UUID?, color: Color) -> some View {
        let label = engine.sources.first { $0.id == id }.map { Self.shortName($0.name) } ?? "—"
        return Text(label)
            .font(.system(size: compact ? 10 : 13, weight: .bold))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 6 : 9).padding(.vertical, compact ? 2 : 3)
            .background(Color.black.opacity(0.6), in: Rectangle())
            .padding(.bottom, compact ? 4 : 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
    }

    @ViewBuilder private func chips(isProgram: Bool) -> some View {
                if isProgram {
                    monitorChip(engine.isAnyLive ? "ON AIR" : "OFF AIR", on: engine.isAnyLive, onColor: DS.pgm) { showOutputs = true }
                    if !compact { monitorChip("Thông số", on: engine.showMonitorInfo) { engine.showMonitorInfo.toggle() } }
                    if engine.pip != nil || engine.logo != nil { monitorChip("Sắp xếp", on: arranging) { arranging.toggle(); if arranging { drawing = false } } }
                    monitorChip("Giờ", on: engine.clockOn) { engine.toggleClock() }
                    if let m = engine.programMovie { monitorChip("Lặp", on: m.loops) { engine.toggleProgramLoop() } }
                    monitorChip("Reset", on: false) { engine.resetProgramLayers(); clearDrawing += 1 }
                    monitorChip("Vẽ", on: drawing) { drawing.toggle(); if drawing { arranging = false } }
                    if drawing { monitorChip("Xoá nét", on: false) { clearDrawing += 1 } }
                } else {
                    monitorChip("Scopes", on: scopesOnPreview) {
                        scopesOnPreview.toggle(); engine.scopesEnabled = scopesOnPreview
                    }
                    monitorChip("Khung an toàn", on: engine.showSafeGuides) { engine.showSafeGuides.toggle() }
                }
    }

    /// Monitor card sized to the largest 16:9 (program aspect) that fits, with its chip row exactly as wide,
    /// so chips line up with the card edges instead of floating over the black gutter.
    private func monitorPane(title: String, color: Color, store: FrameStore, isProgram: Bool) -> some View {
        GeometryReader { geo in
            let ar = CGFloat(engine.format.width) / CGFloat(max(engine.format.height, 1))
            let chipH: CGFloat = compact ? 24 : 30
            let w = min(geo.size.width, max(0, geo.size.height - chipH - 4) * ar)
            monitorCard(title: title, color: color, store: store, isProgram: isProgram, chipH: chipH)
                .frame(width: w)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func monitorCard(title: String, color: Color, store: FrameStore, isProgram: Bool, chipH: CGFloat) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                if isProgram { Spacer(minLength: 0) }
                // chips scroll sideways only when the monitor is too narrow (iPhone landscape)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: compact ? 4 : 6) { chips(isProgram: isProgram) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: compact ? 4 : 6) { chips(isProgram: isProgram) }
                    }
                    .defaultScrollAnchor(.trailing)
                }
                if !isProgram { Spacer(minLength: 0) }
            }
            .frame(height: chipH)
            ZStack {
                MonitorView(store: store)
                if engine.showSafeGuides { SafeGuides() }
                sourceCaption(isProgram ? engine.programID : engine.previewID, color: color)
                if !isProgram && engine.swipeToTake && !scopesOnPreview {
                    SwipeTakeOverlay(onCut: { engine.cut() }, onAuto: { engine.autoTransition() })
                }
                if isProgram {
                    if engine.showMonitorInfo && !compact { monitorInfo.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) }
                    if arranging { ArrangeOverlay(engine: engine) }
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
            .overlay(alignment: .topTrailing) {
                // PVW / PGM tag flush in the top-right corner of the card
                Text(LocalizedStringKey(title)).font(.system(size: compact ? 10 : 12, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, compact ? 6 : 8).padding(.vertical, compact ? 2 : 3)
                    .background(color, in: Rectangle())
                    .allowsHitTesting(false)
            }
            .clipShape(Rectangle())
            .overlay(Rectangle().strokeBorder(color, lineWidth: 1.5))
        }
    }

    private func monitorChip(_ t: String, on: Bool, onColor: Color = DS.accent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(t)).font(.system(size: compact ? 9 : 11, weight: .bold)).lineLimit(1).fixedSize()
                .padding(.horizontal, 7).padding(.vertical, 3)
                .foregroundStyle(on ? .white : DS.text2)
                .background(on ? onColor.opacity(0.85) : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
    }

    private var monitorInfo: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(engine.format.width)×\(engine.format.height) · \(engine.format.fps) fps · \(engine.encoder.codec.label)")
            Text(String(format: L("%.1f Mbps · Âm thanh %.0f dBFS"), Double(engine.currentBitrate) / 1e6, engine.audioLevel))
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(5).background(Color.black.opacity(0.55), in: Rectangle())
        .padding(6)
    }
}

/// Transparent pan catcher on PVW: swipe right (toward PGM) with 1 finger = CUT, 2 fingers = AUTO.
struct SwipeTakeOverlay: UIViewRepresentable {
    var onCut: () -> Void
    var onAuto: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(); v.backgroundColor = .clear
        for n in 1...2 {
            let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
            pan.minimumNumberOfTouches = n; pan.maximumNumberOfTouches = n
            v.addGestureRecognizer(pan)
        }
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.onCut = onCut; context.coordinator.onAuto = onAuto
    }

    final class Coordinator: NSObject {
        var onCut: () -> Void = {}
        var onAuto: () -> Void = {}
        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard g.state == .ended, let v = g.view else { return }
            let t = g.translation(in: v), vel = g.velocity(in: v)
            guard t.x > max(50, v.bounds.width * 0.2), abs(t.x) > abs(t.y) * 1.5 || vel.x > 600 else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if g.maximumNumberOfTouches == 2 { onAuto() } else { onCut() }
        }
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
            Text(LocalizedStringKey(title)).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 58, height: 40)
        .foregroundStyle(active ? .black : .white)
        .background(active ? DS.accent : DS.surface2, in: Rectangle())
    }
}

/// Vertical T-bar that behaves like a hardware lever: the handle stays where the operator leaves it
/// and the transition stays at that point (no auto-complete, no spring back). Pushing all the way to the
/// far end completes the take; that end becomes the new rest position, so the next take is the opposite
/// stroke. Moving back toward the rest end reverses the mix; reaching it cancels.
/// `onChange` receives the stroke progress 0…1 measured from the rest end.
struct TBar: View {
    @Binding var value: Double           // handle position, 0 = top, 1 = bottom
    var onChange: (Double) -> Void
    @State private var rest: Double = 0  // end the current stroke starts from (0 or 1)
    @State private var grab: Double?     // finger offset from the handle when the drag began

    var body: some View {
        GeometryReader { g in
            let h = g.size.height, travel = max(h - 16, 1)
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.85), Color(white: 0.5)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 22)
                Rectangle().fill(Color.black).frame(width: 4).padding(.vertical, 10)
                Rectangle()
                    .fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.6), Color(white: 0.85)], startPoint: .top, endPoint: .bottom))
                    .frame(height: 16)
                    .overlay(Rectangle().fill(Color.black.opacity(0.7)).frame(width: 3))
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    .offset(y: travel * value)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in
                    // relative drag: touching the bar never makes the handle jump to the finger
                    if grab == nil { grab = d.startLocation.y / travel - value }
                    let v = min(1, max(0, d.location.y / travel - (grab ?? 0)))
                    value = v
                    let p = abs(v - rest)
                    if p >= 0.999 {
                        onChange(1)                    // take completes at the far end
                        rest = v > 0.5 ? 1 : 0         // …which is the new rest position
                    } else {
                        onChange(p)                    // held / reversible mix
                    }
                }
                .onEnded { _ in grab = nil })          // stays where it was left
        }
    }
}

/// LED ladder beside the T-bar: full at rest, empties as the bar is pulled (amber when it drives the PiP).
struct TBarLEDs: View {
    let value: Double
    var pip = false
    private let count = 10
    var body: some View {
        GeometryReader { g in
            let lit = Int(((1 - value) * Double(count)).rounded())
            VStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { i in
                    Rectangle()
                        .fill(count - 1 - i < lit ? (pip ? Color.orange : Color.green) : Color(white: 0.18))
                        .frame(height: max(3, (g.size.height - CGFloat(count - 1) * 3) / CGFloat(count)))
                }
            }
        }
        .frame(width: 8)
    }
}

struct LevelMeter: View {
    let db: Float
    var body: some View {
        GeometryReader { g in
            let f = CGFloat(max(0, min(1, (db + 60) / 60)))
            ZStack(alignment: .leading) {
                Rectangle().fill(.gray.opacity(0.3))
                Rectangle().fill(db > -6 ? .red : db > -18 ? .yellow : .green).frame(width: g.size.width * f)
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
    @State private var ndiFound: [String] = []
    @State private var ndiSearching = false

    var body: some View {
        NavigationStack {
            Form {
                if NDIAvailability.isAvailable {
                    Section("NDI® trong mạng") {
                        Button { ndiSearching = true; Task { ndiFound = await engine.findNDISources(); ndiSearching = false } } label: {
                            Label(ndiSearching ? "Đang tìm…" : "Tìm nguồn NDI", systemImage: "dot.radiowaves.left.and.right")
                        }
                        ForEach(ndiFound, id: \.self) { n in
                            Button(n) { engine.addNDISource(n); dismiss() }
                        }
                    }
                }
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
    @State private var draftKey = ""
    @State private var preset: StreamPreset?
    @ObservedObject private var platform = PlatformLive.shared
    @State private var liveTitle = "DTD Studio Live"
    @State private var platformBusy = false
    @State private var platformMessage: String?
    @State private var watchURL: URL?
    @State private var editLinkID: UUID?
    @State private var editLinkText = ""
    @AppStorage("dtd.live.privacy") private var livePrivacy = "public"

    var body: some View {
        NavigationStack {
            Form {
                Section("Đích phát (chạy song song, encode 1 lần)") {
                    // Iterate values, not $bindings: a binding into the array crashes when the last row is deleted.
                    ForEach(engine.outputs) { o in
                        let st = engine.outputStatus[o.id] ?? .idle
                        HStack {
                            VStack(alignment: .leading) {
                                Text(o.name.isEmpty ? o.proto.label : o.name).bold()
                                Text(o.proto == .record ? o.proto.label : o.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(st.text).font(.caption2).foregroundStyle(st == .live ? .red : .secondary)
                                if st == .live, let r = engine.outputRates[o.id] {
                                    Text(verbatim: r).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                if o.proto != .record {
                                    HStack(spacing: 12) {
                                        if let w = o.watchURL, let u = URL(string: w) {
                                            Link(destination: u) { Label("Xem live", systemImage: "play.tv") }
                                            Button { UIPasteboard.general.url = u } label: { Label("Copy link", systemImage: "doc.on.doc") }
                                        }
                                        Button { editLinkID = o.id; editLinkText = o.watchURL ?? "" } label: {
                                            Label(o.watchURL == nil ? "Thêm link xem" : "Sửa link", systemImage: "link")
                                        }
                                    }
                                    .font(.caption).buttonStyle(.borderless)
                                }
                                if o.proto == .rtmp { OutputLogView(id: o.id) }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { engine.outputs.first { $0.id == o.id }?.enabled ?? false },
                                set: { v in if let i = engine.outputs.firstIndex(where: { $0.id == o.id }) { engine.outputs[i].enabled = v } }))
                                .labelsHidden()
                            if st == .idle || { if case .error = st { return true }; return false }() {
                                Button("Phát") { engine.startOutput(o) }.buttonStyle(.borderedProminent)
                            } else {
                                Button("Dừng") { engine.stopOutput(o) }.buttonStyle(.bordered).tint(.red)
                            }
                        }
                    }
                    .onDelete { engine.deleteOutputs(at: $0) }
                }
                Section("Tạo phiên live tự động") {
                    TextField("Tiêu đề buổi live", text: $liveTitle)
                    Picker("Ai được xem", selection: $livePrivacy) {
                        Text("Công khai").tag("public")
                        Text("Không công khai (có link)").tag("unlisted")
                        Text("Chỉ mình tôi").tag("private")
                    }
                    HStack {
                        Button("YouTube Live") { createLive(.youtube) }
                        Button("Facebook Live") { createLive(.facebook) }
                        if platformBusy { ProgressView() }
                    }
                    .buttonStyle(.bordered).disabled(platformBusy)
                    if let platformMessage { Text(platformMessage).font(.caption).textSelection(.enabled) }
                    if let watchURL {
                        HStack {
                            Link(destination: watchURL) { Label("Mở trang xem live", systemImage: "play.tv") }
                            Spacer()
                            Button { UIPasteboard.general.url = watchURL } label: { Label("Copy link", systemImage: "doc.on.doc") }
                                .buttonStyle(.borderless)
                        }
                        Text("Bấm Phát ở đích vừa tạo; sau 10–20 giây trang xem mới có hình.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Thêm đích") {
                    // Platform presets: paste Server URL + Stream key from the platform's live page
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(StreamPreset.all) { p in
                                Button {
                                    preset = p; draftKey = ""
                                    draft = OutputConfig(name: p.name, proto: .rtmp, url: p.server)
                                    if p.id == "youtube" { draft.watchURL = PlatformLive.youtubeChannelLiveURL }
                                } label: {
                                    Label(p.name, systemImage: p.icon)
                                }
                                .buttonStyle(.bordered).tint(preset?.id == p.id ? .orange : nil)
                            }
                        }
                    }
                    if let p = preset {
                        Text(LocalizedStringKey(p.hint)).font(.caption).foregroundStyle(.secondary)
                        if p.vertical && !engine.format.isVertical {
                            HStack {
                                Text("Nền tảng này hiển thị dọc 9:16").font(.caption).foregroundStyle(.orange)
                                Spacer()
                                Button("Chuyển sang 1080×1920") { engine.format.width = 1080; engine.format.height = 1920 }
                                    .font(.caption).buttonStyle(.bordered)
                            }
                        }
                        TextField("Tên", text: $draft.name)
                        TextField("Server URL (rtmp:// hoặc rtmps://)", text: $draft.url)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Stream key", text: $draftKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Link xem (tuỳ chọn, vd https://youtube.com/@kenh/live)", text: Binding(
                            get: { draft.watchURL ?? "" }, set: { draft.watchURL = $0.isEmpty ? nil : $0 }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        HStack {
                            Button("Thêm \(p.name)") {
                                var c = draft
                                c.url = StreamPreset.join(server: draft.url, key: draftKey)
                                engine.outputs.append(c)
                                preset = nil; draftKey = ""
                                draft = OutputConfig(name: "", proto: .rtmp, url: "")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(URL(string: draft.url)?.scheme == nil || draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Huỷ") { preset = nil; draftKey = ""; draft = OutputConfig(name: "", proto: .rtmp, url: "") }
                        }
                    } else {
                        Picker("Giao thức", selection: $draft.proto) {
                            ForEach(OutputProtocol.allCases) { Text($0.label).tag($0) }
                        }
                        TextField("Tên", text: $draft.name)
                        if draft.proto != .record {
                            TextField(draft.proto.placeholder, text: $draft.url)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("Link xem (tuỳ chọn)", text: Binding(
                                get: { draft.watchURL ?? "" }, set: { draft.watchURL = $0.isEmpty ? nil : $0 }))
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        }
                        Button("Thêm") {
                            engine.outputs.append(draft)
                            draft = OutputConfig(name: "", proto: draft.proto, url: "")
                        }
                        .disabled(draft.proto != .record && URL(string: draft.url)?.scheme == nil)
                    }
                }
                Section("Encoder") {
                    Picker("Codec", selection: $engine.encoder.codec) {
                        ForEach(VideoCodecChoice.allCases) { Text($0.label).tag($0) }
                    }
                    if engine.encoder.codec == .hevc {
                        Text("HEVC: YouTube/RTMP cần máy chủ hỗ trợ Enhanced RTMP; Facebook chỉ nhận H.264. SRT/RTSP/ghi file dùng được.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    BitrateControl(bitrate: $engine.encoder.bitrate)
                    Toggle("Bitrate thích ứng", isOn: $engine.encoder.adaptive)
                    if engine.encoder.adaptive {
                        Stepper(String(format: L("Tối thiểu: %.1f Mbps"), Double(engine.encoder.minBitrate) / 1e6), value: $engine.encoder.minBitrate, in: 500_000...10_000_000, step: 250_000)
                        Text(String(format: L("Đang dùng: %.1f Mbps"), Double(engine.currentBitrate) / 1e6)).font(.caption)
                    }
                    Picker("Độ phân giải", selection: Binding(
                        get: { engine.format.resolutionID },
                        set: { id in if let r = ProgramFormat.resolutions.first(where: { $0.id == id }) { engine.format.width = r.width; engine.format.height = r.height } })) {
                        ForEach(ProgramFormat.resolutions) { Text($0.label).tag($0.id) }
                    }
                    Picker("Tốc độ khung", selection: $engine.format.fps) {
                        ForEach(ProgramFormat.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                }
            }
            // small title pinned top-left (no large title block) so the cards start higher
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("Đầu ra").font(.system(size: 15, weight: .bold))
                }
            }
            .listSectionSpacing(.compact)
            .contentMargins(.top, 4, for: .scrollContent)
            .alert("Link xem live", isPresented: Binding(get: { editLinkID != nil }, set: { if !$0 { editLinkID = nil } })) {
                TextField("https://…", text: $editLinkText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Lưu") {
                    if let id = editLinkID, let i = engine.outputs.firstIndex(where: { $0.id == id }) {
                        let t = editLinkText.trimmingCharacters(in: .whitespacesAndNewlines)
                        engine.outputs[i].watchURL = t.isEmpty ? nil : (t.hasPrefix("http") ? t : "https://" + t)
                    }
                    editLinkID = nil
                }
                Button("Huỷ", role: .cancel) { editLinkID = nil }
            } message: { Text("Trang người xem mở để xem buổi live (YouTube: youtube.com/@kenh/live · Facebook: link bài live).") }
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
        platformBusy = true; platformMessage = nil; watchURL = nil
        Task {
            defer { platformBusy = false }
            do {
                let d = p == .youtube
                    ? try await platform.createYouTube(title: liveTitle, privacy: livePrivacy, vertical: engine.format.isVertical)
                    : try await platform.createFacebook(title: liveTitle,
                                                        privacy: livePrivacy == "public" ? "EVERYONE" : livePrivacy == "unlisted" ? "ALL_FRIENDS" : "SELF")
                var cfg = OutputConfig(name: d.name, proto: .rtmp, url: d.url)
                cfg.watchURL = d.watchURL
                cfg.enabled = true
                engine.outputs.append(cfg)
                engine.startOutput(cfg)          // push right away: the platform shows the live as soon as video arrives
                watchURL = d.watchURL.flatMap(URL.init(string:))
                platformMessage = L("Đã tạo và đang phát tới") + " \(d.name)"
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


/// RTMP(S) destinations that take a server URL + stream key copied from the platform.
struct StreamPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let server: String          // fixed ingest server, or "" when the platform gives one per session
    let hint: String
    var vertical = false

    static let all: [StreamPreset] = [
        StreamPreset(id: "youtube", name: "YouTube", icon: "play.rectangle.fill", server: "rtmp://a.rtmp.youtube.com/live2",
                     hint: "YouTube Studio › Phát trực tiếp › Khoá luồng."),
        StreamPreset(id: "facebook", name: "Facebook", icon: "f.square.fill", server: "rtmps://live-api-s.facebook.com:443/rtmp",
                     hint: "Facebook › Video trực tiếp › Phần mềm phát trực tiếp › Khoá luồng."),
        StreamPreset(id: "tiktok", name: "TikTok", icon: "music.note", server: "",
                     hint: "TikTok LIVE Center / LIVE Studio › Khoá luồng: dán Server URL và Stream key (mỗi phiên một server; tài khoản cần được TikTok cấp quyền phát bằng khoá).",
                     vertical: true),
        StreamPreset(id: "instagram", name: "Instagram", icon: "camera.circle.fill", server: "",
                     hint: "instagram.com (trình duyệt máy tính) › Tạo › Video trực tiếp › copy URL luồng + Khoá luồng (mỗi phiên khác nhau, dùng rtmps).",
                     vertical: true),
        StreamPreset(id: "twitch", name: "Twitch", icon: "gamecontroller.fill", server: "rtmp://live.twitch.tv/app",
                     hint: "Twitch › Creator Dashboard › Settings › Stream › Primary Stream key."),
        StreamPreset(id: "kick", name: "Kick", icon: "bolt.fill", server: "",
                     hint: "Kick › Dashboard › Settings › Stream key: dán Stream URL (rtmps://…) và Stream key."),
    ]

    /// server + "/" + key (tolerates a trailing slash, or a full URL pasted into the key field).
    static func join(server: String, key: String) -> String {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.hasPrefix("rtmp://") || k.hasPrefix("rtmps://") { return k }
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s + "/" + k
    }
}


/// Last lines of a destination's diagnostic log; tap to see all and copy.
struct OutputLogView: View {
    let id: UUID
    @State private var expanded = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let lines = OutputLog.shared.get(id)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array((expanded ? lines : Array(lines.suffix(3))).enumerated()), id: \.offset) { _, l in
                        Text(verbatim: l).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(expanded ? nil : 1)
                    }
                    HStack(spacing: 12) {
                        Button(expanded ? "Thu gọn" : "Xem nhật ký") { expanded.toggle() }
                        Button("Copy nhật ký") { UIPasteboard.general.string = lines.joined(separator: "\n") }
                    }
                    .font(.caption2).buttonStyle(.borderless)
                }
            }
        }
    }
}

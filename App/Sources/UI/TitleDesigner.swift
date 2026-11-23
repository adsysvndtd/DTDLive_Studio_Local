import CoreImage
import SwiftUI
import UIKit

/// Multi-layer title designer (full screen): a large 16:9 canvas with the layers drawn exactly as on air,
/// one gesture for select / move / resize (8 handles) / rotate, snap guides, undo / redo, and an inspector
/// with properties, the layer list and saved templates.
///
/// Edits go to a local draft and are written back to the engine a moment after the last change (and on
/// close): writing the whole title list (JSON to UserDefaults + republishing the engine) on every drag
/// step is what made the first version stutter.
struct TitleDesignerSheet: View {
    @Binding var item: TitleItem
    var program: FrameStore?
    /// Program frame shape (width / height): the design is drawn 16:9 and adapted to this on air.
    var programAspect: CGFloat = 16.0 / 9.0
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var draft: TitleItem
    @State private var selected: UUID?
    @State private var undoStack: [[TitleLayer]] = []
    @State private var redoStack: [[TitleLayer]] = []
    @State private var lastCommit = Date.distantPast
    @State private var writeTask: Task<Void, Never>?
    @State private var deleted = false

    @State private var drag: Drag?
    @State private var guidesX: [CGFloat] = []
    @State private var guidesY: [CGFloat] = []
    @State private var lastTap: (id: UUID, at: Date)?

    @State private var tab = 0                      // 0 tổng thể · 1 thuộc tính · 2 lớp · 3 mẫu
    @State private var groupBase: [TitleLayer]?     // layers when a whole-design slider drag began
    @FocusState private var textFocused: Bool
    @State private var bigStep = false
    @State private var showName = false
    @State private var templateName = ""
    @State private var pickImage = false
    @State private var confirmDelete = false
    @State private var fxPreview: Date?
    @State private var fxOut = false
    @State private var fxRenderer = TitleRenderer()
    /// Last drawn design per view: the canvas is drawn again only when the layers or its size change
    /// (not on every unrelated state change such as typing a layer name or a selection change).
    @State private var canvasCache = DesignImageCache()
    @State private var pgmCache = DesignImageCache()
    @AppStorage("ui.titleDesigner.snap") private var snapOn = true
    @AppStorage("ui.titleDesigner.bg") private var bgMode = 0

    init(item: Binding<TitleItem>, program: FrameStore?, programAspect: CGFloat = 16.0 / 9.0, onDelete: @escaping () -> Void) {
        _item = item
        self.program = program
        self.programAspect = programAspect
        self.onDelete = onDelete
        _draft = State(initialValue: item.wrappedValue)
    }

    private struct Drag {
        enum Mode { case none, move, resize(Int, Int), rotate, groupMove, groupScale(Int, Int) }
        var mode: Mode
        var origin: TitleLayer?
        var base: [TitleLayer] = []                 // whole-design gestures: layers at the start
        var bounds: CGRect = .zero                  // … and their box
        var startAngle: CGFloat = 0
        var committed = false
        var moved = false
    }

    private struct Handle: Hashable { let sx: Int; let sy: Int }
    /// Corners first: they win over the edge handles where they overlap.
    private static let handles: [Handle] = [
        Handle(sx: -1, sy: -1), Handle(sx: 1, sy: -1), Handle(sx: -1, sy: 1), Handle(sx: 1, sy: 1),
        Handle(sx: 0, sy: -1), Handle(sx: 0, sy: 1), Handle(sx: -1, sy: 0), Handle(sx: 1, sy: 0)
    ]
    /// Distance of the rotation knob above the top edge, in screen points.
    private static let rotKnob: CGFloat = 30
    private static let swatches = ["#FFFFFF", "#000000", "#E30613", "#FFC400", "#0A84FF", "#30D158"]
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private var layers: [TitleLayer] { draft.layers ?? [] }
    private var selectedLayer: TitleLayer? { selected.flatMap { id in layers.first { $0.id == id } } }

    // MARK: Body

    var body: some View {
        NavigationStack {
            GeometryReader { g in
                if g.size.width >= 820 {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            toolbar
                            canvasArea
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        inspector.frame(width: min(390, g.size.width * 0.36))
                    }
                } else {
                    VStack(spacing: 0) {
                        toolbar
                        canvasArea.layoutPriority(1)
                        Divider()
                        inspector.frame(height: max(280, g.size.height * 0.46))
                    }
                }
            }
            .background(DS.bg)
            .navigationTitle("Thiết kế Title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Xoá title", systemImage: "trash") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { flush(); dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .onChange(of: draft) { _, _ in scheduleWrite() }
        .onDisappear { flush() }
        .confirmationDialog("Xoá title này?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Xoá", role: .destructive) { deleted = true; writeTask?.cancel(); onDelete(); dismiss() }
        }
        .alert("Tên mẫu", isPresented: $showName) {
            TextField("Tên", text: $templateName)
            Button("Lưu") {
                let n = templateName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { TitleTemplateStore.save(n, layers) }
            }
            Button("Huỷ", role: .cancel) {}
        }
        .sheet(isPresented: $pickImage) {
            LibraryImagePicker { name in
                mutateSelected { l in
                    l.imageFile = name
                    if let img = TitleRenderer.libraryImage(name), img.size.width > 0 {   // box takes the picture's proportions
                        let c = l.center
                        l.h = (l.w * img.size.height / img.size.width).rounded()
                        l.y = (c.y - l.h / 2).rounded()
                    }
                }
            }
        }
    }

    // MARK: Write-back

    private func scheduleWrite() {
        writeTask?.cancel()
        writeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, !deleted else { return }
            item = draft
        }
    }

    private func flush() {
        writeTask?.cancel(); writeTask = nil
        if !deleted, item != draft { item = draft }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tool("arrow.uturn.backward", "Hoàn tác", disabled: undoStack.isEmpty) { undo() }
                tool("arrow.uturn.forward", "Làm lại", disabled: redoStack.isEmpty) { redo() }
                separator
                Menu {
                    ForEach(TitleLayer.Kind.allCases) { k in
                        Button { add(k) } label: { Label(k.label, systemImage: k.icon) }
                    }
                } label: { toolLabel("plus.square", "Thêm lớp", tint: DS.accent) }
                if tab != 0, let l = selectedLayer {
                    separator
                    tool("plus.square.on.square", "Nhân bản") { duplicate(l.id) }
                    tool("trash", "Xoá lớp", tint: DS.pgm) { delete(l.id) }
                    tool("square.3.layers.3d.top.filled", "Lên trước") { reorder(l.id, by: 1) }
                    tool("square.3.layers.3d.bottom.filled", "Ra sau") { reorder(l.id, by: -1) }
                    Menu {
                        Button { align(.left) } label: { Label("Căn trái", systemImage: "align.horizontal.left") }
                        Button { align(.centerX) } label: { Label("Giữa ngang", systemImage: "align.horizontal.center") }
                        Button { align(.right) } label: { Label("Căn phải", systemImage: "align.horizontal.right") }
                        Divider()
                        Button { align(.top) } label: { Label("Căn trên", systemImage: "align.vertical.top") }
                        Button { align(.centerY) } label: { Label("Giữa dọc", systemImage: "align.vertical.center") }
                        Button { align(.bottom) } label: { Label("Căn dưới", systemImage: "align.vertical.bottom") }
                    } label: { toolLabel("align.horizontal.center", "Căn chỉnh") }
                }
                separator
                tool(snapOn ? "squareshape.split.3x3" : "square.dashed", "Bắt dóng", on: snapOn) { snapOn.toggle() }
                Menu {
                    Picker("Nền khung vẽ", selection: $bgMode) {
                        Text("Hình Program").tag(0)
                        Text("Ô vuông (trong suốt)").tag(1)
                        Text("Đen").tag(2)
                        Text("Xám").tag(3)
                    }
                } label: { toolLabel("photo.on.rectangle", "Nền") }
                tool(fxPreview == nil ? "play.circle" : "stop.circle", "Xem thử", on: fxPreview != nil) { toggleFXPreview() }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(DS.surface.opacity(0.6))
    }

    private var separator: some View { Rectangle().fill(DS.stroke).frame(width: 1, height: 30).padding(.horizontal, 4) }

    private func tool(_ icon: String, _ title: String, tint: Color = .white, on: Bool = false, disabled: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) { toolLabel(icon, title, tint: tint, on: on) }
            .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.35 : 1)
    }

    private func toolLabel(_ icon: String, _ title: String, tint: Color = .white, on: Bool = false) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 17))
            Text(LocalizedStringKey(title)).font(.system(size: 10)).lineLimit(1)
        }
        .foregroundStyle(on ? Color.black : tint)
        .frame(minWidth: 58).frame(height: 44)
        .background(on ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
    }

    // MARK: Canvas

    private var canvasArea: some View {
        GeometryReader { g in canvas(W: g.size.width) }
            .aspectRatio(16 / 9, contentMode: .fit)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func canvas(W: CGFloat) -> some View {
        let H = W * 9 / 16, s = W / 1920
        return ZStack(alignment: .topLeading) {
            canvasBackground
            if let start = fxPreview {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    fxFrame(start: start, size: CGSize(width: W, height: H))
                }
            } else if let img = canvasCache.image(draft, CGSize(width: W, height: H)) {
                Image(uiImage: img).resizable().frame(width: W, height: H)
            }
            // title-safe area (90 %)
            Rectangle().stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .frame(width: W * 0.9, height: H * 0.9).offset(x: W * 0.05, y: H * 0.05)
                .allowsHitTesting(false)
            ForEach(guidesX, id: \.self) { x in
                Rectangle().fill(Color.pink).frame(width: 1, height: H).offset(x: x * s).allowsHitTesting(false)
            }
            ForEach(guidesY, id: \.self) { y in
                Rectangle().fill(Color.pink).frame(width: W, height: 1).offset(y: y * s).allowsHitTesting(false)
            }
            if fxPreview == nil {
                if tab == 0 { groupOverlay(s: s, W: W, H: H) } else { selectionOverlay(s: s, W: W, H: H) }
            }
            if abs(programAspect - 16.0 / 9.0) > 0.02 {
                Text(verbatim: L("PGM") + " " + Self.aspectLabel(programAspect) + " · " + L("lower third tự co theo khung, xem ở tab Tổng thể"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.black.opacity(0.6), in: Capsule()).padding(6)
                    .allowsHitTesting(false)
            }
            if layers.isEmpty {
                Text("Bấm “Thêm lớp” để bắt đầu thiết kế").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    .frame(width: W, height: H)
            }
        }
        .frame(width: W, height: H)
        .clipped()
        .contentShape(Rectangle())
        .gesture(canvasGesture(s: s))
        .overlay(Rectangle().stroke(DS.stroke))
    }

    @ViewBuilder private var canvasBackground: some View {
        switch bgMode {
        case 1: CheckerBackground()
        case 2: Color.black
        case 3: Color(white: 0.45)
        default:
            if let program { MonitorView(store: program, maxFPS: 10) } else { Color.black }
        }
    }

    @ViewBuilder private func selectionOverlay(s: CGFloat, W: CGFloat, H: CGFloat) -> some View {
        if let l = selectedLayer {
            let r = CGRect(x: l.x * s, y: l.y * s, width: max(2, l.w * s), height: max(2, l.h * s))
            ZStack {
                Rectangle().stroke(l.locked ? Color.orange : Color.cyan,
                                   style: StrokeStyle(lineWidth: 1.5, dash: l.locked ? [5, 3] : []))
                if !l.locked {
                    ForEach(visibleHandles(l, s: s), id: \.self) { hd in
                        handleDot.position(x: r.width / 2 + CGFloat(hd.sx) * r.width / 2,
                                           y: r.height / 2 + CGFloat(hd.sy) * r.height / 2)
                    }
                    Rectangle().fill(Color.cyan).frame(width: 1, height: Self.rotKnob)
                        .position(x: r.width / 2, y: -Self.rotKnob / 2)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Color.cyan, in: Circle())
                        .position(x: r.width / 2, y: -Self.rotKnob)
                }
            }
            .frame(width: r.width, height: r.height)
            .rotationEffect(.degrees(l.rotation))
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
            if drag != nil {
                Text(verbatim: readout(l))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.black.opacity(0.75), in: Capsule()).foregroundStyle(.white)
                    .position(x: min(max(r.midX, 70), W - 70), y: min(r.maxY + 18, H - 12))
                    .allowsHitTesting(false)
            }
        }
    }

    private var handleDot: some View {
        Circle().fill(Color.white).overlay(Circle().stroke(Color.cyan, lineWidth: 2)).frame(width: 14, height: 14)
    }

    private func readout(_ l: TitleLayer) -> String {
        if case .rotate = drag?.mode { return "\(Int(l.rotation))°" }
        if case .resize = drag?.mode {
            return l.kind == .text ? "\(Int(l.w)) × \(Int(l.h)) · \(Int(l.fontSize)) pt" : "\(Int(l.w)) × \(Int(l.h))"
        }
        return "X \(Int(l.x))  Y \(Int(l.y))"
    }

    /// Handles drawn and hit-tested: edge handles are left out when that side is too short to grab.
    private func visibleHandles(_ l: TitleLayer, s: CGFloat) -> [Handle] {
        Self.handles.filter { hd in
            if hd.sx == 0 && l.h * s < 24 { return false }       // top / bottom edges of a thin box
            if hd.sy == 0 && l.w * s < 24 { return false }
            if hd.sx == 0 || hd.sy == 0 { return min(l.w, l.h) * s >= 44 }
            return true
        }
    }

    // MARK: Gesture (one DragGesture for the whole canvas; positions in design space = view / s)

    private func canvasGesture(s: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil { begin(at: v.startLocation, s: s) }
                dragChanged(v, s: s)
            }
            .onEnded { _ in dragEnded() }
    }

    private func begin(at p: CGPoint, s: CGFloat) {
        guard fxPreview == nil else { drag = Drag(mode: .none); return }
        let d = CGPoint(x: p.x / s, y: p.y / s)
        if tab == 0 { beginGroup(at: d, s: s); return }
        // 1. a handle of the selected layer
        if let l = selectedLayer, !l.locked, !l.hidden, let m = handleHit(l, d, s: s) {
            var g = Drag(mode: m, origin: l)
            if case .rotate = m { g.startAngle = angle(d, l.center) }
            drag = g; return
        }
        // 2. inside the selected layer (lets a layer chosen in the list be dragged even when others cover it)
        if let l = selectedLayer, !l.locked, !l.hidden, contains(l, d, tol: 0) {
            drag = Drag(mode: .move, origin: l); return
        }
        // 3. the top layer under the finger
        if let hit = layers.reversed().first(where: { !$0.hidden && !$0.locked && contains($0, d, tol: 6 / s) }) {
            selected = hit.id
            drag = Drag(mode: .move, origin: hit)
        } else {
            drag = Drag(mode: .none, origin: nil)
        }
    }

    private func dragChanged(_ v: DragGesture.Value, s: CGFloat) {
        guard var g = drag else { return }
        if case .none = g.mode { return }
        if case .groupMove = g.mode { groupChanged(&g, v, s: s); return }
        if case .groupScale = g.mode { groupChanged(&g, v, s: s); return }
        guard let o = g.origin else { return }
        if !g.moved && hypot(v.translation.width, v.translation.height) < 3 { return }
        g.moved = true
        if !g.committed { commit(); g.committed = true }
        drag = g
        let d = CGPoint(x: v.location.x / s, y: v.location.y / s)
        switch g.mode {
        case .none: break
        case .move: moveLayer(o, by: CGSize(width: v.translation.width / s, height: v.translation.height / s), s: s)
        case .resize(let sx, let sy): resizeLayer(o, sx: sx, sy: sy, to: d)
        case .rotate: rotateLayer(o, to: d, startAngle: g.startAngle)
        case .groupMove, .groupScale: break
        }
    }

    private func dragEnded() {
        let g = drag
        drag = nil; guidesX = []; guidesY = []
        guard let g, !g.moved else { return }
        // a tap
        if tab == 0 {                                   // whole-design mode: tap a part to edit it on its own
            if let o = g.origin { selected = o.id; tab = 1 }
            return
        }
        guard let o = g.origin else { selected = nil; return }
        if o.kind == .text, let lt = lastTap, lt.id == o.id, Date().timeIntervalSince(lt.at) < 0.45 {
            tab = 1; textFocused = true; lastTap = nil         // double tap on text: edit it
        } else {
            lastTap = (o.id, Date())
        }
    }

    private func moveLayer(_ o: TitleLayer, by t: CGSize, s: CGFloat) {
        var nx = o.x + t.width, ny = o.y + t.height
        var gx: [CGFloat] = [], gy: [CGFloat] = []
        if snapOn {
            let thr = 8 / s
            var tx: [CGFloat] = [0, 96, 960, 1824, 1920]
            var ty: [CGFloat] = [0, 54, 540, 1026, 1080]
            for l in layers where l.id != o.id && !l.hidden {
                tx += [l.x, l.x + l.w / 2, l.x + l.w]
                ty += [l.y, l.y + l.h / 2, l.y + l.h]
            }
            if let sn = Self.snap([nx, nx + o.w / 2, nx + o.w], to: tx, thr: thr) { nx += sn.delta; gx = [sn.at] }
            if let sn = Self.snap([ny, ny + o.h / 2, ny + o.h], to: ty, thr: thr) { ny += sn.delta; gy = [sn.at] }
        }
        guidesX = gx; guidesY = gy
        let fx = nx.rounded(), fy = ny.rounded()
        update(o.id) { $0.x = fx; $0.y = fy }
    }

    private static func snap(_ src: [CGFloat], to targets: [CGFloat], thr: CGFloat) -> (delta: CGFloat, at: CGFloat)? {
        var best: (delta: CGFloat, at: CGFloat)?
        for a in src {
            for t in targets {
                let d = t - a
                if abs(d) <= thr, abs(d) < abs(best?.delta ?? .infinity) { best = (d, t) }
            }
        }
        return best
    }

    /// Resize from handle (sx, sy) with the opposite side fixed, in the layer's own (rotated) axes.
    /// Text: corners scale the lettering, the side edges re-wrap it.
    private func resizeLayer(_ o: TitleLayer, sx: Int, sy: Int, to d: CGPoint) {
        let c0 = o.center
        let local = Self.rot(CGPoint(x: d.x - c0.x, y: d.y - c0.y), -o.rotation)
        let fx = CGFloat(sx), fy = CGFloat(sy)
        let ax = -fx * o.w / 2, ay = -fy * o.h / 2
        var nw = o.w, nh = o.h
        if sx != 0 { nw = max(10, fx * (local.x - ax)) }
        if sy != 0 { nh = max(4, fy * (local.y - ay)) }
        let corner = sx != 0 && sy != 0
        if corner && (o.kind == .text || o.lockAspect) {
            let k = max(nw / max(o.w, 1), nh / max(o.h, 1))
            nw = o.w * k; nh = o.h * k
        }
        var l = o
        if o.kind == .text {
            if corner {
                let k = nw / max(o.w, 1)
                l.fontSize = max(6, (o.fontSize * k).rounded())
                l.letterSpacing = o.letterSpacing * k
                l.textStrokeWidth = o.textStrokeWidth * k
            } else if sy == 0 {
                l.fitText = false; l.w = nw
                nh = TitleRenderer.fittedHeight(l)
            } else {
                l.fitText = false
            }
        }
        let lcx = sx == 0 ? 0 : ax + fx * nw / 2
        let lcy = sy == 0 ? 0 : ay + fy * nh / 2
        let cc = Self.rot(CGPoint(x: lcx, y: lcy), o.rotation)
        let nc = CGPoint(x: c0.x + cc.x, y: c0.y + cc.y)
        l.w = nw.rounded(); l.h = nh.rounded()
        l.x = (nc.x - nw / 2).rounded(); l.y = (nc.y - nh / 2).rounded()
        let result = l
        update(o.id) { $0 = result }
    }

    private func rotateLayer(_ o: TitleLayer, to d: CGPoint, startAngle: CGFloat) {
        var r = o.rotation + angle(d, o.center) - startAngle
        r = r.truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 }
        if r < -180 { r += 360 }
        for t in stride(from: -180.0, through: 180.0, by: 45.0) where abs(r - CGFloat(t)) < 4 { r = CGFloat(t) }
        let fr = r.rounded()
        update(o.id) { $0.rotation = fr }
    }

    private func angle(_ p: CGPoint, _ c: CGPoint) -> CGFloat { atan2(p.y - c.y, p.x - c.x) * 180 / .pi }

    private static func rot(_ p: CGPoint, _ deg: CGFloat) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: p.x * cos(a) - p.y * sin(a), y: p.x * sin(a) + p.y * cos(a))
    }

    private func contains(_ l: TitleLayer, _ d: CGPoint, tol: CGFloat) -> Bool {
        let p = Self.rot(CGPoint(x: d.x - l.center.x, y: d.y - l.center.y), -l.rotation)
        return abs(p.x) <= l.w / 2 + tol && abs(p.y) <= l.h / 2 + tol
    }

    private func handleHit(_ l: TitleLayer, _ d: CGPoint, s: CGFloat) -> Drag.Mode? {
        let p = Self.rot(CGPoint(x: d.x - l.center.x, y: d.y - l.center.y), -l.rotation)
        let small = min(l.w, l.h) * s < 70
        let r = (small ? 14 : 22) / s
        if hypot(p.x, p.y + l.h / 2 + Self.rotKnob / s) <= 24 / s { return .rotate }
        for hd in visibleHandles(l, s: s) {
            let hx = CGFloat(hd.sx) * l.w / 2, hy = CGFloat(hd.sy) * l.h / 2
            if hypot(p.x - hx, p.y - hy) <= r { return .resize(hd.sx, hd.sy) }
        }
        return nil
    }

    // MARK: Whole-design gestures (tab Tổng thể)

    private static let groupCorners: [Handle] = [
        Handle(sx: -1, sy: -1), Handle(sx: 1, sy: -1), Handle(sx: -1, sy: 1), Handle(sx: 1, sy: 1)
    ]

    /// Tab Tổng thể: drag inside the design moves all layers, a corner scales all of them together
    /// (from the opposite corner). A tap picks the part under the finger for editing on its own.
    private func beginGroup(at d: CGPoint, s: CGFloat) {
        guard let g = TitleLayer.groupBounds(layers) else { drag = Drag(mode: .none); return }
        let top = layers.reversed().first { !$0.hidden && contains($0, d, tol: 4 / s) }
        for c in Self.groupCorners {
            let p = CGPoint(x: c.sx < 0 ? g.minX : g.maxX, y: c.sy < 0 ? g.minY : g.maxY)
            if hypot(d.x - p.x, d.y - p.y) <= 26 / s {
                drag = Drag(mode: .groupScale(c.sx, c.sy), origin: top, base: layers, bounds: g)
                return
            }
        }
        if g.insetBy(dx: -8 / s, dy: -8 / s).contains(d) {
            drag = Drag(mode: .groupMove, origin: top, base: layers, bounds: g)
        } else {
            drag = Drag(mode: .none)
        }
    }

    private func groupChanged(_ g: inout Drag, _ v: DragGesture.Value, s: CGFloat) {
        if !g.moved && hypot(v.translation.width, v.translation.height) < 3 { return }
        g.moved = true
        if !g.committed { commit(); g.committed = true }
        drag = g
        let b = g.bounds
        switch g.mode {
        case .groupMove:
            var dx = v.translation.width / s, dy = v.translation.height / s
            var gx: [CGFloat] = [], gy: [CGFloat] = []
            if snapOn {
                let thr = 8 / s
                if let sn = Self.snap([b.minX + dx, b.midX + dx, b.maxX + dx], to: [0, 96, 960, 1824, 1920], thr: thr) {
                    dx += sn.delta; gx = [sn.at]
                }
                if let sn = Self.snap([b.minY + dy, b.midY + dy, b.maxY + dy], to: [0, 54, 540, 1026, 1080], thr: thr) {
                    dy += sn.delta; gy = [sn.at]
                }
            }
            guidesX = gx; guidesY = gy
            draft.layers = TitleLayer.moved(g.base, dx: dx.rounded(), dy: dy.rounded())
        case .groupScale(let sx, let sy):
            let a = CGPoint(x: sx < 0 ? b.maxX : b.minX, y: sy < 0 ? b.maxY : b.minY)
            let d = CGPoint(x: v.location.x / s, y: v.location.y / s)
            let raw = max(abs(d.x - a.x) / max(b.width, 1), abs(d.y - a.y) / max(b.height, 1))
            draft.layers = TitleLayer.scaled(g.base, by: min(max(raw, 0.2), 5), about: a)
        default:
            break
        }
    }

    @ViewBuilder private func groupOverlay(s: CGFloat, W: CGFloat, H: CGFloat) -> some View {
        if let g = TitleLayer.groupBounds(layers) {
            let r = CGRect(x: g.minX * s, y: g.minY * s, width: max(2, g.width * s), height: max(2, g.height * s))
            ZStack(alignment: .topLeading) {
                Rectangle().stroke(DS.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .frame(width: r.width, height: r.height)
                ForEach(Self.groupCorners, id: \.self) { c in
                    RoundedRectangle(cornerRadius: 3).fill(DS.accent)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1.5))
                        .frame(width: 16, height: 16)
                        .position(x: c.sx < 0 ? 0 : r.width, y: c.sy < 0 ? 0 : r.height)
                }
            }
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
            Text(verbatim: groupReadout(g))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.black.opacity(0.75), in: Capsule()).foregroundStyle(.white)
                .position(x: min(max(r.midX, 90), W - 90), y: r.minY > 34 ? r.minY - 16 : min(r.maxY + 16, H - 12))
                .allowsHitTesting(false)
        }
    }

    private func groupReadout(_ g: CGRect) -> String {
        if let d = drag, case .groupScale = d.mode, d.bounds.height > 0 {
            return "\(Int((g.height / d.bounds.height * 100).rounded()))%"
        }
        if drag != nil { return "X \(Int(g.minX))  Y \(Int(g.minY))" }
        return L("Tổng thể") + " · \(Int(g.width)) × \(Int(g.height))"
    }

    private static func aspectLabel(_ a: CGFloat) -> String {
        let known: [(CGFloat, String)] = [(16.0 / 9, "16:9"), (9.0 / 16, "9:16"), (4.0 / 3, "4:3"), (3.0 / 4, "3:4"),
                                          (1, "1:1"), (4.0 / 5, "4:5"), (21.0 / 9, "21:9")]
        for (v, n) in known where abs(v - a) < 0.02 { return n }
        return String(format: "%.2f:1", a)
    }

    // MARK: Edit model (undo / redo)

    private func commit() {
        undoStack.append(layers)
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
        lastCommit = Date()
    }

    /// Inspector edits: one undo step per burst of changes (a slider drag, typing a word…).
    private func commitCoalesced() {
        if Date().timeIntervalSince(lastCommit) > 0.8 { commit() } else { lastCommit = Date() }
    }

    private func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(layers)
        draft.layers = prev
        if let s = selected, !prev.contains(where: { $0.id == s }) { selected = nil }
        lastCommit = .distantPast
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(layers)
        draft.layers = next
        if let s = selected, !next.contains(where: { $0.id == s }) { selected = nil }
        lastCommit = .distantPast
    }

    private func update(_ id: UUID, _ f: (inout TitleLayer) -> Void) {
        guard var ls = draft.layers, let i = ls.firstIndex(where: { $0.id == id }) else { return }
        f(&ls[i])
        draft.layers = ls
    }

    private func mutateSelected(_ f: (inout TitleLayer) -> Void) {
        guard let id = selected else { return }
        commitCoalesced()
        update(id) { l in
            f(&l)
            if l.kind == .text && l.fitText { TitleRenderer.refit(&l) }
        }
    }

    /// Binding to a property of the selected layer (one undo step per burst; text boxes re-fit).
    private func prop<T>(_ kp: WritableKeyPath<TitleLayer, T>) -> Binding<T> {
        Binding(get: { (selectedLayer ?? TitleLayer())[keyPath: kp] },
                set: { v in mutateSelected { $0[keyPath: kp] = v } })
    }

    private func add(_ kind: TitleLayer.Kind) {
        commit()
        var l = TitleLayer.make(kind)
        let same = layers.filter { $0.kind == kind }.count          // cascade so new layers don't stack exactly
        l.x += CGFloat(same * 24); l.y += CGFloat(same * 24)
        var ls = layers; ls.append(l); draft.layers = ls
        selected = l.id; tab = 1
        if kind == .text { textFocused = true }
        if kind == .image { pickImage = true }
    }

    private func duplicate(_ id: UUID) {
        guard var l = layers.first(where: { $0.id == id }) else { return }
        commit()
        l.id = UUID(); l.x += 24; l.y += 24; l.locked = false
        var ls = layers
        let i = (ls.firstIndex { $0.id == id } ?? ls.count - 1) + 1
        ls.insert(l, at: min(i, ls.count)); draft.layers = ls
        selected = l.id
    }

    private func delete(_ id: UUID) {
        commit()
        draft.layers = layers.filter { $0.id != id }
        if selected == id { selected = nil }
    }

    /// +1 = one step to the front, -1 = one step back; ±100 = all the way.
    private func reorder(_ id: UUID, by d: Int) {
        var ls = layers
        guard let i = ls.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(i + d, 0), ls.count - 1)
        guard j != i else { return }
        commit()
        let l = ls.remove(at: i); ls.insert(l, at: j)
        draft.layers = ls
    }

    private enum Align { case left, centerX, right, top, centerY, bottom }

    /// Edges go to the title-safe area (5 % in), centres to the frame centre.
    private func align(_ a: Align) {
        guard let id = selected else { return }
        commit()
        update(id) { l in
            switch a {
            case .left: l.x = 96
            case .centerX: l.x = 960 - l.w / 2
            case .right: l.x = 1824 - l.w
            case .top: l.y = 54
            case .centerY: l.y = 540 - l.h / 2
            case .bottom: l.y = 1026 - l.h
            }
            l.x = l.x.rounded(); l.y = l.y.rounded()
        }
    }

    private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        let k: CGFloat = bigStep ? 10 : 1
        mutateSelected { $0.x += dx * k; $0.y += dy * k }
    }

    // MARK: Effect preview

    private func toggleFXPreview() {
        if fxPreview != nil { fxPreview = nil; return }
        let dur = (draft.fx ?? .fadeSlide) == .cut ? 0 : (draft.fxDuration ?? 0.35)
        var on = draft; on.visible = true
        let r = TitleRenderer()
        r.visibilityChanged(on)
        fxRenderer = r
        fxOut = false
        let start = Date()
        fxPreview = start
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((dur + 1.2) * 1_000_000_000))
            guard fxPreview == start else { return }
            var off = draft; off.visible = false
            r.visibilityChanged(off)       // hiddenAt first, then the frames ask for visible = false
            fxOut = true
            try? await Task.sleep(nanoseconds: UInt64((dur + 0.4) * 1_000_000_000))
            if fxPreview == start { fxPreview = nil; fxOut = false }
        }
    }

    @ViewBuilder private func fxFrame(start: Date, size: CGSize) -> some View {
        if let img = fxImage(size: size) {
            Image(uiImage: img).resizable().frame(width: size.width, height: size.height)
        }
    }

    /// One frame of the in / out preview, through a private renderer (same code path as on air).
    private func fxImage(size: CGSize) -> UIImage? {
        var it = draft
        it.visible = !fxOut
        guard let ci = fxRenderer.render([it], canvas: size, now: HostClock.now),
              let cg = Self.ciContext.createCGImage(ci, from: CGRect(origin: .zero, size: size)) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Tổng thể").tag(0)
                Text("Từng lớp").tag(1)
                Text("Lớp (\(layers.count))").tag(2)
                Text("Mẫu").tag(3)
            }
            .pickerStyle(.segmented).padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case 0: overviewTab
                    case 2: layersTab
                    case 3: templatesTab
                    default: propertiesTab
                    }
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(DS.bg)
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title)).font(.system(size: 11, weight: .bold)).foregroundStyle(DS.text3)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radius))
    }

    // MARK: Tab Tổng thể (the whole lower third at once)

    @ViewBuilder private var overviewTab: some View {
        if layers.isEmpty {
            card("Chưa có thiết kế") {
                Text("Thêm lớp từ thanh công cụ, hoặc nạp một mẫu lower third có sẵn.")
                    .font(.system(size: 12)).foregroundStyle(DS.text2)
                Button { tab = 3 } label: { Label("Mở tab Mẫu", systemImage: "square.grid.2x2") }
                    .font(.system(size: 13))
            }
        } else {
            Text("Kéo trên khung vẽ để dời cả lower third, kéo góc để đổi cỡ đồng bộ. Chạm vào một phần để sửa riêng phần đó.")
                .font(.system(size: 11)).foregroundStyle(DS.text3)
            sizeCard
            fontCard
            textColorsCard
            fillColorsCard
            effectCard
            if abs(programAspect - 16.0 / 9.0) > 0.02 { programPreviewCard }
        }
    }

    private var sizeCard: some View {
        card("Kích thước & vị trí") {
            groupSlider("Cỡ tổng thể", sizeBinding, 0.04...0.6)
            Text("Mọi lớp to / nhỏ cùng lúc, kể cả chữ (số = chiều cao so với khung hình).")
                .font(.system(size: 10)).foregroundStyle(DS.text3)
            groupSlider("Độ dài", lengthBinding, 0.12...0.98)
            Text("Thanh nền dài / ngắn lại, chữ giữ nguyên cỡ.")
                .font(.system(size: 10)).foregroundStyle(DS.text3)
            groupSlider("Cao / thấp", heightPosBinding, 0...0.92)
            HStack(spacing: 6) {
                Text("Dọc").font(.system(size: 12)).foregroundStyle(DS.text3).frame(width: 36, alignment: .leading)
                presetButton("Sát đáy") { place(.bottom) }
                presetButton("Thấp") { place(.low) }
                presetButton("Giữa khung") { place(.middle) }
                presetButton("Trên cùng") { place(.top) }
            }
            HStack(spacing: 6) {
                Text("Ngang").font(.system(size: 12)).foregroundStyle(DS.text3).frame(width: 36, alignment: .leading)
                presetButton("Trái") { place(.left) }
                presetButton("Chính giữa") { place(.centre) }
                presetButton("Phải") { place(.right) }
            }
        }
    }

    private var fontCard: some View {
        card("Phông chữ (tất cả chữ)") {
            HStack(spacing: 6) {
                Picker("Phông", selection: Binding(get: { textLayers.first?.fontDesign ?? 0 },
                                                   set: { v in applyTexts { $0.fontDesign = v } })) {
                    Text("Hệ thống").tag(0); Text("Bo tròn").tag(1); Text("Có chân").tag(2); Text("Đơn cách").tag(3)
                }
                Picker("Độ rộng chữ", selection: Binding(get: { textLayers.first?.fontWidth ?? 0 },
                                                         set: { v in applyTexts { $0.fontWidth = v } })) {
                    Text("Thường").tag(0); Text("Hẹp").tag(1); Text("Rất hẹp").tag(2); Text("Rộng ra").tag(3)
                }
            }
            .pickerStyle(.menu).font(.system(size: 13))
            HStack(spacing: 6) {
                Text("Cỡ chữ").font(.system(size: 13)).foregroundStyle(DS.text2)
                Spacer(minLength: 4)
                presetButton("Nhỏ hơn", icon: "textformat.size.smaller") {
                    applyTexts { $0.fontSize = max(6, ($0.fontSize * 0.92).rounded()) }
                }
                presetButton("To hơn", icon: "textformat.size.larger") {
                    applyTexts { $0.fontSize = min(400, ($0.fontSize * 1.08).rounded()) }
                }
            }
            Toggle("Đổ bóng cho chữ", isOn: Binding(get: { textLayers.contains { $0.shadow } },
                                                    set: { on in applyTexts { $0.shadow = on } }))
                .font(.system(size: 13))
            Toggle("Chữ in hoa", isOn: Binding(get: { !textLayers.isEmpty && textLayers.allSatisfy { $0.uppercase } },
                                               set: { on in applyTexts { $0.uppercase = on } }))
                .font(.system(size: 13))
        }
    }

    private var textColorsCard: some View {
        card("Màu chữ") {
            if textLayers.isEmpty {
                Text("Chưa có lớp chữ").font(.system(size: 12)).foregroundStyle(DS.text3)
            }
            ForEach(textLayers) { l in
                colorRow(layerTitle(l), Binding(get: { layers.first { $0.id == l.id }?.textHex ?? "#FFFFFF" },
                                                set: { h in commitCoalesced(); update(l.id) { $0.textHex = h } }))
            }
        }
    }

    private var fillColorsCard: some View {
        card("Màu nền & màu nhấn") {
            if filledLayers.isEmpty {
                Text("Chưa có lớp có màu nền").font(.system(size: 12)).foregroundStyle(DS.text3)
            }
            ForEach(filledLayers) { l in
                colorRow(layerTitle(l), Binding(get: { layers.first { $0.id == l.id }?.fillHex ?? "#000000" },
                                                set: { h in commitCoalesced(); update(l.id) { $0.fillHex = h } }))
                if l.id == mainFillID {
                    percentRow("Độ đục nền", Binding(get: { layers.first { $0.id == l.id }?.fillOpacity ?? 1 },
                                                     set: { v in commitCoalesced(); update(l.id) { $0.fillOpacity = v } }))
                }
            }
        }
    }

    private var effectCard: some View {
        card("Hiệu ứng vào / ra") {
            Picker("Hiệu ứng", selection: Binding(get: { draft.fx ?? .fadeSlide }, set: { draft.fx = $0 })) {
                ForEach(TitleFX.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
            Picker("Thời gian", selection: Binding(get: { draft.fxDuration ?? 0.35 }, set: { draft.fxDuration = $0 })) {
                ForEach([0.2, 0.35, 0.6, 1.0, 1.5], id: \.self) { Text(verbatim: String(format: "%.2g s", $0)).tag($0) }
            }
            Button { toggleFXPreview() } label: {
                Label(LocalizedStringKey(fxPreview == nil ? "Xem thử trên khung vẽ" : "Dừng xem thử"),
                      systemImage: fxPreview == nil ? "play.circle" : "stop.circle")
            }
            .font(.system(size: 13))
        }
    }

    private var programPreviewCard: some View {
        let aspect = max(programAspect, 0.2)
        var ph: CGFloat = 240
        var pw = ph * aspect
        if pw > 330 { pw = 330; ph = pw / aspect }
        let img = pgmCache.image(draft, CGSize(width: pw * 2, height: ph * 2))
        return card(L("Trên PGM") + " (" + Self.aspectLabel(aspect) + ")") {
            ZStack {
                Color(white: 0.2)
                if let img { Image(uiImage: img).resizable() }
            }
            .frame(width: pw, height: ph)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: .infinity)
            Text("Thiết kế vẽ ở khung 16:9. PGM có tỉ lệ khác nên lower third tự co cho vừa khung và giữ khoảng cách tới mép dưới.")
                .font(.system(size: 10)).foregroundStyle(DS.text3)
        }
    }

    private var textLayers: [TitleLayer] { layers.filter { $0.kind == .text } }
    private var filledLayers: [TitleLayer] { layers.filter { $0.fillHex != nil } }
    /// The biggest filled layer: the background bar (its opacity is offered on the Tổng thể tab).
    private var mainFillID: UUID? { filledLayers.max { $0.w * $0.h < $1.w * $1.h }?.id }

    /// Change every text layer at once (one undo step per burst); fitted boxes re-fit, keeping their anchor.
    private func applyTexts(_ f: (inout TitleLayer) -> Void) {
        commitCoalesced()
        guard var ls = draft.layers else { return }
        for i in ls.indices where ls[i].kind == .text {
            f(&ls[i])
            if ls[i].fitText { TitleRenderer.refit(&ls[i]) }
        }
        draft.layers = ls
    }

    /// Whole-design sliders: a drag works from the layers as they were when it began (no rounding drift).
    private func groupSlider(_ title: String, _ v: Binding<CGFloat>, _ r: ClosedRange<CGFloat>) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title)).font(.system(size: 13)).foregroundStyle(DS.text2).frame(width: 86, alignment: .leading)
            Slider(value: v, in: r, onEditingChanged: { editing in
                if editing { commit(); groupBase = layers } else { groupBase = nil }
            })
            .tint(DS.accent).controlSize(.small)
            Text(verbatim: "\(Int((v.wrappedValue * 100).rounded()))%").font(.system(size: 12).monospacedDigit())
                .foregroundStyle(DS.text3).frame(width: 44, alignment: .trailing)
        }
    }

    /// Height of the design as a share of the frame; setting it scales every layer from the design's anchor.
    private var sizeBinding: Binding<CGFloat> {
        Binding(get: { (TitleLayer.groupBounds(layers)?.height ?? 0) / 1080 },
                set: { target in
                    let base = groupBase ?? layers
                    if groupBase == nil { commitCoalesced() }
                    guard let g = TitleLayer.groupBounds(base), g.height > 0 else { return }
                    draft.layers = TitleLayer.scaled(base, by: target * 1080 / g.height, about: TitleLayer.groupAnchor(g))
                })
    }

    /// Width of the design as a share of the frame; setting it stretches the bars (lettering unchanged).
    private var lengthBinding: Binding<CGFloat> {
        Binding(get: { (TitleLayer.groupBounds(layers)?.width ?? 0) / 1920 },
                set: { target in
                    let base = groupBase ?? layers
                    if groupBase == nil { commitCoalesced() }
                    guard let g = TitleLayer.groupBounds(base), g.width > 0 else { return }
                    draft.layers = TitleLayer.stretched(base, by: target * 1920 / g.width)
                })
    }

    /// Space under the design as a share of the frame height (higher value = placed higher).
    private var heightPosBinding: Binding<CGFloat> {
        Binding(get: { 1 - (TitleLayer.groupBounds(layers)?.maxY ?? 1080) / 1080 },
                set: { v in
                    guard let g = TitleLayer.groupBounds(layers) else { return }
                    if groupBase == nil { commitCoalesced() }
                    draft.layers = TitleLayer.moved(layers, dx: 0, dy: ((1 - v) * 1080 - g.maxY).rounded())
                })
    }

    private enum Place { case bottom, low, middle, top, left, centre, right }

    private func place(_ p: Place) {
        guard let g = TitleLayer.groupBounds(layers) else { return }
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch p {
        case .bottom: dy = 1026 - g.maxY          // title-safe bottom
        case .low: dy = 950 - g.maxY
        case .middle: dy = 540 - g.midY
        case .top: dy = 54 - g.minY
        case .left: dx = 96 - g.minX
        case .centre: dx = 960 - g.midX
        case .right: dx = 1824 - g.maxX
        }
        commit()
        draft.layers = TitleLayer.moved(layers, dx: dx.rounded(), dy: dy.rounded())
    }

    private func presetButton(_ title: String, icon: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon { Label(LocalizedStringKey(title), systemImage: icon) } else { Text(LocalizedStringKey(title)) }
            }
            .font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 6).frame(maxWidth: .infinity).frame(height: 30)
            .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var propertiesTab: some View {
        if let l = selectedLayer {
            HStack(spacing: 8) {
                Image(systemName: l.kind.icon).foregroundStyle(DS.accent)
                TextField(l.kind.label, text: prop(\.name)).textFieldStyle(.roundedBorder).font(.system(size: 13))
                Button { selected = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.text3) }
                    .buttonStyle(.plain).accessibilityLabel("Bỏ chọn")
            }
            if l.kind == .text { textCard(l); textEffectsCard(l) }
            if l.kind == .image { imageCard(l) }
            if l.kind != .image { fillCard(l) }
            strokeCard(l)
            geometryCard(l)
        } else {
            card("Chưa chọn lớp") {
                Text("Chạm vào một lớp trên khung vẽ để chọn (chạm đúp vào chữ để sửa nội dung), hoặc thêm lớp mới:")
                    .font(.system(size: 12)).foregroundStyle(DS.text2)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                    ForEach(TitleLayer.Kind.allCases) { k in
                        Button { add(k) } label: {
                            Label(k.label, systemImage: k.icon).font(.system(size: 12)).lineLimit(1)
                                .frame(maxWidth: .infinity).frame(height: 34)
                                .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func textCard(_ l: TitleLayer) -> some View {
        card("Chữ") {
            TextField("Nội dung", text: prop(\.text), axis: .vertical)
                .lineLimit(1...5).textFieldStyle(.roundedBorder).focused($textFocused)
            HStack(spacing: 6) {
                Picker("Phông", selection: prop(\.fontDesign)) {
                    Text("Hệ thống").tag(0); Text("Bo tròn").tag(1); Text("Có chân").tag(2); Text("Đơn cách").tag(3)
                }
                Picker("Độ rộng chữ", selection: prop(\.fontWidth)) {
                    Text("Thường").tag(0); Text("Hẹp").tag(1); Text("Rất hẹp").tag(2); Text("Rộng ra").tag(3)
                }
            }
            .pickerStyle(.menu).font(.system(size: 13))
            Picker("Độ đậm", selection: prop(\.weight)) {
                Text("Thường").tag(0); Text("Vừa").tag(1); Text("Hơi đậm").tag(2)
                Text("Đậm").tag(3); Text("Rất đậm").tag(4); Text("Đen").tag(5)
            }
            .pickerStyle(.menu).font(.system(size: 13))
            numberRow("Cỡ chữ", prop(\.fontSize), 8...300, step: 2)
            HStack(spacing: 6) {
                chip("Nghiêng", "italic", prop(\.italic))
                chip("CHỮ HOA", "textformat", prop(\.uppercase))
                Spacer(minLength: 4)
                Picker("Căn", selection: prop(\.align)) {
                    Image(systemName: "text.alignleft").tag(0)
                    Image(systemName: "text.aligncenter").tag(1)
                    Image(systemName: "text.alignright").tag(2)
                }
                .pickerStyle(.segmented).frame(width: 120)
            }
            sliderRow("Giãn chữ", prop(\.letterSpacing), -5...30)
            colorRow("Màu chữ", prop(\.textHex))
            Toggle("Khung ôm theo chữ", isOn: prop(\.fitText)).font(.system(size: 13))
        }
    }

    private func textEffectsCard(_ l: TitleLayer) -> some View {
        card("Hiệu ứng chữ") {
            Toggle("Đổ bóng", isOn: prop(\.shadow)).font(.system(size: 13))
            if l.shadow {
                colorRow("Màu bóng", prop(\.shadowHex))
                sliderRow("Độ nhoè", prop(\.shadowBlur), 0...40)
            }
            Toggle("Viền chữ", isOn: Binding(get: { (selectedLayer?.textStrokeWidth ?? 0) > 0 },
                                             set: { on in mutateSelected { $0.textStrokeWidth = on ? 2 : 0 } }))
                .font(.system(size: 13))
            if l.textStrokeWidth > 0 {
                colorRow("Màu viền chữ", prop(\.textStrokeHex))
                sliderRow("Dày viền chữ", prop(\.textStrokeWidth), 0.5...12)
            }
        }
    }

    private func imageCard(_ l: TitleLayer) -> some View {
        card("Ảnh / logo") {
            HStack(spacing: 10) {
                Group {
                    if let n = l.imageFile, let img = TitleRenderer.libraryImage(n) {
                        Image(uiImage: img).resizable().scaledToFit()
                    } else {
                        Image(systemName: "photo").foregroundStyle(DS.text3)
                    }
                }
                .frame(width: 64, height: 44).background(CheckerBackground()).clipShape(RoundedRectangle(cornerRadius: 4))
                Button { pickImage = true } label: { Label(l.imageFile == nil ? "Chọn ảnh / logo" : "Đổi ảnh", systemImage: "photo.on.rectangle") }
                    .font(.system(size: 13))
            }
            Toggle("Giữ tỉ lệ khi kéo góc", isOn: prop(\.lockAspect)).font(.system(size: 13))
        }
    }

    private func fillCard(_ l: TitleLayer) -> some View {
        card(l.kind == .text ? "Nền sau chữ" : l.kind == .line ? "Màu đường kẻ" : "Màu tô") {
            Toggle(l.kind == .text ? "Có nền" : "Tô màu",
                   isOn: Binding(get: { selectedLayer?.fillHex != nil },
                                 set: { on in mutateSelected { $0.fillHex = on ? ($0.fillHex ?? "#101418") : nil } }))
                .font(.system(size: 13))
            if l.fillHex != nil {
                colorRow("Màu", Binding(get: { selectedLayer?.fillHex ?? "#000000" },
                                        set: { h in mutateSelected { $0.fillHex = h } }))
                percentRow("Độ đục", prop(\.fillOpacity))
                if l.kind == .roundRect || l.kind == .text { sliderRow("Bo góc", prop(\.cornerRadius), 0...100) }
            }
        }
    }

    private func strokeCard(_ l: TitleLayer) -> some View {
        card(l.kind == .text ? "Viền khung" : "Viền") {
            Toggle("Có viền", isOn: Binding(get: { (selectedLayer?.strokeWidth ?? 0) > 0 },
                                            set: { on in mutateSelected { l in
                                                l.strokeWidth = on ? max(2, l.strokeWidth) : 0
                                                if on && l.strokeHex == nil { l.strokeHex = "#FFFFFF" }
                                            } }))
                .font(.system(size: 13))
            if l.strokeWidth > 0 {
                colorRow("Màu viền", Binding(get: { selectedLayer?.strokeHex ?? "#FFFFFF" },
                                             set: { h in mutateSelected { $0.strokeHex = h } }))
                sliderRow("Độ dày", prop(\.strokeWidth), 1...30)
            }
        }
    }

    private func geometryCard(_ l: TitleLayer) -> some View {
        card("Vị trí & kích thước") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    field("X", Binding(get: { selectedLayer?.x ?? 0 }, set: { v in mutateSelected { $0.x = v } }))
                    field("Y", Binding(get: { selectedLayer?.y ?? 0 }, set: { v in mutateSelected { $0.y = v } }))
                }
                GridRow {
                    field("Rộng", Binding(get: { selectedLayer?.w ?? 0 }, set: { v in mutateSelected { l in
                        l.w = max(10, v); l.fitText = false
                        if l.kind == .text { l.h = TitleRenderer.fittedHeight(l) }
                    } }))
                    field("Cao", Binding(get: { selectedLayer?.h ?? 0 }, set: { v in mutateSelected { $0.h = max(4, v); $0.fitText = false } }))
                }
            }
            HStack(spacing: 6) {
                Text("Dịch").font(.system(size: 13)).foregroundStyle(DS.text2)
                nudgeButton("arrow.left") { nudge(-1, 0) }
                nudgeButton("arrow.up") { nudge(0, -1) }
                nudgeButton("arrow.down") { nudge(0, 1) }
                nudgeButton("arrow.right") { nudge(1, 0) }
                Toggle("×10", isOn: $bigStep).toggleStyle(.button).font(.system(size: 12))
            }
            HStack(spacing: 6) {
                alignButton("align.horizontal.left", .left)
                alignButton("align.horizontal.center", .centerX)
                alignButton("align.horizontal.right", .right)
                alignButton("align.vertical.top", .top)
                alignButton("align.vertical.center", .centerY)
                alignButton("align.vertical.bottom", .bottom)
            }
            HStack(spacing: 6) {
                sliderRow("Xoay", prop(\.rotation), -180...180, unit: "°")
                if l.rotation != 0 {
                    Button { mutateSelected { $0.rotation = 0 } } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless).accessibilityLabel("Về 0°")
                }
            }
            percentRow("Độ đục lớp", prop(\.opacity))
            if l.kind != .text && l.kind != .image {
                Toggle("Giữ tỉ lệ khi kéo góc", isOn: prop(\.lockAspect)).font(.system(size: 13))
            }
            Toggle("Khoá lớp (không chọn / kéo trên khung vẽ)", isOn: prop(\.locked)).font(.system(size: 13))
        }
    }

    // MARK: Layers / templates

    private var layersTab: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Lớp trên cùng nằm phía trước. Chạm để chọn, kéo trên khung vẽ để di chuyển.")
                .font(.system(size: 11)).foregroundStyle(DS.text3)
            if layers.isEmpty { Text("Chưa có lớp nào").font(.system(size: 13)).foregroundStyle(DS.text3).padding(.vertical, 8) }
            ForEach(layers.reversed()) { layer in layerRow(layer) }
        }
    }

    private func layerRow(_ layer: TitleLayer) -> some View {
        let on = selected == layer.id
        return HStack(spacing: 8) {
            Image(systemName: layer.kind.icon).font(.system(size: 12)).frame(width: 18).foregroundStyle(on ? .black : DS.accent)
            Text(verbatim: layerTitle(layer)).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(on ? .black : (layer.hidden ? DS.text3 : .white))
            Spacer(minLength: 4)
            Button { commit(); update(layer.id) { $0.hidden.toggle() } } label: {
                Image(systemName: layer.hidden ? "eye.slash" : "eye").frame(width: 28, height: 28)
            }.buttonStyle(.plain).accessibilityLabel(layer.hidden ? "Hiện lớp" : "Ẩn lớp")
            Button { commit(); update(layer.id) { $0.locked.toggle() } } label: {
                Image(systemName: layer.locked ? "lock.fill" : "lock.open").frame(width: 28, height: 28)
            }.buttonStyle(.plain).accessibilityLabel(layer.locked ? "Mở khoá lớp" : "Khoá lớp")
            Menu {
                Button { reorder(layer.id, by: 100) } label: { Label("Đưa lên trên cùng", systemImage: "square.3.layers.3d.top.filled") }
                Button { reorder(layer.id, by: 1) } label: { Label("Lên 1 lớp", systemImage: "chevron.up") }
                Button { reorder(layer.id, by: -1) } label: { Label("Xuống 1 lớp", systemImage: "chevron.down") }
                Button { reorder(layer.id, by: -100) } label: { Label("Xuống dưới cùng", systemImage: "square.3.layers.3d.bottom.filled") }
                Divider()
                Button { duplicate(layer.id) } label: { Label("Nhân bản", systemImage: "plus.square.on.square") }
                Button(role: .destructive) { delete(layer.id) } label: { Label("Xoá lớp", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 28, height: 28) }
        }
        .font(.system(size: 13))
        .foregroundStyle(on ? .black : DS.text2)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(on ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        .contentShape(Rectangle())
        .onTapGesture { selected = layer.id }
    }

    private func layerTitle(_ l: TitleLayer) -> String {
        if !l.name.isEmpty { return l.name }
        if l.kind == .text { return l.text.isEmpty ? L("Chữ") : l.text.replacingOccurrences(of: "\n", with: " ") }
        if l.kind == .image { return l.imageFile ?? L("Ảnh / logo") }
        return l.kind.label
    }

    private var templatesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            card("Lưu thiết kế này") {
                Button { templateName = ""; showName = true } label: {
                    Label("Lưu thành mẫu…", systemImage: "square.and.arrow.down")
                }
                .font(.system(size: 13)).disabled(layers.isEmpty)
            }
            card("Mẫu có sẵn") {
                templateRow(L("Lower third cơ bản"), deletable: false) {
                    TitleLayer.starter(accent: draft.accentHex)
                }
                templateRow(L("Lower third có tiêu đề"), deletable: false) {
                    TitleLayer.starterHeader(accent: draft.accentHex)
                }
            }
            card("Mẫu đã lưu") {
                let names = TitleTemplateStore.names()
                if names.isEmpty { Text("Chưa có mẫu nào").font(.system(size: 13)).foregroundStyle(DS.text3) }
                ForEach(names, id: \.self) { n in
                    templateRow(n, deletable: true) { TitleTemplateStore.load(n) ?? [] }
                }
            }
            Text("Nạp mẫu sẽ thay toàn bộ thiết kế hiện tại (có thể Hoàn tác).").font(.system(size: 11)).foregroundStyle(DS.text3)
        }
    }

    private func templateRow(_ name: String, deletable: Bool, _ make: @escaping () -> [TitleLayer]) -> some View {
        HStack {
            Text(verbatim: name).font(.system(size: 13)).lineLimit(1)
            Spacer()
            Button("Nạp") {
                let ls = make()
                guard !ls.isEmpty else { return }
                commit(); draft.layers = ls; selected = nil; tab = 0
            }
            .font(.system(size: 13, weight: .semibold))
            if deletable {
                Button(role: .destructive) { TitleTemplateStore.delete(name) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
    }

    // MARK: Small controls

    private func chip(_ title: String, _ icon: String, _ b: Binding<Bool>) -> some View {
        Button { b.wrappedValue.toggle() } label: {
            Label(LocalizedStringKey(title), systemImage: icon).font(.system(size: 12)).lineLimit(1)
                .padding(.horizontal, 8).frame(height: 28)
                .foregroundStyle(b.wrappedValue ? Color.black : .white)
                .background(b.wrappedValue ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }.buttonStyle(.plain)
    }

    private func nudgeButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).frame(width: 32, height: 28)
                .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }.buttonStyle(.plain)
    }

    private func alignButton(_ icon: String, _ a: Align) -> some View {
        Button { align(a) } label: {
            Image(systemName: icon).font(.system(size: 13)).frame(maxWidth: .infinity).frame(height: 30)
                .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }.buttonStyle(.plain)
    }

    private func field(_ title: String, _ v: Binding<CGFloat>) -> some View {
        let d = Binding<Double>(get: { Double(v.wrappedValue) }, set: { v.wrappedValue = CGFloat($0) })
        return HStack(spacing: 6) {
            Text(LocalizedStringKey(title)).font(.system(size: 12)).foregroundStyle(DS.text3).frame(width: 34, alignment: .leading)
            TextField("", value: d, format: .number.precision(.fractionLength(0)))
                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder).font(.system(size: 13).monospacedDigit())
        }
    }

    private func numberRow(_ title: String, _ v: Binding<CGFloat>, _ r: ClosedRange<CGFloat>, step: CGFloat) -> some View {
        let lo = Double(r.lowerBound), hi = Double(r.upperBound)
        let d = Binding<Double>(get: { Double(v.wrappedValue) }, set: { v.wrappedValue = CGFloat(min(max($0, lo), hi)) })
        return HStack(spacing: 8) {
            Text(LocalizedStringKey(title)).font(.system(size: 13)).foregroundStyle(DS.text2)
            Spacer(minLength: 4)
            TextField("", value: d, format: .number.precision(.fractionLength(0)))
                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder).frame(width: 64).font(.system(size: 13).monospacedDigit())
            Stepper("", value: d, in: lo...hi, step: Double(step)).labelsHidden()
        }
    }

    private func sliderRow(_ title: String, _ v: Binding<CGFloat>, _ r: ClosedRange<CGFloat>, unit: String = "") -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title)).font(.system(size: 13)).foregroundStyle(DS.text2).frame(width: 86, alignment: .leading)
            Slider(value: v, in: r).tint(DS.accent).controlSize(.small)
            Text(verbatim: "\(Int(v.wrappedValue.rounded()))\(unit)").font(.system(size: 12).monospacedDigit())
                .foregroundStyle(DS.text3).frame(width: 44, alignment: .trailing)
        }
    }

    private func percentRow(_ title: String, _ v: Binding<CGFloat>) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title)).font(.system(size: 13)).foregroundStyle(DS.text2).frame(width: 86, alignment: .leading)
            Slider(value: v, in: 0...1).tint(DS.accent).controlSize(.small)
            Text(verbatim: "\(Int((v.wrappedValue * 100).rounded()))%").font(.system(size: 12).monospacedDigit())
                .foregroundStyle(DS.text3).frame(width: 44, alignment: .trailing)
        }
    }

    private func colorRow(_ title: String, _ hex: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(LocalizedStringKey(title)).font(.system(size: 13)).foregroundStyle(DS.text2).lineLimit(1)
            Spacer(minLength: 4)
            ForEach(Self.swatches, id: \.self) { h in
                let on = hex.wrappedValue.uppercased() == h
                Circle().fill(Color(UIColor(hex: h))).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(on ? DS.accent : Color.white.opacity(0.3), lineWidth: on ? 2.5 : 1))
                    .onTapGesture { hex.wrappedValue = h }
            }
            ColorPicker("", selection: Binding(get: { Color(UIColor(hex: hex.wrappedValue)) },
                                               set: { hex.wrappedValue = UIColor($0).hexString }), supportsOpacity: false)
                .labelsHidden()
        }
    }
}

/// Pictures / logos from the library as tappable tiles (on a checkerboard, so transparency shows).
struct LibraryImagePicker: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                let files = Self.files()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(files, id: \.self) { u in
                        Button { onPick(u.lastPathComponent); dismiss() } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    CheckerBackground()
                                    if let img = MediaLibrary.thumbnail(u, kind: .logo) {
                                        Image(uiImage: img).resizable().scaledToFit().padding(4)
                                    } else {
                                        Image(systemName: "photo")
                                    }
                                }
                                .frame(height: 74).clipShape(RoundedRectangle(cornerRadius: DS.radius))
                                Text(verbatim: u.deletingPathExtension().lastPathComponent).font(.system(size: 10)).lineLimit(1)
                                    .foregroundStyle(DS.text3)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                .padding()
                if files.isEmpty {
                    Text("Nhập ảnh / logo ở các mục Ảnh và Logo").font(.system(size: 13)).foregroundStyle(DS.text3).padding()
                }
            }
            .background(DS.bg)
            .navigationTitle("Chọn ảnh / logo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    static func files() -> [URL] {
        var out: [URL] = []
        for k in [LibraryKind.logo, .picture, .overlay] {
            out += (try? FileManager.default.contentsOfDirectory(at: MediaLibrary.directory(k), includingPropertiesForKeys: nil))?
                .filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) } ?? []
        }
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Named custom-title designs, saved for reuse (JSON in UserDefaults).
enum TitleTemplateStore {
    private static let key = "dtd.titleTemplates.v1"
    private static func all() -> [String: [TitleLayer]] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode([String: [TitleLayer]].self, from: d) else { return [:] }
        return m
    }
    private static func write(_ m: [String: [TitleLayer]]) {
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func names() -> [String] { all().keys.sorted() }
    static func load(_ name: String) -> [TitleLayer]? {
        all()[name].map { $0.map { var l = $0; l.id = UUID(); return l } }   // fresh ids
    }
    static func save(_ name: String, _ layers: [TitleLayer]) { var m = all(); m[name] = layers; write(m) }
    static func delete(_ name: String) { var m = all(); m[name] = nil; write(m) }
}

/// One-entry memo of `TitleRenderer.drawCustom` keyed by the layers and the canvas size.
final class DesignImageCache {
    private var key: ([TitleLayer], CGSize)?
    private var value: UIImage?

    func image(_ item: TitleItem, _ size: CGSize) -> UIImage? {
        let layers = item.layers ?? []
        if let k = key, k.1 == size, k.0 == layers { return value }
        value = TitleRenderer.drawCustom(item, canvas: size)
        key = (layers, size)
        return value
    }
}

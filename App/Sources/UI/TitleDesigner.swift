import SwiftUI
import UIKit

/// Multi-layer title designer: a 16:9 canvas over the live Program with draggable / resizable /
/// rotatable layers, snap guides, undo, a layer list and a property panel. Layers live in the
/// title's 1920×1080 design space (see TitleLayer); this view only edits `item.layers`.
struct TitleDesignerSheet: View {
    @Binding var item: TitleItem
    var program: FrameStore?
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selected: UUID?
    @State private var history: [[TitleLayer]] = []
    @State private var startFrames: [UUID: CGRect] = [:]   // design-space frames at gesture start
    @State private var startRotation: CGFloat = 0
    @State private var snapV = false      // showing the vertical centre guide
    @State private var snapH = false
    @State private var showName = false
    @State private var templateName = ""

    private var layers: [TitleLayer] { item.layers ?? [] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                canvas
                Divider()
                controls
            }
            .background(DS.bg)
            .navigationTitle("Thiết kế Title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { if !history.isEmpty { item.layers = history.removeLast() } } label: {
                        Label("Hoàn tác", systemImage: "arrow.uturn.backward")
                    }.disabled(history.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { g in
            let W = g.size.width, H = W * 9 / 16, s = W / 1920
            ZStack(alignment: .topLeading) {
                if let program { MonitorView(store: program, maxFPS: 10) } else { Color.black }
                // rendered design (authoritative look)
                if let img = TitleRenderer.drawCustom(item, canvas: CGSize(width: W, height: H)) {
                    Image(uiImage: img).resizable().frame(width: W, height: H)
                }
                // title-safe guide
                Rectangle().stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: W * 0.9, height: H * 0.9).offset(x: W * 0.05, y: H * 0.05)
                // snap guides
                if snapV { Rectangle().fill(Color.cyan).frame(width: 1, height: H).offset(x: W / 2) }
                if snapH { Rectangle().fill(Color.cyan).frame(width: W, height: 1).offset(y: H / 2) }
                // interactive layer hit areas (back to front) + selection handles
                ForEach(layers) { layer in
                    layerHandle(layer, s: s)
                }
            }
            .frame(width: W, height: H)
            .clipped()
            .contentShape(Rectangle())
            .overlay(Rectangle().stroke(DS.stroke))
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .padding(8)
    }

    @ViewBuilder private func layerHandle(_ layer: TitleLayer, s: CGFloat) -> some View {
        let r = CGRect(x: layer.x * s, y: layer.y * s, width: max(8, layer.w * s), height: max(8, layer.h * s))
        let isSel = selected == layer.id
        ZStack {
            Rectangle().fill(Color.clear).contentShape(Rectangle())
            if isSel {
                Rectangle().stroke(Color.cyan, lineWidth: 1.5)
                // resize handle (bottom-right)
                handleDot.position(x: r.width, y: r.height).gesture(resizeGesture(layer, s: s))
                // rotate handle (above top edge)
                handleDot.position(x: r.width / 2, y: -22)
                    .overlay(Rectangle().fill(Color.cyan).frame(width: 1, height: 22).position(x: r.width / 2, y: -11))
                    .gesture(rotateGesture(layer, s: s))
            }
        }
        .frame(width: r.width, height: r.height)
        .rotationEffect(.degrees(layer.rotation))
        .position(x: r.midX, y: r.midY)
        .gesture(moveGesture(layer, s: s))
        .onTapGesture { selected = layer.id }
    }

    private var handleDot: some View {
        Circle().fill(Color.white).overlay(Circle().stroke(Color.cyan, lineWidth: 2)).frame(width: 16, height: 16)
    }

    // MARK: Gestures (operate in design space; translation is divided by the view scale)

    private func moveGesture(_ layer: TitleLayer, s: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if startFrames[layer.id] == nil { beginEdit(layer) }
                guard let f = startFrames[layer.id] else { return }
                var nx = f.minX + v.translation.width / s
                var ny = f.minY + v.translation.height / s
                // snap the layer centre to the frame centre (960 / 540) within 16 design px
                let cx = nx + f.width / 2, cy = ny + f.height / 2
                snapV = abs(cx - 960) < 16; if snapV { nx = 960 - f.width / 2 }
                snapH = abs(cy - 540) < 16; if snapH { ny = 540 - f.height / 2 }
                update(layer.id) { $0.x = nx.rounded(); $0.y = ny.rounded() }
            }
            .onEnded { _ in endEdit(layer); snapV = false; snapH = false }
    }

    private func resizeGesture(_ layer: TitleLayer, s: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if startFrames[layer.id] == nil { beginEdit(layer) }
                guard let f = startFrames[layer.id] else { return }
                let nw = max(20, f.width + v.translation.width / s)
                let nh = max(10, f.height + v.translation.height / s)
                update(layer.id) { $0.w = nw.rounded(); $0.h = nh.rounded(); $0.fitText = false }
            }
            .onEnded { _ in endEdit(layer) }
    }

    private func rotateGesture(_ layer: TitleLayer, s: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if startFrames[layer.id] == nil { beginEdit(layer); startRotation = layer.rotation }
                // angle from the box centre to the drag point (handle sits above centre → offset 90°)
                let dx = v.location.x - layer.w * s / 2
                let dy = v.location.y - (-22)
                var deg = startRotation + atan2(dy, dx) * 180 / .pi - atan2(-22 - layer.h * s / 2, 0) * 180 / .pi
                if abs(deg.truncatingRemainder(dividingBy: 15)) < 3 { deg = (deg / 15).rounded() * 15 }   // snap to 15°
                update(layer.id) { $0.rotation = deg.rounded() }
            }
            .onEnded { _ in endEdit(layer) }
    }

    private func beginEdit(_ layer: TitleLayer) {
        pushHistory()
        startFrames[layer.id] = layer.frame
        selected = layer.id
    }
    private func endEdit(_ layer: TitleLayer) { startFrames[layer.id] = nil }

    // MARK: Layer mutation

    private func pushHistory() { history.append(layers); if history.count > 50 { history.removeFirst() } }

    private func update(_ id: UUID, _ f: (inout TitleLayer) -> Void) {
        guard var ls = item.layers, let i = ls.firstIndex(where: { $0.id == id }) else { return }
        f(&ls[i]); item.layers = ls
    }

    private func add(_ kind: TitleLayer.Kind) {
        pushHistory()
        var ls = item.layers ?? []
        let l = TitleLayer.make(kind)
        ls.append(l); item.layers = ls; selected = l.id
    }

    private func deleteSelected() {
        guard let id = selected else { return }
        pushHistory()
        item.layers?.removeAll { $0.id == id }; selected = item.layers?.last?.id
    }

    private func duplicateSelected() {
        guard let id = selected, var l = layers.first(where: { $0.id == id }) else { return }
        pushHistory()
        l.id = UUID(); l.x += 24; l.y += 24
        item.layers?.append(l); selected = l.id
    }

    private func move(_ id: UUID, by d: Int) {
        guard var ls = item.layers, let i = ls.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard j >= 0, j < ls.count else { return }
        pushHistory(); ls.swapAt(i, j); item.layers = ls
    }

    private func selectedBinding() -> Binding<TitleLayer>? {
        guard let id = selected, layers.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { item.layers?.first { $0.id == id } ?? TitleLayer() },
            set: { nv in update(id) { $0 = nv } })
    }

    // MARK: Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                addBar
                if !layers.isEmpty { layerList }
                if let b = selectedBinding() { LayerProperties(layer: b, onCommit: pushHistory) }
                templateBar
                Button("Xoá title này", role: .destructive) { onDelete(); dismiss() }
                    .font(.system(size: 13)).padding(.top, 4)
            }
            .padding(12)
        }
        .frame(maxHeight: 360)
    }

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Thêm lớp").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.text3)
            HStack(spacing: 6) {
                ForEach(TitleLayer.Kind.allCases) { k in
                    Button { add(k) } label: {
                        VStack(spacing: 3) {
                            Image(systemName: k.icon).font(.system(size: 15))
                            Text(k.label).font(.system(size: 9)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var layerList: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Các lớp (trên = trước)").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.text3)
            ForEach(layers.reversed()) { layer in
                HStack(spacing: 6) {
                    Image(systemName: layer.kind.icon).font(.system(size: 11)).frame(width: 16).foregroundStyle(DS.accent)
                    Text(verbatim: layerTitle(layer)).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Button { update(layer.id) { $0.hidden.toggle() } } label: {
                        Image(systemName: layer.hidden ? "eye.slash" : "eye").font(.system(size: 12)).foregroundStyle(DS.text3)
                    }.buttonStyle(.plain)
                    Button { move(layer.id, by: 1) } label: { Image(systemName: "chevron.up").font(.system(size: 11)) }.buttonStyle(.plain)
                    Button { move(layer.id, by: -1) } label: { Image(systemName: "chevron.down").font(.system(size: 11)) }.buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(selected == layer.id ? DS.accent.opacity(0.22) : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                .contentShape(Rectangle())
                .onTapGesture { selected = layer.id }
            }
            if selected != nil {
                HStack(spacing: 8) {
                    Button { duplicateSelected() } label: { Label("Nhân bản", systemImage: "plus.square.on.square").font(.system(size: 12)) }
                    Button(role: .destructive) { deleteSelected() } label: { Label("Xoá lớp", systemImage: "trash").font(.system(size: 12)) }
                }.padding(.top, 2)
            }
        }
    }

    private func layerTitle(_ l: TitleLayer) -> String {
        if l.kind == .text { return l.text.isEmpty ? L("Chữ") : l.text }
        if l.kind == .image { return l.imageFile ?? L("Ảnh / logo") }
        return l.kind.label
    }

    private var templateBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mẫu đã lưu").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.text3)
            HStack(spacing: 6) {
                Button { templateName = ""; showName = true } label: {
                    Label("Lưu mẫu này", systemImage: "square.and.arrow.down").font(.system(size: 12))
                }
                Menu {
                    let names = TitleTemplateStore.names()
                    if names.isEmpty { Text("Chưa có mẫu") }
                    ForEach(names, id: \.self) { n in
                        Button(n) { if let ls = TitleTemplateStore.load(n) { pushHistory(); item.layers = ls; selected = ls.last?.id } }
                    }
                } label: { Label("Nạp mẫu", systemImage: "square.and.arrow.up").font(.system(size: 12)) }
            }
        }
        .alert("Tên mẫu", isPresented: $showName) {
            TextField("Tên", text: $templateName)
            Button("Lưu") { if !templateName.isEmpty { TitleTemplateStore.save(templateName, layers) } }
            Button("Huỷ", role: .cancel) {}
        }
    }
}

/// Property editor for one layer. Different fields by kind.
private struct LayerProperties: View {
    @Binding var layer: TitleLayer
    var onCommit: () -> Void
    @State private var pickImage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lớp đang chọn · \(layer.kind.label)").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.text3)
            if layer.kind == .text {
                TextField("Nội dung", text: $layer.text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
                slider("Cỡ chữ", $layer.fontSize, 12...200) { "\(Int($0))" }
                HStack(spacing: 10) {
                    Toggle("Đậm", isOn: $layer.bold).toggleStyle(.button)
                    Toggle("Nghiêng", isOn: $layer.italic).toggleStyle(.button)
                    Picker("Căn", selection: $layer.align) {
                        Image(systemName: "text.alignleft").tag(0)
                        Image(systemName: "text.aligncenter").tag(1)
                        Image(systemName: "text.alignright").tag(2)
                    }.pickerStyle(.segmented).frame(width: 130)
                }.font(.system(size: 12))
                color("Màu chữ", bindingHex($layer.textHex))
            }
            if layer.kind == .image {
                Button { pickImage = true } label: { Label(layer.imageFile ?? L("Chọn ảnh / logo"), systemImage: "photo") }
                    .font(.system(size: 13))
                    .sheet(isPresented: $pickImage) { LibraryImagePicker { layer.imageFile = $0; onCommit() } }
            }
            // fill (shapes + optional text background)
            if layer.kind != .image {
                let hasFill = Binding(get: { layer.fillHex != nil }, set: { layer.fillHex = $0 ? (layer.fillHex ?? "#000000") : nil; onCommit() })
                Toggle(layer.kind == .text ? "Nền sau chữ" : "Tô màu", isOn: hasFill).font(.system(size: 13))
                if layer.fillHex != nil {
                    color("Màu tô", Binding(get: { layer.fillHex ?? "#000000" }, set: { layer.fillHex = $0 }))
                    slider("Độ đục", $layer.fillOpacity, 0...1) { "\(Int($0 * 100))%" }
                    if layer.kind == .roundRect || layer.kind == .text {
                        slider("Bo góc", $layer.cornerRadius, 0...80) { "\(Int($0))" }
                    }
                }
            }
            // stroke
            let hasStroke = Binding(get: { layer.strokeWidth > 0 }, set: { layer.strokeWidth = $0 ? max(2, layer.strokeWidth) : 0; if $0 && layer.strokeHex == nil { layer.strokeHex = "#FFFFFF" }; onCommit() })
            Toggle("Viền", isOn: hasStroke).font(.system(size: 13))
            if layer.strokeWidth > 0 {
                color("Màu viền", Binding(get: { layer.strokeHex ?? "#FFFFFF" }, set: { layer.strokeHex = $0 }))
                slider("Dày viền", $layer.strokeWidth, 1...30) { "\(Int($0))" }
            }
            slider("Độ đục lớp", $layer.opacity, 0...1) { "\(Int($0 * 100))%" }
            slider("Xoay", $layer.rotation, -180...180) { "\(Int($0))°" }
            HStack(spacing: 10) {
                stepperRow("X", $layer.x, -200...1920)
                stepperRow("Y", $layer.y, -200...1080)
            }
            HStack(spacing: 10) {
                stepperRow("Rộng", $layer.w, 10...1920)
                stepperRow("Cao", $layer.h, 4...1080)
            }
        }
        .padding(10).background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radius))
    }

    private func bindingHex(_ b: Binding<String>) -> Binding<String> { b }

    private func color(_ title: String, _ hex: Binding<String>) -> some View {
        HStack {
            Text(LocalizedStringKey(title)).font(.system(size: 13)).foregroundStyle(DS.text2)
            Spacer()
            ColorPicker("", selection: Binding(get: { Color(UIColor(hex: hex.wrappedValue)) },
                                               set: { hex.wrappedValue = UIColor($0).hexString; onCommit() }), supportsOpacity: false).labelsHidden()
        }.frame(height: 30)
    }

    private func slider(_ title: String, _ v: Binding<CGFloat>, _ r: ClosedRange<CGFloat>, _ fmt: @escaping (CGFloat) -> String) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title)).font(.system(size: 13)).foregroundStyle(DS.text2).frame(width: 74, alignment: .leading)
            Slider(value: v, in: r) { editing in if editing { onCommit() } }.tint(DS.accent).controlSize(.small)
            Text(verbatim: fmt(v.wrappedValue)).font(.system(size: 12).monospacedDigit()).foregroundStyle(DS.text3).frame(width: 42, alignment: .trailing)
        }.frame(height: 30)
    }

    private func stepperRow(_ title: String, _ v: Binding<CGFloat>, _ r: ClosedRange<CGFloat>) -> some View {
        HStack(spacing: 4) {
            Text(LocalizedStringKey(title)).font(.system(size: 12)).foregroundStyle(DS.text3)
            Stepper(value: v, in: r, step: 2) { Text(verbatim: "\(Int(v.wrappedValue))").font(.system(size: 12).monospacedDigit()) }
        }
    }
}

/// Pictures/logos from the library as tappable tiles.
private struct LibraryImagePicker: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                let files = Self.files()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(files, id: \.self) { u in
                        Button { onPick(u.lastPathComponent); dismiss() } label: {
                            Group {
                                if let img = UIImage(contentsOfFile: u.path) { Image(uiImage: img).resizable().scaledToFit().padding(4) }
                                else { Image(systemName: "photo") }
                            }
                            .frame(height: 70).frame(maxWidth: .infinity)
                            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: DS.radius))
                        }.buttonStyle(.plain)
                    }
                }.padding()
                if files.isEmpty { Text("Nhập ảnh / logo ở các mục Ảnh và Logo").font(.system(size: 13)).foregroundStyle(DS.text3).padding() }
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

/// Named custom-title designs, saved for reuse (stored as JSON in UserDefaults).
enum TitleTemplateStore {
    private static let key = "dtd.titleTemplates.v1"
    private static func all() -> [String: [TitleLayer]] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode([String: [TitleLayer]].self, from: d) else { return [:] }
        return m
    }
    static func names() -> [String] { all().keys.sorted() }
    static func load(_ name: String) -> [TitleLayer]? {
        all()[name].map { $0.map { var l = $0; l.id = UUID(); return l } }   // fresh ids
    }
    static func save(_ name: String, _ layers: [TitleLayer]) {
        var m = all(); m[name] = layers
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: key) }
    }
}

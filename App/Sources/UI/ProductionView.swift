import CoreVideo
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Bottom half of the studio: category list · content · transition column.
enum ProdCategory: String, CaseIterable, Identifiable {
    case favorite, camera, pip, movie, picture, transition, overlay, title, logo, audio, adjust, auto, replay, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .favorite: return "Yêu thích"
        case .camera: return "Camera"
        case .pip: return "PiP"
        case .movie: return "Video"
        case .picture: return "Ảnh"
        case .transition: return "Chuyển cảnh"
        case .overlay: return "Lớp phủ"
        case .title: return "Title"
        case .logo: return "Logo"
        case .audio: return "Âm thanh"
        case .adjust: return "Màu & PTZ"
        case .auto: return "Tự động"
        case .replay: return "Replay"
        case .settings: return "Cài đặt"
        }
    }
    var icon: String {
        switch self {
        case .favorite: return "heart.fill"
        case .camera: return "video.fill"
        case .pip: return "pip.fill"
        case .movie: return "film"
        case .picture: return "photo"
        case .transition: return "square.on.square.dashed"
        case .overlay: return "square.3.layers.3d"
        case .title: return "textformat"
        case .logo: return "seal.fill"
        case .audio: return "music.note"
        case .adjust: return "slider.horizontal.3"
        case .auto: return "arrow.triangle.2.circlepath"
        case .replay: return "gobackward"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - Category list

struct CategoryList: View {
    @Binding var selection: ProdCategory
    var compact = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: compact ? 4 : 6) {
                ForEach(ProdCategory.allCases) { c in
                    Button { selection = c } label: {
                        Group {
                            if compact {
                                VStack(spacing: 2) {
                                    Image(systemName: c.icon).font(.system(size: 14, weight: .semibold))
                                    Text(c.label).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                                }
                                .frame(maxWidth: .infinity, minHeight: 40)
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: c.icon).font(.system(size: 14, weight: .semibold)).frame(width: 18)
                                    Text(c.label).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10).frame(height: 38)
                            }
                        }
                        .foregroundStyle(selection == c ? Color.black : DS.text2)
                        .background(selection == c ? Color.white : DS.surface2, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(compact ? 6 : 10)
        }
        .background(DS.surface)
    }
}

// MARK: - Content area

struct CategoryContent: View {
    @ObservedObject var engine: StudioEngine
    @ObservedObject var library: MediaLibrary
    let category: ProdCategory
    var compact = false
    @Binding var showAddSource: Bool
    @State private var importing: LibraryKind?
    @State private var photoKind: LibraryKind?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var adjustingSource: UUID?
    @State private var ptzSource: UUID?
    @State private var infoSource: UUID?
    @State private var showOutputs = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DS.stroke)
            if category == .settings {
                SettingsForm(engine: engine, onOpenOutputs: { showOutputs = true })
            } else {
                ScrollView {
                    content.padding(compact ? 8 : 12)
                }
            }
        }
        .sheet(isPresented: $showOutputs) { OutputsSheet(engine: engine) }
        .sheet(item: Binding(get: { ptzSource.map(IDBox.init) }, set: { ptzSource = $0?.id })) { box in
            NavigationStack {
                ScrollView { PTZPanel(engine: engine, sourceID: box.id).padding() }
                    .background(DS.bg)
                    .navigationTitle("PTZ · " + (engine.sources.first { $0.id == box.id }?.name ?? ""))
                    .toolbar { Button("Xong") { ptzSource = nil } }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(get: { infoSource.map(IDBox.init) }, set: { infoSource = $0?.id })) { box in
            SourceInfoView(engine: engine, sourceID: box.id).presentationDetents([.medium])
        }
        .background(DS.bg)
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: importing.map(types) ?? [.data], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r, let k = importing { library.importFiles(urls, into: k) }
            importing = nil
        }
        .photosPicker(isPresented: Binding(get: { photoKind != nil }, set: { if !$0 { photoKind = nil } }),
                      selection: $photoItems, matching: .images)
        .onChange(of: photoItems) { _, items in
            let k = photoKind ?? .picture
            Task {
                for i in items { if let d = try? await i.loadTransferable(type: Data.self) { library.importImage(d, into: k) } }
                photoItems = []
            }
        }
        .sheet(item: Binding(get: { adjustingSource.map(IDBox.init) }, set: { adjustingSource = $0?.id })) { box in
            NavigationStack {
                ScrollView { SourceAdjustView(engine: engine, sourceID: box.id).padding() }
                    .background(DS.bg)
                    .navigationTitle(engine.sources.first { $0.id == box.id }?.name ?? "Nguồn")
                    .toolbar { Button("Xong") { adjustingSource = nil } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(category.label).font(compact ? .subheadline.weight(.bold) : .headline)
            Spacer()
            switch category {
            case .camera, .favorite:
                if category == .camera, let pv = engine.previewID {
                    iconButton("info.circle", "Thông tin nguồn PVW") { infoSource = pv }
                    iconButton("arrow.up.and.down.and.arrow.left.and.right", "PTZ nguồn PVW") { ptzSource = pv }
                    iconButton("paintpalette", "Màu nguồn PVW") { adjustingSource = pv }
                }
                headerButton("Thêm nguồn", "plus") { showAddSource = true }
            case .movie:
                headerButton("Nhập video", "square.and.arrow.down") { importing = .movie }
            case .picture, .overlay, .logo:
                let k: LibraryKind = category == .picture ? .picture : category == .overlay ? .overlay : .logo
                headerButton("Thư viện ảnh", "photo.on.rectangle") { photoKind = k }
                headerButton("Tệp", "folder") { importing = k }
            case .audio:
                headerButton("Nhập nhạc", "square.and.arrow.down") { importing = .music }
            case .title:
                Menu {
                    ForEach(TitleStyle.allCases) { s in
                        Button(s.label) { engine.upsertTitle(TitleItem(style: s, line1: s == .clock ? "" : s.label)) }
                    }
                } label: { Label("Thêm title", systemImage: "plus").font(.caption.weight(.semibold)) }
                .buttonStyle(.bordered)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, compact ? 10 : 14).frame(height: compact ? 38 : 48)
        .background(DS.surface)
    }

    private func iconButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: compact ? 15 : 18)).frame(width: 30, height: 30) }
            .buttonStyle(.plain).foregroundStyle(DS.text2)
            .accessibilityLabel(label)
    }

    private func headerButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.caption.weight(.semibold)).lineLimit(1) }
            .buttonStyle(.bordered)
    }

    private func types(_ k: LibraryKind) -> [UTType] {
        switch k {
        case .movie: return [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        case .picture, .overlay, .logo: return [.image, .png, .jpeg]
        case .music: return [.audio, .mp3, .mpeg4Audio, .wav]
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: compact ? 120 : 210, maximum: compact ? 180 : 320), spacing: compact ? 6 : 10)]
    }

    @ViewBuilder private var content: some View {
        switch category {
        case .favorite:
            let favs = engine.sources.filter { engine.favorites.contains($0.id) }
            if favs.isEmpty { emptyHint("Bấm ♡ trên một nguồn để thêm vào Yêu thích") }
            sourceGrid(favs)
        case .camera:
            let local = engine.sources.filter { $0 is CameraSource }
            let net = engine.sources.filter { !($0 is CameraSource) && !($0 is FileSource) && !($0 is ImageSource) && $0.id != engine.replay.id }
            sectionHeader("Camera trong máy & USB")
            if local.isEmpty { emptyHint("Chưa có camera — bấm Thêm nguồn") }
            sourceGrid(local)
            sectionHeader("Camera mạng (SRT · RTSP · RTMP · DTDLive)")
            if net.isEmpty { emptyHint("Chưa có camera mạng") }
            sourceGrid(net)
            PairedDevicesSection(pairing: engine.pairing, port: engine.controlPort).padding(.top, 8)
        case .settings:
            EmptyView()
        case .pip:
            pipContent
        case .movie:
            libraryGrid(.movie) { engine.cueMovie($0) }
            let playing = engine.sources.compactMap { $0 as? FileSource }
            if !playing.isEmpty {
                sectionHeader("Video đang dùng làm nguồn")
                sourceGrid(playing)
            }
        case .picture:
            libraryGrid(.picture) { engine.cuePicture($0) }
        case .transition:
            transitionContent
        case .overlay:
            Toggle("Hiện lớp phủ trên Program", isOn: $engine.foregroundOn).disabled(engine.foreground == nil)
            Text("Ảnh PNG có nền trong suốt, phủ toàn khung hình (khung viền, băng rôn nhà tài trợ…)").font(.caption).foregroundStyle(DS.text3)
            libraryGrid(.overlay, selected: engine.currentForegroundURL) { engine.useForeground($0) }
        case .title:
            ScoreboardControl(engine: engine, compact: compact).padding(.bottom, 4)
            TitlesPanel(engine: engine)
        case .logo:
            HStack {
                Toggle("Hiện logo", isOn: $engine.logoOn).disabled(engine.logo == nil).fixedSize()
                Spacer()
                Picker("Vị trí", selection: $engine.logoCorner) { ForEach(StudioEngine.Corner.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).frame(maxWidth: 380)
            }
            libraryGrid(.logo, selected: engine.currentLogoURL) { engine.useLogo($0) }
        case .audio:
            AudioMixerView(engine: engine, compact: compact)
            musicList
        case .adjust:
            SourcePanel(engine: engine)
        case .auto:
            AutoPanel(auto: engine.autoSwitcher, engine: engine)
        case .replay:
            ReplayPanel(engine: engine)
        }
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption.weight(.bold)).foregroundStyle(DS.text3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    private func emptyHint(_ t: String) -> some View {
        Text(t).font(.caption).foregroundStyle(DS.text3).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }

    // MARK: Sources

    private func sourceGrid(_ list: [any VideoSource]) -> some View {
        LazyVGrid(columns: columns, spacing: compact ? 6 : 10) {
            ForEach(list, id: \.id) { s in
                SourceCell(engine: engine, source: s, index: (engine.sources.firstIndex { $0.id == s.id } ?? 0) + 1,
                           compact: compact, onAdjust: { adjustingSource = s.id })
            }
        }
    }

    // MARK: PiP

    @ViewBuilder private var pipContent: some View {
        sectionHeader("Mẫu bố cục nhiều nguồn — chọn mẫu để đưa lên Preview, rồi CUT/AUTO hoặc phím PiP TRANS")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 150 : 220), spacing: compact ? 6 : 10)], spacing: compact ? 6 : 10) {
            ForEach(LayoutTemplate.all) { t in
                Button { engine.chooseLayout(t.id) } label: {
                    VStack(spacing: 0) {
                        LayoutThumbnail(template: t, names: slotNames(for: t))
                            .aspectRatio(16 / 9, contentMode: .fit)
                        Text("\(t.id). \(t.name)").font(.caption.weight(.semibold)).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 26).background(DS.surface)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(engine.layoutTemplateID == t.id ? DS.accent : DS.stroke,
                                                                     lineWidth: engine.layoutTemplateID == t.id ? 3 : 1))
                }
                .buttonStyle(.plain)
            }
        }
        if !engine.layoutSlots.isEmpty {
            sectionHeader("Gán nguồn cho từng khung (chọn khung → bấm nguồn)")
            HStack(spacing: 6) {
                ForEach(engine.layoutSlots.indices, id: \.self) { i in
                    let sel = engine.layoutSelectedSlot == i
                    Button { engine.layoutSelectedSlot = i } label: {
                        Text("Khung \(i + 1): \(engine.sources.first { $0.id == engine.layoutSlots[i] }?.name ?? "trống")")
                            .font(.caption.weight(.semibold)).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .foregroundStyle(sel ? .black : .white)
                            .background(sel ? DS.accent : DS.surface2, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            LazyVGrid(columns: columns, spacing: compact ? 6 : 10) {
                ForEach(engine.sources.filter { $0.id != engine.layoutSource.id }, id: \.id) { s in
                    Button { engine.assignLayoutSlot(engine.layoutSelectedSlot, source: s.id) } label: {
                        ZStack(alignment: .bottomLeading) {
                            MonitorView(store: s.frames, maxFPS: 8).aspectRatio(16 / 9, contentMode: .fit)
                            Text(s.name).font(.caption2.weight(.semibold)).lineLimit(1).padding(4)
                                .frame(maxWidth: .infinity, alignment: .leading).background(Color.black.opacity(0.55))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(engine.layoutSlots.contains(s.id) ? DS.accent2 : DS.stroke,
                                                                         lineWidth: engine.layoutSlots.contains(s.id) ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        sectionHeader("Khung PiP đơn đè lên Program")
        HStack(spacing: 12) {
            Toggle("PiP trên Program", isOn: $engine.pipOn).disabled(engine.pip == nil).fixedSize()
            Spacer()
            Picker("Vị trí", selection: $engine.pipPreset) { ForEach(StudioEngine.PiPPreset.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.menu)
        }
        LazyVGrid(columns: columns, spacing: compact ? 6 : 10) {
            ForEach(engine.sources.filter { $0.id != engine.layoutSource.id }, id: \.id) { s in
                let on = engine.pip?.pipSourceID == s.id
                Button { engine.setPiP(on ? nil : s.id) } label: {
                    ZStack(alignment: .bottomLeading) {
                        MonitorView(store: s.frames, maxFPS: 8).aspectRatio(16 / 9, contentMode: .fit)
                        Text(s.name).font(.caption2.weight(.semibold)).lineLimit(1).padding(4)
                            .frame(maxWidth: .infinity, alignment: .leading).background(Color.black.opacity(0.55))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? DS.accent2 : DS.stroke, lineWidth: on ? 3 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func slotNames(for t: LayoutTemplate) -> [String] {
        (0..<t.slots.count).map { i in
            if t.id == engine.layoutTemplateID, i < engine.layoutSlots.count,
               let n = engine.sources.first(where: { $0.id == engine.layoutSlots[i] })?.name { return n }
            return i == 0 ? "Chính" : "Cam \(i + 1)"
        }
    }

    // MARK: Transitions

    @ViewBuilder private var transitionContent: some View {
        LabeledSlider(title: "Thời gian chuyển cảnh", value: $engine.transitionDuration, range: 0.2...3) { String(format: "%.1f s", $0) }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 130 : 200), spacing: compact ? 6 : 10)], spacing: compact ? 6 : 10) {
            ForEach(Array(TransitionStyle.allCases.filter { $0 != .cut }.enumerated()), id: \.element) { i, t in
                Button { engine.transition = t } label: {
                    VStack(spacing: 0) {
                        TransitionPreviewView(style: t, animate: engine.transition == t)
                            .aspectRatio(16 / 9, contentMode: .fit)
                        Text("\(i + 1): \(t.label)").font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .foregroundStyle(engine.transition == t ? Color.black : .white)
                            .background(engine.transition == t ? DS.accent : DS.surface)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(engine.transition == t ? DS.accent : DS.stroke, lineWidth: engine.transition == t ? 3 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Media library grids

    private func libraryGrid(_ k: LibraryKind, selected: URL? = nil, onTap: @escaping (URL) -> Void) -> some View {
        let items = library.list(k)
        return VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty { emptyHint("Thư viện trống — dùng nút nhập ở phía trên. Tệp lưu trong Files › DTD Studio › Library › \(k.folder)") }
            LazyVGrid(columns: columns, spacing: compact ? 6 : 10) {
                ForEach(items, id: \.self) { url in
                    LibraryCell(url: url, kind: k, selected: url == selected)
                        .onTapGesture { onTap(url) }
                        .contextMenu {
                            if k == .movie {
                                Button { engine.openInReplay(url) } label: { Label("Mở trong Replay (mark in/out)", systemImage: "scissors") }
                            }
                            Button("Xoá khỏi thư viện", role: .destructive) { library.delete(url) }
                        }
                }
            }
        }
    }

    @ViewBuilder private var musicList: some View {
        SectionCard("Nhạc nền", systemImage: "music.note.list") {
            let items = library.list(.music)
            if items.isEmpty { Text("Chưa có nhạc — bấm Nhập nhạc").font(.caption).foregroundStyle(DS.text3) }
            ForEach(items, id: \.self) { url in
                HStack {
                    Image(systemName: engine.nowPlayingMusic == url ? "speaker.wave.2.fill" : "music.note")
                        .foregroundStyle(engine.nowPlayingMusic == url ? DS.accent : DS.text2)
                    Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                    Spacer()
                    Button(engine.nowPlayingMusic == url ? "Dừng" : "Phát") { engine.toggleMusic(url) }
                        .buttonStyle(.bordered).font(.caption)
                }
                .contextMenu { Button("Xoá", role: .destructive) { library.delete(url) } }
            }
        }
    }
}

private struct IDBox: Identifiable { let id: UUID }

/// One input tile: live thumbnail, number, name, status, favourite and settings.
struct SourceCell: View {
    @ObservedObject var engine: StudioEngine
    let source: any VideoSource
    let index: Int
    var compact = false
    var onAdjust: () -> Void

    var body: some View {
        let pgm = engine.programID == source.id, pvw = engine.previewID == source.id
        VStack(spacing: 0) {
            ZStack {
                MonitorView(store: source.frames, maxFPS: 10).aspectRatio(16 / 9, contentMode: .fit)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if case .error(let e) = source.status {
                        Text(e).font(.caption2).padding(6).background(.black.opacity(0.7), in: Capsule()).lineLimit(1)
                    } else if source.status == .connecting {
                        Text("Đang kết nối…").font(.caption2.weight(.semibold)).padding(6).background(.black.opacity(0.7), in: Capsule())
                    } else if source.frames.latest() == nil {
                        Text("Không có tín hiệu").font(.caption.weight(.bold)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.6), in: Capsule())
                            .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                    }
                }
            }
            HStack(spacing: 6) {
                Text("\(index)").font(.caption2.weight(.heavy)).frame(width: 18, height: 18)
                    .background(pgm ? DS.pgm : pvw ? DS.pvw : DS.surface2, in: RoundedRectangle(cornerRadius: 4))
                Text(source.name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Button { engine.toggleFavorite(source.id) } label: {
                    Image(systemName: engine.favorites.contains(source.id) ? "heart.fill" : "heart")
                        .foregroundStyle(engine.favorites.contains(source.id) ? DS.accent : DS.text2)
                }
                .buttonStyle(.plain)
                Menu {
                    Button { engine.select(source.id) } label: { Label("Đưa lên Preview", systemImage: "rectangle.on.rectangle") }
                    Button { engine.take(source.id) } label: { Label("Lên sóng ngay", systemImage: "dot.radiowaves.left.and.right") }
                    Button { engine.setPiP(source.id) } label: { Label("Dùng làm PiP", systemImage: "pip") }
                    Button(action: onAdjust) { Label("Màu, key, PTZ…", systemImage: "slider.horizontal.3") }
                    if let f = source as? FileSource {
                        Button { f.isPlaying ? f.pause() : f.play(); engine.objectWillChange.send() } label: {
                            Label(f.isPlaying ? "Tạm dừng" : "Phát", systemImage: f.isPlaying ? "pause" : "play")
                        }
                        Button { f.restart() } label: { Label("Phát lại từ đầu", systemImage: "backward.end") }
                    }
                    Divider()
                    Button(role: .destructive) { engine.remove(source) } label: { Label("Xoá nguồn", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis").foregroundStyle(DS.text2).frame(width: 22, height: 18) }
            }
            .padding(.horizontal, 6).frame(height: compact ? 24 : 28)
            .background(DS.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(pgm ? DS.pgm : pvw ? DS.pvw : DS.stroke, lineWidth: pgm || pvw ? 3 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { engine.take(source.id) }
        .onTapGesture { engine.select(source.id) }
    }
}

struct LibraryCell: View {
    let url: URL
    let kind: LibraryKind
    var selected = false
    @State private var thumb: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if kind == .overlay || kind == .logo {
                    CheckerBackground()
                }
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFit()
                } else {
                    Image(systemName: kind == .movie ? "film" : "photo").font(.title).foregroundStyle(DS.text3)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            Text(url.deletingPathExtension().lastPathComponent).font(.caption.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 26).background(DS.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? DS.accent : DS.stroke, lineWidth: selected ? 3 : 1))
        .task(id: url) {
            let u = url, k = kind
            thumb = await Task.detached { MediaLibrary.thumbnail(u, kind: k) }.value
        }
    }
}

struct CheckerBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 10
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color(white: 0.22)))
                }
            }
        }
        .background(Color(white: 0.15))
    }
}

/// Per-source settings sheet (colour, key, geometry, PTZ) for one source.
struct SourceAdjustView: View {
    @ObservedObject var engine: StudioEngine
    let sourceID: UUID
    var body: some View {
        SourcePanel(engine: engine, fixedSource: sourceID)
    }
}

// MARK: - Transition column (right)

struct TransitionColumn: View {
    @ObservedObject var engine: StudioEngine
    @Binding var tbarValue: Double
    var compact = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: compact ? 6 : 8) {
                VStack(spacing: 2) {
                    Text(String(format: "Thời gian %.1fs", engine.transitionDuration)).font(.caption2).foregroundStyle(DS.text2)
                    HStack(spacing: 0) {
                        Button { engine.transitionDuration = max(0.2, engine.transitionDuration - 0.1) } label: { Image(systemName: "minus").frame(maxWidth: .infinity, minHeight: 28) }
                        Divider().frame(height: 18)
                        Button { engine.transitionDuration = min(3, engine.transitionDuration + 0.1) } label: { Image(systemName: "plus").frame(maxWidth: .infinity, minHeight: 28) }
                    }
                    .buttonStyle(.plain)
                    .background(DS.surface2, in: Capsule())
                }
                Text(engine.transition.label).font(.caption.weight(.heavy)).foregroundStyle(DS.accent)
                key("PiP TRANS") { engine.layoutTransition() }
                key("FLASH") { engine.flashTransition() }
                key("CUT") { engine.cut() }.keyboardShortcut(.space, modifiers: [])
                key("AUTO", color: DS.accent, text: .black) { engine.autoTransition() }.keyboardShortcut(.return, modifiers: [])
                TBar(value: $tbarValue) { engine.tbar($0) }
                    .frame(width: compact ? 30 : 40, height: compact ? 90 : 130)
                    .padding(.vertical, 4)
                toggleKey("TITLE", on: engine.armedTitleVisible) { engine.toggleArmedTitle() }
                toggleKey("TITLE 2", on: engine.secondTitle?.visible ?? false, enabled: engine.secondTitle != nil) { engine.toggleSecondTitle() }
                toggleKey("LOGO", on: engine.logoOn, enabled: engine.logo != nil) { engine.logoOn.toggle() }
                toggleKey("LỚP PHỦ", on: engine.foregroundOn, enabled: engine.foreground != nil) { engine.foregroundOn.toggle() }
                toggleKey("PiP", on: engine.pipOn, enabled: engine.pip != nil) { engine.pipOn.toggle() }
                if engine.pip != nil {
                    VStack(spacing: 2) {
                        Text("PiP T-bar").font(.caption2).foregroundStyle(DS.text2)
                        Slider(value: $engine.pipFade, in: 0...1).tint(DS.accent2)
                    }
                }
                toggleKey("FTB", on: engine.fadeToBlack, onColor: DS.pgm) { engine.fadeToBlack.toggle() }
            }
            .padding(compact ? 6 : 10)
        }
        .background(DS.surface)
    }

    private func key(_ t: String, color: Color = DS.surface2, text: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: compact ? 12 : 14, weight: .heavy))
                .frame(maxWidth: .infinity, minHeight: compact ? 34 : 44)
                .foregroundStyle(text)
                .background(color, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    private func toggleKey(_ t: String, on: Bool, enabled: Bool = true, onColor: Color = DS.pvw, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle().fill(on ? onColor : DS.text3).frame(width: 7, height: 7)
                Text(t).font(.system(size: compact ? 10 : 12, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 30 : 36)
            .foregroundStyle(on ? .white : DS.text2)
            .background(on ? onColor.opacity(0.28) : DS.surface2, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? onColor : Color.clear))
        }
        .buttonStyle(.plain)
        .disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
}


/// Template preview: transparent-checker canvas with silhouette windows (drawn, no images).
struct LayoutThumbnail: View {
    let template: LayoutTemplate
    let names: [String]

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                CheckerBackground()
                ForEach(Array(template.slots.enumerated()), id: \.offset) { i, slot in
                    let r = CGRect(x: slot.rect.minX * g.size.width, y: slot.rect.minY * g.size.height,
                                   width: slot.rect.width * g.size.width, height: slot.rect.height * g.size.height)
                    ZStack(alignment: .bottom) {
                        Color.black
                        Image(systemName: "person.fill").resizable().scaledToFit()
                            .foregroundStyle(Color(white: 0.42))
                            .frame(height: r.height * 0.62)
                        Text(names[safe: i] ?? "").font(.system(size: max(7, r.height * 0.13), weight: .bold)).lineLimit(1)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color(white: 0.42), in: Capsule())
                            .padding(.bottom, 2)
                    }
                    .frame(width: r.width, height: r.height)
                    .clipped()
                    .overlay(Rectangle().stroke(DS.accent.opacity(0.85), lineWidth: 1))
                    .rotation3DEffect(.degrees(slot.perspective ? 18 : 0), axis: (x: 0, y: 1, z: 0))
                    .offset(x: r.minX, y: r.minY)
                }
            }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}


/// Shows what a transition looks like on two sample frames ("A" → "B"); the selected one animates.
struct TransitionPreviewView: View {
    let style: TransitionStyle
    var animate: Bool

    var body: some View {
        if animate {
            TimelineView(.periodic(from: .now, by: 1.0 / 12)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.0
                image(min(1, t))
            }
        } else {
            image(0.45)
        }
    }

    private func image(_ p: Double) -> some View {
        Group {
            if let img = TransitionPreviewRenderer.shared.frame(style, progress: p) { Image(uiImage: img).resizable() }
            else { Color.black }
        }
    }
}

final class TransitionPreviewRenderer: @unchecked Sendable {
    static let shared = TransitionPreviewRenderer()
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let size = CGSize(width: 320, height: 180)
    private var cache: [String: UIImage] = [:]
    private let lock = NSLock()
    private lazy var a = sample("A", bg: UIColor(white: 0.93, alpha: 1), fg: UIColor(white: 0.08, alpha: 1))
    private lazy var b = sample("B", bg: UIColor(white: 0.10, alpha: 1), fg: UIColor(white: 0.95, alpha: 1))

    func frame(_ style: TransitionStyle, progress: Double) -> UIImage? {
        let key = "\(style.rawValue)-\(Int(progress * 24))"
        lock.lock(); if let c = cache[key] { lock.unlock(); return c }; lock.unlock()
        let extent = CGRect(origin: .zero, size: size)
        let out = Switcher.blend(a, b, style: style, progress: CGFloat(progress), extent: extent)
        guard let cg = ci.createCGImage(out, from: extent) else { return nil }
        let img = UIImage(cgImage: cg)
        lock.lock(); cache[key] = img; lock.unlock()
        return img
    }

    private func sample(_ letter: String, bg: UIColor, fg: UIColor) -> CIImage {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            bg.setFill(); UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            let a = NSAttributedString(string: letter, attributes: [.font: UIFont.systemFont(ofSize: 130, weight: .black), .foregroundColor: fg])
            a.draw(at: CGPoint(x: (size.width - a.size().width) / 2, y: (size.height - a.size().height) / 2))
        }
        return CIImage(cgImage: img.cgImage!)
    }
}


/// Read-only details for a source (kind, status, resolution, address).
struct SourceInfoView: View {
    @ObservedObject var engine: StudioEngine
    let sourceID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let s = engine.sources.first(where: { $0.id == sourceID }) {
                    LabeledContent("Tên", value: s.name)
                    LabeledContent("Loại", value: s.kind.rawValue.uppercased())
                    LabeledContent("Trạng thái", value: String(describing: s.status))
                    if let pb = s.frames.latest() {
                        LabeledContent("Độ phân giải", value: "\(CVPixelBufferGetWidth(pb))×\(CVPixelBufferGetHeight(pb))")
                    } else {
                        LabeledContent("Độ phân giải", value: "Không có tín hiệu")
                    }
                    if let f = s as? FileSource { LabeledContent("Tệp", value: f.url.lastPathComponent) }
                    LabeledContent("Trên PGM", value: engine.programID == s.id ? "Có" : "Không")
                    LabeledContent("Yêu thích", value: engine.favorites.contains(s.id) ? "Có" : "Không")
                }
            }
            .navigationTitle("Thông tin nguồn")
            .toolbar { Button("Xong") { dismiss() } }
        }
    }
}

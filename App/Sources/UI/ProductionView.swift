import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Bottom half of the studio: category list · content · transition column.
enum ProdCategory: String, CaseIterable, Identifiable {
    case favorite, camera, pip, movie, picture, transition, overlay, title, logo, audio, adjust, auto, replay
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DS.stroke)
            ScrollView {
                content.padding(compact ? 8 : 12)
            }
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
            musicList
            AudioPanel(engine: engine)
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
        HStack(spacing: 12) {
            Toggle("PiP trên Program", isOn: $engine.pipOn).disabled(engine.pip == nil).fixedSize()
            Spacer()
            Picker("Vị trí", selection: $engine.pipPreset) { ForEach(StudioEngine.PiPPreset.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.menu)
        }
        sectionHeader("Chọn nguồn cho khung PiP")
        LazyVGrid(columns: columns, spacing: compact ? 6 : 10) {
            ForEach(engine.sources, id: \.id) { s in
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

    // MARK: Transitions

    @ViewBuilder private var transitionContent: some View {
        LabeledSlider(title: "Thời gian chuyển cảnh", value: $engine.transitionDuration, range: 0.2...3) { String(format: "%.1f s", $0) }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 80 : 110), spacing: 8)], spacing: 8) {
            ForEach(TransitionStyle.allCases.filter { $0 != .cut }) { t in
                Button { engine.transition = t } label: {
                    VStack(spacing: 6) {
                        Image(systemName: t.icon).font(.title2)
                        Text(t.label).font(.caption.weight(.bold))
                    }
                    .frame(maxWidth: .infinity, minHeight: compact ? 60 : 78)
                    .foregroundStyle(engine.transition == t ? Color.black : .white)
                    .background(engine.transition == t ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: 10))
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
                key("FLASH") { engine.flashTransition() }
                key("CUT") { engine.cut() }.keyboardShortcut(.space, modifiers: [])
                key("AUTO", color: DS.accent, text: .black) { engine.autoTransition() }.keyboardShortcut(.return, modifiers: [])
                TBar(value: $tbarValue) { engine.tbar($0) }
                    .frame(width: compact ? 30 : 40, height: compact ? 90 : 130)
                    .padding(.vertical, 4)
                toggleKey("TITLE", on: engine.armedTitleVisible) { engine.toggleArmedTitle() }
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

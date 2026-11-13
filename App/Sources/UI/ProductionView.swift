import CoreVideo
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Bottom half of the studio: category list · content · transition column.
enum ProdCategory: String, CaseIterable, Identifiable {
    case favorite, camera, pip, movie, picture, transition, overlay, title, chat, logo, audio, adjust, auto, replay, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .favorite: return L("Yêu thích")
        case .camera: return "Camera"
        case .pip: return "PiP"
        case .movie: return "Video"
        case .picture: return L("Ảnh")
        case .transition: return L("Chuyển cảnh")
        case .overlay: return "SuperFG"
        case .title: return "Title"
        case .chat: return L("Bình luận")
        case .logo: return "Logo"
        case .audio: return L("Âm thanh")
        case .adjust: return L("Màu & PTZ")
        case .auto: return L("Tự động")
        case .replay: return "Replay"
        case .settings: return L("Cài đặt")
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
        case .chat: return "bubble.left.and.bubble.right.fill"
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
            VStack(spacing: compact ? 3 : 4) {
                ForEach(ProdCategory.allCases) { c in
                    Button { selection = c } label: {
                        Group {
                            if compact {
                                VStack(spacing: 2) {
                                    Image(systemName: c.icon).font(.system(size: 12, weight: .semibold))
                                    Text(LocalizedStringKey(c.label)).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                                }
                                .frame(maxWidth: .infinity, minHeight: 34)
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: c.icon).font(.system(size: 12, weight: .semibold)).frame(width: 16)
                                    Text(LocalizedStringKey(c.label)).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8).frame(height: 30)
                            }
                        }
                        .foregroundStyle(selection == c ? Color.black : DS.text2)
                        .background(selection == c ? Color.white : DS.surface2, in: Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(compact ? 4 : 8)
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
    /// Library the open picker imports into — kept separately so dismissing the picker
    /// (which clears photoKind / importing) never sends a Logo into Ảnh or vice versa.
    @State private var photoTarget: LibraryKind = .picture
    @State private var videoPick = false
    @State private var videoItem: PhotosPickerItem?
    @State private var fileTarget: LibraryKind = .picture
    /// Background picture for PiP layouts, picked straight from Photos / Files and applied at once.
    @State private var bgPhoto: PhotosPickerItem?
    @State private var bgFile = false
    @State private var adjustingSource: UUID?
    @State private var ptzSource: UUID?
    @State private var infoSource: UUID?
    @State private var showOutputs = false

    var body: some View {
        VStack(spacing: 0) {
            if category == .settings {
                SettingsForm(engine: engine, onOpenOutputs: { showOutputs = true })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                        if hasToolbar { header }
                        content
                    }
                    .font(DS.fBody)              // one text size for every category page
                    .controlSize(.small)
                    .padding(compact ? 8 : 12)
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
                      allowedContentTypes: types(fileTarget), allowsMultipleSelection: true) { r in
            switch r {
            case .success(let urls):
                if let err = library.importFiles(urls, into: fileTarget) { engine.message = err }
            case .failure(let e):
                engine.message = "Không mở được tệp: \(e.localizedDescription)"
            }
            importing = nil
        }
        .photosPicker(isPresented: Binding(get: { photoKind != nil }, set: { if !$0 { photoKind = nil } }),
                      selection: $photoItems, matching: .images)
        .photosPicker(isPresented: $videoPick, selection: $videoItem, matching: .videos)
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            Task {
                if let mv = try? await item.loadTransferable(type: PickedMovie.self) {
                    if let err = library.importFiles([mv.url], into: .movie) { engine.message = err }
                    try? FileManager.default.removeItem(at: mv.url)
                } else {
                    engine.message = L("Không đọc được video từ Thư viện ảnh")
                }
                videoItem = nil
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            let k = photoTarget
            Task {
                for i in items { if let d = try? await i.loadTransferable(type: Data.self) { library.importImage(d, into: k, name: k == .logo ? "Logo" : k == .overlay ? "SuperFG" : "Ảnh") } }
                photoItems = []
            }
        }
        .sheet(item: Binding(get: { adjustingSource.map(IDBox.init) }, set: { adjustingSource = $0?.id })) { box in
            NavigationStack {
                ScrollView { SourceAdjustView(engine: engine, sourceID: box.id).padding() }
                    .background(DS.bg)
                    .navigationTitle(engine.sources.first { $0.id == box.id }?.name ?? L("Nguồn"))
                    .toolbar { Button("Xong") { adjustingSource = nil } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var hasToolbar: Bool {
        switch category {
        case .camera, .favorite, .movie, .picture, .overlay, .logo, .audio, .title: return true
        default: return false
        }
    }

    /// Panel actions, pinned to the top-right corner of the panel (no category title).
    private var header: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            switch category {
            case .camera, .favorite:
                if category == .camera, let pv = engine.previewID {
                    iconButton("info.circle", "Thông tin nguồn PVW") { infoSource = pv }
                    iconButton("arrow.up.and.down.and.arrow.left.and.right", "PTZ nguồn PVW") { ptzSource = pv }
                    iconButton("paintpalette", "Màu nguồn PVW") { adjustingSource = pv }
                    iconButton("rotate.right", "Xoay nguồn PVW 90°") {
                        // each tap: +90° clockwise (0 → 90 → 180 → 270 → 0)
                        var p = engine.processing[pv] ?? SourceProcessing()
                        let next = (p.turns + 1) % 4
                        p.rotate180 = false; p.quarterTurns = next == 0 ? nil : next
                        engine.setProcessing(pv, p)
                    }
                }
                headerButton("Thêm nguồn", "plus") { showAddSource = true }
            case .movie:
                Menu {
                    Button { videoPick = true } label: { Label("Thư viện ảnh", systemImage: "photo.on.rectangle") }
                    Button { fileTarget = .movie; importing = .movie } label: { Label("Tệp", systemImage: "folder") }
                } label: { toolbarLabel("Nhập video", "square.and.arrow.down") }
            case .picture, .overlay, .logo:
                importImageMenu(category == .picture ? .picture : category == .overlay ? .overlay : .logo)
            case .audio:
                headerButton("Nhập nhạc", "square.and.arrow.down") { fileTarget = .music; importing = .music }
                headerButton("Nhập hiệu ứng", "sparkles") { fileTarget = .sound; importing = .sound }
            case .title:
                Menu {
                    ForEach(TitleStyle.allCases) { s in
                        Button(s.label) {
                            var t = TitleItem(style: s, line1: s == .clock ? "" : s.label)
                            if s == .logoStrap {   // template: logo + header + name + role, logo = the loaded logo
                                t.header = "DTD STUDIO"; t.line1 = L("Họ và tên"); t.line2 = L("Chức danh")
                                t.logoFile = engine.currentLogoURL?.lastPathComponent
                            }
                            engine.upsertTitle(t)
                        }
                    }
                } label: { toolbarLabel("Thêm title", "plus") }
                headerButton("Ẩn tất cả", "eye.slash") { engine.setTitleVisible(nil, false) }
            default:
                EmptyView()
            }
        }
    }

    private func toolbarButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { toolbarLabel(title, icon) }.buttonStyle(.plain)
    }

    private func toolbarLabel(_ title: String, _ icon: String) -> some View {
        Label(LocalizedStringKey(title), systemImage: icon)
            .font(.system(size: compact ? 11 : 12, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, compact ? 6 : 8).frame(height: compact ? 24 : 28)
            .foregroundStyle(.white)
            .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
            .overlay(RoundedRectangle(cornerRadius: DS.radius).stroke(DS.stroke))
    }

    private func iconButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: compact ? 15 : 18)).frame(width: 30, height: 30) }
            .buttonStyle(.plain).foregroundStyle(DS.text2)
            .accessibilityLabel(label)
    }

    /// One "Nhập ảnh" button; the source (Photos or Files) is chosen from its menu.
    private func importImageMenu(_ k: LibraryKind) -> some View {
        Menu {
            Button { photoTarget = k; photoKind = k } label: { Label("Thư viện ảnh", systemImage: "photo.on.rectangle") }
            Button { fileTarget = k; importing = k } label: { Label("Tệp", systemImage: "folder") }
        } label: { toolbarLabel("Nhập ảnh", "square.and.arrow.down") }
        .id(k)
    }

    private func headerButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(title), systemImage: icon)
                .font(.system(size: compact ? 11 : 12, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, compact ? 6 : 8).frame(height: compact ? 24 : 28)
                .foregroundStyle(.white)
                .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                .overlay(RoundedRectangle(cornerRadius: DS.radius).stroke(DS.stroke))
        }
        .buttonStyle(.plain)
    }

    private func types(_ k: LibraryKind) -> [UTType] {
        switch k {
        case .movie: return [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        case .picture, .logo: return [.image, .png, .jpeg, .heic]
        case .overlay: return [.image, .png, .movie, .quickTimeMovie, .mpeg4Movie]
        case .music, .sound: return [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
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
            sourceGrid(local)
            sectionHeader("Camera mạng (SRT · RTSP · RTMP · DTDLive)")
            sourceGrid(net)
            IngestSection(ingest: engine.ingest, pairing: engine.pairing).padding(.top, 8)
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
            SuperFGPanel(engine: engine, compact: compact)
            sectionHeader("SuperFG của bạn: ảnh PNG/JPG chạy như thẻ có hiệu ứng · video .mov có kênh alpha")
            libraryGrid(.overlay, selected: engine.currentForegroundURL) { engine.useForeground($0) }
        case .title:
            HTMLGraphicsPanel(html: engine.html, repo: engine.graphicsRepo, compact: true,
                              background: engine.switcher.previewMonitor,
                              aspect: CGFloat(engine.format.width) / CGFloat(max(engine.format.height, 1))).padding(.bottom, 2)
            ScoreboardControl(engine: engine, compact: true).padding(.bottom, 2)
            TitlesPanel(engine: engine)
        case .logo:
            HStack {
                Label(engine.logo == nil ? "Chưa nạp logo" : (engine.logoOn ? "Logo đang trên PGM" : "Logo đã nạp — bấm Logo On"),
                      systemImage: "seal").font(DS.fBody).foregroundStyle(engine.logoOn ? DS.pgm : DS.text2)
                Spacer()
                Picker("Vị trí", selection: $engine.logoCorner) { ForEach(StudioEngine.Corner.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).frame(maxWidth: 380)
            }
            HStack(spacing: 16) {
                LabeledSlider(title: "Cỡ logo", value: $engine.logoSize, range: 0.03...0.4) { "\(Int($0 * 100))%" }
                LabeledSlider(title: "Độ trong", value: $engine.logoOpacity, range: 0.1...1) { "\(Int($0 * 100))%" }
            }
            .frame(maxWidth: 560)
            .disabled(engine.logo == nil)
            libraryGrid(.logo, selected: engine.currentLogoURL) { engine.useLogo($0) }
        case .audio:
            AudioMixerView(engine: engine, library: library, compact: compact)
            musicList
            effectsPads
        case .adjust:
            SourcePanel(engine: engine)
        case .chat:
            LiveChatPanel(chat: engine.liveChat, compact: compact)
        case .auto:
            AutoPanel(auto: engine.autoSwitcher, engine: engine)
        case .replay:
            ReplayPanel(engine: engine)
        }
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(LocalizedStringKey(t)).textCase(.uppercase).font(DS.fHeader).foregroundStyle(DS.text2).tracking(0.6)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    private func emptyHint(_ t: String) -> some View {
        Text(LocalizedStringKey(t)).font(DS.fBody).foregroundStyle(DS.text3).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
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

    /// Background behind the layout windows: colour, a picture from the library, or a blurred live input.
    @ViewBuilder private var layoutBackgroundPicker: some View {
        sectionHeader("Nền bố cục")
        let bg = engine.layoutBackground
        let isColor: Bool = { if case .color = bg { return true }; return false }()
        HStack(spacing: 10) {
            ColorPicker("Màu nền", selection: Binding(
                get: { if case .color(let h) = bg { return Color(UIColor(hex: h)) } else { return Color(white: 0.05) } },
                set: { engine.layoutBackground = .color(UIColor($0).hexString) }), supportsOpacity: false)
                .font(DS.fBodyBold).fixedSize()
            if !isColor {
                Button("Bỏ ảnh nền") { engine.layoutBackground = .color("#0A0D12") }
                    .font(DS.fBodyBold).buttonStyle(.bordered)
            }
            Spacer()
            PhotosPicker(selection: $bgPhoto, matching: .images) { toolbarLabel("Ảnh nền từ Thư viện", "photo.on.rectangle") }
                .buttonStyle(.plain)
            toolbarButton("Tệp", "folder") { bgFile = true }
        }
        .onChange(of: bgPhoto) { _, item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self),
                   let url = library.importImage(d, into: .picture, name: "Nen") {
                    engine.layoutBackground = .picture(url.lastPathComponent)
                }
                bgPhoto = nil
            }
        }
        .fileImporter(isPresented: $bgFile, allowedContentTypes: [.image]) { r in
            if case .success(let u) = r {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                if let d = try? Data(contentsOf: u), let url = library.importImage(d, into: .picture, name: "Nen") {
                    engine.layoutBackground = .picture(url.lastPathComponent)
                }
            }
        }
        let pics = library.list(.picture)
        if pics.isEmpty {
            emptyHint("Chưa có ảnh nền — bấm Ảnh nền từ Thư viện hoặc Tệp")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pics, id: \.self) { url in
                        let on = bg == .picture(url.lastPathComponent)
                        Button { engine.layoutBackground = .picture(url.lastPathComponent) } label: {
                            LibraryCell(url: url, kind: .picture, selected: on)
                                .frame(width: compact ? 120 : 160)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        let live = engine.sources.filter { $0.id != engine.layoutSource.id }
        if !live.isEmpty {
            Menu {
                ForEach(live, id: \.id) { s in Button(s.name) { engine.layoutBackground = .source(s.id) } }
            } label: {
                let cur: String = { if case .source(let id) = bg { return engine.sources.first { $0.id == id }?.name ?? "—" }; return L("chọn nguồn") }()
                Label("Nền là nguồn video (làm mờ): \(cur)", systemImage: "camera.filters").font(DS.fBodyBold)
            }
        }
    }

    /// Frame drawn around each layout window: built-in designs, or a PNG from the SuperFG library.
    @ViewBuilder private var layoutFramePicker: some View {
        sectionHeader("Khung viền")
        HStack(spacing: 6) {
            ForEach(LayoutFrame.Style.allCases) { st in
                let on = engine.layoutFrame.style == st
                Button { engine.layoutFrame.style = st } label: {
                    Text(verbatim: st.label).font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: compact ? 28 : 32)
                        .foregroundStyle(on ? .black : .white)
                        .background(on ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        switch engine.layoutFrame.style {
        case .none:
            EmptyView()
        case .image:
            let pngs = library.list(.overlay).filter { ["png", "heic"].contains($0.pathExtension.lowercased()) }
            HStack {
                Text("PNG có tâm trong suốt, lấy từ thư viện SuperFG").font(.caption2).foregroundStyle(DS.text3)
                Spacer()
                importImageMenu(.overlay)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pngs, id: \.self) { url in
                        Button { engine.layoutFrame.imageName = url.lastPathComponent } label: {
                            LibraryCell(url: url, kind: .overlay, selected: engine.layoutFrame.imageName == url.lastPathComponent)
                                .frame(width: compact ? 120 : 160)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        default:
            HStack(spacing: 14) {
                ColorPicker("Màu 1", selection: Binding(get: { Color(UIColor(hex: engine.layoutFrame.color1)) },
                                                         set: { engine.layoutFrame.color1 = UIColor($0).hexString }), supportsOpacity: false).fixedSize()
                if engine.layoutFrame.style != .line {
                    ColorPicker("Màu 2", selection: Binding(get: { Color(UIColor(hex: engine.layoutFrame.color2)) },
                                                             set: { engine.layoutFrame.color2 = UIColor($0).hexString }), supportsOpacity: false).fixedSize()
                }
                if engine.layoutFrame.style == .tech {
                    ColorPicker("Màu 3", selection: Binding(get: { Color(UIColor(hex: engine.layoutFrame.color3)) },
                                                             set: { engine.layoutFrame.color3 = UIColor($0).hexString }), supportsOpacity: false).fixedSize()
                }
                Spacer()
            }
            .font(DS.fBodyBold)
            LabeledSlider(title: "Độ dày", value: $engine.layoutFrame.thickness, range: 0.004...0.04) { String(format: "%.1f%%", $0 * 100) }
                .frame(maxWidth: 420)
        }
    }

    @ViewBuilder private var pipContent: some View {
        sectionHeader("Mẫu bố cục")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 150 : 220), spacing: compact ? 6 : 10)], spacing: compact ? 6 : 10) {
            ForEach(LayoutTemplate.all) { t in
                Button { engine.chooseLayout(t.id) } label: {
                    LayoutThumbnail(template: t, names: [], singleScale: engine.layoutSingleScale)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .accessibilityLabel(t.name)
                        .clipShape(Rectangle())
                    .overlay(RoundedRectangle(cornerRadius: DS.radius).stroke(engine.layoutTemplateID == t.id ? DS.accent : DS.stroke,
                                                                     lineWidth: engine.layoutTemplateID == t.id ? 3 : 1))
                }
                .buttonStyle(.plain)
            }
        }
        sectionHeader("Chỉnh khung")
        HStack(spacing: 6) {
            toolbarButton("Thêm khung", "plus.rectangle") { engine.insertLayoutWindow() }
            toolbarButton("Xoá khung \(engine.layoutSelectedSlot + 1)", "minus.rectangle") { engine.removeLayoutWindow(engine.layoutSelectedSlot) }
                .disabled(engine.layoutTemplate.slots.count < 2)
            if engine.layoutEdited {
                toolbarButton("Khôi phục mẫu", "arrow.uturn.backward") { engine.resetLayoutEdits() }
            }
            Spacer(minLength: 0)
        }
        LayoutEditor(engine: engine)
            .frame(maxWidth: 640)
        if engine.layoutTemplate.slots.count == 1 && !engine.layoutEdited && !engine.layoutTemplate.slots[0].perspective {
            LabeledSlider(title: "Cỡ khung", value: $engine.layoutSingleScale, range: 0.2...1) { "\(Int($0 * 100))%" }
                .frame(maxWidth: 420)
        }
        layoutBackgroundPicker
        layoutFramePicker
        if !engine.layoutSlots.isEmpty {
            sectionHeader("Gán nguồn")
            HStack(spacing: 6) {
                ForEach(engine.layoutSlots.indices, id: \.self) { i in
                    let sel = engine.layoutSelectedSlot == i
                    Button { engine.layoutSelectedSlot = i } label: {
                        Text("Khung \(i + 1): \(engine.sources.first { $0.id == engine.layoutSlots[i] }?.name ?? "trống")")
                            .font(DS.fBodyBold).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .foregroundStyle(sel ? .black : .white)
                            .background(sel ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
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
                        .clipShape(Rectangle())
                        .overlay(Rectangle().stroke(engine.layoutSlots.contains(s.id) ? DS.accent2 : DS.stroke,
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
                    .clipShape(Rectangle())
                    .overlay(Rectangle().stroke(on ? DS.accent2 : DS.stroke, lineWidth: on ? 3 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func slotNames(for t: LayoutTemplate) -> [String] {
        (0..<t.slots.count).map { i in
            if t.id == engine.layoutTemplateID, i < engine.layoutSlots.count,
               let n = engine.sources.first(where: { $0.id == engine.layoutSlots[i] })?.name { return n }
            return i == 0 ? L("Chính") : "Cam \(i + 1)"
        }
    }

    // MARK: Transitions

    @ViewBuilder private var transitionContent: some View {
        LabeledSlider(title: "Thời gian chuyển cảnh", value: $engine.transitionDuration, range: 0.2...3) { String(format: "%.1f s", $0) }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 130 : 200), spacing: compact ? 6 : 10)], spacing: compact ? 6 : 10) {
            ForEach(Array(TransitionStyle.allCases.filter { $0 != .cut }.enumerated()), id: \.element) { i, t in
                Button { engine.transition = t; engine.superFG.asTransition = false } label: {
                    VStack(spacing: 0) {
                        TransitionPreviewView(style: t, animate: (engine.transition == t && !engine.superFGStingerReady))
                            .aspectRatio(16 / 9, contentMode: .fit)
                        Text("\(i + 1): \(t.label)").font(DS.fBodyBold)
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .foregroundStyle((engine.transition == t && !engine.superFGStingerReady) ? Color.black : .white)
                            .background((engine.transition == t && !engine.superFGStingerReady) ? DS.accent : DS.surface)
                    }
                    .clipShape(Rectangle())
                    .overlay(Rectangle().stroke((engine.transition == t && !engine.superFGStingerReady) ? DS.accent : DS.stroke, lineWidth: (engine.transition == t && !engine.superFGStingerReady) ? 3 : 1))
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
            else if k == .movie || k == .picture { Text("Chạm để đưa lên PVW, rồi Cut / chuyển cảnh ở cột phải").font(.caption2).foregroundStyle(DS.text3) }
            else if k == .logo || k == .overlay { Text("Chạm để nạp, bật/tắt bằng phím ở cột phải").font(.caption2).foregroundStyle(DS.text3) }
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

    /// Sound-effect pads: one tap plays the file once on the music channel (applause, stinger, whistle…).
    @ViewBuilder private var effectsPads: some View {
        SectionCard("Hiệu ứng âm thanh", systemImage: "sparkles") {
            let items = library.list(.sound)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 90 : 120), spacing: 8)], spacing: 8) {
                ForEach(items, id: \.self) { url in
                    Button { engine.playEffect(url) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "speaker.wave.2.circle.fill").font(.title2)
                            Text(url.deletingPathExtension().lastPathComponent).font(DS.fBodyBold).lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: compact ? 56 : 70)
                        .foregroundStyle(.white)
                        .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Xoá", role: .destructive) { library.delete(url) } }
                }
            }
        }
    }

    @ViewBuilder private var musicList: some View {
        SectionCard("Nhạc nền", systemImage: "music.note.list") {
            let items = library.list(.music)
            ForEach(items, id: \.self) { url in
                HStack {
                    Image(systemName: engine.nowPlayingMusic == url ? "speaker.wave.2.fill" : "music.note")
                        .foregroundStyle(engine.nowPlayingMusic == url ? DS.accent : DS.text2)
                    Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                    Spacer()
                    Button(engine.nowPlayingMusic == url ? "Dừng" : "Phát") { engine.toggleMusic(url) }
                        .buttonStyle(.bordered).font(DS.fBody)
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
                        Text(e).font(.caption2).padding(6).background(.black.opacity(0.7), in: Rectangle()).lineLimit(1)
                    } else if source.status == .connecting {
                        Text("Đang kết nối…").font(.caption2.weight(.semibold)).padding(6).background(.black.opacity(0.7), in: Rectangle())
                    } else if source.frames.latest() == nil {
                        Text("Không có tín hiệu").font(DS.fBodyBold).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.6), in: Rectangle())
                            .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                    }
                }
            }
            HStack(spacing: 6) {
                Text("\(index)").font(.caption2.weight(.heavy)).frame(width: 18, height: 18)
                    .background(pgm ? DS.pgm : pvw ? DS.pvw : DS.surface2, in: Rectangle())
                Text(source.name).font(DS.fBodyBold).lineLimit(1)
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
        .clipShape(Rectangle())
        .overlay(RoundedRectangle(cornerRadius: DS.radius).stroke(pgm ? DS.pgm : pvw ? DS.pvw : DS.stroke, lineWidth: pgm || pvw ? 3 : 1))
        .contentShape(Rectangle())
        .onTapGesture { engine.select(source.id) }
    }
}

struct LibraryCell: View {
    /// "Ảnh-20261111-160015.png" → "11/11 16:00:15"; other names without extension.
    static func displayName(_ url: URL) -> String {
        let n = url.deletingPathExtension().lastPathComponent
        let parts = n.split(separator: "-")
        if parts.count == 3, parts[1].count == 8, parts[2].count == 6, let _ = Int(parts[1]), let _ = Int(parts[2]) {
            let d = Array(parts[1]), t = Array(parts[2])
            return "\(String(d[6...7]))/\(String(d[4...5])) \(String(t[0...1])):\(String(t[2...3])):\(String(t[4...5]))"
        }
        return n
    }

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
            Text(Self.displayName(url)).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(DS.text2)
                .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).background(DS.surface)
        }
        .clipShape(Rectangle())
        .overlay(Rectangle().stroke(selected ? DS.accent : DS.stroke, lineWidth: selected ? 3 : 1))
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
    /// PiP T-Bar: the T-bar fades the PiP in/out instead of running the program transition.
    @State private var pipTBar = false
    @State private var pipDir: Double?

    /// PiP T-bar: pulls the PiP in when it is off, out when it is on; releasing early restores it.
    private func pipT(_ v: Double) {
        if pipDir == nil {
            if v <= 0.001 { return }
            pipDir = engine.pipOn ? -1 : 1
            if !engine.pipOn { engine.pipOn = true; engine.pipFade = 0 }
        }
        let dir = pipDir ?? 1
        engine.pipFade = dir < 0 ? 1 - v : v
        if v >= 0.999 {
            if dir < 0 { engine.pipOn = false } else { engine.pipFade = 1 }
            pipDir = nil
        } else if v <= 0.001 {
            if dir > 0 { engine.pipOn = false } else { engine.pipFade = 1 }
            pipDir = nil
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: compact ? 6 : 8) {
                VStack(spacing: 2) {
                    Text(String(format: L("Thời gian %.1fs"), engine.transitionDuration)).font(.caption2).foregroundStyle(DS.text2)
                    HStack(spacing: 0) {
                        Button { engine.transitionDuration = max(0.2, engine.transitionDuration - 0.1) } label: { Image(systemName: "minus").frame(maxWidth: .infinity, minHeight: 24) }
                        Divider().frame(height: 18)
                        Button { engine.transitionDuration = min(3, engine.transitionDuration + 0.1) } label: { Image(systemName: "plus").frame(maxWidth: .infinity, minHeight: 24) }
                    }
                    .buttonStyle(.plain)
                    .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                }
                key("PiP Trans", enabled: engine.layoutSlots.count > 0) { engine.layoutTransition() }
                // AUTO key named after the selected transition (Dissolve, Wipe…)
                if engine.superFGStingerReady {
                    // A selected SuperFG card is the transition: tap to go back to the normal one.
                    Button { engine.superFG.asTransition = false } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles.rectangle.stack").font(.caption2)
                            Text("SuperFG").font(.caption2.weight(.bold))
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(.black).frame(maxWidth: .infinity, minHeight: 22)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: DS.radius))
                    }
                    .buttonStyle(.plain)
                }
                key(engine.superFGStingerReady ? "SUPERFG" : engine.transition.label, color: engine.superFGStingerReady ? .orange : DS.accent, text: .black) { engine.autoTransition() }.keyboardShortcut(.return, modifiers: [])
                key("Cut") { engine.cut() }.keyboardShortcut(.space, modifiers: [])
                HStack(spacing: 6) {
                    TBarLEDs(value: tbarValue, pip: pipTBar)
                    TBar(value: $tbarValue) { v in if pipTBar { pipT(v) } else { engine.tbar(v) } }
                        .frame(width: compact ? 30 : 38, height: compact ? 86 : 124)
                }
                .padding(.vertical, 4)
                onKey("SuperFG", on: engine.foregroundOn, enabled: engine.superFGArmed) { engine.foregroundOn.toggle() }
                onKey("Title", on: engine.armedTitleVisible, enabled: !engine.titles.isEmpty) { engine.toggleArmedTitle() }
                onKey("HTML", on: engine.html.onAir, enabled: engine.html.loadedID != nil) { engine.html.toggle() }
                onKey("Title 2", on: engine.secondTitle?.visible ?? false, enabled: engine.secondTitle != nil) { engine.toggleSecondTitle() }
                onKey("Logo", on: engine.logoOn, enabled: engine.logo != nil) { engine.logoOn.toggle() }
                onKey("PiP", on: engine.pipOn, enabled: engine.pip != nil) { engine.pipOn.toggle() }
                onKey("PiP T-Bar", on: pipTBar, enabled: engine.pip != nil, suffix: false) { pipTBar.toggle() }
                toggleKey("FTB", on: engine.fadeToBlack, onColor: DS.pgm) { engine.fadeToBlack.toggle() }
            }
            .padding(compact ? 4 : 8)
        }
        .background(DS.surface)
    }

    /// Layer keys styled like hardware: "<name> On", lit white while the layer is on air.
    private func onKey(_ t: String, on: Bool, enabled: Bool = true, suffix: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(suffix ? "\(t) On" : t)).font(.system(size: compact ? 11 : 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: compact ? 29 : 37)
                .foregroundStyle(on ? .black : DS.text2)
                .background(on ? Color.white : DS.surface2, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(on ? 0 : 0.12)))
                .shadow(color: on ? .white.opacity(0.35) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
        .disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }

    /// Keys use one case style: "Cut", "Quét", "PiP Trans" (labels like "QUÉT" are normalised).
    static func keyCase(_ t: String) -> String {
        guard t == t.uppercased(), t.count > 1 else { return t }
        return String(t.prefix(1)) + t.dropFirst().lowercased()
    }

    private func key(_ t: String, color: Color = DS.surface2, text: Color = .white, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(Self.keyCase(t))).font(.system(size: compact ? 11 : 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: compact ? 29 : 37)
                .foregroundStyle(text)
                .background(color, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }

    private func toggleKey(_ t: String, on: Bool, enabled: Bool = true, onColor: Color = DS.pvw, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle().fill(on ? onColor : DS.text3).frame(width: 7, height: 7)
                Text(LocalizedStringKey(t)).font(.system(size: compact ? 9 : 10, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 26 : 31)
            .foregroundStyle(on ? .white : DS.text2)
            .background(on ? onColor.opacity(0.28) : DS.surface2, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? onColor : Color.clear))
        }
        .buttonStyle(.plain)
        .disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
}


/// Template preview: transparent-checker canvas with silhouette windows (drawn, no images).
struct LayoutThumbnail: View {
    let template: LayoutTemplate
    let names: [String]
    var singleScale: Double? = nil

    private var slots: [LayoutTemplate.Slot] {
        guard template.slots.count == 1, let k = singleScale.map({ CGFloat($0) }) else { return template.slots }
        var s = template.slots[0]
        s.rect = CGRect(x: (1 - k) / 2, y: (1 - k) / 2, width: k, height: k)
        return [s]
    }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                CheckerBackground()
                ForEach(Array(slots.enumerated()), id: \.offset) { i, slot in
                    let r = CGRect(x: slot.rect.minX * g.size.width, y: slot.rect.minY * g.size.height,
                                   width: slot.rect.width * g.size.width, height: slot.rect.height * g.size.height)
                    ZStack(alignment: .bottom) {
                        Color.black
                        Image(systemName: "person.fill").resizable().scaledToFit()
                            .foregroundStyle(Color(white: 0.42))
                            .frame(height: r.height * 0.62)
                        if let n = names[safe: i], !n.isEmpty {
                            Text(n).font(.system(size: max(7, r.height * 0.13), weight: .bold)).lineLimit(1)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color(white: 0.42), in: Rectangle())
                                .padding(.bottom, 2)
                        }
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
    @ObservedObject private var linkStats = DTDLiveStats.shared
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
                        if CVPixelBufferGetHeight(pb) < min(engine.format.height, engine.format.width) * 9 / 10 {
                            Text(LF("Nguồn nhỏ hơn chương trình (%@×%@): hình bị phóng to nên mềm trên YouTube/Facebook. Đặt camera/DTDLive cùng độ phân giải với chương trình.",
                                    "\(engine.format.width)", "\(engine.format.height)"))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        LabeledContent("Độ phân giải", value: "Không có tín hiệu")
                    }
                    if let f = s as? FileSource { LabeledContent("Tệp", value: f.url.lastPathComponent) }
                    if let l = linkStats.lines[s.id] {
                        Section(header: Text("Đường truyền Wi‑Fi (DTDLive)")) {
                            LabeledContent("Tốc độ nhận", value: String(format: "%.1f Mbps", l.mbps))
                            LabeledContent("RTT", value: String(format: "%.0f ms", l.rttMs))
                            LabeledContent("Mất gói (2 s gần nhất)", value: String(format: "%.1f %%", l.lossPct))
                            LabeledContent("Gói bị bỏ (đến trễ)", value: "\(l.droppedPkts) · " + LF("tổng %@", "\(l.totalDropped)"))
                            LabeledContent("Khung hình hỏng bị bỏ qua", value: "\(l.brokenFrames) · " + LF("tổng %@", "\(l.totalBroken)"))
                            LabeledContent("Độ trễ SRT / bộ đệm", value: "\(l.latencyMs) ms / \(l.bufferMs) ms")
                            // The camera feed is decoded and encoded again for the platforms: below ~1.5× the
                            // output bitrate the PGM inherits the camera's compression on top of its own.
                            if l.mbps > 0.3, l.mbps < Double(engine.encoder.bitrate) / 1e6 * 1.5 {
                                Text(LF("Camera gửi %@ Mbps — thấp so với bitrate phát %@ Mbps: hình bị nén hai lần nên mờ. Cập nhật DTDLive (tự gửi ~12 Mbps cho 1080p30 qua Wi‑Fi) hoặc tăng bitrate trên DTDLive.",
                                        String(format: "%.1f", l.mbps), String(format: "%.1f", Double(engine.encoder.bitrate) / 1e6)))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Text(l.grade == 0 ? "Đường truyền tốt." :
                                 l.grade == 1 ? "Wi‑Fi chập chờn: SRT đang gửi lại gói, hình vẫn đủ." :
                                 "Gói đến quá trễ bị bỏ → hình giật. Tăng độ trễ Wi‑Fi (Cài đặt › Kết nối), dùng Wi‑Fi 5 GHz, đặt máy gần router hoặc giảm bitrate trên DTDLive.")
                                .font(.caption).foregroundStyle(l.grade == 2 ? .red : l.grade == 1 ? .orange : .green)
                        }
                    }
                    LabeledContent("Trên PGM", value: L(engine.programID == s.id ? "Có" : "Không"))
                    LabeledContent("Yêu thích", value: L(engine.favorites.contains(s.id) ? "Có" : "Không"))
                }
            }
            .navigationTitle("Thông tin nguồn")
            .toolbar { Button("Xong") { dismiss() } }
        }
    }
}


/// Direct-manipulation editor for the PiP layout: drag a window to move it, drag its corner to resize.
/// Windows are always kept fully inside the frame (StudioEngine.clampWindow).
struct LayoutEditor: View {
    @ObservedObject var engine: StudioEngine
    @State private var startRect: CGRect?

    var body: some View {
        GeometryReader { g in
            let W = g.size.width, H = g.size.height
            ZStack(alignment: .topLeading) {
                MonitorView(store: engine.layoutSource.frames, maxFPS: 15)
                ForEach(Array(engine.layoutTemplate.slots.enumerated()), id: \.offset) { i, slot in
                    window(i, slot.rect, W: W, H: H)
                }
            }
            .clipped()
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(Rectangle().stroke(DS.stroke))
    }

    @ViewBuilder
    private func window(_ i: Int, _ r: CGRect, W: CGFloat, H: CGFloat) -> some View {
        let sel = engine.layoutSelectedSlot == i
        let name = engine.layoutSlots.indices.contains(i)
            ? (engine.sources.first { $0.id == engine.layoutSlots[i] }?.name ?? "—") : "—"
        Rectangle()
            .fill(Color.white.opacity(sel ? 0.10 : 0.02))
            .overlay(Rectangle().stroke(sel ? DS.accent : Color.white.opacity(0.75), lineWidth: sel ? 2 : 1))
            .overlay(alignment: .topLeading) {
                Text(verbatim: "\(i + 1) · \(name)").font(.system(size: 10, weight: .bold)).lineLimit(1)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .foregroundStyle(sel ? .black : .white)
                    .background(sel ? DS.accent : Color.black.opacity(0.6))
            }
            .overlay(alignment: .bottomTrailing) {
                // resize handle
                Rectangle().fill(sel ? DS.accent : Color.white)
                    .frame(width: 18, height: 18)
                    .overlay(Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.black))
                    .highPriorityGesture(DragGesture(minimumDistance: 1)
                        .onChanged { d in
                            engine.layoutSelectedSlot = i
                            let s = startRect ?? r
                            if startRect == nil { startRect = r }
                            let nr = CGRect(x: s.minX, y: s.minY,
                                            width: min(s.width + d.translation.width / W, 1 - s.minX),
                                            height: min(s.height + d.translation.height / H, 1 - s.minY))
                            engine.setLayoutWindow(i, nr)
                        }
                        .onEnded { _ in startRect = nil })
            }
            .frame(width: r.width * W, height: r.height * H)
            .contentShape(Rectangle())
            .offset(x: r.minX * W, y: r.minY * H)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { d in
                    engine.layoutSelectedSlot = i
                    let s = startRect ?? r
                    if startRect == nil { startRect = r }
                    engine.setLayoutWindow(i, s.offsetBy(dx: d.translation.width / W, dy: d.translation.height / H))
                }
                .onEnded { _ in startRect = nil })
            .onTapGesture { engine.layoutSelectedSlot = i }
    }
}


/// A video picked from Photos, copied to a temp file the library then imports.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { m in SentTransferredFile(m.url) } importing: { r in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(r.file.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: r.file, to: dst)
            return PickedMovie(url: dst)
        }
    }
}

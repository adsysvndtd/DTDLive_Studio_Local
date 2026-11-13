@preconcurrency import AVFoundation
import Combine
import CoreImage
import Foundation
import ImageIO
import SwiftUI

/// Wires sources -> switcher -> encoders -> outputs, plus graphics, audio mixer,
/// replay, remote control, tally and PTZ, and exposes state to SwiftUI.
@MainActor
final class StudioEngine: ObservableObject {
    static weak var shared: StudioEngine?

    // MARK: Published state
    @Published private(set) var sources: [any VideoSource] = []
    @Published private(set) var programID: UUID?
    @Published private(set) var previewID: UUID?
    @Published var transition: TransitionStyle = .mix
    @Published var transitionDuration: Double = 0.8
    @Published var outputs: [OutputConfig] = [] { didSet { saveOutputs() } }
    @Published private(set) var outputStatus: [UUID: OutputStatus] = [:]
    @Published var encoder = EncoderSettings() {
        didSet { videoEncoder.update(encoder); currentBitrate = encoder.bitrate; UserDefaults.standard.set(try? JSONEncoder().encode(encoder), forKey: "dtd.encoder.v1") }
    }
    @Published var format = ProgramFormat() {
        didSet {
            switcher.setFormat(format)
            videoEncoder.fps = Double(format.fps)
            UserDefaults.standard.set(try? JSONEncoder().encode(format), forKey: "dtd.format.v1")
        }
    }
    @Published var logo: OverlayLayer? { didSet { pushOverlays() } }
    @Published var pip: OverlayLayer? { didSet { pushOverlays() } }
    /// Full-frame foreground graphic (PNG with alpha: frames, bugs, sponsor bars).
    @Published var foreground: OverlayLayer? { didSet { pushOverlays() } }

    // MARK: Production state (library / quick keys)
    let library = MediaLibrary()
    let replayEditor = ReplayEditor()
    let pairing = PairingManager()
    /// Push ingest (SRT / RTMP / RTSP, one port each, many stream keys) + DTDLive pairing.
    let ingest = IngestHub()
    /// HTML5 graphics (lower thirds, tickers) synced from Git.
    let html = HTMLGraphics()
    let graphicsRepo = GraphicsRepo()
    private var htmlChange: AnyCancellable?

    // MARK: Multi-source layouts (PiP templates)
    private(set) lazy var layoutSource = LayoutSource()
    @Published var layoutTemplateID = 2
    /// Decorative frame around layout windows.
    @Published var layoutFrame: LayoutFrame = StudioEngine.load(LayoutFrame.self, key: "dtd.layoutframe.v1") ?? LayoutFrame() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(layoutFrame), forKey: "dtd.layoutframe.v1"); refreshLayout() }
    }
    /// Size of the window in the one-window layouts (1 = full frame), centred on the background.
    @Published var layoutSingleScale: Double = UserDefaults.standard.object(forKey: "dtd.layout.single") as? Double ?? 0.7 {
        didSet { UserDefaults.standard.set(layoutSingleScale, forKey: "dtd.layout.single"); refreshLayout() }
    }
    @Published var layoutSlots: [UUID?] = []
    @Published var layoutSelectedSlot = 0
    var controlPort: UInt16 { control.httpPort }
    /// Lets any view jump the studio to a category (e.g. "open in Replay" from the Video library).
    @Published var requestedCategory: ProdCategory?
    @Published var favorites: Set<UUID> = []
    @Published var pipPreset: PiPPreset = .bottomRight { didSet { applyPiPPreset() } }
    @Published var pipOn = false { didSet { pip?.visible = pipOn; if pipOn { pip?.opacity = 1; pipFade = 1 } } }
    /// PiP T-bar: 0 = hidden, 1 = fully shown.
    @Published var pipFade: Double = 1 { didSet { pip?.opacity = CGFloat(pipFade); pip?.visible = pipFade > 0.01 } }
    @Published var logoCorner: Corner = .topRight { didSet { if let l = logo { logo?.rect = logoCorner.rect(size: l.rect.size) } } }
    /// Logo height as a fraction of the frame (width follows the image aspect).
    @Published var logoSize: Double = UserDefaults.standard.object(forKey: "dtd.logo.size") as? Double ?? 0.12 {
        didSet { UserDefaults.standard.set(logoSize, forKey: "dtd.logo.size"); resizeLogo() }
    }
    @Published var logoOpacity: Double = UserDefaults.standard.object(forKey: "dtd.logo.opacity") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(logoOpacity, forKey: "dtd.logo.opacity"); logo?.opacity = CGFloat(logoOpacity) }
    }
    private var logoAspect: CGFloat = 1
    @Published var logoOn = false { didSet { logo?.visible = logoOn } }
    @Published var foregroundOn = false {
        didSet {
            foreground?.visible = foregroundOn
            guard oldValue != foregroundOn, superFGActiveTemplate != nil || libraryCardURL != nil else { return }
            foregroundOn ? playSuperFGCard() : switcher.hideCard()
        }
    }
    /// SuperFG key can be pressed: a card or a library foreground is loaded.
    var superFGArmed: Bool { foreground != nil || superFGActiveTemplate != nil || libraryCardURL != nil }
    /// A still picture from the SuperFG library loaded as an animated card (plays with SuperFGConfig.libraryMotion).
    @Published private(set) var libraryCardURL: URL?
    @Published var armedTitleID: UUID?
    /// Title assigned to the "Title 2 On" key (default: first title other than the armed one).
    @Published var armedTitle2ID: UUID?
    @Published private(set) var currentLogoURL: URL?
    @Published private(set) var currentForegroundURL: URL?
    @Published private(set) var nowPlayingMusic: URL?
    @Published var showSafeGuides = false
    @Published var showMonitorInfo = false
    /// One-line operator message (import / playback errors), shown as an alert.
    @Published var message: String?
    /// Swipe on PVW toward PGM: 1 finger = CUT, 2 fingers = AUTO.
    @Published var swipeToTake = UserDefaults.standard.object(forKey: "swipeToTake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(swipeToTake, forKey: "swipeToTake") }
    }
    @Published var externalSafeGuides = false

    enum PiPPreset: String, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight, large, sideLeft
        var id: String { rawValue }
        var label: String {
            switch self {
            case .topLeft: return L("Trên trái")
            case .topRight: return L("Trên phải")
            case .bottomLeft: return L("Dưới trái")
            case .bottomRight: return L("Dưới phải")
            case .large: return L("Lớn giữa phải")
            case .sideLeft: return L("Nửa trái")
            }
        }
        var rect: CGRect {
            switch self {
            case .topLeft: return CGRect(x: 0.04, y: 0.05, width: 0.30, height: 0.30)
            case .topRight: return CGRect(x: 0.66, y: 0.05, width: 0.30, height: 0.30)
            case .bottomLeft: return CGRect(x: 0.04, y: 0.63, width: 0.30, height: 0.30)
            case .bottomRight: return CGRect(x: 0.66, y: 0.63, width: 0.30, height: 0.30)
            case .large: return CGRect(x: 0.45, y: 0.20, width: 0.52, height: 0.52)
            case .sideLeft: return CGRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0)
            }
        }
    }

    enum Corner: String, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: String { rawValue }
        var label: String { L(["topLeft": "Trên trái", "topRight": "Trên phải", "bottomLeft": "Dưới trái", "bottomRight": "Dưới phải"][rawValue]!) }
        func rect(size: CGSize) -> CGRect {
            let m: CGFloat = 0.03
            switch self {
            case .topLeft: return CGRect(x: m, y: m, width: size.width, height: size.height)
            case .topRight: return CGRect(x: 1 - m - size.width, y: m, width: size.width, height: size.height)
            case .bottomLeft: return CGRect(x: m, y: 1 - m - size.height, width: size.width, height: size.height)
            case .bottomRight: return CGRect(x: 1 - m - size.width, y: 1 - m - size.height, width: size.width, height: size.height)
            }
        }
    }
    @Published var fadeToBlack = false { didSet { switcher.setFadeToBlack(fadeToBlack) } }
    @Published private(set) var audioLevel: Float = -60
    @Published private(set) var audioChannels: [AudioChannelState] = []
    @Published var titles: [TitleItem] = [] { didSet { saveTitles() } }
    @Published private(set) var processing: [UUID: SourceProcessing] = [:]
    @Published var scopeKind: ScopeKind = .waveform
    @Published var scopesEnabled = false
    @Published private(set) var scopeResult = ScopeAnalyzer.Result()
    @Published var ptz: [UUID: PTZConfig] = [:]
    @Published var externalMode: ExternalMode = .program
    @Published var externalDisplayConnected = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// Bitrate actually in use (adaptive bitrate may lower it below `encoder.bitrate`).
    @Published private(set) var currentBitrate = EncoderSettings().bitrate
    private var calmSeconds = 0

    enum ExternalMode: String, CaseIterable { case program, multiview }

    // MARK: Pipeline
    let switcher = Switcher()
    let titleRenderer = TitleRenderer()
    let annotation = AnnotationLayer()
    let replayBuffer = ReplayBuffer()
    private(set) lazy var replay = ReplaySource(buffer: replayBuffer)
    private(set) lazy var autoSwitcher = AutoSwitcher(engine: self)
    private let audio = AudioCapture()
    private let videoEncoder: VideoEncoder
    private let audioEncoder: AudioEncoder
    private let outputManager: OutputManager
    private let control = ControlServer()
    private let scopes = ScopeAnalyzer()
    private var ptzControllers: [UUID: PTZController] = [:]
    private var timers: [Timer] = []
    private var titlesSnapshot: [TitleItem] = []
    private var tally: (program: Set<UUID>, preview: Set<UUID>) = ([], [])

    // Undo for graphics/layout edits (titles, logo, PiP, per-source processing).
    private struct Snapshot { var titles: [TitleItem]; var logo: OverlayLayer?; var pip: OverlayLayer?; var processing: [UUID: SourceProcessing] }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    init() {
        let ve = VideoEncoder(settings: EncoderSettings())
        // Must match AudioCapture.format (48 kHz stereo float); `self` isn't usable before all stored properties are set.
        let ae = AudioEncoder(input: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!, bitrate: 128_000)
        videoEncoder = ve
        audioEncoder = ae
        outputManager = OutputManager(audioFormat: ae.outputFormat, requestKeyframe: { [weak ve] in ve?.requestKeyframe() })
        Self.shared = self

        let om = outputManager, rb = replayBuffer, titlesR = titleRenderer, ann = annotation
        #if targetEnvironment(simulator)
        // No hardware encoder in the Simulator: skip encoding in UI-test/demo runs (outputs can't work there anyway).
        let encodeOn = !DemoMode.isOn
        #else
        let encodeOn = true
        #endif
        // Battery: the hardware encoder only runs while something consumes it (an output, a recording,
        // or the replay buffer when armed).
        let gate = encodeGate
        let ndiBox = ndiOut
        switcher.onProgramFrame = { pb, t in
            if encodeOn && gate.value > 0 { ve.encode(pb, pts: t) }
            ndiBox.send(pb)
        }
        ve.onEncoded = { sb in om.video(sb); rb.append(sb) }
        ve.onProblem = { [weak self] text in Task { @MainActor in self?.logToLiveOutputs(text) } }
        switcher.onPoolRebuilt = { [weak self] in
            Task { @MainActor in self?.logToLiveOutputs("Hết bộ đệm khung hình — đã tạo lại (khung bị giữ ở bộ mã hoá)") }
        }
        audio.onBuffer = { pcm, when in ae.append(pcm, when: when) }
        ae.onEncoded = { buf, when in om.audio(buf, when: when) }
        // audio always flows: the mixer, or silence when the mixer could not start (see startSilentAudio)
        om.hasAudio = { true }
        om.onStatus = { [weak self] id, st in Task { @MainActor in self?.outputStatus[id] = st } }
        switcher.graphicsProvider = { [weak self] size, now in
            let items = MainActorBox.titles(self)
            var img = titlesR.render(items, canvas: size, now: now)
            if let h = HTMLFrameBox.shared.image, h.extent.width > 0 {
                let k = size.width / h.extent.width
                let hs = h.transformed(by: CGAffineTransform(scaleX: k, y: k))
                img = img.map { hs.composited(over: $0) } ?? hs
            }
            if let a = ann.current { img = img.map { a.composited(over: $0) } ?? a }
            return img
        }
        switcher.onTally = { [weak self] pgm, pvw in
            Task { @MainActor in self?.updateTally(program: pgm, preview: pvw) }
        }

        outputs = Self.load([OutputConfig].self, key: "dtd.outputs.v1") ?? []
        if let bg = Self.load(LayoutBackground.self, key: "dtd.layoutbg.v1") { layoutBackground = bg }
        restoreLogo()
        if ndiOutputOn { ndiOut.configure(on: NDIAvailability.isAvailable, name: ndiName, fps: format.fps) }
        titles = Self.load([TitleItem].self, key: "dtd.titles.v1") ?? Self.defaultTitles
        titlesSnapshot = titles
        MainActorBox.setTitles(titles)
        switcher.start()
        // Demo/screenshot mode: no microphone or LAN listeners, so no permission alerts cover the UI.
        if !DemoMode.isOn {
            try? audio.start()
            // YouTube / Facebook refuse or stall a stream without an audio track: if the mixer can't run
            // (no microphone permission, audio session error) feed silent AAC so every output still has audio.
            if !audio.isRunning { startSilentAudio(ae) }
            control.target = self
            try? control.start()
        }

        replay.onFinished = { [weak self] in self?.replayFinished() }
        pairing.engine = self
        ingest.engine = self
        let h = html
        graphicsRepo.onUpdated = { h.reload() }
        // key column / remote follow the HTML graphics state
        htmlChange = html.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if !DemoMode.isOn { ingest.start() }
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Assign only on change: every @Published write re-renders the whole studio view.
                let level = (self.audio.peakDB * 2).rounded() / 2
                if level != self.audioLevel { self.audioLevel = level }
                let ch = self.audio.channels.map { c -> AudioChannelState in var c = c; c.level = (c.level * 2).rounded() / 2; return c }
                if ch != self.audioChannels { self.audioChannels = ch }
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateScopes() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                StreamStats.bitrateKbps = self.currentBitrate / 1000
                StreamStats.fps = self.format.fps
                self.encoderWatchdog()
                let now = HostClock.now
                for t in self.titles where self.titleRenderer.countdownDone(t, now: now) { self.setTitleVisible(t.id, false) }
                await self.adaptBitrate()
                self.updateOutputRates()
                self.updateEncodeGate()
                self.applyThermalState()
            }
        })
        if let saved = Self.load(EncoderSettings.self, key: "dtd.encoder.v1") { encoder = saved }
        if let fg = Self.load(SuperFGConfig.self, key: "dtd.superfg.v1") { superFG = fg }
        if let f = Self.load(ProgramFormat.self, key: "dtd.format.v1") { format = f }
    }

    static let defaultTitles: [TitleItem] = [
        TitleItem(style: .lowerThird, line1: "Tên khách mời", line2: "Chức danh"),
        TitleItem(style: .scoreBug, line1: "Đội A", line2: "Đội B", period: "H1", position: CGPoint(x: 0.083, y: 0.03)),
        TitleItem(style: .ticker, line1: "Tin nhanh: nhập nội dung chữ chạy tại đây"),
        TitleItem(style: .clock, position: CGPoint(x: 0.88, y: 0.04))
    ]

    // MARK: Sources

    func add(_ source: any VideoSource) {
        sources.append(source)
        switcher.register(source.id, store: source.frames)
        let a = audio, id = source.id, name = source.name
        if let s = source as? SRTInputSource { s.sink.onAudio = { a.feed(sourceID: id, name: name, buffer: $0) } }
        if let s = source as? RTMPInputSource { s.sink.onAudio = { a.feed(sourceID: id, name: name, buffer: $0) } }
        if let s = source as? RTSPInputSource { s.onAudio = { a.feed(sourceID: id, name: name, buffer: $0) } }
        if let s = source as? FileSource { s.onAudio = { a.feed(sourceID: id, name: name, buffer: $0) } }
        Task { await source.start(); objectWillChange.send() }
        if programID == nil { switcher.take(source.id) } else if previewID == nil { switcher.setPreview(source.id) }
        syncState()
    }

    func remove(_ source: any VideoSource) {
        switcher.unregister(source.id)
        sources.removeAll { $0.id == source.id }
        audio.removeChannel(source.id)
        ptzControllers[source.id] = nil
        Task { await source.stop() }
        syncState()
    }

    func sourceIndex(_ n: Int) -> (any VideoSource)? { n >= 1 && n <= sources.count ? sources[n - 1] : nil }

    // MARK: Switching

    func select(_ id: UUID) { switcher.setPreview(id); syncState() }
    func take(_ id: UUID) { switcher.take(id); syncState() }
    func cut() { switcher.cut(); syncState() }
    func autoTransition() {
        switcher.auto(transition, duration: transitionDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + transitionDuration + 0.05) { [weak self] in self?.syncState() }
    }

    /// T-bar position 0...1; releasing at the end completes the transition.
    func tbar(_ p: Double) { switcher.setManual(p, style: transition); if p >= 0.999 || p <= 0.001 { syncState() } }

    private func syncState() {
        let s = switcher.state
        programID = s.program; previewID = s.preview
    }

    private func updateTally(program: Set<UUID>, preview: Set<UUID>) {
        guard program != tally.program || preview != tally.preview else { return }
        let old = tally.program
        tally = (program, preview)
        audio.setProgram(program, main: switcher.state.program)
        for id in program.symmetricDifference(old) {
            Task { await ptzControllers[id]?.tally(program.contains(id)) }
        }
        #if NDI_SDK
        for case let s as NDIInputSource in sources { s.setTally(program: program.contains(s.id), preview: preview.contains(s.id)) }
        #endif
        syncState()
    }

    // MARK: Graphics

    private func pushOverlays() { switcher.setOverlays([pip, foreground, logo].compactMap { $0 }) }

    // MARK: Library actions

    func toggleFavorite(_ id: UUID) { if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) } }

    /// Adds (or reuses) a movie as an input and puts it on preview.
    func cueMovie(_ url: URL) {
        if let s = sources.first(where: { ($0 as? FileSource)?.url == url }) { select(s.id); (s as? FileSource)?.restart(); return }
        guard FileManager.default.isReadableFile(atPath: url.path) else { message = LF("Không đọc được video %@", "\(url.lastPathComponent)"); return }
        let s = FileSource(name: url.deletingPathExtension().lastPathComponent, url: url)
        add(s); select(s.id)
    }

    /// Double-tap on a library item: straight to program (cut).

    func cuePicture(_ url: URL) {
        if let s = sources.first(where: { ($0 as? ImageSource)?.url == url }) { select(s.id); return }
        guard UIImage(contentsOfFile: url.path) != nil else { message = LF("Không đọc được ảnh %@", "\(url.lastPathComponent)"); return }
        let s = ImageSource(url: url)
        add(s); select(s.id)
    }

    func useLogo(_ url: URL) {
        guard let (ci, px) = Self.loadOverlayImage(url) else {
            message = L("Không đọc được logo") + " \(url.lastPathComponent)"; return
        }
        checkpoint()
        logoAspect = px.width / max(px.height, 1)
        var l = OverlayLayer(image: ci, rect: logoCorner.rect(size: logoFrameSize()))
        l.visible = logoOn                      // armed; goes on air with the Logo key (live swap if already on)
        l.opacity = CGFloat(logoOpacity)
        logo = l; currentLogoURL = url
        UserDefaults.standard.set(url.lastPathComponent, forKey: "dtd.logo.file")
        message = logoOn ? L("Đã đổi logo trên PGM") : L("Đã nạp logo — bấm Logo ở cột phải để lên PGM")
    }

    /// Normalised logo box for the current size setting (width from the image aspect, ≤ 60 %).
    private func logoFrameSize() -> CGSize {
        let k = logoAspect * CGFloat(format.height) / CGFloat(max(format.width, 1))   // width per unit height
        var h = CGFloat(min(max(logoSize, 0.03), 0.6)), w = h * k
        if w > 0.6 { w = 0.6; h = w / max(k, 0.01) }
        return CGSize(width: w, height: h)
    }


    /// Applies the size slider, keeping the logo pinned to the corner it sits nearest to
    /// (so a logo dragged with "Sắp xếp" stays where it was put).
    private func resizeLogo() {
        guard let cur = logo?.rect else { return }
        let sz = logoFrameSize()
        let right = cur.midX > 0.5, bottom = cur.midY > 0.5
        let x = right ? cur.maxX - sz.width : cur.minX
        let y = bottom ? cur.maxY - sz.height : cur.minY
        logo?.rect = CGRect(x: min(max(x, 0), 1 - sz.width), y: min(max(y, 0), 1 - sz.height), width: sz.width, height: sz.height)
    }

    /// Reads a still (PNG/JPEG/HEIC) with its EXIF orientation applied and alpha kept,
    /// pinned at origin so the compositor can scale/place it. Returns the image and its pixel size.
    nonisolated static func loadOverlayImage(_ url: URL) -> (CIImage, CGSize)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orient = (props?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        var img = CIImage(cgImage: cg).oriented(orient)
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        guard img.extent.width > 0, img.extent.height > 0 else { return nil }
        return (img, img.extent.size)
    }

    /// Re-loads the last logo at launch (armed, not on air).
    private func restoreLogo() {
        guard logo == nil, let name = UserDefaults.standard.string(forKey: "dtd.logo.file") else { return }
        let url = MediaLibrary.directory(.logo).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path), let (ci, px) = Self.loadOverlayImage(url) else { return }
        logoAspect = px.width / max(px.height, 1)
        var l = OverlayLayer(image: ci, rect: logoCorner.rect(size: logoFrameSize()))
        l.visible = false
        l.opacity = CGFloat(logoOpacity)
        logo = l; currentLogoURL = url
    }


    /// SuperFG from the library: PNG with alpha, or a video with alpha (HEVC .mov) that loops.
    func useForeground(_ url: URL) {
        checkpoint()
        stopForegroundVideo()
        if superFGActiveTemplate != nil || libraryCardURL != nil {
            if foregroundOn { switcher.hideCard() }
            superFGActiveTemplate = nil; libraryCardURL = nil; superFGCard = nil
        }
        if ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
            // Video with alpha: its own animation, keyed as a layer.
            let v = FileSource(name: "SuperFG", url: url)      // muted: no onAudio, not listed as an input
            switcher.register(v.id, store: v.frames)
            Task { await v.start() }
            foregroundVideo = v
            foreground = OverlayLayer(pipSourceID: v.id, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
            foreground?.visible = foregroundOn       // armed; SuperFG On key puts it on air
        } else {
            // Picture: played as a card with a transition, like the built-in cards.
            guard let img = UIImage(contentsOfFile: url.path)?.normalized(), let ci = CIImage(image: img) else {
                message = LF("Không đọc được %@", "\(url.lastPathComponent)"); return
            }
            foreground = nil
            libraryCardURL = url
            superFGCard = (Self.fillFrame(ci, CGSize(width: format.width, height: format.height)), nil, superFG.libraryMotionValue)
            if foregroundOn { playSuperFGCard() }
        }
        currentForegroundURL = url
    }

    /// Scales a picture to cover the program frame (centre crop), origin at zero.
    private static func fillFrame(_ img: CIImage, _ size: CGSize) -> CIImage {
        let e = img.extent
        guard e.width > 0, e.height > 0 else { return img }
        let k = max(size.width / e.width, size.height / e.height)
        let s = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).transformed(by: CGAffineTransform(scaleX: k, y: k))
        let dx = (s.extent.width - size.width) / 2, dy = (s.extent.height - size.height) / 2
        return s.transformed(by: CGAffineTransform(translationX: -dx, y: -dy)).cropped(to: CGRect(origin: .zero, size: size))
    }

    func clearForeground() {
        foregroundOn = false; stopForegroundVideo()
        foreground = nil; currentForegroundURL = nil; superFGActiveTemplate = nil; superFGCard = nil; libraryCardURL = nil
    }

    private var foregroundVideo: FileSource?
    private func stopForegroundVideo() {
        guard let v = foregroundVideo else { return }
        switcher.unregister(v.id)
        Task { await v.stop() }
        foregroundVideo = nil
    }

    // MARK: SuperFG templates (DTD Studio's own designs)

    @Published var superFG = SuperFGConfig() {
        didSet {
            if let d = try? JSONEncoder().encode(superFG) { UserDefaults.standard.set(d, forKey: "dtd.superfg.v1") }
            // Text / colour edits update the card on screen without restarting its animation.
            if libraryCardURL != nil, oldValue.libraryMotion != superFG.libraryMotion, let c = superFGCard {
                superFGCard = (c.bg, c.text, superFG.libraryMotionValue)
            }
            if superFGActiveTemplate != nil, oldValue.texts != superFG.texts || oldValue.accents != superFG.accents {
                renderSuperFGCard()
                if foregroundOn, let c = superFGCard { switcher.updateCard(background: c.bg, text: c.text, motion: c.motion) }
            }
        }
    }
    @Published private(set) var superFGActiveTemplate: String?
    private var superFGCard: (bg: CIImage, text: CIImage?, motion: SuperFGMotion)?
    private var superFGToken = 0

    /// Arms a card; if SuperFG is on, the new card plays in straight away.
    func applySuperFG(_ templateID: String) {
        guard SuperFGTemplate.all.contains(where: { $0.id == templateID }) else { return }
        stopForegroundVideo()
        foreground = nil; currentForegroundURL = nil; libraryCardURL = nil
        if superFG.templateID != templateID { superFG.templateID = templateID }
        superFGActiveTemplate = templateID
        renderSuperFGCard()
        if foregroundOn { playSuperFGCard() }
    }

    private func renderSuperFGCard() {
        guard let id = superFGActiveTemplate, let t = SuperFGTemplate.all.first(where: { $0.id == id }) else { superFGCard = nil; return }
        let size = CGSize(width: format.width, height: format.height)
        guard let bg = t.renderBackground(superFG, size: size).cgImage else { return }
        let tx = t.renderText(superFG, size: size).cgImage.map { CIImage(cgImage: $0) }
        superFGCard = (CIImage(cgImage: bg), tx, t.motion)
    }

    /// In-animation, then (optionally) cut PVW→PGM while covered and play out after the hold time.
    private func playSuperFGCard() {
        if superFGCard == nil { renderSuperFGCard() }
        guard let c = superFGCard else { return }
        switcher.showCard(background: c.bg, text: c.text, motion: c.motion)
        superFGToken += 1
        let token = superFGToken
        if superFG.takeOnCover {
            DispatchQueue.main.asyncAfter(deadline: .now() + Switcher.cardIn) { [weak self] in
                guard let self, self.superFGToken == token, self.foregroundOn else { return }
                self.cut()
            }
        }
        if superFG.playOnce {
            DispatchQueue.main.asyncAfter(deadline: .now() + Switcher.cardIn + max(0.5, superFG.hold)) { [weak self] in
                guard let self, self.superFGToken == token, self.foregroundOn else { return }
                self.foregroundOn = false
            }
        }
    }

    func toggleMusic(_ url: URL) {
        if nowPlayingMusic == url { stopMusic(); nowPlayingMusic = nil; return }
        do { try audio.playMusic(url); nowPlayingMusic = url } catch { message = LF("Không phát được nhạc: %@", "\(error.localizedDescription)") }
    }

    private func applyPiPPreset() { pip?.rect = pipPreset.rect }

    /// Title key: shows/hides the armed title (or the first one).
    func toggleArmedTitle() {
        guard let id = armedTitleID ?? titles.first?.id, let t = titles.first(where: { $0.id == id }) else { return }
        setTitleVisible(id, !t.visible)
    }

    /// Second title key: the first title other than the armed one (e.g. a ticker under a lower third).
    var secondTitle: TitleItem? {
        let armed = armedTitleID ?? titles.first?.id
        if let id = armedTitle2ID, id != armed, let t = titles.first(where: { $0.id == id }) { return t }
        return titles.first { $0.id != armed && $0.style != .clock }
    }
    func toggleSecondTitle() { if let t = secondTitle { setTitleVisible(t.id, !t.visible) } }
    var armedTitleVisible: Bool { titles.first { $0.id == (armedTitleID ?? titles.first?.id) }?.visible ?? false }

    /// Built-in template for the current id (before user edits).
    var baseLayoutTemplate: LayoutTemplate { LayoutTemplate.all.first { $0.id == layoutTemplateID } ?? LayoutTemplate.all[1] }
    /// Current template with the operator's edits (moved/resized/inserted windows) applied.
    var layoutTemplate: LayoutTemplate {
        let b = baseLayoutTemplate
        guard let rects = layoutEdits[b.id], !rects.isEmpty else { return b }
        return LayoutTemplate(id: b.id, name: b.name, slots: rects.map { LayoutTemplate.Slot(rect: $0) }, background: b.background)
    }
    var layoutEdited: Bool { layoutEdits[layoutTemplateID] != nil }

    /// Per-template window rects edited in the PiP editor (normalised, top-left origin).
    @Published var layoutEdits: [Int: [CGRect]] = StudioEngine.load([Int: [CGRect]].self, key: "dtd.layoutedits.v1") ?? [:] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(layoutEdits), forKey: "dtd.layoutedits.v1") }
    }

    /// Keeps a window fully inside the frame, at least 6% in size.
    static func clampWindow(_ r: CGRect) -> CGRect {
        let minS: CGFloat = 0.06
        let w = min(max(r.width, minS), 1), h = min(max(r.height, minS), 1)
        let x = min(max(r.minX, 0), 1 - w), y = min(max(r.minY, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private var editableRects: [CGRect] { layoutTemplate.slots.map(\.rect) }

    func setLayoutWindow(_ i: Int, _ r: CGRect) {
        var rects = editableRects
        guard rects.indices.contains(i) else { return }
        rects[i] = Self.clampWindow(r)
        layoutEdits[layoutTemplateID] = rects
        refreshLayout()
    }

    /// Inserts a new window (centre, 32%) and fills it with the next unused input.
    func insertLayoutWindow() {
        var rects = editableRects
        let off = CGFloat(rects.count % 5) * 0.04
        rects.append(Self.clampWindow(CGRect(x: 0.34 + off, y: 0.34 + off, width: 0.32, height: 0.32)))
        layoutEdits[layoutTemplateID] = rects
        let pool = ([programID, previewID] + sources.map(\.id)).compactMap { $0 }.filter { $0 != layoutSource.id && $0 != replay.id }
        layoutSlots.append(pool.first { !layoutSlots.contains($0) } ?? pool.first)
        layoutSelectedSlot = layoutSlots.count - 1
        refreshLayout()
    }

    func removeLayoutWindow(_ i: Int) {
        var rects = editableRects
        guard rects.count > 1, rects.indices.contains(i) else { return }
        rects.remove(at: i)
        layoutEdits[layoutTemplateID] = rects
        if layoutSlots.indices.contains(i) { layoutSlots.remove(at: i) }
        layoutSelectedSlot = min(layoutSelectedSlot, layoutSlots.count - 1)
        refreshLayout()
    }

    func resetLayoutEdits() {
        layoutEdits[layoutTemplateID] = nil
        chooseLayout(layoutTemplateID)
    }

    /// Picks a template; empty slots are filled with the first inputs (program first).
    func chooseLayout(_ id: Int) {
        layoutTemplateID = id
        let n = layoutTemplate.slots.count
        var slots = Array(layoutSlots.prefix(n))
        let pool = ([programID, previewID] + sources.map(\.id)).compactMap { $0 }.filter { $0 != layoutSource.id && $0 != replay.id }
        var unique: [UUID] = []
        for p in pool where !unique.contains(p) { unique.append(p) }
        while slots.count < n { slots.append(unique.first { !slots.contains($0) }) }
        layoutSlots = slots
        layoutSelectedSlot = 0
        refreshLayout()
        if !sources.contains(where: { $0.id == layoutSource.id }) {
            sources.append(layoutSource)
            switcher.register(layoutSource.id, store: layoutSource.frames)
            Task { await layoutSource.start() }
        }
        select(layoutSource.id)
    }

    func assignLayoutSlot(_ slot: Int, source: UUID) {
        guard slot < layoutSlots.count else { return }
        layoutSlots[slot] = source
        layoutSelectedSlot = min(slot + 1, layoutSlots.count - 1)
        refreshLayout()
    }

    func refreshLayout() {
        let stores = layoutSlots.map { id in id.flatMap { i in sources.first { $0.id == i }?.frames } }
        var still: CIImage?, color: CIColor?, live: FrameStore?
        switch layoutBackground {
        case .color(let hex): color = CIColor(color: UIColor(hex: hex))
        case .picture(let name):
            let url = MediaLibrary.directory(.picture).appendingPathComponent(name)
            if let img = UIImage(contentsOfFile: url.path)?.normalized() { still = CIImage(image: img) }
        case .source(let id): live = sources.first { $0.id == id }?.frames
        }
        var tpl = layoutTemplate
        if tpl.slots.count == 1 && !layoutEdited && !tpl.slots[0].perspective {
            // one-window layout: shrink around the centre so the background shows around it
            let k = CGFloat(min(max(layoutSingleScale, 0.2), 1))
            var slot = tpl.slots[0]
            slot.rect = CGRect(x: (1 - k) / 2, y: (1 - k) / 2, width: k, height: k)
            tpl = LayoutTemplate(id: tpl.id, name: tpl.name, slots: [slot], background: tpl.background)
        }
        var frameImg: CIImage?
        if layoutFrame.style == .image, let n = layoutFrame.imageName {
            frameImg = Self.loadOverlayImage(MediaLibrary.directory(.overlay).appendingPathComponent(n))?.0
        }
        layoutSource.configure(template: tpl, inputs: stores,
                               size: CGSize(width: format.width, height: format.height), background: live,
                               still: still, color: color, frame: layoutFrame, frameImage: frameImg)
    }

    /// What fills the frame behind the PiP layout windows when the cameras don't cover it.
    enum LayoutBackground: Codable, Equatable {
        case color(String)       // hex
        case picture(String)     // file name in Library/Ảnh
        case source(UUID)        // a live input, blurred
    }
    @Published var layoutBackground: LayoutBackground = .color("#0A0D12") {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(layoutBackground), forKey: "dtd.layoutbg.v1")
            refreshLayout()
        }
    }

    /// "PiP TRANS": transition program into the current layout.
    func layoutTransition() {
        if !sources.contains(where: { $0.id == layoutSource.id }) { chooseLayout(layoutTemplateID) }
        select(layoutSource.id)
        autoTransition()
    }

    func flashTransition() {
        let keep = transition
        transition = .flash
        autoTransition()
        transition = keep
    }

    func setLogo(_ image: UIImage?) {
        checkpoint()
        guard let image, let ci = CIImage(image: image) else { logo = nil; return }
        logo = OverlayLayer(image: ci, rect: CGRect(x: 0.86, y: 0.04, width: 0.11, height: 0.11))
    }

    func setPiP(_ id: UUID?) {
        checkpoint()
        guard let id, sources.contains(where: { $0.id == id }) else { pip = nil; return }
        var l = OverlayLayer(pipSourceID: id, rect: pipPreset.rect)
        l.visible = pipOn                       // armed; PiP On key / PiP T-Bar puts it on air
        pip = l
    }

    /// Move/resize PiP or logo; snaps to edges and the safe-area grid (5% margins, thirds).
    func setOverlayRect(pip isPiP: Bool, _ rect: CGRect, snap: Bool = true) {
        var r = rect
        if snap {
            let guides: [CGFloat] = [0, 0.05, 1.0 / 3, 0.5, 2.0 / 3, 0.95, 1]
            func s(_ v: CGFloat) -> CGFloat { guides.first { abs($0 - v) < 0.015 } ?? v }
            r.origin.x = s(r.minX); r.origin.y = s(r.minY)
            if let x = guides.first(where: { abs($0 - r.maxX) < 0.015 }) { r.origin.x = x - r.width }
            if let y = guides.first(where: { abs($0 - r.maxY) < 0.015 }) { r.origin.y = y - r.height }
        }
        if isPiP { pip?.rect = r } else { logo?.rect = r }
    }

    func upsertTitle(_ t: TitleItem) {
        checkpoint()
        if let i = titles.firstIndex(where: { $0.id == t.id }) {
            let wasVisible = titles[i].visible
            titles[i] = t
            if wasVisible != t.visible { titleRenderer.visibilityChanged(t) }
        } else {
            titles.append(t)
        }
    }

    func setTitleVisible(_ id: UUID?, _ on: Bool) {
        for i in titles.indices where id == nil || titles[i].id == id {
            guard titles[i].visible != on else { continue }
            titles[i].visible = on
            titleRenderer.visibilityChanged(titles[i])
        }
    }

    func setScore(a: Int? = nil, b: Int? = nil) {
        for i in titles.indices where titles[i].style == .scoreBug {
            if let a { titles[i].scoreA = max(0, a) }
            if let b { titles[i].scoreB = max(0, b) }
        }
    }

    // MARK: Scoreboard (same look as DTDLive)

    var scoreboardIndex: Int? { titles.firstIndex { $0.style == .scoreBug } }

    /// Adds a scoreboard title if there is none; returns its id.
    @discardableResult
    func ensureScoreboard() -> UUID {
        if let i = scoreboardIndex { return titles[i].id }
        let t = TitleItem(style: .scoreBug, line1: "HOME", line2: "AWAY", position: CGPoint(x: 0.083, y: 0.03))
        upsertTitle(t)
        return t.id
    }

    func updateScoreboard(_ f: (inout TitleItem) -> Void) {
        guard let i = scoreboardIndex else { return }
        f(&titles[i])
    }

    /// Fraction of the program frame the scoreboard covers at its current scale.
    func scoreboardFraction(_ t: TitleItem) -> CGSize {
        let sz = ScoreboardRenderer.size(compact: t.sb.compact)
        let W = CGFloat(format.width), H = CGFloat(max(format.height, 1))
        let k = W / 1920 * t.scale
        return CGSize(width: sz.width * k / W, height: sz.height * k / H)
    }

    /// Quick placement: x 0 = left, 0.5 = centre, 1 = right; top or bottom; 3 % margin.
    func placeScoreboard(x: CGFloat, top: Bool) {
        updateScoreboard { t in
            let f = scoreboardFraction(t), m: CGFloat = 0.03
            t.position.x = x == 0.5 ? (1 - f.width) / 2 : (x < 0.5 ? m : 1 - m - f.width)
            t.position.y = top ? m : 1 - m - f.height
            t.position.x = min(max(0, t.position.x), max(0, 1 - f.width))
        }
    }

    func setScoreboardScale(_ s: CGFloat) {
        updateScoreboard { t in
            t.scale = min(max(s, 0.3), 1.6)
            let f = scoreboardFraction(t)
            t.position.x = min(max(0, t.position.x), max(0, 1 - f.width))
            t.position.y = min(max(0, t.position.y), max(0, 1 - f.height))
        }
    }

    /// Wide strip across the top or the compact two-row corner board.
    func setScoreboardCompact(_ c: Bool) {
        updateScoreboard { t in
            var b = t.sb; b.compact = c; t.sb = b
            let landscape = format.width >= format.height
            // width as a fraction of the frame: wide 80 % (98 % portrait), compact 30 % (50 % portrait)
            let wf: CGFloat = c ? (landscape ? 0.3 : 0.5) : (landscape ? 0.8 : 0.98)
            t.scale = wf * 1920 / ScoreboardRenderer.size(compact: c).width
        }
        placeScoreboard(x: c ? 0 : 0.5, top: true)
    }

    /// Picks a wide-strip look and applies its default colours.
    func setScoreboardStyle(_ st: ScoreboardStyle) {
        updateScoreboard { t in
            var b = t.sb; b.style = st.rawValue
            (b.homeColor, b.awayColor, b.centerColor) = st.palette
            t.sb = b
        }
        if scoreboardIndex.map({ titles[$0].sb.compact }) == true { setScoreboardCompact(false) }
    }
    func setScoreboardBanner(_ text: String) { updateScoreboard { var b = $0.sb; b.banner = text; $0.sb = b } }

    func scoreboardClockToggle() { updateScoreboard { var b = $0.sb; b.toggleClock(); $0.sb = b } }
    func scoreboardClockReset() { updateScoreboard { var b = $0.sb; b.resetClock(); $0.sb = b } }

    func removeTitle(_ id: UUID) { checkpoint(); titles.removeAll { $0.id == id } }

    // MARK: Per-source processing & scopes

    func processingFor(_ id: UUID) -> SourceProcessing { processing[id] ?? SourceProcessing() }

    func setProcessing(_ id: UUID, _ p: SourceProcessing, undoable: Bool = true) {
        if undoable { checkpoint() }
        processing[id] = p.isIdentity ? nil : p
        switcher.setProcessing(id, p)
    }

    private func updateScopes() {
        guard scopesEnabled, let pb = switcher.programMonitor.latest() else { return }
        let s = scopes
        Task.detached(priority: .utility) {
            let r = s.analyze(pb)
            await MainActor.run { [weak self] in self?.scopeResult = r }
        }
    }

    // MARK: Adaptive bitrate

    /// AIMD on the shared encoder: drop 25% when any destination is >1 s behind,
    /// climb 8% after 5 calm seconds. One slow destination lowers quality for all —
    /// the price of encoding once; disable `adaptive` to let that destination drop frames instead.
    private func adaptBitrate() async {
        guard encoder.adaptive, isAnyLive else {
            if currentBitrate != encoder.bitrate { currentBitrate = encoder.bitrate; videoEncoder.setBitrate(currentBitrate) }
            return
        }
        let lag = await outputManager.congestion(fps: Double(format.fps))
        var next = currentBitrate
        if lag > 1.0 {
            next = max(encoder.minBitrate, Int(Double(currentBitrate) * 0.75)); calmSeconds = 0
        } else if lag < 0.2 {
            calmSeconds += 1
            if calmSeconds >= 5 { next = min(encoder.bitrate, Int(Double(currentBitrate) * 1.08)); calmSeconds = 0 }
        } else {
            calmSeconds = 0
        }
        if next != currentBitrate { currentBitrate = next; videoEncoder.setBitrate(next) }
    }

    // MARK: Undo / redo

    private func snapshot() -> Snapshot { Snapshot(titles: titles, logo: logo, pip: pip, processing: processing) }

    private func checkpoint() {
        undoStack.append(snapshot())
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true; canRedo = false
    }

    private func restore(_ s: Snapshot) {
        titles = s.titles; logo = s.logo; pip = s.pip
        for id in Set(processing.keys).union(s.processing.keys) { switcher.setProcessing(id, s.processing[id]) }
        processing = s.processing
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(snapshot()); restore(s)
        canUndo = !undoStack.isEmpty; canRedo = true
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(snapshot()); restore(s)
        canRedo = !redoStack.isEmpty; canUndo = true
    }

    // MARK: Audio

    func updateAudioChannel(_ c: AudioChannelState) { audio.update(c) }

    // MARK: Power: encode gating, thermal throttling, per-output send rates

    /// > 0 while the encoder must run.
    private let encodeGate = Counter()
    /// Replay needs the encoder running all the time; off by default to save battery.
    @Published var replayArmed = UserDefaults.standard.bool(forKey: "dtd.replayArmed") {
        didSet { UserDefaults.standard.set(replayArmed, forKey: "dtd.replayArmed"); updateEncodeGate() }
    }
    private func updateEncodeGate() {
        let active = replayArmed || outputStatus.values.contains { s in
            if case .idle = s { return false }; if case .error = s { return false }; return true
        }
        let want = active ? 1 : 0
        let cur = encodeGate.value
        if want != cur {
            encodeGate.add(want - cur)
            if active { videoEncoder.requestKeyframe() }
        }
    }

    /// "V 30/s · A 47/s" per destination — tells "no video" from "no audio" when a platform stays offline.
    @Published private(set) var outputRates: [UUID: String] = [:]
    private var lastCounts: [UUID: (Int, Int)] = [:]
    private func updateOutputRates() {
        let now = outputManager.sentCounts()
        var r: [UUID: String] = [:]
        for (id, c) in now {
            let p = lastCounts[id] ?? (0, 0)
            r[id] = "Hình \(max(0, c.0 - p.0))/s · Tiếng \(max(0, c.1 - p.1))/s"
        }
        lastCounts = now
        if r != outputRates { outputRates = r }
    }

    // MARK: NDI

    /// Program → NDI output (needs the NDI SDK; see scripts/ndi-setup.sh).
    let ndiOut = NDIOutputBox()
    @Published var ndiOutputOn: Bool = UserDefaults.standard.bool(forKey: "dtd.ndi.out") {
        didSet {
            UserDefaults.standard.set(ndiOutputOn, forKey: "dtd.ndi.out")
            ndiOut.configure(on: ndiOutputOn && NDIAvailability.isAvailable, name: ndiName, fps: format.fps)
        }
    }
    @Published var ndiName: String = UserDefaults.standard.string(forKey: "dtd.ndi.name") ?? "DTD Studio PGM" {
        didSet { UserDefaults.standard.set(ndiName, forKey: "dtd.ndi.name"); if ndiOutputOn { ndiOut.configure(on: true, name: ndiName, fps: format.fps) } }
    }

    /// NDI sources on the network (empty without the SDK).
    func findNDISources() async -> [String] {
        #if NDI_SDK
        return await Task.detached { NDIFinder().sources(waitMs: 1500) }.value
        #else
        return []
        #endif
    }

    func addNDISource(_ name: String) {
        #if NDI_SDK
        add(NDIInputSource(ndiName: name))
        #endif
    }

    /// Writes a line into the diagnostic log of every destination that is running.
    func logToLiveOutputs(_ text: String) {
        for o in outputs where (outputStatus[o.id] ?? .idle) != .idle { OutputLog.shared.add(o.id, text) }
    }

    private var lastEncIn = 0, lastEncOut = 0, lastRendered = 0, watchdogTick = 0
    /// Every second: if frames go into the encoder but none come out, rebuild it (keeps a live stream from freezing).
    /// Every 5 s while on air, writes render → encoder → out rates into the output logs.
    private func encoderWatchdog() {
        let i = videoEncoder.framesIn.value, o = videoEncoder.framesOut.value, r = switcher.renderedFrames.value
        defer { lastEncIn = i; lastEncOut = o; lastRendered = r }
        guard encodeGate.value > 0 else { watchdogTick = 0; return }
        _ = videoEncoder.restartIfStalled(i - lastEncIn, o - lastEncOut)
        watchdogTick += 1
        if watchdogTick % 5 == 1 {
            let st = switcher.renderStats.take()
            logToLiveOutputs("Khung hình/giây: dựng \(r - lastRendered) · vào mã hoá \(i - lastEncIn) · ra \(o - lastEncOut) · dựng TB \(String(format: "%.1f", st.avg)) ms, max \(String(format: "%.0f", st.max)) ms, quá hạn \(st.over)")
        }
    }

    /// Heat: lower the program frame rate when iOS reports the device getting hot, restore when it cools.
    @Published private(set) var thermalThrottled = false
    private func applyThermalState() {
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        guard hot != thermalThrottled else { return }
        thermalThrottled = hot
        if isAnyLive || isRecording {
            // While on air, changing fps rebuilds the encoder and forces every destination to reconnect;
            // cut the bitrate instead (less encoder + radio work), restore when it cools.
            let target = hot ? max(encoder.minBitrate, encoder.bitrate * 2 / 3) : encoder.bitrate
            currentBitrate = target; videoEncoder.setBitrate(target)
            if hot { message = L("Máy đang nóng — tạm giảm bitrate để hạ nhiệt") }
            return
        }
        let fps = hot ? min(format.fps, 25) : format.fps
        var f = format; f.fps = fps
        switcher.setFormat(f)
        videoEncoder.fps = Double(fps)
        if hot { message = LF("Máy đang nóng — tạm giảm còn %@ hình/giây để hạ nhiệt", "\(fps)") }
    }

    private var silenceTimer: DispatchSourceTimer?
    private func startSilentAudio(_ ae: AudioEncoder) {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let frames: AVAudioFrameCount = 1024
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "silence.audio", qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: .nanoseconds(Int(Double(frames) / 48000 * 1e9)))
        t.setEventHandler {
            guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
            b.frameLength = frames            // freshly allocated buffers are zero-filled
            ae.append(b, when: AVAudioTime(hostTime: mach_absolute_time()))
        }
        t.resume()
        silenceTimer = t
        message = L("Không mở được micro/bộ trộn âm thanh — đang phát kèm âm thanh câm. Kiểm tra quyền Micro trong Cài đặt iOS.")
    }

    /// PCM from a pushed camera (ingest server thread) into its own mixer channel.
    nonisolated func audioFeed(sourceID: UUID, name: String) -> @Sendable (AVAudioPCMBuffer) -> Void {
        let a = audio
        return { a.feed(sourceID: sourceID, name: name, buffer: $0) }
    }

    func injectDemoAudio() {
        var list = [AudioChannelState(id: AudioCapture.micID, name: "Mic"),
                    AudioChannelState(id: AudioCapture.musicID, name: "Nhạc", gain: 0.6)]
        for (i, s) in sources.prefix(4).enumerated() {
            list.append(AudioChannelState(id: s.id, name: "Cam \(i + 1)", followVideo: true))
        }
        list.append(AudioChannelState(id: UUID(), name: "Video", muted: true))
        audio.injectDemo(list)
        let start = Date()
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.audio.demoTick(Date().timeIntervalSince(start)) }
        })
    }
    var audioInputs: [AudioCapture.Input] { audio.inputs }
    var audioInputID: String? { audio.currentInputID }
    func setAudioInput(_ id: String?) { audio.setInput(id); objectWillChange.send() }
    var micDelayMs: Double {
        get { audio.micDelayMs }
        set { audio.micDelayMs = newValue; objectWillChange.send() }
    }
    var masterGain: Float {
        get { audio.masterGain }
        set { audio.masterGain = newValue; objectWillChange.send() }
    }
    /// Turn AFV on/off for every source channel at once (mic & music stay manual).
    // MARK: Monitor quick keys (Time / Reset / Loop)

    var clockOn: Bool { titles.contains { $0.style == .clock && $0.visible } }
    /// Show/hide an on-air clock; creates one in the top-right corner the first time.
    func toggleClock() {
        if let t = titles.first(where: { $0.style == .clock }) {
            setTitleVisible(t.id, !t.visible)
        } else {
            var t = TitleItem(style: .clock, line1: "")
            t.position = CGPoint(x: 0.82, y: 0.05)
            titles.append(t)
            setTitleVisible(t.id, true)
        }
    }
    /// Clears every keyed layer off program: PiP, logo, foreground, titles, drawing, FTB.
    func resetProgramLayers() {
        pipOn = false; logoOn = false; foregroundOn = false; fadeToBlack = false
        setTitleVisible(nil, false)
        annotation.clear()
        objectWillChange.send()
    }
    /// The movie currently on program (if any) and its loop state.
    var programMovie: FileSource? { sources.first { $0.id == programID } as? FileSource }
    func toggleProgramLoop() { programMovie?.loops.toggle(); objectWillChange.send() }

    /// Mixer AFV keys: AFV1 / AFV2 switch every source channel to follow video; tapping the active key turns AFV off.
    var afvMode: AudioCapture.AFVMode? {
        let src = audioChannels.filter { $0.id != AudioCapture.micID && $0.id != AudioCapture.musicID }
        guard !src.isEmpty, src.allSatisfy(\.followVideo) else { return nil }
        return audio.afvMode
    }
    func setAFVMode(_ m: AudioCapture.AFVMode?) {
        if let m { audio.afvMode = m }
        setAFVAll(m != nil)
        objectWillChange.send()
    }
    func nudgeGain(_ id: UUID, dB: Float) {
        guard var c = audioChannels.first(where: { $0.id == id }) else { return }
        let cur = 20 * log10(max(c.gain, 0.0001)) + dB
        c.gain = cur <= -60 ? 0 : min(2, powf(10, cur / 20))
        audio.update(c)
    }
    func nudgeTrim(_ id: UUID, dB: Float) {
        guard var c = audioChannels.first(where: { $0.id == id }) else { return }
        c.trim = min(24, max(-12, c.trim + dB)); audio.update(c)
    }
    var masterNudge: (Float) -> Void { { [weak self] d in
        guard let self else { return }
        let cur = 20 * log10(max(self.masterGain, 0.0001)) + d
        self.masterGain = cur <= -60 ? 0 : min(2, powf(10, cur / 20))
    } }

    func setAFVAll(_ on: Bool) {
        for var c in audioChannels where c.id != AudioCapture.micID && c.id != AudioCapture.musicID {
            c.followVideo = on; audio.update(c)
        }
    }
    var monitorProgram: Bool {
        get { audio.monitorProgram }
        set { audio.monitorProgram = newValue; objectWillChange.send() }
    }
    func playMusic(_ url: URL) {
        do { try audio.playMusic(url) } catch { message = LF("Không phát được nhạc: %@", "\(error.localizedDescription)") }
    }
    var speakerMonitor: Bool {
        get { audio.speakerMonitor }
        set { audio.speakerMonitor = newValue; objectWillChange.send() }
    }
    func stopMusic() { audio.stopMusic() }
    func playEffect(_ url: URL) { audio.playEffect(url) }

    // MARK: Replay

    func startReplay(speed: Double = 0.5, length: Double = 8) {
        if !sources.contains(where: { $0.id == replay.id }) {
            sources.append(replay)
            switcher.register(replay.id, store: replay.frames)
            Task { await replay.start() }
        }
        replay.speed = speed; replay.length = length
        replay.play()
        switcher.setPreview(replay.id)
        autoTransition()
    }

    /// True while a replay is on PGM (drives the PLAY REPLAY / STOP button).
    @Published private(set) var replayOnAir = false
    /// Program source before the replay was taken to air; restored when the replay ends or is stopped.
    private var preReplayProgram: UUID?
    private var replayFileID: UUID?

    func stopReplay() {
        replay.cancel()
        if let id = replayFileID, let f = sources.first(where: { $0.id == id }) as? FileSource { f.pause() }
        returnFromReplay()
    }

    /// Takes the previous source back to air (if the replay is still on PGM) and clears the replay state.
    private func returnFromReplay() {
        let onAir = programID == replay.id || (replayFileID != nil && programID == replayFileID)
        if onAir, let back = preReplayProgram, sources.contains(where: { $0.id == back }) {
            switcher.setPreview(back); syncState()
            autoTransition()
        }
        replayOnAir = false; preReplayProgram = nil; replayFileID = nil
    }

    private func beginReplayOnAir(_ id: UUID) {
        if programID != id { preReplayProgram = programID }
        replayOnAir = true
        autoTransition()
    }

    private func ensureReplaySource() {
        if !sources.contains(where: { $0.id == replay.id }) {
            sources.append(replay)
            switcher.register(replay.id, store: replay.frames)
            Task { await replay.start() }
        }
    }

    /// Plays the editor's current MARK IN → MARK OUT range and takes it to air.
    func playEditorRange(toAir: Bool = true) {
        let ed = replayEditor
        switch ed.material {
        case .buffer:
            let r = ed.bufferRange()
            guard !r.samples.isEmpty else { return }
            ensureReplaySource()
            replay.play(samples: r.samples, inPTS: r.inPTS, outPTS: r.outPTS, speed: ed.speed, loop: ed.loop)
            switcher.setPreview(replay.id)
        case .file(let url):
            cueMovie(url)
            if let f = sources.first(where: { ($0 as? FileSource)?.url == url }) as? FileSource {
                f.onRangeEnd = { [weak self] in self?.returnFromReplay() }
                f.playRange(in: ed.effectiveRange.lowerBound, out: ed.effectiveRange.upperBound, rate: Float(ed.speed), loop: ed.loop)
                switcher.setPreview(f.id)
                if toAir { replayFileID = f.id }
            }
        }
        syncState()
        if toAir { beginReplayOnAir(previewID ?? replay.id) }
    }

    func playClip(_ c: ReplayClip, toAir: Bool = true) {
        let ed = replayEditor
        switch c.material {
        case .buffer:
            ensureReplaySource()
            replay.play(samples: c.samples, inPTS: c.basePTS + c.inT, outPTS: c.basePTS + c.outT, speed: ed.speed, loop: ed.loop)
            switcher.setPreview(replay.id)
        case .file(let url):
            cueMovie(url)
            if let f = sources.first(where: { ($0 as? FileSource)?.url == url }) as? FileSource {
                f.onRangeEnd = { [weak self] in self?.returnFromReplay() }
                f.playRange(in: c.inT, out: c.outT, rate: Float(ed.speed), loop: ed.loop)
                switcher.setPreview(f.id)
                if toAir { replayFileID = f.id }
            }
        }
        syncState()
        if toAir { beginReplayOnAir(previewID ?? replay.id) }
    }

    func openInReplay(_ url: URL) {
        replayEditor.loadFile(url)
        requestedCategory = .replay
    }

    private func replayFinished() {
        // Replay ended: go back to the source that was on air before it.
        if replayOnAir || programID == replay.id { returnFromReplay() }
    }

    // MARK: PTZ

    func setPTZ(_ id: UUID, _ c: PTZConfig?) {
        ptz[id] = c
        Task { await ptzControllers[id]?.close() }
        ptzControllers[id] = c.map { PTZController(config: $0) }
    }

    func ptzMove(_ id: UUID, pan: Double, tilt: Double, zoom: Double) {
        guard let p = ptzControllers[id] else { return }
        Task { await p.move(pan: pan, tilt: tilt, zoom: zoom) }
    }

    func ptzPreset(_ id: UUID, _ n: Int, store: Bool) {
        guard let p = ptzControllers[id] else { return }
        Task { store ? await p.storePreset(n) : await p.recallPreset(n) }
    }

    // MARK: Outputs

    func startOutput(_ c: OutputConfig) { outputManager.start(c); outputStatus[c.id] = .connecting; updateEncodeGate() }
    func stopOutput(_ c: OutputConfig) { outputManager.stop(c.id); outputStatus[c.id] = .idle }

    /// Stops the destinations first, then removes them (deleting a live row must not leave a slot running).
    func deleteOutputs(at offsets: IndexSet) {
        let gone = offsets.compactMap { outputs.indices.contains($0) ? outputs[$0] : nil }
        for c in gone {
            outputManager.stop(c.id)
            outputStatus[c.id] = nil
            outputRates[c.id] = nil
            OutputLog.shared.clear(c.id)
        }
        let ids = Set(gone.map(\.id))
        outputs.removeAll { ids.contains($0.id) }
        updateEncodeGate()
    }
    func startAll() { outputs.filter { $0.enabled && $0.proto != .record }.forEach(startOutput) }
    func stopAll() { outputs.filter { $0.proto != .record }.forEach(stopOutput) }
    var isAnyLive: Bool { outputs.contains { $0.proto != .record && outputStatus[$0.id] == .live } }
    var isRecording: Bool { outputs.contains { $0.proto == .record && outputStatus[$0.id] == .live } }

    func toggleRecording() {
        if let r = outputs.first(where: { $0.proto == .record }) {
            (outputStatus[r.id] ?? .idle) == .idle ? startOutput(r) : stopOutput(r)
        } else {
            let r = OutputConfig(name: "Ghi file", proto: .record, url: "")
            outputs.append(r); startOutput(r)
        }
    }

    // MARK: Persistence

    private func saveOutputs() { Self.save(outputs, key: "dtd.outputs.v1") }
    private func saveTitles() { Self.save(titles, key: "dtd.titles.v1"); MainActorBox.setTitles(titles) }
    private static func save<T: Encodable>(_ v: T, key: String) { UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: key) }
    private static func load<T: Decodable>(_ t: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

/// Lock-protected copy of titles readable from the render thread without hopping to the main actor.
enum MainActorBox {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var items: [TitleItem] = []
    static func setTitles(_ t: [TitleItem]) { lock.lock(); items = t; lock.unlock() }
    static func titles(_ owner: AnyObject?) -> [TitleItem] { lock.lock(); defer { lock.unlock() }; return items }
}

// MARK: - Remote control (web remote, Companion/Stream Deck, OSC, DTDLive camera tally)

extension StudioEngine: ControlTarget {
    func handle(_ cmd: ControlCommand) async {
        switch cmd {
        case .cut: cut()
        case .auto: autoTransition()
        case .take(let n): if let s = sourceIndex(n) { take(s.id) }
        case .preview(let n): if let s = sourceIndex(n) { select(s.id) }
        case .ftb(let on): fadeToBlack = on
        case .titleShow(let id, let on): setTitleVisible(id, on)
        case .titleUpdate(let t): upsertTitle(t)
        case .scoreA(let v): setScore(a: v)
        case .scoreB(let v): setScore(b: v)
        case .streamStart: startAll()
        case .streamStop: stopAll()
        case .recordToggle: toggleRecording()
        case .replay: startReplay()
        case .replayStop: stopReplay()
        case .ptz(let n, let p, let t, let z): if let s = sourceIndex(n) { ptzMove(s.id, pan: p, tilt: t, zoom: z) }
        case .ptzPreset(let n, let k, let store): if let s = sourceIndex(n) { ptzPreset(s.id, k, store: store) }
        }
    }

    func pairRequest(_ body: Data) async -> Data { pairing.handleRequest(body) }
    func pairStatus(_ requestID: String) async -> Data { pairing.handleStatus(requestID) }

    func stateJSON() async -> Data {
        let score = titles.first { $0.style == .scoreBug }
        let obj: [String: Any] = [
            "live": isAnyLive, "recording": isRecording, "ftb": fadeToBlack,
            "scoreA": score?.scoreA ?? 0, "scoreB": score?.scoreB ?? 0,
            "sources": sources.map { ["name": $0.name, "id": $0.id.uuidString,
                                      "program": $0.id == programID, "preview": $0.id == previewID] },
            "titles": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(titles))) ?? []
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    /// Tally by source name (the DTDLive camera app sends its camera name as SRT streamid / RTMP key / source name).
    func tallyJSON(for name: String) async -> Data {
        let ids = sources.filter { $0.name == name || $0.name.hasSuffix(name) || (($0 as? SRTInputSource)?.url.absoluteString.contains(name) ?? false) }.map(\.id)
        let pgm = ids.contains { tally.program.contains($0) }, pvw = ids.contains { tally.preview.contains($0) }
        return Data("{\"program\":\(pgm),\"preview\":\(pvw)}".utf8)
    }
}

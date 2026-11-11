@preconcurrency import AVFoundation
import Combine
import CoreImage
import Foundation
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
    @Published var format = ProgramFormat() { didSet { switcher.setFormat(format) } }
    @Published var logo: OverlayLayer? { didSet { pushOverlays() } }
    @Published var pip: OverlayLayer? { didSet { pushOverlays() } }
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
        switcher.onProgramFrame = { pb, t in if encodeOn { ve.encode(pb, pts: t) } }
        ve.onEncoded = { sb in om.video(sb); rb.append(sb) }
        audio.onBuffer = { pcm, when in ae.append(pcm, when: when) }
        ae.onEncoded = { buf, when in om.audio(buf, when: when) }
        om.onStatus = { [weak self] id, st in Task { @MainActor in self?.outputStatus[id] = st } }
        switcher.graphicsProvider = { [weak self] size, now in
            let items = MainActorBox.titles(self)
            var img = titlesR.render(items, canvas: size, now: now)
            if let a = ann.current { img = img.map { a.composited(over: $0) } ?? a }
            return img
        }
        switcher.onTally = { [weak self] pgm, pvw in
            Task { @MainActor in self?.updateTally(program: pgm, preview: pvw) }
        }

        outputs = Self.load([OutputConfig].self, key: "dtd.outputs.v1") ?? []
        titles = Self.load([TitleItem].self, key: "dtd.titles.v1") ?? Self.defaultTitles
        titlesSnapshot = titles
        MainActorBox.setTitles(titles)
        switcher.start()
        // Demo/screenshot mode: no microphone or LAN listeners, so no permission alerts cover the UI.
        if !DemoMode.isOn {
            try? audio.start()
            control.target = self
            try? control.start()
        }

        replay.onFinished = { [weak self] in self?.replayFinished() }
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
            Task { @MainActor in await self?.adaptBitrate() }
        })
        if let saved = Self.load(EncoderSettings.self, key: "dtd.encoder.v1") { encoder = saved }
    }

    static let defaultTitles: [TitleItem] = [
        TitleItem(style: .lowerThird, line1: "Tên khách mời", line2: "Chức danh"),
        TitleItem(style: .scoreBug, line1: "Đội A", line2: "Đội B", period: "H1", position: CGPoint(x: 0.04, y: 0.04)),
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
        audio.setProgram(program)
        for id in program.symmetricDifference(old) {
            Task { await ptzControllers[id]?.tally(program.contains(id)) }
        }
        #if NDI_SDK
        for case let s as NDIInputSource in sources { s.setTally(program: program.contains(s.id), preview: preview.contains(s.id)) }
        #endif
        syncState()
    }

    // MARK: Graphics

    private func pushOverlays() { switcher.setOverlays([pip, logo].compactMap { $0 }) }

    func setLogo(_ image: UIImage?) {
        checkpoint()
        guard let image, let ci = CIImage(image: image) else { logo = nil; return }
        logo = OverlayLayer(image: ci, rect: CGRect(x: 0.86, y: 0.04, width: 0.11, height: 0.11))
    }

    func setPiP(_ id: UUID?) {
        checkpoint()
        guard let id, sources.contains(where: { $0.id == id }) else { pip = nil; return }
        pip = OverlayLayer(pipSourceID: id, rect: CGRect(x: 0.66, y: 0.62, width: 0.3, height: 0.3))
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
    func playMusic(_ url: URL) { try? audio.playMusic(url) }
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

    func stopReplay() { replay.cancel() }

    private func replayFinished() {
        // Return to the previous program source.
        if programID == replay.id { autoTransition() }
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

    func startOutput(_ c: OutputConfig) { outputManager.start(c); outputStatus[c.id] = .connecting }
    func stopOutput(_ c: OutputConfig) { outputManager.stop(c.id); outputStatus[c.id] = .idle }
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

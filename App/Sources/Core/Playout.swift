import AVFoundation
import Foundation
import UIKit

// MARK: - Playlist source

/// Movie files played one after another as one switcher source (one tile, one mixer channel).
/// Each clip is a FileSource writing into this source's FrameStore: the last picture of a clip stays up
/// until the first frame of the next one arrives (no black between clips), and the next clip is opened
/// while the current one plays so the change is quick.
final class PlaylistSource: VideoSource {
    let id = UUID()
    var name: String
    let kind: SourceKind = .file
    let frames = FrameStore()
    private(set) var status: SourceStatus = .idle

    let urls: [URL]
    var loops: Bool
    private(set) var index = 0
    private var current: FileSource?
    private var preloaded: FileSource?
    private var stopped = false

    /// Clip sound to the program mixer (set by the engine before start()).
    var onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Main thread: a clip started (its index).
    var onItemChanged: ((Int) -> Void)?
    /// Main thread: the last clip ended (not looping); its last picture stays up.
    var onFinished: (() -> Void)?

    init(name: String, urls: [URL], loops: Bool) {
        self.name = name
        self.urls = urls
        self.loops = loops
    }

    var currentSeconds: Double? { current?.currentSeconds }
    var durationSeconds: Double? { current?.durationSeconds }
    var isPlaying: Bool { current?.isPlaying ?? false }
    var currentName: String? { urls.indices.contains(index) ? urls[index].deletingPathExtension().lastPathComponent : nil }

    func start() async {
        stopped = false
        status = .live
        await play(at: 0)
    }

    func play(at i: Int) async {
        guard !stopped, urls.indices.contains(i) else { return }
        if let old = current { old.onEnded = nil; await old.stop() }
        let clip: FileSource
        if let p = preloaded, p.url == urls[i] { clip = p } else { clip = makeClip(urls[i]) }
        preloaded = nil
        clip.onEnded = { [weak self] in
            guard let self else { return }
            Task { await self.advance() }
        }
        current = clip
        index = i
        await clip.start()
        let cb = onItemChanged
        DispatchQueue.main.async { cb?(i) }
        if let n = nextIndex(after: i), urls[n] != urls[i] { preloaded = makeClip(urls[n]) }   // get the next file ready
    }

    func skip(_ d: Int) async {
        guard !urls.isEmpty else { return }
        await play(at: ((index + d) % urls.count + urls.count) % urls.count)
    }

    func pause() { current?.pause() }
    func resume() { current?.play() }

    func stop() async {
        stopped = true
        current?.onEnded = nil
        await current?.stop()
        current = nil
        preloaded = nil
        frames.clear()
        status = .idle
    }

    private func advance() async {
        guard !stopped else { return }
        if let n = nextIndex(after: index) {
            await play(at: n)
        } else {
            let cb = onFinished
            DispatchQueue.main.async { cb?() }
        }
    }

    private func nextIndex(after i: Int) -> Int? {
        if i + 1 < urls.count { return i + 1 }
        return loops && !urls.isEmpty ? 0 : nil
    }

    private func makeClip(_ u: URL) -> FileSource {
        let f = FileSource(name: u.deletingPathExtension().lastPathComponent, url: u, frames: frames)
        f.loops = false
        f.clearsOnStop = false
        f.onAudio = onAudio
        return f
    }
}

// MARK: - Scheduled playout

/// What happens when a (non-looping) list has played to the end.
enum PlayoutEndAction: String, Codable, CaseIterable, Identifiable {
    case previousSource, stopOutputs, hold
    var id: String { rawValue }
    var label: String {
        switch self {
        case .previousSource: return L("Chuyển PGM về nguồn trước đó")
        case .stopOutputs: return L("Tắt các kết nối phát đã bật")
        case .hold: return L("Giữ khung hình cuối")
        }
    }
}

/// The list and its schedule (saved between launches).
struct PlayoutPlan: Codable, Equatable {
    var files: [String] = []                    // Video library file names, in play order
    var loop = false
    var scheduled = false
    var startAt = Date().addingTimeInterval(3600)
    var outputIDs: [UUID] = []                  // stream connections opened when the list starts
    var endAction: PlayoutEndAction = .previousSource
}

/// Import video → build and schedule a list → at the start time the list goes to PGM and the chosen
/// stream connections open. It plays through the switcher, so logo / titles / scoreboard stay on top.
@MainActor
final class PlayoutController: ObservableObject {
    enum State: Equatable { case idle, armed, playing, finished }

    @Published var plan: PlayoutPlan { didSet { save() } }
    @Published private(set) var state: State = .idle
    @Published private(set) var index = 0
    /// Ticks once a second while armed / playing, for clocks and progress in the UI.
    @Published private(set) var now = Date()
    @Published private(set) var durations: [String: Double] = [:]
    @Published private(set) var startedAt: Date?

    weak var engine: StudioEngine?
    private(set) var source: PlaylistSource?
    private var timer: Timer?
    private var startedOutputs: Set<UUID> = []
    private var previousProgram: UUID?
    private static let key = "dtd.playout.plan.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let p = try? JSONDecoder().decode(PlayoutPlan.self, from: d) {
            plan = p
        } else {
            plan = PlayoutPlan()
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(plan) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    /// Armed or playing: the screen stays on and the operator is warned to keep the app open.
    var isActive: Bool { state == .armed || state == .playing }

    func url(_ file: String) -> URL { MediaLibrary.directory(.movie).appendingPathComponent(file) }
    func exists(_ file: String) -> Bool { FileManager.default.fileExists(atPath: url(file).path) }

    /// Clip lengths (read from the files in the background, once each).
    func loadDurations() {
        for f in Set(plan.files) where durations[f] == nil && exists(f) {
            let u = url(f)
            Task {
                if let d = try? await AVURLAsset(url: u).load(.duration), d.seconds.isFinite { durations[f] = d.seconds }
            }
        }
    }

    var totalDuration: Double { plan.files.reduce(0) { $0 + (durations[$1] ?? 0) } }

    /// When clip i starts: from the real start while playing, else from the scheduled time (or now).
    func plannedStart(of i: Int) -> Date {
        let base = startedAt ?? (plan.scheduled ? plan.startAt : now)
        return base.addingTimeInterval(plan.files.prefix(i).reduce(0) { $0 + (durations[$1] ?? 0) })
    }

    // MARK: Control

    /// "Hẹn giờ": wait for plan.startAt (starts at once if that time has passed).
    func arm() {
        guard !plan.files.isEmpty else { engine?.message = L("Danh sách phát chưa có video"); return }
        guard plan.startAt > Date() else { go(); return }
        state = .armed
        now = Date()
        startTimer()
        engine?.updateIdleTimer()
    }

    func cancelSchedule() {
        guard state == .armed else { return }
        state = .idle
        stopTimer()
        engine?.updateIdleTimer()
    }

    func startNow() { go() }

    func skip(_ d: Int) {
        guard let s = source else { return }
        Task { await s.skip(d) }
    }

    func playClip(_ i: Int) {
        guard let s = source, state == .playing else { return }
        Task { await s.play(at: i) }
    }

    /// Operator stop: PGM back to the source before the list (or any other source), list removed.
    /// Stream connections are left running unless the plan says to close them at the end.
    func stop() {
        guard let engine else { return }
        if let s = source, engine.programID == s.id, let back = fallbackSource(excluding: s.id) { engine.take(back) }
        if plan.endAction == .stopOutputs { stopStartedOutputs() }
        state = .idle
        startedAt = nil
        stopTimer()
        removeSourceLater()
        engine.updateIdleTimer()
    }

    private func go() {
        guard let engine else { return }
        let files = plan.files.filter(exists)
        guard !files.isEmpty else {
            engine.message = L("Danh sách phát chưa có video (hoặc video đã bị xoá khỏi thư viện)")
            state = .idle
            return
        }
        if files.count < plan.files.count {
            engine.message = L("Bỏ qua các video đã bị xoá khỏi thư viện")
        }
        if let late = plan.scheduled ? Date().timeIntervalSince(plan.startAt) : nil, late > 60, state == .armed {
            engine.message = LF("Danh sách bắt đầu trễ %@ phút (ứng dụng không mở đúng giờ)", "\(Int(late / 60))")
        }
        if let old = source { engine.remove(old); source = nil }
        previousProgram = engine.programID
        let s = PlaylistSource(name: L("Danh sách phát"), urls: files.map(url), loops: plan.loop)
        s.onItemChanged = { [weak self] i in self?.index = i }
        s.onFinished = { [weak self] in self?.finished() }
        source = s
        index = 0
        startedAt = Date()
        now = Date()
        state = .playing
        engine.add(s)
        engine.take(s.id)
        startedOutputs = []
        for id in plan.outputIDs {
            guard let c = engine.outputs.first(where: { $0.id == id }) else { continue }
            let running: Bool
            switch engine.outputStatus[id] {
            case .live?, .connecting?, .reconnecting?: running = true
            default: running = false
            }
            if !running {                               // a connection already on air is left as it is
                engine.startOutput(c)
                startedOutputs.insert(id)
            }
        }
        startTimer()
        engine.updateIdleTimer()
    }

    private func finished() {
        guard let engine, state == .playing else { return }
        state = .finished
        switch plan.endAction {
        case .previousSource:
            if let s = source, let back = fallbackSource(excluding: s.id) { engine.take(back) }
            removeSourceLater()
        case .stopOutputs:
            stopStartedOutputs()
        case .hold:
            break
        }
        stopTimer()
        engine.updateIdleTimer()
    }

    private func fallbackSource(excluding id: UUID) -> UUID? {
        guard let engine else { return nil }
        if let p = previousProgram, p != id, engine.sources.contains(where: { $0.id == p }) { return p }
        return engine.sources.first { $0.id != id && $0.id != engine.replay.id }?.id
    }

    private func stopStartedOutputs() {
        guard let engine else { return }
        for id in startedOutputs {
            if let c = engine.outputs.first(where: { $0.id == id }) { engine.stopOutput(c) }
        }
        startedOutputs = []
    }

    /// Takes the list out of the sources once the transition away from it is over (kept while still on PGM).
    private func removeSourceLater() {
        guard let s = source else { return }
        source = nil
        let delay = (engine?.transitionDuration ?? 0.8) + 0.4
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let engine = self?.engine, engine.programID != s.id else { return }
            engine.remove(s)
        }
    }

    // MARK: Clock

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        now = Date()
        if state == .armed, plan.startAt <= now { go() }
    }
}

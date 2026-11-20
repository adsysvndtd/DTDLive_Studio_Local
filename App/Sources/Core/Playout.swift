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
    /// false = cued: the first clip waits on its first frame until roll() (the list goes to PGM).
    private(set) var rolling: Bool

    /// Clip sound to the program mixer (set by the engine before start()).
    var onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Main thread: a clip started (its index).
    var onItemChanged: ((Int) -> Void)?
    /// Main thread: the last clip ended (not looping); its last picture stays up.
    var onFinished: (() -> Void)?

    init(name: String, urls: [URL], loops: Bool, rolling: Bool = true) {
        self.name = name
        self.urls = urls
        self.loops = loops
        self.rolling = rolling
    }

    /// Start playing (from the cued first frame, or the clip chosen while cued).
    func roll() {
        rolling = true
        current?.play()
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
        if !rolling { clip.cueAtStart() }
        let cb = onItemChanged
        DispatchQueue.main.async { cb?(i) }
        if let n = nextIndex(after: i), urls[n] != urls[i] { preloaded = makeClip(urls[n]) }   // get the next file ready
    }

    func skip(_ d: Int) async {
        guard !urls.isEmpty else { return }
        await play(at: ((index + d) % urls.count + urls.count) % urls.count)
    }

    func pause() { current?.pause() }
    func resume() { if rolling { current?.play() } }

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

/// The list and its schedule (saved between launches).
struct PlayoutPlan: Codable, Equatable {
    var files: [String] = []                    // Video library file names, in play order
    var loop = false
    var scheduled = false
    var startAt = Date().addingTimeInterval(3600)
}

/// Import video → list → (schedule) → the list is cued on PVW. Like every source it reaches PGM only with a
/// transition (CUT / AUTO / T-bar / stinger); it starts rolling the moment it is on PGM. Streaming is started
/// with Phát as usual. It plays through the switcher, so logo / titles / scoreboard stay on top.
@MainActor
final class PlayoutController: ObservableObject {
    enum State: Equatable { case idle, armed, cued, playing, finished }

    @Published var plan: PlayoutPlan { didSet { save() } }
    @Published private(set) var state: State = .idle
    @Published private(set) var index = 0
    /// Ticks once a second while armed / cued / playing, for clocks and progress in the UI.
    @Published private(set) var now = Date()
    @Published private(set) var durations: [String: Double] = [:]
    @Published private(set) var startedAt: Date?

    weak var engine: StudioEngine?
    private(set) var source: PlaylistSource?
    private var timer: Timer?
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

    /// Armed, cued or playing: the screen stays on and the operator is told to keep the app open.
    var isActive: Bool { state == .armed || state == .cued || state == .playing }

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

    /// "Hẹn giờ": at plan.startAt the list is cued on PVW (at once if that time has passed).
    func arm() {
        guard !plan.files.isEmpty else { engine?.message = L("Danh sách phát chưa có video"); return }
        guard plan.startAt > Date() else { cue(); return }
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

    /// Put the list on PVW, waiting on the first frame of the first clip.
    func cue() {
        guard let engine else { return }
        let files = plan.files.filter(exists)
        guard !files.isEmpty else {
            engine.message = L("Danh sách phát chưa có video (hoặc video đã bị xoá khỏi thư viện)")
            state = .idle
            return
        }
        var notes: [String] = []
        if files.count < plan.files.count { notes.append(L("Bỏ qua các video đã bị xoá khỏi thư viện")) }
        if state == .armed, plan.scheduled {
            let late = Date().timeIntervalSince(plan.startAt)
            if late > 60 { notes.append(LF("Danh sách lên PVW trễ %@ phút (ứng dụng không mở đúng giờ)", "\(Int(late / 60))")) }
        }
        if let old = source { discard(old) }
        let s = PlaylistSource(name: L("Danh sách phát"), urls: files.map(url), loops: plan.loop, rolling: false)
        s.onItemChanged = { [weak self] i in self?.index = i }
        s.onFinished = { [weak self] in self?.finished() }
        source = s
        index = 0
        startedAt = nil
        now = Date()
        state = .cued
        engine.add(s)
        engine.select(s.id)                              // PVW only; PGM changes with a transition
        notes.append(L("Danh sách phát đã lên PVW — bấm CUT / AUTO / T-bar để phát lên PGM"))
        engine.message = notes.joined(separator: "\n")
        startTimer()
        engine.updateIdleTimer()
    }

    /// Called by the engine whenever PGM changes: a cued list starts rolling when it reaches PGM.
    func programChanged(_ onAir: Set<UUID>) {
        guard state == .cued, let s = source, onAir.contains(s.id) else { return }
        s.roll()
        startedAt = Date()
        state = .playing
    }

    func skip(_ d: Int) {
        guard let s = source, state == .cued || state == .playing else { return }
        Task { await s.skip(d) }
    }

    func playClip(_ i: Int) {
        guard let s = source, state == .cued || state == .playing else { return }
        Task { await s.play(at: i) }
    }

    /// Stop the list. It never changes PGM by itself: while still on PGM it holds its picture and is
    /// removed once a transition has taken it off air.
    func stop() {
        if let s = source { discard(s) }
        source = nil
        state = .idle
        startedAt = nil
        stopTimer()
        engine?.updateIdleTimer()
    }

    private func finished() {
        guard state == .playing else { return }
        state = .finished
        engine?.message = L("Danh sách phát đã hết — giữ khung cuối, bấm chuyển cảnh để rời")
        stopTimer()
        engine?.updateIdleTimer()
    }

    /// Pause now; take the source out of the inputs as soon as it is not on PGM.
    private func discard(_ s: PlaylistSource) {
        s.pause()
        Task { @MainActor [weak self] in
            while let engine = self?.engine, engine.programID == s.id {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let engine = self?.engine, engine.sources.contains(where: { $0.id == s.id }) else { return }
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
        if state == .armed, plan.startAt <= now { cue() }
    }
}

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
    /// Optional so plans saved before this option still decode.
    var directPGM: Bool?
    /// Go straight to PGM (cut) instead of waiting on PVW for a transition.
    var toProgram: Bool { get { directPGM ?? false } set { directPGM = newValue } }
}

/// One time slot of the day schedule: its own video list, cued on PVW at its start time.
struct ScheduleSlot: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    /// Date and time of the first occurrence (repeating slots use only the time of day).
    var start = Date()
    /// Calendar weekdays it repeats on (1 = CN … 7 = T7); empty = only on the date of `start`.
    var repeatDays: [Int] = []
    var files: [String] = []
    var loop = false
    var enabled = true
    /// Optional so slots saved before this option still decode.
    var directPGM: Bool?
    /// At its time the list cuts straight to PGM instead of waiting on PVW.
    var toProgram: Bool { get { directPGM ?? false } set { directPGM = newValue } }

    /// On the calendar for this day (enabled or not).
    func scheduled(on day: Date, _ cal: Calendar) -> Bool {
        if repeatDays.isEmpty { return cal.isDate(start, inSameDayAs: day) }
        return repeatDays.contains(cal.component(.weekday, from: day)) && cal.startOfDay(for: day) >= cal.startOfDay(for: start)
    }

    /// Will actually be cued on this day.
    func fires(on day: Date, _ cal: Calendar) -> Bool { enabled && !files.isEmpty && scheduled(on: day, cal) }

    func fireTime(on day: Date, _ cal: Calendar) -> Date {
        let hm = cal.dateComponents([.hour, .minute], from: start)
        return cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: day) ?? day
    }
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

    /// Day schedule: time slots, each with its own list.
    @Published var schedule: [ScheduleSlot] { didSet { saveSchedule() } }
    /// The day schedule is running: each slot's list is cued on PVW at its time.
    @Published var scheduleOn: Bool {
        didSet {
            UserDefaults.standard.set(scheduleOn, forKey: Self.onKey)
            if scheduleOn && !oldValue { markPast(olderThan: 0) }
            updateTimer()
            engine?.updateIdleTimer()
        }
    }

    weak var engine: StudioEngine?
    private(set) var source: PlaylistSource?
    private var timer: Timer?
    /// Slot id → day ("yyyy-MM-dd") it was last cued, so a slot fires once a day (kept across launches).
    private var fired: [String: String]
    private static let key = "dtd.playout.plan.v1"
    private static let scheduleKey = "dtd.playout.schedule.v1"
    private static let onKey = "dtd.playout.scheduleOn"
    private static let firedKey = "dtd.playout.fired.v1"
    /// A slot whose time passed while the app was not open is still cued within this window, else skipped.
    private static let lateWindow: TimeInterval = 600

    init() {
        let ud = UserDefaults.standard
        plan = ud.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(PlayoutPlan.self, from: $0) } ?? PlayoutPlan()
        schedule = ud.data(forKey: Self.scheduleKey).flatMap { try? JSONDecoder().decode([ScheduleSlot].self, from: $0) } ?? []
        fired = (ud.dictionary(forKey: Self.firedKey) as? [String: String]) ?? [:]
        scheduleOn = ud.bool(forKey: Self.onKey)
        if scheduleOn {
            markPast(olderThan: Self.lateWindow)      // slots long past before this launch: not cued now
            updateTimer()
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(plan) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    private func saveSchedule() {
        if let d = try? JSONEncoder().encode(schedule) { UserDefaults.standard.set(d, forKey: Self.scheduleKey) }
    }

    /// Armed, cued or playing: the screen stays on and the operator is told to keep the app open.
    var isActive: Bool { state == .armed || state == .cued || state == .playing }
    /// The screen stays on (also while the day schedule is waiting for its next slot).
    var keepsScreenOn: Bool { isActive || scheduleOn }

    // MARK: Day schedule

    private static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    private func dayKey(_ d: Date) -> String { Self.dayFormat.string(from: d) }

    /// Slots on the calendar for a day, in time order.
    func slots(on day: Date) -> [ScheduleSlot] {
        let cal = Calendar.current
        return schedule.filter { $0.scheduled(on: day, cal) }
            .sorted { $0.fireTime(on: day, cal) < $1.fireTime(on: day, cal) }
    }

    func duration(of files: [String]) -> Double { files.reduce(0) { $0 + (durations[$1] ?? 0) } }

    /// Next slot that will be cued (within a week).
    func nextFire(after date: Date = Date()) -> (slot: ScheduleSlot, at: Date)? {
        let cal = Calendar.current
        for d in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: d, to: cal.startOfDay(for: date)) else { continue }
            let hits = schedule.filter { $0.fires(on: day, cal) }
                .map { (slot: $0, at: $0.fireTime(on: day, cal)) }
                .filter { $0.at > date }
                .sorted { $0.at < $1.at }
            if let first = hits.first { return first }
        }
        return nil
    }

    /// Marks today's slots whose time is more than `olderThan` seconds ago as done (no cue, no message).
    private func markPast(olderThan: TimeInterval) {
        let cal = Calendar.current, t = Date(), key = dayKey(t)
        for s in schedule where s.fires(on: t, cal) && t.timeIntervalSince(s.fireTime(on: t, cal)) > olderThan {
            fired[s.id.uuidString] = key
        }
        UserDefaults.standard.set(fired, forKey: Self.firedKey)
    }

    private func checkSchedule() {
        let cal = Calendar.current, t = now, key = dayKey(t)
        for s in schedule where s.fires(on: t, cal) && fired[s.id.uuidString] != key {
            let at = s.fireTime(on: t, cal)
            guard t >= at else { continue }
            fired[s.id.uuidString] = key
            UserDefaults.standard.set(fired, forKey: Self.firedKey)
            let label = s.name.isEmpty ? L("Danh sách phát") : s.name
            if t.timeIntervalSince(at) > Self.lateWindow {
                engine?.message = LF("Bỏ qua khung giờ %@ lúc %@: ứng dụng không mở đúng giờ", label, Self.hm.string(from: at))
                continue
            }
            cue(files: s.files, loop: s.loop, name: label, toProgram: s.toProgram)
        }
    }

    static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    func url(_ file: String) -> URL { MediaLibrary.directory(.movie).appendingPathComponent(file) }
    func exists(_ file: String) -> Bool { FileManager.default.fileExists(atPath: url(file).path) }

    /// Clip lengths (read from the files in the background, once each).
    func loadDurations() { loadDurations(plan.files + schedule.flatMap(\.files)) }

    func loadDurations(_ files: [String]) {
        for f in Set(files) where durations[f] == nil && exists(f) {
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
        updateTimer()
        engine?.updateIdleTimer()
    }

    func cancelSchedule() {
        guard state == .armed else { return }
        state = .idle
        updateTimer()
        engine?.updateIdleTimer()
    }

    /// Put the list on PVW, waiting on the first frame of the first clip.
    func cue() { cue(files: plan.files, loop: plan.loop, name: L("Danh sách phát"), toProgram: plan.toProgram) }

    /// Put any list on PVW (the manual list or a schedule slot's). A list already playing on PGM keeps
    /// playing until a transition takes it off air.
    /// `toProgram`: skip PVW — cut the list straight to PGM (it starts rolling there).
    func cue(files all: [String], loop: Bool, name: String, toProgram: Bool = false) {
        guard let engine else { return }
        let files = all.filter(exists)
        guard !files.isEmpty else {
            engine.message = L("Danh sách phát chưa có video (hoặc video đã bị xoá khỏi thư viện)")
            if state == .armed { state = .idle }
            updateTimer()
            return
        }
        var notes: [String] = []
        if files.count < all.count { notes.append(L("Bỏ qua các video đã bị xoá khỏi thư viện")) }
        if state == .armed, plan.scheduled {
            let late = Date().timeIntervalSince(plan.startAt)
            if late > 60 { notes.append(LF("Danh sách lên PVW trễ %@ phút (ứng dụng không mở đúng giờ)", "\(Int(late / 60))")) }
        }
        if let old = source { retire(old, pause: false) }
        let s = PlaylistSource(name: name, urls: files.map(url), loops: loop, rolling: false)
        s.onItemChanged = { [weak self, weak s] i in
            guard let self, let s, self.source === s else { return }
            self.index = i
        }
        s.onFinished = { [weak self, weak s] in
            guard let self, let s, self.source === s else { return }
            self.finished()
        }
        source = s
        index = 0
        startedAt = nil
        now = Date()
        state = .cued
        engine.add(s)
        if toProgram {
            // Cut straight to PGM once the first frame is decoded (PVW is left as it was).
            notes.append(LF("%@ phát thẳng lên PGM", name))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak s] in
                guard let self, let s, self.source === s, self.state == .cued, let engine = self.engine else { return }
                engine.take(s.id)
            }
        } else {
            engine.select(s.id)                          // PVW only; PGM changes with a transition
            notes.append(LF("%@ đã lên PVW — bấm CUT / AUTO / T-bar để phát lên PGM", name))
        }
        engine.message = notes.joined(separator: "\n")
        updateTimer()
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
        if let s = source { retire(s, pause: true) }
        source = nil
        state = .idle
        startedAt = nil
        updateTimer()
        engine?.updateIdleTimer()
    }

    private func finished() {
        guard state == .playing else { return }
        state = .finished
        engine?.message = L("Danh sách phát đã hết — giữ khung cuối, bấm chuyển cảnh để rời")
        updateTimer()
        engine?.updateIdleTimer()
    }

    /// Take a list out of the inputs as soon as it is not on PGM. `pause`: stop it now (operator stop);
    /// otherwise a list still on air keeps playing until a transition takes it off.
    private func retire(_ s: PlaylistSource, pause: Bool) {
        if pause || self.engine?.programID != s.id { s.pause() }
        Task { @MainActor [weak self] in
            while let engine = self?.engine, engine.programID == s.id {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let engine = self?.engine, engine.sources.contains(where: { $0.id == s.id }) else { return }
            await s.stop()
            engine.remove(s)
        }
    }

    // MARK: Clock

    /// The one-second clock runs while something is scheduled, cued or playing.
    private func updateTimer() {
        if scheduleOn || state != .idle { startTimer() } else { stopTimer() }
    }

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
        if scheduleOn { checkSchedule() }
    }
}

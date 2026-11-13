@preconcurrency import AVFoundation
import Foundation
import os

/// One fader on the audio mixer.
struct AudioChannelState: Identifiable, Equatable {
    let id: UUID
    var name: String
    var gain: Float = 1          // linear 0...2
    var muted = false
    var followVideo = false      // AFV: only audible while its source is on program
    var solo = false             // when any channel is soloed, only soloed channels are heard
    var trim: Float = 0          // input gain in dB (−12…+24), applied before the fader
    var level: Float = -60       // dBFS peak (read-only for UI)
}

/// Program audio mixer: microphone / USB interface + every network source's audio
/// + background music, each on its own fader, mixed by AVAudioEngine and tapped
/// as 48 kHz stereo PCM (host-time stamped) for the AAC encoder.
final class AudioCapture: @unchecked Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    static let micID = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
    static let musicID = UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!

    private let engine = AVAudioEngine()
    private let bus = AVAudioMixerNode()         // program bus (tapped)
    private var channelMixers: [UUID: AVAudioMixerNode] = [:]
    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var playerFormats: [UUID: AVAudioFormat] = [:]
    private var states: [UUID: AudioChannelState] = [:]
    private var programIDs: Set<UUID> = []
    private var programMain: UUID?

    /// Audio-follow-video rule for channels with followVideo:
    ///   afv1 = only the source on PGM is heard; afv2 = every source visible on PGM (incl. PiP / layout windows).
    enum AFVMode: String { case afv1, afv2 }
    var afvMode: AFVMode = .afv1 { didSet { DispatchQueue.main.async { self.applyGains() } } }
    private var lock = os_unfair_lock()
    private var musicFile: AVAudioFile?
    private let micDelay = AVAudioUnitDelay()

    /// Mic/line delay in milliseconds (0–500) to match camera/network video latency.
    var isRunning: Bool { engine.isRunning }

    var micDelayMs: Double = 0 {
        didSet {
            micDelay.delayTime = micDelayMs / 1000
            micDelay.bypass = micDelayMs <= 0
        }
    }


    var onBuffer: Handler?
    var masterGain: Float = 1 { didSet { bus.outputVolume = masterGain } }
    private(set) var peakDB: Float = -60
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetoothA2DP, .mixWithOthers, .defaultToSpeaker])
        try session.setPreferredSampleRate(48000)
        try session.setActive(true)

        engine.attach(bus)
        // Local listening (device speaker / headphones):
        //   programMon = the whole program incl. mic (headphones only, the speaker would feed back)
        //   localMix   = music, effects, movie and network-source sound without the mic (safe on the speaker)
        engine.attach(programMon)
        engine.attach(localMix)
        engine.connect(bus, to: programMon, format: format)
        engine.connect(programMon, to: engine.mainMixerNode, format: format)
        engine.connect(localMix, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        applyMonitor()

        // Microphone channel (through a delay line to line mic/line audio up with late video)
        let mic = makeChannel(Self.micID, name: "Mic")
        engine.attach(micDelay)
        micDelay.wetDryMix = 100; micDelay.feedback = 0; micDelay.lowPassCutoff = 20000; micDelay.delayTime = 0
        let inFmt = engine.inputNode.outputFormat(forBus: 0)
        engine.connect(engine.inputNode, to: micDelay, format: inFmt)
        engine.connect(micDelay, to: mic, format: inFmt)

        // Music channel
        let music = makeChannel(Self.musicID, name: "Nhạc nền")
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: music, format: format)
        players[Self.musicID] = player

        bus.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self else { return }
            self.peakDB = Self.peak(buffer)
            let t = when.isHostTimeValid ? when : AVAudioTime(hostTime: mach_absolute_time())
            self.onBuffer?(buffer, t)
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: Input device / monitoring

    struct Input: Identifiable, Hashable { let id: String; let name: String }

    var inputs: [Input] {
        (AVAudioSession.sharedInstance().availableInputs ?? []).map { Input(id: $0.uid, name: $0.portName) }
    }

    var currentInputID: String? { AVAudioSession.sharedInstance().preferredInput?.uid ?? AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid }

    /// Select microphone / USB interface / headset mic (nil = system default).
    func setInput(_ uid: String?) {
        let s = AVAudioSession.sharedInstance()
        try? s.setPreferredInput(s.availableInputs?.first { $0.uid == uid })
    }

    /// Hear the full Program (with mic) — headphones only: on the speaker the mic would feed back.
    var monitorProgram = false { didSet { applyMonitor() } }
    /// Hear music, sound effects, movie and camera sound on the device (no mic, so no feedback). On by default.
    var speakerMonitor = true { didSet { applyMonitor() } }

    private let programMon = AVAudioMixerNode()
    private let localMix = AVAudioMixerNode()

    private func applyMonitor() {
        programMon.outputVolume = monitorProgram ? 1 : 0
        localMix.outputVolume = (speakerMonitor && !monitorProgram) ? 1 : 0
    }

    func stop() {
        bus.removeTap(onBus: 0)
        engine.stop()
    }

    @discardableResult
    private func makeChannel(_ id: UUID, name: String) -> AVAudioMixerNode {
        let m = AVAudioMixerNode()
        engine.attach(m)
        if id == Self.micID {
            engine.connect(m, to: bus, format: format)
        } else {
            // fan out: program bus + local listening mix (fader / mute apply to both)
            engine.connect(m, to: [AVAudioConnectionPoint(node: bus, bus: bus.nextAvailableInputBus),
                                   AVAudioConnectionPoint(node: localMix, bus: localMix.nextAvailableInputBus)],
                           fromBus: 0, format: format)
        }
        m.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] b, _ in
            guard let self else { return }
            let db = Self.peak(b)
            os_unfair_lock_lock(&self.lock); self.states[id]?.level = db; os_unfair_lock_unlock(&self.lock)
        }
        channelMixers[id] = m
        os_unfair_lock_lock(&lock); states[id] = AudioChannelState(id: id, name: name); os_unfair_lock_unlock(&lock)
        return m
    }

    // MARK: Network-source channels

    /// Called with decoded PCM from an SRT/RTMP source. Creates its fader lazily.
    func feed(sourceID: UUID, name: String, buffer: AVAudioPCMBuffer) {
        DispatchQueue.main.async { [self] in
            if channelMixers[sourceID] == nil { makeChannel(sourceID, name: name); applyGains() }
            if playerFormats[sourceID] != buffer.format {
                players[sourceID].map { engine.disconnectNodeOutput($0); engine.detach($0) }
                let p = AVAudioPlayerNode()
                engine.attach(p)
                engine.connect(p, to: channelMixers[sourceID]!, format: buffer.format)
                players[sourceID] = p
                playerFormats[sourceID] = buffer.format
                p.play()
            }
            players[sourceID]?.scheduleBuffer(buffer)
        }
    }

    func renameChannel(_ id: UUID, to name: String) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        states[id]?.name = name
    }

    func removeChannel(_ id: UUID) {
        DispatchQueue.main.async { [self] in
            players[id].map { $0.stop(); engine.detach($0) }
            channelMixers[id].map { $0.removeTap(onBus: 0); engine.detach($0) }
            players[id] = nil; channelMixers[id] = nil; playerFormats[id] = nil
            os_unfair_lock_lock(&lock); states[id] = nil; os_unfair_lock_unlock(&lock)
        }
    }

    // MARK: Faders / AFV

    var channels: [AudioChannelState] {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return states.values.sorted { a, b in
            if a.id == Self.micID { return true }
            if b.id == Self.micID { return false }
            if a.id == Self.musicID { return true }
            if b.id == Self.musicID { return false }
            return a.name < b.name
        }
    }

    /// Screenshot/demo mode: fill the mixer with channels and moving fake levels (engine not running).
    func injectDemo(_ list: [AudioChannelState]) {
        os_unfair_lock_lock(&lock); for c in list { states[c.id] = c }; os_unfair_lock_unlock(&lock)
    }
    func demoTick(_ t: Double) {
        os_unfair_lock_lock(&lock)
        for (i, k) in states.keys.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
            let s = states[k]!
            let base: Float = s.muted ? -60 : -30 + 20 * Float(s.gain) / 2
            states[k]?.level = min(0, base + 8 * Float(sin(t * (1.3 + Double(i) * 0.4))))
        }
        peakDB = -14 + 4 * Float(sin(t * 1.7))
        os_unfair_lock_unlock(&lock)
    }

    func update(_ s: AudioChannelState) {
        os_unfair_lock_lock(&lock); let level = states[s.id]?.level ?? -60; states[s.id] = s; states[s.id]?.level = level; os_unfair_lock_unlock(&lock)
        applyGains()
    }

    /// Called with the sources on program (audio-follow-video).
    func setProgram(_ ids: Set<UUID>, main: UUID? = nil) {
        os_unfair_lock_lock(&lock)
        let changed = ids != programIDs || main != programMain
        programIDs = ids; programMain = main
        os_unfair_lock_unlock(&lock)
        if changed { DispatchQueue.main.async { self.applyGains() } }
    }

    private func applyGains() {
        os_unfair_lock_lock(&lock); let st = states; let all = programIDs; let main = programMain; os_unfair_lock_unlock(&lock)
        let pgm: Set<UUID> = afvMode == .afv1 ? Set([main].compactMap { $0 }) : all
        let anySolo = st.values.contains { $0.solo }
        for (id, s) in st {
            let audible = !s.muted && (!s.followVideo || pgm.contains(id)) && (!anySolo || s.solo)
            channelMixers[id]?.outputVolume = audible ? s.gain * powf(10, s.trim / 20) : 0
        }
    }

    // MARK: Background music

    struct NotRunning: LocalizedError { var errorDescription: String? { "bộ trộn âm thanh chưa chạy (kiểm tra quyền micro)" } }

    func playMusic(_ url: URL, loop: Bool = true) throws {
        guard engine.isRunning, let player = players[Self.musicID] else { throw NotRunning() }
        let file = try AVAudioFile(forReading: url)
        musicFile = file
        player.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: channelMixers[Self.musicID]!, format: file.processingFormat)
        func schedule() {
            player.scheduleFile(file, at: nil) { [weak self] in
                if loop, self?.musicFile === file { DispatchQueue.main.async { schedule() } }
            }
        }
        schedule()
        player.play()
    }

    func stopMusic() { musicFile = nil; players[Self.musicID]?.stop() }

    /// One-shot sound effect (stinger) on the music channel without stopping the bed.
    func playEffect(_ url: URL) {
        guard engine.isRunning, let file = try? AVAudioFile(forReading: url), let m = channelMixers[Self.musicID] else { return }
        let p = AVAudioPlayerNode()
        engine.attach(p)
        engine.connect(p, to: m, format: file.processingFormat)
        p.scheduleFile(file, at: nil) { [weak self] in DispatchQueue.main.async { self?.engine.detach(p) } }
        p.play()
    }

    static func peak(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData else { return -60 }
        var peak: Float = 0
        for c in 0..<Int(b.format.channelCount) { for i in 0..<Int(b.frameLength) { peak = max(peak, abs(ch[c][i])) } }
        return 20 * log10(max(peak, 0.000_01))
    }
}

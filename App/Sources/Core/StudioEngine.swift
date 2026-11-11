@preconcurrency import AVFoundation
import Combine
import CoreImage
import Foundation
import SwiftUI

/// Wires sources -> switcher -> encoders -> outputs, and exposes state to SwiftUI.
@MainActor
final class StudioEngine: ObservableObject {
    @Published private(set) var sources: [any VideoSource] = []
    @Published private(set) var programID: UUID?
    @Published private(set) var previewID: UUID?
    @Published var transition: TransitionStyle = .mix
    @Published var transitionDuration: Double = 0.8
    @Published var outputs: [OutputConfig] = [] { didSet { save() } }
    @Published private(set) var outputStatus: [UUID: OutputStatus] = [:]
    @Published var encoder = EncoderSettings() { didSet { videoEncoder.update(encoder) } }
    @Published var format = ProgramFormat() { didSet { switcher.setFormat(format) } }
    @Published var logo: OverlayLayer? { didSet { pushOverlays() } }
    @Published var pip: OverlayLayer? { didSet { pushOverlays() } }
    @Published var fadeToBlack = false { didSet { switcher.setFadeToBlack(fadeToBlack) } }
    @Published private(set) var audioLevel: Float = -60

    let switcher = Switcher()
    private let audio = AudioCapture()
    private let videoEncoder: VideoEncoder
    private let audioEncoder: AudioEncoder
    private let outputManager: OutputManager
    private var meterTimer: Timer?

    init() {
        let ve = VideoEncoder(settings: EncoderSettings())
        // Must match AudioCapture.format (48 kHz stereo float); `self` isn't usable before all stored properties are set.
        let ae = AudioEncoder(input: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!, bitrate: 128_000)
        videoEncoder = ve
        audioEncoder = ae
        outputManager = OutputManager(audioFormat: ae.outputFormat, requestKeyframe: { [weak ve] in ve?.requestKeyframe() })

        let om = outputManager
        switcher.onProgramFrame = { pb, t in ve.encode(pb, pts: t) }
        ve.onEncoded = { sb in om.video(sb) }
        audio.onBuffer = { pcm, when in ae.append(pcm, when: when) }
        ae.onEncoded = { buf, when in om.audio(buf, when: when) }
        om.onStatus = { [weak self] id, st in Task { @MainActor in self?.outputStatus[id] = st } }

        outputs = Self.load()
        switcher.start()
        try? audio.start()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.audioLevel = self?.audio.peakDB ?? -60 }
        }
    }

    // MARK: Sources

    func add(_ source: any VideoSource) {
        sources.append(source)
        switcher.register(source.id, store: source.frames)
        Task { await source.start(); objectWillChange.send() }
        if programID == nil { switcher.take(source.id) } else if previewID == nil { switcher.setPreview(source.id) }
        syncState()
    }

    func remove(_ source: any VideoSource) {
        switcher.unregister(source.id)
        sources.removeAll { $0.id == source.id }
        Task { await source.stop() }
        syncState()
    }

    // MARK: Switching

    func select(_ id: UUID) { switcher.setPreview(id); syncState() }
    func take(_ id: UUID) { switcher.take(id); syncState() }
    func cut() { switcher.cut(); syncState() }
    func autoTransition() {
        switcher.auto(transition, duration: transitionDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + transitionDuration + 0.05) { [weak self] in self?.syncState() }
    }

    private func syncState() {
        let s = switcher.state
        programID = s.program; previewID = s.preview
    }

    private func pushOverlays() { switcher.setOverlays([pip, logo].compactMap { $0 }) }

    func setLogo(_ image: UIImage?) {
        guard let image, let ci = CIImage(image: image) else { logo = nil; return }
        logo = OverlayLayer(image: ci, rect: CGRect(x: 0.86, y: 0.04, width: 0.11, height: 0.11))
    }

    func setPiP(_ id: UUID?) {
        guard let id, let s = sources.first(where: { $0.id == id }) else { pip = nil; return }
        pip = OverlayLayer(pipSource: s.frames, rect: CGRect(x: 0.66, y: 0.62, width: 0.3, height: 0.3))
    }

    // MARK: Outputs

    func startOutput(_ c: OutputConfig) { outputManager.start(c); outputStatus[c.id] = .connecting }
    func stopOutput(_ c: OutputConfig) { outputManager.stop(c.id); outputStatus[c.id] = .idle }
    func startAll() { outputs.filter(\.enabled).forEach(startOutput) }
    func stopAll() { outputManager.stopAll(); outputs.forEach { outputStatus[$0.id] = .idle } }
    var isAnyLive: Bool { outputStatus.values.contains(.live) }

    private static let key = "dtd.outputs.v1"
    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(outputs), forKey: Self.key) }
    private static func load() -> [OutputConfig] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([OutputConfig].self, from: d)) ?? []
    }
}

import Foundation

/// Automatic switching: rotate through chosen inputs on a timer (sequence or random),
/// or follow the loudest audio channel (simple voice-activated switching for talk shows).
@MainActor
final class AutoSwitcher: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case sequence, random, audio
        var id: String { rawValue }
        var label: String { self == .sequence ? "Lần lượt" : self == .random ? "Ngẫu nhiên" : "Theo âm thanh" }
    }

    @Published var enabled = false { didSet { enabled ? start() : stop() } }
    @Published var mode: Mode = .sequence
    @Published var interval: Double = 8
    @Published var inputs: [UUID] = []
    /// For audio mode: source -> audio channel id to watch (defaults to the source's own channel).
    var audioMap: [UUID: UUID] = [:]
    var holdMinimum: Double = 3

    private var timer: Timer?
    private var index = 0
    private var lastSwitch = Date.distantPast
    private weak var engine: StudioEngine?

    init(engine: StudioEngine) { self.engine = engine }

    private func start() {
        stop()
        let tick = mode == .audio ? 0.25 : interval
        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
    }

    private func stop() { timer?.invalidate(); timer = nil }

    private func step() {
        guard let engine, !inputs.isEmpty else { return }
        let next: UUID?
        switch mode {
        case .sequence:
            index = (index + 1) % inputs.count
            next = inputs[index]
        case .random:
            next = inputs.filter { $0 != engine.programID }.randomElement() ?? inputs.first
        case .audio:
            guard Date().timeIntervalSince(lastSwitch) >= holdMinimum else { return }
            let levels = engine.audioChannels
            next = inputs.max { a, b in
                let la = levels.first { $0.id == (audioMap[a] ?? a) }?.level ?? -60
                let lb = levels.first { $0.id == (audioMap[b] ?? b) }?.level ?? -60
                return la < lb
            }
            if let n = next, let l = levels.first(where: { $0.id == (audioMap[n] ?? n) })?.level, l < -40 { return }
        }
        guard let next, next != engine.programID else { return }
        engine.select(next)
        engine.autoTransition()
        lastSwitch = Date()
    }
}

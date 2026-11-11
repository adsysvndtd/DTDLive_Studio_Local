@preconcurrency import AVFoundation
import Foundation

/// Program audio: microphone / USB audio interface via AVAudioEngine,
/// with master gain and a level meter. Output PCM is stamped in host time.
final class AudioCapture: @unchecked Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    var onBuffer: Handler?
    var gain: Float = 1 { didSet { mixer.outputVolume = gain } }
    private(set) var peakDB: Float = -60
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetoothA2DP, .mixWithOthers, .defaultToSpeaker])
        try session.setPreferredSampleRate(48000)
        try session.setActive(true)

        engine.attach(mixer)
        let input = engine.inputNode
        engine.connect(input, to: mixer, format: input.outputFormat(forBus: 0))
        // Mixer is tapped, not routed to speakers (avoids feedback).
        engine.connect(mixer, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self else { return }
            self.meter(buffer)
            let t = when.isHostTimeValid ? when : AVAudioTime(hostTime: mach_absolute_time())
            self.onBuffer?(buffer, t)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        mixer.removeTap(onBus: 0)
        engine.stop()
    }

    private func meter(_ b: AVAudioPCMBuffer) {
        guard let ch = b.floatChannelData else { return }
        var peak: Float = 0
        for c in 0..<Int(b.format.channelCount) {
            for i in 0..<Int(b.frameLength) { peak = max(peak, abs(ch[c][i])) }
        }
        peakDB = 20 * log10(max(peak, 0.000_01))
    }
}

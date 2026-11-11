@preconcurrency import AVFoundation
import Foundation
import HaishinKit
import RTMPHaishinKit
import SRTHaishinKit

/// Receives decoded frames from a HaishinKit incoming stream into a FrameStore.
final class FrameSink: StreamOutput, @unchecked Sendable {
    let store: FrameStore
    var onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?
    init(store: FrameStore) { self.store = store }
    func stream(_ stream: some StreamConvertible, didOutput video: CMSampleBuffer) {
        if let pb = video.imageBuffer { store.put(pb) }
    }
    func stream(_ stream: some StreamConvertible, didOutput audio: AVAudioBuffer, when: AVAudioTime) {
        if let pcm = audio as? AVAudioPCMBuffer { onAudio?(pcm) }
    }
}

/// SRT input. URL examples:
///   srt://0.0.0.0:9001?mode=listener          (phone/encoder pushes to the iPad)
///   srt://10.0.0.5:9000?mode=caller&streamid=cam1&passphrase=xxxx&latency=120000
@MainActor
final class SRTInputSource: VideoSource {
    let id = UUID()
    var name: String
    let kind: SourceKind = .srt
    let frames = FrameStore()
    private(set) var status: SourceStatus = .idle

    let url: URL
    private var connection: SRTConnection?
    private var stream: SRTStream?
    lazy var sink = FrameSink(store: frames)

    init(name: String, url: URL) { self.name = name; self.url = url }

    func start() async {
        status = .connecting
        let conn = SRTConnection()
        let s = SRTStream(connection: conn)
        connection = conn; stream = s
        await s.addOutput(sink)
        do {
            try await conn.connect(url)
            await s.play()
            status = .live
        } catch {
            status = .error("\(error)")
        }
    }

    func stop() async {
        await stream?.close()
        await connection?.close()
        frames.clear()
        status = .idle
    }
}

/// RTMP play input, e.g. rtmp://server/live/cam2
@MainActor
final class RTMPInputSource: VideoSource {
    let id = UUID()
    var name: String
    let kind: SourceKind = .rtmpPull
    let frames = FrameStore()
    private(set) var status: SourceStatus = .idle

    let url: URL
    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    lazy var sink = FrameSink(store: frames)

    init(name: String, url: URL) { self.name = name; self.url = url }

    func start() async {
        status = .connecting
        let (app, key) = RTMPURL.split(url)
        let conn = RTMPConnection()
        let s = RTMPStream(connection: conn)
        connection = conn; stream = s
        await s.addOutput(sink)
        do {
            _ = try await conn.connect(app)
            _ = try await s.play(key)
            status = .live
        } catch {
            status = .error("\(error)")
        }
    }

    func stop() async {
        _ = try? await stream?.close()
        try? await connection?.close()
        frames.clear()
        status = .idle
    }
}

enum RTMPURL {
    /// "rtmp://host/app/key" -> ("rtmp://host/app", "key"). Keeps query strings on the key.
    static func split(_ url: URL) -> (String, String) {
        let s = url.absoluteString
        guard let slash = s.lastIndex(of: "/"), s.distance(from: s.startIndex, to: slash) > 8 else { return (s, "") }
        return (String(s[..<slash]), String(s[s.index(after: slash)...]))
    }
}

/// Local video file as an input (intro, ads, replays): loops by default, its sound goes to the mixer.
/// One AVPlayerItem with one AVPlayerItemVideoOutput (an output can only be attached to a single item,
/// so AVPlayerLooper's copies never delivered frames after the first pass).
@MainActor
final class FileSource: VideoSource {
    let id = UUID()
    var name: String
    let kind: SourceKind = .file
    let frames = FrameStore()
    private(set) var status: SourceStatus = .idle

    private let player = AVPlayer()
    private let item: AVPlayerItem
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ])
    private var link: CADisplayLink?
    private var endObserver: NSObjectProtocol?
    private var boundary: Any?
    private var tapAttached = false

    let url: URL
    /// Movie sound goes to the program mixer (set by the engine before start()).
    var onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        didSet { tap = onAudio.map { h in PlayerAudioTap(handler: h) } }
    }
    private var tap: PlayerAudioTap?

    /// Loop at end of file (default) or hold the last frame.
    var loops = true

    private(set) var isPlaying = false

    init(name: String, url: URL) {
        self.name = name
        self.url = url
        item = AVPlayerItem(url: url)
        item.add(output)
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
    }

    func start() async {
        if let tap, !tapAttached {
            tapAttached = true
            await tap.attach(to: item)        // routes the sound into the mixer (player itself is muted by the tap)
        } else if tap == nil {
            player.isMuted = true             // no mixer: never play from the device speaker directly
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.loops { self.player.seek(to: .zero); self.player.play() } else { self.isPlaying = false }
            }
        }
        player.play()
        isPlaying = true
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 30)
        l.add(to: .main, forMode: .common)
        link = l
        status = .live
    }

    @objc private func tick() {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: t), let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
            frames.put(pb)
        } else if !isPlaying, let last = lastFrame {
            frames.put(last)                  // paused / ended: keep the still alive (no "no signal" slate)
            return
        }
        if let pb = frames.latest(staleAfter: 10) { lastFrame = pb }
    }
    private var lastFrame: CVPixelBuffer?

    /// Plays [inT, outT] (seconds in the file) at `rate`; loops or pauses at the out point.
    func playRange(in inT: Double, out outT: Double, rate: Float, loop: Bool) {
        if let b = boundary { player.removeTimeObserver(b); boundary = nil }
        let inTime = CMTime(seconds: inT, preferredTimescale: 600), outTime = CMTime(seconds: outT, preferredTimescale: 600)
        player.seek(to: inTime, toleranceBefore: .zero, toleranceAfter: .zero)
        boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: outTime)], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if loop { self.player.seek(to: inTime, toleranceBefore: .zero, toleranceAfter: .zero) } else { self.player.pause(); self.isPlaying = false }
            }
        }
        player.rate = rate
        isPlaying = true
    }

    func play() { player.play(); isPlaying = true }
    func pause() { player.pause(); isPlaying = false }
    func restart() {
        if let b = boundary { player.removeTimeObserver(b); boundary = nil }
        player.seek(to: .zero); player.play(); isPlaying = true
    }

    func stop() async {
        link?.invalidate(); link = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        if let b = boundary { player.removeTimeObserver(b); boundary = nil }
        isPlaying = false
        player.pause()
        frames.clear()
        status = .idle
    }
}
}

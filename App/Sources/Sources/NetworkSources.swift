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

/// Looping local video file (intro, ads, replays).
@MainActor
final class FileSource: VideoSource {
    let id = UUID()
    var name: String
    let kind: SourceKind = .file
    let frames = FrameStore()
    private(set) var status: SourceStatus = .idle

    private let player: AVQueuePlayer
    private var looper: AVPlayerLooper?
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    private var link: CADisplayLink?

    let url: URL

    init(name: String, url: URL) {
        self.name = name
        self.url = url
        let item = AVPlayerItem(url: url)
        player = AVQueuePlayer()
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
    }

    func start() async {
        player.items().forEach { $0.add(output) }
        player.play()
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
        }
    }

    func stop() async {
        link?.invalidate(); link = nil
        player.pause()
        frames.clear()
        status = .idle
    }
}

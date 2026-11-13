@preconcurrency import AVFoundation
import Foundation
import SRTKit

/// Receiving side of DTD Studio: cameras push to the iPad, many per protocol on one port,
/// told apart by stream key — plus DTDLive phones that pair over Wi-Fi.
///
///   SRT   srt://<IP>:9000?streamid=<key>            (also "#!::r=live/<key>,m=publish")
///   RTMP  rtmp://<IP>:1935/live/<key>
///   RTSP  rtsp://<IP>:8554/live/<key>               (ANNOUNCE/RECORD, RTP over TCP)
///   DTDLive  "Gửi tới máy khác" → pick DTD Studio → confirm the 6-digit code
///
/// Each new key becomes an input automatically; when the camera drops, the input stays (no signal)
/// and picks up again when the same key reconnects.
@MainActor
final class IngestHub: ObservableObject {
    struct Settings: Codable, Equatable {
        var srtEnabled = true
        var srtPort = 9000
        var srtPassphrase = ""          // empty = unencrypted; 10–79 chars otherwise
        var srtLatencyMs = 200
        var rtmpEnabled = true
        var rtmpPort = 1935
        var rtspEnabled = true
        var rtspPort = 8554
        var dtdLiveEnabled = true
    }

    struct StreamInfo: Identifiable, Equatable {
        var id: String { proto + ":" + key }
        let proto: String
        let key: String
        var peer: String
        var online: Bool
    }

    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            save()
            // servers restart; paired DTDLive cameras stay connected unless DTDLive itself was switched
            stopServers(); startServers()
            if settings.dtdLiveEnabled != oldValue.dtdLiveEnabled {
                if settings.dtdLiveEnabled { dtdLive.start() } else { dtdLive.stop() }
            }
        }
    }
    @Published private(set) var streams: [StreamInfo] = []
    @Published private(set) var listenErrors: [String: String] = [:]   // proto -> error

    weak var engine: StudioEngine?
    let router = IngestRouter()
    let dtdLive: DTDLiveLink
    private var srt: SRTKIngestServer?
    private var rtmp: RTMPServer?
    private var rtsp: RTSPServer?
    private static let storeKey = "dtd.ingest.v1"

    init() {
        settings = UserDefaults.standard.data(forKey: Self.storeKey).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        dtdLive = DTDLiveLink(router: router)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: Self.storeKey) }
    }

    // MARK: Lifecycle

    func start() {
        dtdLive.engine = engine
        dtdLive.pairing = engine?.pairing
        engine?.pairing.dtdLive = dtdLive
        if settings.dtdLiveEnabled { dtdLive.start() }
        startServers()
    }

    func stop() {
        dtdLive.stop()
        stopServers()
    }

    private func startServers() {
        if settings.srtEnabled { startSRT() }
        if settings.rtmpEnabled { startRTMP() }
        if settings.rtspEnabled { startRTSP() }
    }

    private func stopServers() {
        if let s = srt { DispatchQueue.global(qos: .utility).async { s.stop() } }
        srt = nil
        rtmp?.stop(); rtmp = nil
        rtsp?.stop(); rtsp = nil
        listenErrors = [:]
    }

    // MARK: Servers

    private func startSRT() {
        let router = self.router
        let server = SRTKIngestServer(port: settings.srtPort, passphrase: settings.srtPassphrase, latencyMs: settings.srtLatencyMs,
            onListening: { [weak self] _, error in
                Task { @MainActor in self?.listenErrors["srt"] = error.isEmpty ? nil : error }
            },
            onStream: { [weak self] key, connected, peer in
                if connected { _ = router.ensure("srt:" + key) }
                Task { @MainActor in self?.streamChanged(proto: "srt", key: key, connected: connected, peer: peer) }
            },
            onFrame: { key, pb in router.sink("srt:" + key)?.pacer.pushArrival(pb) },
            onAudio: { key, aac, asc, rate, channels, _ in
                router.sink("srt:" + key)?.aac([UInt8](aac), asc: [UInt8](asc), sampleRate: rate, channels: channels)
            })
        srt = server
        server.start()
    }

    private func events(_ proto: String) -> RTMPServer.Events {
        let router = self.router
        return RTMPServer.Events(
            onListening: { [weak self] _, error in Task { @MainActor in self?.listenErrors[proto] = error } },
            onStream: { [weak self] key, connected, peer in
                if connected { _ = router.ensure(proto + ":" + key) }
                Task { @MainActor in self?.streamChanged(proto: proto, key: key, connected: connected, peer: peer) }
            },
            sink: { key in router.ensure(proto + ":" + key) })
    }

    private func startRTMP() {
        guard let p = UInt16(exactly: settings.rtmpPort) else { return }
        let s = RTMPServer(port: p, events: events("rtmp"))
        rtmp = s; s.start()
    }

    private func startRTSP() {
        guard let p = UInt16(exactly: settings.rtspPort) else { return }
        let s = RTSPServer(port: p, events: events("rtsp"))
        rtsp = s; s.start()
    }

    // MARK: Inputs

    private func streamChanged(proto: String, key: String, connected: Bool, peer: String) {
        let id = proto + ":" + key
        if let i = streams.firstIndex(where: { $0.id == id }) {
            streams[i].online = connected
            if !peer.isEmpty { streams[i].peer = peer }
        } else if connected {
            streams.append(StreamInfo(proto: proto, key: key, peer: peer, online: true))
        }
        guard let engine else { return }
        if let src = engine.sources.compactMap({ $0 as? IngestSource }).first(where: { $0.ingestKey == id }) {
            src.setOnline(connected, peer: peer)
            engine.objectWillChange.send()
            return
        }
        guard connected else { return }
        let sink = router.ensure(id)
        let kind: SourceKind = proto == "srt" ? .srt : proto == "rtmp" ? .rtmpPull : .rtsp
        let src = IngestSource(name: key, kind: kind, ingestKey: id, frames: sink.frames)
        src.setOnline(true, peer: peer)
        sink.onAudio = engine.audioFeed(sourceID: src.id, name: key)
        engine.add(src)
    }

    // MARK: URLs for the operator

    struct URLInfo: Identifiable { var id: String { proto }; let proto: String; let url: String }

    func urls(ip: String) -> [URLInfo] {
        var out: [URLInfo] = []
        if settings.srtEnabled {
            let pass = settings.srtPassphrase.isEmpty ? "" : "&passphrase=\(settings.srtPassphrase)"
            out.append(URLInfo(proto: "SRT", url: "srt://\(ip):\(settings.srtPort)?streamid=<key>\(pass)"))
        }
        if settings.rtmpEnabled { out.append(URLInfo(proto: "RTMP", url: "rtmp://\(ip):\(settings.rtmpPort)/live/<key>")) }
        if settings.rtspEnabled { out.append(URLInfo(proto: "RTSP", url: "rtsp://\(ip):\(settings.rtspPort)/live/<key>")) }
        return out
    }
}

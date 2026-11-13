import Foundation
import SRTKit

/// Lets DTDLive phones find and pair with DTD Studio exactly as they pair with another DTDLive:
/// Studio publishes `_dtd-pair._tcp` and runs the DTDLive pairing protocol (SRTKCameraPair) as the
/// receiving side. Both screens show the same 6-digit code; after Accept, each camera gets its own
/// encrypted SRT receiver (SRTKCameraReceiver) and appears as an input. Many cameras can be paired;
/// each camera's bond is remembered so it reconnects without asking again.
@MainActor
final class DTDLiveLink: NSObject, NetServiceDelegate {
    static let serviceType = "_dtd-pair._tcp."
    static let serviceName: String = {
        let key = "dtd.dtdlive.instance"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let name = "DTDStudio-" + UUID().uuidString.prefix(6)
        UserDefaults.standard.set(name, forKey: key)
        return name
    }()
    private static let bondsKey = "dtd.dtdlive.bonds.v1"
    /// SRT receive latency for DTDLive over Wi-Fi: room for retransmissions before a packet is given up.
    /// 120 ms (the old value) drops packets on busy Wi-Fi → broken pictures; 300 ms is a safe default.
    static var latencyMs: Int {
        get { let v = UserDefaults.standard.integer(forKey: "dtd.dtdlive.latency"); return v > 0 ? v : 300 }
        set { UserDefaults.standard.set(newValue, forKey: "dtd.dtdlive.latency") }
    }

    weak var engine: StudioEngine?
    weak var pairing: PairingManager?
    let router: IngestRouter

    private struct Camera {
        let receiver: SRTKCameraReceiver
        var port: Int
        let source: IngestSource
    }
    private var control: SRTKCameraPair?
    private var publication: NetService?
    private var cameras: [String: Camera] = [:]          // bond -> camera
    private var pendingMedia: [String: String] = [:]     // bond -> request id waiting for the media port
    private var session = UUID()
    private(set) var listening = false

    init(router: IngestRouter) { self.router = router }

    private var bonds: [String] {
        get { (UserDefaults.standard.string(forKey: Self.bondsKey) ?? "").split(separator: ",").map(String.init) }
        set { UserDefaults.standard.set(newValue.joined(separator: ","), forKey: Self.bondsKey) }
    }

    func start() {
        guard control == nil else { return }
        let token = UUID(); session = token
        let pair = SRTKCameraPair { [weak self] event, id, peer, value, port in
            DispatchQueue.main.async {
                guard let self, self.session == token else { return }
                switch event {
                case .listening:
                    self.publish(port: port)
                case .verify:
                    // DTDLive shows the same 6 digits; the operator compares and accepts in the pairing banner.
                    let code = value.count == 6 ? String(value.prefix(3)) + " " + String(value.suffix(3)) : value
                    self.pairing?.addExternal(PairRequest(id: UUID(), deviceID: "dtdlive:" + peer,
                                                          deviceName: Self.pretty(peer), model: "", app: "DTDLive",
                                                          protocols: ["srt"], pullURL: nil, confirmCode: code,
                                                          created: Date(), dtdLiveRequest: id))
                case .authorized:
                    self.authorize(request: id, bond: value, peer: peer)
                case .ended:
                    self.pairing?.removeExternal(dtdLiveRequest: id)
                default: break
                }
            }
        }
        control = pair
        pair.listen(bond: bonds.joined(separator: ","))
    }

    func stop() {
        session = UUID()
        publication?.stop(); publication = nil
        if let c = control { DispatchQueue.global(qos: .utility).async { c.stop() } }
        control = nil
        for (_, cam) in cameras { let r = cam.receiver; DispatchQueue.global(qos: .utility).async { r.stop() } }
        cameras.removeAll()
        listening = false
    }

    /// Operator decision from the pairing banner.
    func decide(_ request: String, allow: Bool) { control?.decide(request, allow: allow) }

    /// Forget every paired DTDLive (they will ask for confirmation again).
    func forgetAll() { bonds = []; stop(); start() }

    private func authorize(request: String, bond: String, peer: String) {
        pairing?.removeExternal(dtdLiveRequest: request)
        if let cam = cameras[bond] {
            let name = Self.pretty(peer)
            if cam.source.name != name, let engine {
                cam.source.name = name
                router.sink(cam.source.ingestKey)?.onAudio = engine.audioFeed(sourceID: cam.source.id, name: name)
                engine.renameCameraAudio(cam.source.id, to: name)
                engine.objectWillChange.send()
            }
            if cam.port > 0 { control?.mediaReady(request, port: cam.port) }
            else { pendingMedia[bond] = request }
            return
        }
        guard let engine else { return }
        let key = "dtdlive:" + bond.prefix(12)
        let source = IngestSource(name: Self.pretty(peer), kind: .srt, ingestKey: key)
        // Audio from the phone's mic: AAC in the same SRT stream → decoder → its own mixer channel.
        let sink = IngestRouter.Sink(frames: source.frames, onAudio: engine.audioFeed(sourceID: source.id, name: source.name))
        router.set(key, sink)
        pendingMedia[bond] = request
        let frames = source.frames
        // Wi-Fi delivers frames in bursts: play them on an even beat (~0.1 s buffer) instead of on arrival.
        let pacer = FramePacer(store: frames)
        pacer.delay = 0.1
        let rx = SRTKCameraReceiver(passphrase: String(bond.suffix(32)), latencyMs: Self.latencyMs, audioBufferMs: 100,
                                    onListening: { [weak self] port in
            DispatchQueue.main.async {
                guard let self, var cam = self.cameras[bond] else { return }
                cam.port = port; self.cameras[bond] = cam
                if !self.bonds.contains(bond) { self.bonds.append(bond) }
                if let req = self.pendingMedia.removeValue(forKey: bond) { self.control?.mediaReady(req, port: port) }
            }
        }, onState: { state, _ in
            if state != .connected { frames.clear() }
            DispatchQueue.main.async { source.setOnline(state == .connected) }
        }, onFrame: { pb in pacer.pushArrival(pb) }, onAudio: { aac, asc, rate, channels, _ in
            sink.aac([UInt8](aac), asc: [UInt8](asc), sampleRate: rate, channels: channels)
        })
        cameras[bond] = Camera(receiver: rx, port: 0, source: source)
        engine.add(source)
        rx.approved = true
        rx.start()
        startStats()
    }

    // MARK: Link quality (per DTDLive, every 2 s)

    private var statsTimer: Timer?
    private var lastStats: [String: [String: Double]] = [:]

    private func startStats() {
        guard statsTimer == nil else { return }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleStats() }
        }
    }

    private func sampleStats() {
        for (bond, cam) in cameras {
            let d = cam.receiver.linkStats().mapValues { $0.doubleValue }
            let prev = lastStats[bond] ?? [:]
            lastStats[bond] = d
            guard (d["connected"] ?? 0) > 0 else { DTDLiveStats.shared.set(cam.source.id, nil); continue }
            func delta(_ k: String) -> Double { max(0, (d[k] ?? 0) - (prev[k] ?? 0)) }
            let recv = delta("recv"), lost = delta("lost"), dropped = delta("dropped")
            let lossPct = recv + lost > 0 ? lost / (recv + lost) * 100 : 0
            let line = DTDLiveStats.Line(
                mbps: d["mbps"] ?? 0, rttMs: d["rttMs"] ?? 0, lossPct: lossPct, droppedPkts: Int(dropped),
                brokenFrames: Int(delta("videoDropped")), decodeErrors: Int(delta("decodeErrors")),
                latencyMs: Int(d["latencyMs"] ?? 0), bufferMs: Int(d["rcvBufMs"] ?? 0),
                totalLost: Int(d["lost"] ?? 0), totalDropped: Int(d["dropped"] ?? 0), totalBroken: Int(d["videoDropped"] ?? 0))
            DTDLiveStats.shared.set(cam.source.id, line)
        }
    }

    private func publish(port: Int) {
        let service = NetService(domain: "local.", type: Self.serviceType, name: Self.serviceName, port: Int32(port))
        publication = service
        service.delegate = self
        service.publish()
        listening = true
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Task { @MainActor in self.listening = false }
    }

    /// "iPhone-DTDLive-1A2B3C4D" -> "DTDLive 1A2B"
    static func pretty(_ peer: String) -> String {
        if let alias = WiFiSourceName.display(peer) { return alias }
        if peer == "DTDLive-Screen" { return "DTDLive Screen" }
        let tail = peer.split(separator: "-").last.map(String.init) ?? peer
        return "DTDLive " + tail.prefix(4)
    }
}


/// Latest Wi-Fi link figures per DTDLive input (shown in Source info and under the input tile).
@MainActor
final class DTDLiveStats: ObservableObject {
    struct Line: Equatable {
        var mbps: Double, rttMs: Double, lossPct: Double, droppedPkts: Int, brokenFrames: Int, decodeErrors: Int
        var latencyMs: Int, bufferMs: Int, totalLost: Int, totalDropped: Int, totalBroken: Int
        /// good / weak / bad for the colour dot
        var grade: Int { droppedPkts > 0 || brokenFrames > 0 ? 2 : (lossPct > 2 || rttMs > Double(latencyMs) / 3 ? 1 : 0) }
    }
    static let shared = DTDLiveStats()
    @Published private(set) var lines: [UUID: Line] = [:]
    func set(_ id: UUID, _ l: Line?) { if lines[id] != l { lines[id] = l } }
}

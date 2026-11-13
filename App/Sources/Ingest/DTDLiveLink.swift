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
        if let cam = cameras[bond], cam.port > 0 {
            // known camera reconnecting: same receiver, same input
            control?.mediaReady(request, port: cam.port)
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
        let rx = SRTKCameraReceiver(passphrase: String(bond.suffix(32)), audioBufferMs: 100, onListening: { [weak self] port in
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
        let tail = peer.split(separator: "-").last.map(String.init) ?? peer
        return "DTDLive " + tail.prefix(4)
    }
}

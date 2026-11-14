import CryptoKit
import Foundation
import Network

/// Wi-Fi pairing for camera devices (DTDLive and any app that implements docs/PAIRING.md).
///
/// Flow (no typed pairing code):
///  1. Device finds the studio via Bonjour `_dtdstudio._tcp` and POSTs /api/pair/request.
///  2. Both screens show the same 6-digit confirmation ID derived from both device IDs + a nonce.
///  3. Operator checks the IDs match and taps Accept on the studio.
///  4. Studio creates the input (SRT listener with a per-device passphrase, or pulls the
///     device's RTSP/RTMP URL) and returns connection details on /api/pair/status.
///  5. The device is remembered as trusted; next time it reconnects without confirmation.
struct PairRequest: Identifiable, Equatable {
    let id: UUID
    let deviceID: String
    let deviceName: String
    let model: String
    let app: String
    let protocols: [String]          // offered by the device, in preference order: "srt", "rtsp", "rtmp"
    let pullURL: String?             // device-hosted RTSP URL, or RTMP URL on a server, for pull modes
    let confirmCode: String          // "482 913"
    let created: Date
    /// Set for requests that come from DTDLive's own pairing protocol (`_dtd-pair._tcp`).
    var dtdLiveRequest: String? = nil
    var expired: Bool { Date().timeIntervalSince(created) > 120 }
}

struct PairedDevice: Codable, Identifiable, Equatable {
    var id: String { deviceID }
    let deviceID: String
    var name: String
    var token: String                // SRT passphrase / auth token (hex, 32 chars)
    var srtPort: UInt16
    var protocolUsed: String
    var lastSeen: Date
}

enum PairState: Equatable {
    case pending
    case accepted(PairResponse)
    case rejected
}

struct PairResponse: Codable, Equatable {
    var status: String               // "accepted"
    var inputName: String
    var protocolUsed: String         // "srt" (device pushes) | "rtsp"/"rtmp" (studio pulls)
    var pushURL: String?             // for srt: where the device must send (caller)
    var token: String
    var tallyURL: String
}

@MainActor
final class PairingManager: ObservableObject {
    @Published private(set) var pending: [PairRequest] = []
    @Published private(set) var trusted: [PairedDevice] = []
    @Published var autoAcceptTrusted = true
    private var states: [UUID: PairState] = [:]
    let studioID: String
    weak var engine: StudioEngine?
    private let storeKey = "dtd.pairing.trusted.v1"

    init() {
        if let id = UserDefaults.standard.string(forKey: "dtd.studio.id") { studioID = id }
        else { studioID = UUID().uuidString; UserDefaults.standard.set(studioID, forKey: "dtd.studio.id") }
        if let d = UserDefaults.standard.data(forKey: storeKey), let t = try? JSONDecoder().decode([PairedDevice].self, from: d) { trusted = t }
    }

    // MARK: HTTP entry points (called by ControlServer)

    struct RequestBody: Codable {
        var deviceID: String
        var name: String
        var model: String?
        var app: String?
        var protocols: [String]?
        var pullURL: String?
        var nonce: String?
        var token: String?            // trusted reconnect
    }

    func handleRequest(_ body: Data) -> Data {
        guard let b = try? JSONDecoder().decode(RequestBody.self, from: body), !b.deviceID.isEmpty else {
            return json(["status": "error", "error": "bad request"])
        }
        // Throttle: one open request per device, at most 5 pending overall.
        pending.removeAll { $0.expired || $0.deviceID == b.deviceID }
        if pending.count >= 5 { return json(["status": "error", "error": "busy"]) }

        let nonce = b.nonce ?? UUID().uuidString
        let code = Self.confirmCode(studioID: studioID, deviceID: b.deviceID, nonce: nonce)
        let req = PairRequest(id: UUID(), deviceID: b.deviceID, deviceName: String(b.name.prefix(40)),
                              model: b.model ?? "", app: b.app ?? "", protocols: b.protocols ?? ["srt"],
                              pullURL: b.pullURL, confirmCode: code, created: Date())

        if autoAcceptTrusted, let t = trusted.first(where: { $0.deviceID == b.deviceID }), let tok = b.token, Self.equal(tok, t.token) {
            states[req.id] = .pending
            accept(req, reuse: t)
            return json(["status": "accepted-pending", "requestId": req.id.uuidString, "confirmCode": code, "trusted": true])
        }
        pending.append(req)
        states[req.id] = .pending
        return json(["status": "pending", "requestId": req.id.uuidString, "confirmCode": code,
                     "studioName": "DTDStudio", "studioId": studioID])
    }

    func handleStatus(_ requestID: String) -> Data {
        guard let id = UUID(uuidString: requestID), let s = states[id] else { return json(["status": "unknown"]) }
        switch s {
        case .pending:
            if pending.first(where: { $0.id == id })?.expired ?? false { states[id] = .rejected; return json(["status": "expired"]) }
            return json(["status": "pending"])
        case .rejected: return json(["status": "rejected"])
        case .accepted(let r): return (try? JSONEncoder().encode(r)) ?? json(["status": "error"])
        }
    }

    // MARK: Operator actions

    /// DTDLive protocol: shown in the same banner, decided by DTDLiveLink.
    weak var dtdLive: DTDLiveLink?
    func addExternal(_ r: PairRequest) { pending.removeAll { $0.deviceID == r.deviceID }; pending.append(r) }
    func removeExternal(dtdLiveRequest id: String) { pending.removeAll { $0.dtdLiveRequest == id } }

    func reject(_ r: PairRequest) {
        if let req = r.dtdLiveRequest { dtdLive?.decide(req, allow: false); pending.removeAll { $0.id == r.id }; return }
        states[r.id] = .rejected
        pending.removeAll { $0.id == r.id }
    }

    func accept(_ r: PairRequest, reuse: PairedDevice? = nil) {
        if let req = r.dtdLiveRequest { dtdLive?.decide(req, allow: true); pending.removeAll { $0.id == r.id }; return }
        guard let engine else { return }
        pending.removeAll { $0.id == r.id }
        let token = reuse?.token ?? Self.randomToken()
        let ip = NetworkInfo.wifiIPv4() ?? "0.0.0.0"
        let name = r.deviceName
        var response = PairResponse(status: "accepted", inputName: name, protocolUsed: "srt", pushURL: nil, token: token,
                                    tallyURL: "http://\(ip):\(engine.controlPort)/api/tally?name=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)")
        var port = reuse?.srtPort ?? 0

        // Remove an old input for the same device (reconnects replace it).
        if let old = engine.sources.first(where: { $0.name == name }) { engine.remove(old) }

        let wantsPull = r.protocols.first.map { $0 == "rtsp" || $0 == "rtmp" } ?? false
        if wantsPull, let pull = r.pullURL, let url = URL(string: pull) {
            let proto = r.protocols.first!
            engine.add(proto == "rtsp" ? RTSPInputSource(name: name, url: url) : RTMPInputSource(name: name, url: url))
            response.protocolUsed = proto
        } else {
            if port == 0 { port = nextFreePort() }
            let listen = "srt://0.0.0.0:\(port)?mode=listener&passphrase=\(token)&pbkeylen=16&latency=120000"
            if let url = URL(string: listen) { engine.add(SRTInputSource(name: name, url: url)) }
            response.pushURL = "srt://\(ip):\(port)?mode=caller&passphrase=\(token)&pbkeylen=16&latency=120000&streamid=\(r.deviceID)"
            response.protocolUsed = "srt"
        }
        if let s = engine.sources.last { engine.select(s.id) }
        states[r.id] = .accepted(response)

        let dev = PairedDevice(deviceID: r.deviceID, name: name, token: token, srtPort: port,
                               protocolUsed: response.protocolUsed, lastSeen: Date())
        trusted.removeAll { $0.deviceID == r.deviceID }
        trusted.append(dev)
        save()
    }

    /// Demo / screenshot helper: a fake incoming request.
    func injectDemoRequest() {
        let r = PairRequest(id: UUID(), deviceID: "DEMO-IPHONE", deviceName: "iPhone 16 Pro · Thanh", model: "iPhone17,1",
                            app: "DTDLive", protocols: ["srt"], pullURL: nil,
                            confirmCode: Self.confirmCode(studioID: studioID, deviceID: "DEMO-IPHONE", nonce: "demo"), created: Date())
        pending.append(r); states[r.id] = .pending
    }

    func forget(_ d: PairedDevice) { trusted.removeAll { $0.deviceID == d.deviceID }; save() }

    // MARK: Helpers

    private func nextFreePort() -> UInt16 {
        let used = Set(trusted.map(\.srtPort))
        var p: UInt16 = 9101
        while used.contains(p) { p += 1 }
        return p
    }

    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(trusted), forKey: storeKey) }

    private func json(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8) }

    /// Same 6 digits on both screens: SHA-256(studioID | deviceID | nonce) → 000 000–999 999.
    nonisolated static func confirmCode(studioID: String, deviceID: String, nonce: String) -> String {
        let h = SHA256.hash(data: Data("\(studioID)|\(deviceID)|\(nonce)".utf8))
        let v = h.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let s = String(format: "%06u", v)
        return s.prefix(3) + " " + s.suffix(3)
    }

    nonisolated static func randomToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Constant-time compare for tokens.
    nonisolated static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

enum NetworkInfo {
    /// IPv4 of the Wi-Fi (en0) or first non-loopback interface.
    static func wifiIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host), name = String(cString: a.ifa_name)
            if ip.hasPrefix("127.") { continue }
            if name == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }
}

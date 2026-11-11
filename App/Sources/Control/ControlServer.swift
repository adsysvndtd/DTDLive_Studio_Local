import Foundation
import Network

/// Commands accepted from the LAN (web remote, Bitfocus Companion / Stream Deck, OSC, DTD Cam tally).
enum ControlCommand {
    case cut, auto, take(Int), preview(Int), ftb(Bool)
    case titleShow(UUID?, Bool), titleUpdate(TitleItem), scoreA(Int), scoreB(Int)
    case streamStart, streamStop, recordToggle
    case replay, replayStop
    case ptz(source: Int, pan: Double, tilt: Double, zoom: Double), ptzPreset(source: Int, preset: Int, store: Bool)
}

protocol ControlTarget: AnyObject, Sendable {
    func handle(_ cmd: ControlCommand) async
    func stateJSON() async -> Data
    func tallyJSON(for name: String) async -> Data
}

/// Tiny HTTP/1.1 server (port 8080) + OSC/UDP listener (port 8000).
///
/// HTTP:
///   GET  /                       web remote (titles, switching, score)
///   GET  /api/state              JSON state
///   POST /api/cut | /api/auto | /api/ftb?on=1
///   POST /api/take?input=N | /api/preview?input=N         (1-based, multiview order)
///   POST /api/title  (JSON TitleItem)  | POST /api/title/show?id=UUID&on=1
///   POST /api/score?a=N&b=N | /api/stream/start | /api/stream/stop | /api/record | /api/replay
///   POST /api/ptz?input=N&pan=-1..1&tilt=-1..1&zoom=-1..1 | /api/ptz/preset?input=N&preset=K[&store=1]
///   GET  /api/tally?name=<source name>   -> {"program":bool,"preview":bool}  (DTD Cam polls this)
/// OSC (same verbs): /dtd/cut, /dtd/auto, /dtd/take i, /dtd/preview i, /dtd/ftb i, /dtd/score ii, /dtd/replay
final class ControlServer: @unchecked Sendable {
    private var http: NWListener?
    private var osc: NWListener?
    weak var target: (any ControlTarget)?
    private let queue = DispatchQueue(label: "control.server")
    let httpPort: UInt16
    let oscPort: UInt16

    init(httpPort: UInt16 = 8080, oscPort: UInt16 = 8000) { self.httpPort = httpPort; self.oscPort = oscPort }

    func start() throws {
        let h = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: httpPort)!)
        h.service = NWListener.Service(name: "DTD Studio", type: "_http._tcp")
        h.newConnectionHandler = { [weak self] c in self?.serveHTTP(c) }
        h.start(queue: queue)
        http = h

        let o = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: oscPort)!)
        o.newConnectionHandler = { [weak self] c in self?.serveOSC(c) }
        o.start(queue: queue)
        osc = o
    }

    func stop() { http?.cancel(); osc?.cancel() }

    // MARK: HTTP

    private func serveHTTP(_ c: NWConnection) {
        c.start(queue: queue)
        var buffer = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
                guard let self else { return }
                if let data { buffer.append(data) }
                if let req = HTTPRequest.parse(buffer) {
                    Task {
                        let resp = await self.route(req)
                        c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
                    }
                } else if done || err != nil || buffer.count > 1 << 20 {
                    c.cancel()
                } else { read() }
            }
        }
        read()
    }

    private func route(_ r: HTTPRequest) async -> Data {
        guard let target else { return HTTPRequest.response(503, "text/plain", Data("not ready".utf8)) }
        let q = r.query
        func int(_ k: String) -> Int? { q[k].flatMap(Int.init) }
        func dbl(_ k: String) -> Double { q[k].flatMap(Double.init) ?? 0 }
        let ok = HTTPRequest.response(200, "application/json", Data("{\"ok\":true}".utf8))
        switch (r.method, r.path) {
        case ("GET", "/"): return HTTPRequest.response(200, "text/html; charset=utf-8", Data(RemotePage.html.utf8))
        case ("GET", "/api/state"): return HTTPRequest.response(200, "application/json", await target.stateJSON())
        case ("GET", "/api/tally"): return HTTPRequest.response(200, "application/json", await target.tallyJSON(for: q["name"] ?? ""))
        case ("POST", "/api/cut"): await target.handle(.cut)
        case ("POST", "/api/auto"): await target.handle(.auto)
        case ("POST", "/api/ftb"): await target.handle(.ftb(q["on"] == "1"))
        case ("POST", "/api/take"): if let i = int("input") { await target.handle(.take(i)) }
        case ("POST", "/api/preview"): if let i = int("input") { await target.handle(.preview(i)) }
        case ("POST", "/api/title"):
            guard let t = try? JSONDecoder().decode(TitleItem.self, from: r.body) else {
                return HTTPRequest.response(400, "text/plain", Data("bad title json".utf8))
            }
            await target.handle(.titleUpdate(t))
        case ("POST", "/api/title/show"): await target.handle(.titleShow(q["id"].flatMap(UUID.init), q["on"] != "0"))
        case ("POST", "/api/score"):
            if let a = int("a") { await target.handle(.scoreA(a)) }
            if let b = int("b") { await target.handle(.scoreB(b)) }
        case ("POST", "/api/stream/start"): await target.handle(.streamStart)
        case ("POST", "/api/stream/stop"): await target.handle(.streamStop)
        case ("POST", "/api/record"): await target.handle(.recordToggle)
        case ("POST", "/api/replay"): await target.handle(q["stop"] == "1" ? .replayStop : .replay)
        case ("POST", "/api/ptz"):
            if let i = int("input") { await target.handle(.ptz(source: i, pan: dbl("pan"), tilt: dbl("tilt"), zoom: dbl("zoom"))) }
        case ("POST", "/api/ptz/preset"):
            if let i = int("input"), let p = int("preset") { await target.handle(.ptzPreset(source: i, preset: p, store: q["store"] == "1")) }
        default:
            return HTTPRequest.response(404, "text/plain", Data("not found".utf8))
        }
        return ok
    }

    // MARK: OSC

    private func serveOSC(_ c: NWConnection) {
        c.start(queue: queue)
        func read() {
            c.receiveMessage { [weak self] data, _, _, err in
                if let data, let msg = OSCMessage.parse(data) { Task { await self?.dispatch(msg) } }
                if err == nil { read() }
            }
        }
        read()
    }

    private func dispatch(_ m: OSCMessage) async {
        guard let target else { return }
        let i = m.ints
        switch m.address {
        case "/dtd/cut": await target.handle(.cut)
        case "/dtd/auto": await target.handle(.auto)
        case "/dtd/take": if let n = i.first { await target.handle(.take(n)) }
        case "/dtd/preview": if let n = i.first { await target.handle(.preview(n)) }
        case "/dtd/ftb": await target.handle(.ftb((i.first ?? 1) != 0))
        case "/dtd/score": if i.count >= 2 { await target.handle(.scoreA(i[0])); await target.handle(.scoreB(i[1])) }
        case "/dtd/replay": await target.handle(.replay)
        case "/dtd/stream/start": await target.handle(.streamStart)
        case "/dtd/stream/stop": await target.handle(.streamStop)
        default: break
        }
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var body: Data

    static func parse(_ d: Data) -> HTTPRequest? {
        guard let headEnd = d.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: d[..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var length = 0
        for l in lines.dropFirst() where l.lowercased().hasPrefix("content-length:") {
            length = Int(l.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let bodyStart = headEnd.upperBound
        guard d.distance(from: bodyStart, to: d.endIndex) >= length else { return nil }
        let comps = URLComponents(string: String(first[1]))
        var q: [String: String] = [:]
        comps?.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        return HTTPRequest(method: String(first[0]), path: comps?.path ?? "/", query: q,
                           body: Data(d[bodyStart..<d.index(bodyStart, offsetBy: length)]))
    }

    static func response(_ code: Int, _ type: String, _ body: Data) -> Data {
        var h = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        h += "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        return Data(h.utf8) + body
    }
}

/// Minimal OSC 1.0 message parser (int32 / float32 / string args).
struct OSCMessage {
    var address: String
    var args: [Any]
    var ints: [Int] { args.compactMap { ($0 as? Int32).map(Int.init) ?? ($0 as? Float).map { Int($0) } } }

    static func parse(_ d: Data) -> OSCMessage? {
        let b = [UInt8](d)
        var i = 0
        func str() -> String? {
            guard let end = b[i...].firstIndex(of: 0) else { return nil }
            let s = String(decoding: b[i..<end], as: UTF8.self)
            i = (end + 4) & ~3
            return s
        }
        func u32() -> UInt32? {
            guard i + 4 <= b.count else { return nil }
            defer { i += 4 }
            return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
        }
        guard let addr = str(), addr.hasPrefix("/") else { return nil }
        guard i < b.count, let tags = str(), tags.hasPrefix(",") else { return OSCMessage(address: addr, args: []) }
        var args: [Any] = []
        for t in tags.dropFirst() {
            switch t {
            case "i": if let v = u32() { args.append(Int32(bitPattern: v)) }
            case "f": if let v = u32() { args.append(Float(bitPattern: v)) }
            case "s": if let v = str() { args.append(v) }
            case "T": args.append(Int32(1))
            case "F": args.append(Int32(0))
            default: break
            }
        }
        return OSCMessage(address: addr, args: args)
    }
}

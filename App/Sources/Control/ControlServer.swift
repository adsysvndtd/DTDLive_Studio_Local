import Foundation
import Network
import Security

/// Commands accepted from the LAN (web remote, Bitfocus Companion / Stream Deck, OSC, DTDLive camera tally).
enum ControlCommand {
    case cut, auto, take(Int), preview(Int), ftb(Bool)
    case titleShow(UUID?, Bool), titleUpdate(TitleItem), scoreA(Int), scoreB(Int)
    // Sport scoreboard (rules engine): control id from /api/scoreboard, template, undo/redo, names, on air
    case sportAction(String, String?), sportTemplate(String?), sportUndo, sportRedo, sportRestart
    case scoreboardTeams(String?, String?), scoreboardShow(Bool)
    case streamStart, streamStop, recordToggle
    case replay, replayStop
    case ptz(source: Int, pan: Double, tilt: Double, zoom: Double), ptzPreset(source: Int, preset: Int, store: Bool)
}

protocol ControlTarget: AnyObject, Sendable {
    func handle(_ cmd: ControlCommand) async
    func stateJSON() async -> Data
    func tallyJSON(for name: String) async -> Data
    func scoreboardJSON(lang: String?) async -> Data
    func pairRequest(_ body: Data) async -> Data
    func pairStatus(_ requestID: String) async -> Data
}

/// Tiny HTTP/1.1 server (port 8080) + OSC/UDP listener (port 8000).
///
/// HTTP (every page / API needs ?key=<access key> or header X-DTD-Key, except pairing and tally):
///   GET  /                       web remote (titles, switching, score)
///   GET  /api/state              JSON state
///   POST /api/cut | /api/auto | /api/ftb?on=1
///   POST /api/take?input=N | /api/preview?input=N         (1-based, multiview order)
///   POST /api/title  (JSON TitleItem)  | POST /api/title/show?id=UUID&on=1
///   POST /api/score?a=N&b=N | /api/stream/start | /api/stream/stop | /api/record | /api/replay (1st: cue on PVW, 2nd: play to PGM)
///   POST /api/ptz?input=N&pan=-1..1&tilt=-1..1&zoom=-1..1 | /api/ptz/preset?input=N&preset=K[&store=1]
///   POST /api/pair/request  {deviceID,name,model,app,protocols,pullURL,nonce,token} -> {requestId, confirmCode}
///   GET  /api/pair/status?id=<requestId>  -> pending | rejected | expired | {status:"accepted", pushURL, token, ...}
///   GET  /api/tally?name=<source name>   -> {"program":bool,"preview":bool}  (camera app DTDLive polls this)
///   GET  /scoreboard                     web scoreboard operator (rules engine: pickleball, cầu lông, bóng chuyền, bóng đá, bi-a)
///   GET  /api/scoreboard                 JSON: display, controls (ids), templates, teams
///   POST /api/scoreboard/action?id=<control id>[&input=<player>] | /api/scoreboard/template?t=<id|empty>
///   POST /api/scoreboard/undo | /redo | /restart | /api/scoreboard/teams?home=&away= | /api/scoreboard/show?on=1
/// OSC (same verbs): /dtd/cut, /dtd/auto, /dtd/take i, /dtd/preview i, /dtd/ftb i, /dtd/score ii, /dtd/replay,
///   /dtd/sb s (scoreboard control id, e.g. "rally-home"), /dtd/sb/undo
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
        // Camera apps (DTDLive…) browse for this service to pair; TXT carries protocol version.
        h.service = NWListener.Service(name: "DTDStudio", type: "_dtdstudio._tcp",
                                       txtRecord: NWTXTRecord(["v": "1", "api": "/api/pair"]))
        h.newConnectionHandler = { [weak self] c in self?.serveHTTP(c) }
        h.start(queue: queue)
        http = h

        let o = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: oscPort)!)
        o.newConnectionHandler = { [weak self] c in self?.serveOSC(c) }
        o.start(queue: queue)
        osc = o
    }

    func stop() { http?.cancel(); osc?.cancel() }

    // MARK: Access key

    /// Secret appended to the web remote link (…:8080/?key=…). Every page and API call must carry it
    /// (query `key=` or header `X-DTD-Key`), so someone else on the same Wi‑Fi can't drive the show.
    /// Camera pairing and tally (DTDLive) have their own handshake and stay open.
    static var accessKey: String {
        if let k = UserDefaults.standard.string(forKey: keyDefaults), k.count >= 8 { return k }
        return newAccessKey()
    }
    private static let keyDefaults = "dtd.remote.key"

    @discardableResult
    static func newAccessKey() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: 12)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<12).map { _ in UInt8.random(in: 0...255) }
        }
        let k = String(bytes.map { alphabet[Int($0) % alphabet.count] })
        UserDefaults.standard.set(k, forKey: keyDefaults)
        return k
    }

    /// Web pages follow ?lang=en|vi, else the app's language (Settings › Ngôn ngữ).
    static func page(_ html: String, _ lang: String?) -> String {
        html.replacingOccurrences(of: "__LANG__", with: uiLang(lang))
    }
    static func uiLang(_ asked: String?) -> String {
        if asked == "en" || asked == "vi" { return asked! }
        switch AppLanguage.current {
        case "en", "vi": return AppLanguage.current
        default: return (Locale.preferredLanguages.first ?? "vi").hasPrefix("vi") ? "vi" : "en"
        }
    }

    private static let openPaths: Set<String> = ["/api/pair/request", "/api/pair/status", "/api/tally", "/favicon.ico"]

    private static func authorized(_ r: HTTPRequest) -> Bool {
        if openPaths.contains(r.path) { return true }
        let given = r.query["key"] ?? r.headers["x-dtd-key"] ?? ""
        let k = accessKey
        guard given.utf8.count == k.utf8.count else { return false }
        return zip(given.utf8, k.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0   // constant time
    }

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
        guard Self.authorized(r) else {
            if r.method == "GET", !r.path.hasPrefix("/api/") {
                let page = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'>"
                    + "<body style='font:16px -apple-system,sans-serif;background:#111;color:#eee;padding:24px'>"
                    + "<h3>DTDStudio</h3><p>Liên kết thiếu hoặc sai key bảo mật. Mở đúng đường link trong "
                    + "DTDStudio › Cài đặt › Điều khiển từ xa (link có <code>?key=…</code>).</p>"
                    + "<p style='color:#999'>The link is missing its security key or the key is wrong. Open the link from "
                    + "DTDStudio › Settings › Remote control (it ends with <code>?key=…</code>).</p></body>"
                return HTTPRequest.response(401, "text/html; charset=utf-8", Data(page.utf8))
            }
            return HTTPRequest.response(401, "application/json", Data("{\"error\":\"key required\"}".utf8))
        }
        let q = r.query
        func int(_ k: String) -> Int? { q[k].flatMap(Int.init) }
        func dbl(_ k: String) -> Double { q[k].flatMap(Double.init) ?? 0 }
        let ok = HTTPRequest.response(200, "application/json", Data("{\"ok\":true}".utf8))
        switch (r.method, r.path) {
        case ("GET", "/"): return HTTPRequest.response(200, "text/html; charset=utf-8", Data(Self.page(RemotePage.html, q["lang"]).utf8))
        case ("GET", "/api/state"): return HTTPRequest.response(200, "application/json", await target.stateJSON())
        case ("GET", "/api/tally"): return HTTPRequest.response(200, "application/json", await target.tallyJSON(for: q["name"] ?? ""))
        case ("POST", "/api/pair/request"): return HTTPRequest.response(200, "application/json", await target.pairRequest(r.body))
        case ("GET", "/api/pair/status"): return HTTPRequest.response(200, "application/json", await target.pairStatus(q["id"] ?? ""))
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
        case ("GET", "/scoreboard"): return HTTPRequest.response(200, "text/html; charset=utf-8", Data(Self.page(ScoreboardRemotePage.html, q["lang"]).utf8))
        case ("GET", "/api/scoreboard"): return HTTPRequest.response(200, "application/json", await target.scoreboardJSON(lang: q["lang"]))
        case ("POST", "/api/scoreboard/action"):
            if let id = q["id"] { await target.handle(.sportAction(id, q["input"])) }
            return HTTPRequest.response(200, "application/json", await target.scoreboardJSON(lang: q["lang"]))
        case ("POST", "/api/scoreboard/template"):
            let t = q["t"] ?? ""
            await target.handle(.sportTemplate(t.isEmpty ? nil : t))
            return HTTPRequest.response(200, "application/json", await target.scoreboardJSON(lang: q["lang"]))
        case ("POST", "/api/scoreboard/undo"): await target.handle(.sportUndo)
            return HTTPRequest.response(200, "application/json", await target.scoreboardJSON(lang: q["lang"]))
        case ("POST", "/api/scoreboard/redo"): await target.handle(.sportRedo)
            return HTTPRequest.response(200, "application/json", await target.scoreboardJSON(lang: q["lang"]))
        case ("POST", "/api/scoreboard/restart"): await target.handle(.sportRestart)
            return HTTPRequest.response(200, "application/json", await target.scoreboardJSON(lang: q["lang"]))
        case ("POST", "/api/scoreboard/teams"): await target.handle(.scoreboardTeams(q["home"], q["away"]))
            return HTTPRequest.response(200, "application/json", await target.scoreboardJSON(lang: q["lang"]))
        case ("POST", "/api/scoreboard/show"): await target.handle(.scoreboardShow(q["on"] != "0"))
            return HTTPRequest.response(200, "application/json", await target.scoreboardJSON(lang: q["lang"]))
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
        case "/dtd/sb": if let id = m.args.first as? String { await target.handle(.sportAction(id, m.args.dropFirst().first as? String)) }
        case "/dtd/sb/undo": await target.handle(.sportUndo)
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
    /// Header names lower-cased.
    var headers: [String: String] = [:]
    var body: Data

    static func parse(_ d: Data) -> HTTPRequest? {
        guard let headEnd = d.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: d[..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var length = 0
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        length = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headEnd.upperBound
        guard d.distance(from: bodyStart, to: d.endIndex) >= length else { return nil }
        let comps = URLComponents(string: String(first[1]))
        var q: [String: String] = [:]
        comps?.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        return HTTPRequest(method: String(first[0]), path: comps?.path ?? "/", query: q, headers: headers,
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

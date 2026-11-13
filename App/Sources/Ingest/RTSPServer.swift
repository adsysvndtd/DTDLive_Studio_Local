import Foundation
import Network
import RTSPPush

/// RTSP ingest server (push / RECORD): many cameras or encoders send to one port (8554), each on its own path
/// (rtsp://<iPad IP>:8554/live/<key>). ANNOUNCE (SDP) → SETUP (RTP over TCP, interleaved) → RECORD.
/// H.264 / H.265 video, AAC audio. UDP transport is refused with 461 so clients fall back to TCP.
final class RTSPServer: @unchecked Sendable {
    private let port: UInt16
    private let events: RTMPServer.Events
    private let queue = DispatchQueue(label: "ingest.rtsp", qos: .userInitiated)
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: RTSPIngestSession] = [:]

    init(port: UInt16, events: RTMPServer.Events) { self.port = port; self.events = events }

    func start() {
        queue.async { [self] in
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
                l.stateUpdateHandler = { [weak self] st in
                    guard let self else { return }
                    switch st {
                    case .ready: self.events.onListening(self.port, nil)
                    case .failed(let e): self.events.onListening(self.port, "\(e)")
                    default: break
                    }
                }
                l.newConnectionHandler = { [weak self] c in
                    guard let self else { return }
                    let s = RTSPIngestSession(connection: c, queue: self.queue, events: self.events)
                    let id = ObjectIdentifier(s)
                    self.sessions[id] = s
                    s.onClose = { [weak self] in self?.sessions[id] = nil }
                    s.start()
                }
                l.start(queue: queue)
                listener = l
            } catch {
                events.onListening(port, "\(error)")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel(); listener = nil
            for s in sessions.values { s.close() }
            sessions.removeAll()
        }
    }
}

final class RTSPIngestSession: @unchecked Sendable {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let events: RTMPServer.Events
    var onClose: (() -> Void)?

    private var buf = [UInt8]()
    private var closed = false
    private var key: String?
    private var recording = false
    private let sessionID = String(UInt32.random(in: 0x1000_0000...0xFFFF_FFFF), radix: 16)

    private var media: [SDPMedia] = []
    private var channelMedia: [UInt8: Int] = [:]     // interleaved RTP channel -> media index
    private var h264 = H264Depacketizer()
    private var h265 = H265Depacketizer()

    private var peer: String {
        if case .hostPort(let h, let p) = conn.endpoint { return "\(h):\(p)" }
        return "\(conn.endpoint)"
    }

    init(connection: NWConnection, queue: DispatchQueue, events: RTMPServer.Events) {
        conn = connection; self.queue = queue; self.events = events
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            switch st { case .failed, .cancelled: self?.finish(); default: break }
        }
        conn.start(queue: queue)
        receive()
    }

    func close() { conn.cancel(); finish() }

    private func finish() {
        guard !closed else { return }
        closed = true
        if recording, let k = key { events.onStream(k, false, "") }
        onClose?()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty { self.buf.append(contentsOf: data); self.process() }
            if done || err != nil || self.closed { self.close(); return }
            self.receive()
        }
    }

    private func process() {
        while !closed, !buf.isEmpty {
            if buf[0] == 0x24 {                                          // '$' interleaved frame
                guard buf.count >= 4 else { return }
                let ch = buf[1], n = Int(buf[2]) << 8 | Int(buf[3])
                guard buf.count >= 4 + n else { return }
                let pkt = Array(buf[4..<(4 + n)])
                buf.removeFirst(4 + n)
                rtp(channel: ch, pkt)
                continue
            }
            // text request: headers end at CRLFCRLF, then Content-Length body
            guard let end = headerEnd() else {
                if buf.count > 64 * 1024 { close() }
                return
            }
            let head = String(decoding: buf[0..<end], as: UTF8.self)
            var headers: [String: String] = [:]
            let lines = head.components(separatedBy: "\r\n")
            for l in lines.dropFirst() {
                guard let c = l.firstIndex(of: ":") else { continue }
                headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
            let bodyLen = Int(headers["content-length"] ?? "0") ?? 0
            guard buf.count >= end + 4 + bodyLen else { return }
            let body = String(decoding: buf[(end + 4)..<(end + 4 + bodyLen)], as: UTF8.self)
            buf.removeFirst(end + 4 + bodyLen)
            let parts = (lines.first ?? "").split(separator: " ")
            guard parts.count >= 2 else { close(); return }
            request(method: String(parts[0]).uppercased(), url: String(parts[1]), headers: headers, body: body)
        }
    }

    private func headerEnd() -> Int? {
        guard buf.count >= 4 else { return nil }
        for i in 0...(buf.count - 4) where buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10 { return i }
        return nil
    }

    // MARK: Requests

    private func request(method: String, url: String, headers: [String: String], body: String) {
        let cseq = headers["cseq"] ?? "0"
        switch method {
        case "OPTIONS":
            reply(cseq, extra: ["Public": "OPTIONS, ANNOUNCE, SETUP, RECORD, TEARDOWN, GET_PARAMETER"])
        case "ANNOUNCE":
            key = Self.keyFromURL(url)
            media = SDPParser.parse(body).filter { $0.codec == .h264 || $0.codec == .h265 || $0.codec == .aac }
            guard media.contains(where: { $0.type == "video" }) else { reply(cseq, status: "415 Unsupported Media Type"); return }
            reply(cseq)
        case "SETUP":
            let transport = headers["transport"] ?? ""
            guard transport.lowercased().contains("tcp"), let range = transport.range(of: "interleaved=") else {
                reply(cseq, status: "461 Unsupported Transport"); return
            }
            let chans = transport[range.upperBound...].prefix { $0.isNumber || $0 == "-" }.split(separator: "-")
            let rtpCh = UInt8(chans.first ?? "0") ?? 0
            channelMedia[rtpCh] = mediaIndex(for: url)
            reply(cseq, extra: ["Transport": "RTP/AVP/TCP;unicast;interleaved=\(rtpCh)-\(rtpCh &+ 1);mode=record",
                                "Session": "\(sessionID);timeout=60"])
        case "RECORD":
            guard let k = key else { reply(cseq, status: "455 Method Not Valid in This State"); return }
            reply(cseq, extra: ["Session": sessionID])
            recording = true
            events.onStream(k, true, peer)
            configureSink()
        case "GET_PARAMETER", "SET_PARAMETER":
            reply(cseq, extra: ["Session": sessionID])
        case "TEARDOWN":
            reply(cseq)
            close()
        default:
            reply(cseq, status: "405 Method Not Allowed")
        }
    }

    /// Matches SETUP URLs to SDP media by their a=control suffix; falls back to the next unassigned media.
    private func mediaIndex(for url: String) -> Int {
        for (i, m) in media.enumerated() {
            if let c = m.control, c != "*", url.hasSuffix(c) { return i }
        }
        let used = Set(channelMedia.values)
        return media.indices.first { !used.contains($0) } ?? 0
    }

    /// rtsp://host:8554/live/cam1 -> "cam1"
    static func keyFromURL(_ url: String) -> String {
        var path = url
        if let r = path.range(of: "://") { path = String(path[r.upperBound...]) }
        if let s = path.firstIndex(of: "/") { path = String(path[s...]) } else { path = "" }
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        let comps = path.split(separator: "/").map(String.init).filter { !$0.lowercased().hasPrefix("streamid=") && !$0.lowercased().hasPrefix("trackid=") }
        let k = comps.last ?? ""
        return k.isEmpty ? "rtsp" : String(k.prefix(64))
    }

    private func reply(_ cseq: String, status: String = "200 OK", extra: [String: String] = [:]) {
        var s = "RTSP/1.0 \(status)\r\nCSeq: \(cseq)\r\nServer: DTD Studio\r\n"
        for (k, v) in extra { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        conn.send(content: s.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    // MARK: Media

    private func configureSink() {
        guard let k = key, let sink = events.sink(k) else { return }
        sink.pipeline.reset()
        h264 = H264Depacketizer(); h265 = H265Depacketizer()
        sink.pipeline.configure(video: media.first { $0.type == "video" }, audio: media.first { $0.codec == .aac })
    }

    private func rtp(channel: UInt8, _ bytes: [UInt8]) {
        guard recording, let k = key, let idx = channelMedia[channel], idx < media.count,
              let p = RTPPacket.parse(bytes), let sink = events.sink(k) else { return }
        let m = media[idx]
        switch m.codec {
        case .h264:
            for au in h264.push(p) { if let pb = sink.pipeline.video(au) { sink.pacer.push(pb, media: Double(au.timestamp) / 90_000) } }
        case .h265:
            for au in h265.push(p) { if let pb = sink.pipeline.video(au) { sink.pacer.push(pb, media: Double(au.timestamp) / 90_000) } }
        case .aac:
            for frame in AACDepacketizer.accessUnits(p, sizeLength: m.aacSizeLength, indexLength: m.aacIndexLength) {
                if let pcm = sink.pipeline.audio(frame) { sink.onAudio?(pcm) }
            }
        default:
            break
        }
    }
}

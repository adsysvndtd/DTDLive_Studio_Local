import Foundation
import Network
import RTSPPush

/// RTMP ingest server: many encoders/cameras publish to one port (1935), each identified by its stream key
/// (rtmp://<iPad IP>:1935/live/<key>). H.264 (and enhanced-RTMP HEVC) video, AAC audio.
/// Simple handshake, AMF0 commands: connect, releaseStream, FCPublish, createStream, publish, deleteStream.
final class RTMPServer: @unchecked Sendable {
    struct Events: Sendable {
        var onListening: @Sendable (UInt16, String?) -> Void
        var onStream: @Sendable (_ key: String, _ connected: Bool, _ peer: String) -> Void
        var sink: @Sendable (_ key: String) -> IngestRouter.Sink?
    }

    private let port: UInt16
    private let events: Events
    private let queue = DispatchQueue(label: "ingest.rtmp", qos: .userInitiated)
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: RTMPSession] = [:]

    init(port: UInt16, events: Events) { self.port = port; self.events = events }

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
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
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

    private func accept(_ c: NWConnection) {
        let s = RTMPSession(connection: c, queue: queue, events: events)
        let key = ObjectIdentifier(s)
        sessions[key] = s
        s.onClose = { [weak self] in self?.sessions[key] = nil }
        s.start()
    }
}

/// One publisher connection.
final class RTMPSession: @unchecked Sendable {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let events: RTMPServer.Events
    var onClose: (() -> Void)?

    private enum Phase { case c0c1, c2, chunks }
    private var phase = Phase.c0c1
    private var buf = [UInt8]()
    private var inChunkSize = 128
    private var windowAck: UInt32 = 2_500_000
    private var received: UInt64 = 0
    private var lastAck: UInt64 = 0
    private var closed = false

    private struct ChunkState {
        var timestamp: UInt32 = 0
        var delta: UInt32 = 0
        var length = 0
        var type: UInt8 = 0
        var streamID: UInt32 = 0
        var extended = false
        var payload = [UInt8]()
    }
    private var chunkStreams: [Int: ChunkState] = [:]

    // publishing
    private var streamKey: String?
    private var app = "live"
    private var nalLength = 4
    private var parameterSets: [[UInt8]] = []
    private var isHEVC = false
    private var asc: [UInt8] = []
    private var sampleRate = 48000
    private var channels = 2

    private var peer: String {
        if case .hostPort(let h, let p) = conn.endpoint { return "\(h):\(p)" }
        return "\(conn.endpoint)"
    }

    init(connection: NWConnection, queue: DispatchQueue, events: RTMPServer.Events) {
        conn = connection; self.queue = queue; self.events = events
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    func close() { conn.cancel(); finish() }

    private func finish() {
        guard !closed else { return }
        closed = true
        if let k = streamKey { events.onStream(k, false, "") }
        onClose?()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buf.append(contentsOf: data)
                self.received += UInt64(data.count)
                self.process()
                if self.received - self.lastAck >= UInt64(self.windowAck) {
                    self.lastAck = self.received
                    self.sendControl(type: 3, payload: Self.be32(UInt32(truncatingIfNeeded: self.received)))
                }
            }
            if done || err != nil || self.closed { self.close(); return }
            self.receive()
        }
    }

    // MARK: Parsing

    private func process() {
        while !closed {
            switch phase {
            case .c0c1:
                guard buf.count >= 1537 else { return }
                let c1 = Array(buf[1..<1537])
                buf.removeFirst(1537)
                var s1 = [UInt8](repeating: 0, count: 1536)
                for i in 8..<1536 { s1[i] = UInt8.random(in: 0...255) }
                send([3] + s1 + c1)               // S0 + S1 + S2 (echo of C1)
                phase = .c2
            case .c2:
                guard buf.count >= 1536 else { return }
                buf.removeFirst(1536)
                phase = .chunks
            case .chunks:
                guard parseChunk() else { return }
            }
        }
    }

    /// Parses one chunk from `buf`; returns false when more bytes are needed.
    private func parseChunk() -> Bool {
        var i = 0
        guard buf.count >= 1 else { return false }
        let fmt = Int(buf[0] >> 6)
        var csid = Int(buf[0] & 0x3F)
        i = 1
        if csid == 0 { guard buf.count >= 2 else { return false }; csid = 64 + Int(buf[1]); i = 2 }
        else if csid == 1 { guard buf.count >= 3 else { return false }; csid = 64 + Int(buf[1]) + Int(buf[2]) * 256; i = 3 }
        var st = chunkStreams[csid] ?? ChunkState()
        let headerLen = [11, 7, 3, 0][fmt]
        guard buf.count >= i + headerLen else { return false }
        var ts: UInt32 = 0
        if fmt <= 2 { ts = UInt32(buf[i]) << 16 | UInt32(buf[i + 1]) << 8 | UInt32(buf[i + 2]) }
        if fmt <= 1 {
            st.length = Int(buf[i + 3]) << 16 | Int(buf[i + 4]) << 8 | Int(buf[i + 5])
            st.type = buf[i + 6]
        }
        if fmt == 0 {
            st.streamID = UInt32(buf[i + 7]) | UInt32(buf[i + 8]) << 8 | UInt32(buf[i + 9]) << 16 | UInt32(buf[i + 10]) << 24
        }
        i += headerLen
        let needsExt = fmt <= 2 ? ts == 0xFFFFFF : st.extended
        if needsExt {
            guard buf.count >= i + 4 else { return false }
            let ext = UInt32(buf[i]) << 24 | UInt32(buf[i + 1]) << 16 | UInt32(buf[i + 2]) << 8 | UInt32(buf[i + 3])
            if fmt <= 2 { ts = ext }
            i += 4
        }
        let remaining = st.length - st.payload.count
        let take = min(remaining, inChunkSize)
        guard take >= 0, buf.count >= i + take else { return false }
        // header applies only at the start of a message
        if st.payload.isEmpty {
            switch fmt {
            case 0: st.timestamp = ts; st.delta = 0
            case 1, 2: st.delta = ts; st.timestamp &+= ts
            default: if st.length > 0 { st.timestamp &+= st.delta }
            }
            if fmt <= 2 { st.extended = ts >= 0xFFFFFF }
        }
        st.payload.append(contentsOf: buf[i..<(i + take)])
        buf.removeFirst(i + take)
        if st.payload.count >= st.length {
            let msg = st.payload
            st.payload = []
            chunkStreams[csid] = st
            handle(type: st.type, streamID: st.streamID, timestamp: st.timestamp, payload: msg)
        } else {
            chunkStreams[csid] = st
        }
        return true
    }

    // MARK: Messages

    private func handle(type: UInt8, streamID: UInt32, timestamp: UInt32, payload: [UInt8]) {
        switch type {
        case 1:  // Set Chunk Size
            if payload.count >= 4 { inChunkSize = max(1, Int(Self.u32(payload, 0) & 0x7FFF_FFFF)) }
        case 5:  // Window Acknowledgement Size
            if payload.count >= 4 { windowAck = max(1, Self.u32(payload, 0)) }
        case 20: // AMF0 command
            command(AMF0.decodeAll(payload), streamID: streamID)
        case 8:
            audio(payload)
        case 9:
            video(payload, timestamp: timestamp)
        default:
            break
        }
    }

    private func command(_ v: [AMF0.Value], streamID: UInt32) {
        guard case .string(let name)? = v.first else { return }
        let tid: Double = { if v.count > 1, case .number(let n) = v[1] { return n }; return 0 }()
        switch name {
        case "connect":
            if v.count > 2, case .object(let o) = v[2], case .string(let a)? = o["app"] { app = a }
            sendControl(type: 5, payload: Self.be32(2_500_000))               // Window Ack Size
            sendControl(type: 6, payload: Self.be32(2_500_000) + [2])         // Set Peer Bandwidth (dynamic)
            sendControl(type: 1, payload: Self.be32(4096))                    // Set Chunk Size
            outChunkSize = 4096
            sendCommand(csid: 3, streamID: 0, [
                .string("_result"), .number(tid),
                .object(["fmsVer": .string("FMS/3,0,1,123"), "capabilities": .number(31)]),
                .object(["level": .string("status"), "code": .string("NetConnection.Connect.Success"),
                         "description": .string("Connection succeeded."), "objectEncoding": .number(0)])
            ])
        case "releaseStream", "FCPublish":
            if name == "FCPublish", v.count > 3, case .string(let k) = v[3] {
                sendCommand(csid: 3, streamID: 0, [.string("onFCPublish"), .number(0), .null,
                                                   .object(["code": .string("NetStream.Publish.Start"), "description": .string(k)])])
            }
            sendCommand(csid: 3, streamID: 0, [.string("_result"), .number(tid), .null, .undefined])
        case "createStream":
            sendCommand(csid: 3, streamID: 0, [.string("_result"), .number(tid), .null, .number(1)])
        case "publish":
            guard v.count > 3, case .string(let raw) = v[3] else { return }
            let key = Self.cleanKey(raw)
            streamKey = key
            sendCommand(csid: 5, streamID: max(1, streamID), [
                .string("onStatus"), .number(0), .null,
                .object(["level": .string("status"), "code": .string("NetStream.Publish.Start"),
                         "description": .string("\(key) is now published.")])
            ])
            events.onStream(key, true, peer)
        case "FCUnpublish", "deleteStream", "closeStream":
            if let k = streamKey { events.onStream(k, false, ""); streamKey = nil }
        default:
            break
        }
    }

    /// "cam1?token=x" -> "cam1"; "live/cam1" -> "cam1"
    static func cleanKey(_ raw: String) -> String {
        var k = raw
        if let q = k.firstIndex(of: "?") { k = String(k[..<q]) }
        if let s = k.lastIndex(of: "/") { k = String(k[k.index(after: s)...]) }
        k = String(k.filter { $0.isASCII && !$0.isWhitespace }.prefix(64))
        return k.isEmpty ? "rtmp" : k
    }

    // MARK: Media

    private func audio(_ p: [UInt8]) {
        guard let key = streamKey, p.count >= 2, p[0] >> 4 == 10 else { return }   // AAC only
        if p[1] == 0 {
            asc = Array(p[2...])
            if asc.count >= 2 {
                let freqIdx = Int((asc[0] & 0x07) << 1 | asc[1] >> 7)
                let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
                if freqIdx < rates.count { sampleRate = rates[freqIdx] }
                channels = max(1, Int((asc[1] >> 3) & 0x0F))
            }
            return
        }
        guard !asc.isEmpty, p.count > 2 else { return }
        events.sink(key)?.aac(Array(p[2...]), asc: asc, sampleRate: sampleRate, channels: channels)
    }

    private func video(_ p: [UInt8], timestamp: UInt32) {
        guard let key = streamKey, p.count >= 5 else { return }
        let exHeader = p[0] & 0x80 != 0
        var isKey = (p[0] >> 4) & 0x07 == 1
        var body: ArraySlice<UInt8>
        var isConfig = false
        if exHeader {
            // enhanced RTMP: [frameType|packetType][fourCC][payload]
            let packetType = p[0] & 0x0F
            let fourCC = String(bytes: p[1..<5], encoding: .ascii) ?? ""
            guard fourCC == "hvc1" || fourCC == "avc1" else { return }
            setHEVC(fourCC == "hvc1")
            isKey = (p[0] >> 4) & 0x07 == 1
            switch packetType {
            case 0: isConfig = true; body = p[5...]
            case 1: guard p.count > 8 else { return }; body = p[8...]   // CodedFrames: 3-byte composition time
            case 3: body = p[5...]                                     // CodedFramesX
            default: return
            }
        } else {
            guard p[0] & 0x0F == 7 else { return }   // AVC
            setHEVC(false)
            isConfig = p[1] == 0
            if p[1] == 2 { return }
            body = p[5...]
        }
        if isConfig { parseConfig(Array(body)); return }
        var nals: [[UInt8]] = []
        var i = body.startIndex
        while i + nalLength <= body.endIndex {
            var n = 0
            for k in 0..<nalLength { n = n << 8 | Int(body[i + k]) }
            i += nalLength
            guard n > 0, i + n <= body.endIndex else { break }
            nals.append(Array(body[i..<(i + n)]))
            i += n
        }
        guard !nals.isEmpty else { return }
        if isKey { nals = parameterSets + nals }
        guard let sink = events.sink(key) else { return }
        if let pb = sink.pipeline.video(AccessUnit(nalUnits: nals, timestamp: timestamp, isKeyframe: isKey)) {
            sink.pacer.push(pb, media: Double(timestamp) / 1000)   // RTMP timestamps are ms
        }
    }

    private func setHEVC(_ on: Bool) {
        guard on != isHEVC else { return }
        isHEVC = on
        if let key = streamKey { events.sink(key)?.pipeline.setHEVC(on) }
    }

    /// AVCDecoderConfigurationRecord / HEVCDecoderConfigurationRecord -> parameter sets.
    private func parseConfig(_ c: [UInt8]) {
        var sets: [[UInt8]] = []
        if isHEVC {
            guard c.count >= 23 else { return }
            nalLength = Int(c[21] & 0x03) + 1
            var i = 23
            for _ in 0..<Int(c[22]) {
                guard i + 3 <= c.count else { break }
                let count = Int(c[i + 1]) << 8 | Int(c[i + 2]); i += 3
                for _ in 0..<count {
                    guard i + 2 <= c.count else { break }
                    let n = Int(c[i]) << 8 | Int(c[i + 1]); i += 2
                    guard i + n <= c.count else { break }
                    sets.append(Array(c[i..<(i + n)])); i += n
                }
            }
        } else {
            guard c.count >= 7 else { return }
            nalLength = Int(c[4] & 0x03) + 1
            var i = 6
            for _ in 0..<Int(c[5] & 0x1F) {
                guard i + 2 <= c.count else { return }
                let n = Int(c[i]) << 8 | Int(c[i + 1]); i += 2
                guard i + n <= c.count else { return }
                sets.append(Array(c[i..<(i + n)])); i += n
            }
            guard i < c.count else { return }
            let pps = Int(c[i]); i += 1
            for _ in 0..<pps {
                guard i + 2 <= c.count else { break }
                let n = Int(c[i]) << 8 | Int(c[i + 1]); i += 2
                guard i + n <= c.count else { break }
                sets.append(Array(c[i..<(i + n)])); i += n
            }
        }
        if !sets.isEmpty { parameterSets = sets }
    }

    // MARK: Writing

    private var outChunkSize = 128

    private func send(_ bytes: [UInt8]) {
        conn.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    private func sendControl(type: UInt8, payload: [UInt8]) {
        sendMessage(csid: 2, type: type, streamID: 0, payload: payload)
    }

    private func sendCommand(csid: UInt8, streamID: UInt32, _ values: [AMF0.Value]) {
        sendMessage(csid: csid, type: 20, streamID: streamID, payload: values.flatMap(AMF0.encode))
    }

    private func sendMessage(csid: UInt8, type: UInt8, streamID: UInt32, payload: [UInt8]) {
        var out: [UInt8] = [csid & 0x3F, 0, 0, 0]                    // fmt 0, timestamp 0
        let n = payload.count
        out += [UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF), type]
        out += [UInt8(streamID & 0xFF), UInt8(streamID >> 8 & 0xFF), UInt8(streamID >> 16 & 0xFF), UInt8(streamID >> 24 & 0xFF)]
        var i = 0
        let size = type == 1 ? 128 : outChunkSize   // Set Chunk Size itself goes out in the old size
        while i < n {
            if i > 0 { out.append(0xC0 | (csid & 0x3F)) }             // fmt 3 continuation
            let end = min(n, i + size)
            out += payload[i..<end]
            i = end
        }
        send(out)
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}

/// Minimal AMF0 (numbers, booleans, strings, objects, ECMA arrays, null/undefined).
enum AMF0 {
    indirect enum Value: Equatable {
        case number(Double), bool(Bool), string(String), object([String: Value]), null, undefined, array([Value])
    }

    static func decodeAll(_ b: [UInt8]) -> [Value] {
        var i = 0, out: [Value] = []
        while i < b.count, let v = decode(b, &i) { out.append(v) }
        return out
    }

    static func decode(_ b: [UInt8], _ i: inout Int) -> Value? {
        guard i < b.count else { return nil }
        let t = b[i]; i += 1
        switch t {
        case 0:
            guard i + 8 <= b.count else { return nil }
            var bits: UInt64 = 0
            for k in 0..<8 { bits = bits << 8 | UInt64(b[i + k]) }
            i += 8
            return .number(Double(bitPattern: bits))
        case 1:
            guard i < b.count else { return nil }
            defer { i += 1 }
            return .bool(b[i] != 0)
        case 2:
            return str(b, &i).map(Value.string)
        case 3, 8:
            if t == 8 { i += 4 }
            var o: [String: Value] = [:]
            while i + 3 <= b.count {
                if b[i] == 0, b[i + 1] == 0, b[i + 2] == 9 { i += 3; break }
                guard let k = str(b, &i), let v = decode(b, &i) else { return nil }
                o[k] = v
            }
            return .object(o)
        case 5: return .null
        case 6: return .undefined
        case 10:
            guard i + 4 <= b.count else { return nil }
            let n = Int(RTMPSession.u32(b, i)); i += 4
            var a: [Value] = []
            for _ in 0..<n { guard let v = decode(b, &i) else { return nil }; a.append(v) }
            return .array(a)
        default:
            return nil
        }
    }

    private static func str(_ b: [UInt8], _ i: inout Int) -> String? {
        guard i + 2 <= b.count else { return nil }
        let n = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
        guard i + n <= b.count else { return nil }
        defer { i += n }
        return String(decoding: b[i..<(i + n)], as: UTF8.self)
    }

    static func encode(_ v: Value) -> [UInt8] {
        switch v {
        case .number(let d):
            let bits = d.bitPattern
            return [0] + (0..<8).map { UInt8(bits >> (56 - 8 * UInt64($0)) & 0xFF) }
        case .bool(let x): return [1, x ? 1 : 0]
        case .string(let s): return [2] + key(s)
        case .object(let o):
            var out: [UInt8] = [3]
            for (k, val) in o.sorted(by: { $0.key < $1.key }) { out += key(k) + encode(val) }
            return out + [0, 0, 9]
        case .null: return [5]
        case .undefined: return [6]
        case .array(let a):
            let n = UInt32(a.count)
            return [10] + RTMPSession.be32(n) + a.flatMap(encode)
        }
    }

    private static func key(_ s: String) -> [UInt8] {
        let u = Array(s.utf8)
        return [UInt8(u.count >> 8 & 0xFF), UInt8(u.count & 0xFF)] + u
    }
}

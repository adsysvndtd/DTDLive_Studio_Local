import Foundation

/// Splits an RTSP-over-TCP byte stream into responses and interleaved binary frames.
public enum RTSPStreamItem: Equatable {
    case response(statusCode: Int)
    case interleaved(channel: UInt8, data: [UInt8])
}

public struct RTSPStreamDemuxer {
    private var buffer = Data()
    public private(set) var responses: [RTSPResponse] = []

    public init() {}

    /// Appends bytes and returns complete interleaved frames; complete responses go to `takeResponses()`.
    public mutating func append(_ d: Data) -> [(UInt8, [UInt8])] {
        buffer.append(d)
        var frames: [(UInt8, [UInt8])] = []
        while let first = buffer.first {
            if first == 0x24 {
                guard buffer.count >= 4 else { break }
                let s = buffer.startIndex
                let len = Int(buffer[s + 2]) << 8 | Int(buffer[s + 3])
                guard buffer.count >= 4 + len else { break }
                frames.append((buffer[s + 1], Array(buffer[(s + 4)..<(s + 4 + len)])))
                buffer.removeFirst(4 + len)
            } else if first == UInt8(ascii: "R") {
                guard let r = RTSPResponse.parse(&buffer) else { break }
                responses.append(r)
            } else {
                // Resync on garbage: drop until next '$' or 'R'.
                buffer.removeFirst()
            }
        }
        return frames
    }

    public mutating func takeResponses() -> [RTSPResponse] {
        defer { responses.removeAll() }
        return responses
    }
}

#if canImport(Network)
import Network

/// RTSP player (DESCRIBE / SETUP / PLAY) with RTP interleaved over TCP.
/// Works with IP cameras (Hikvision, Dahua, Axis…), MediaMTX, Wowza, GStreamer.
public actor RTSPPlayClient {
    public enum State: Equatable { case idle, connecting, playing, failed(String) }
    public enum ClientError: Error { case badURL, noMedia, connectionClosed, status(Int, String), timeout }

    public struct Tracks {
        public var video: SDPMedia?
        public var audio: SDPMedia?
    }

    public private(set) var state: State = .idle
    public private(set) var tracks = Tracks()

    /// Video access unit (NAL units without start codes), RTP timestamp in the media clock.
    public var onVideo: (@Sendable (AccessUnit) -> Void)?
    /// Raw AAC frames with RTP timestamp.
    public var onAudio: (@Sendable ([UInt8], UInt32) -> Void)?

    private let url: URL
    private var connection: NWConnection?
    private var cseq = 0
    private var session: String?
    private var sessionTimeout = 60
    private var auth: RTSPAuthenticator?
    private var demux = RTSPStreamDemuxer()
    private var pending: CheckedContinuation<RTSPResponse, Error>?
    private var keepAlive: Task<Void, Never>?
    private var videoChannel: UInt8 = 0
    private var audioChannel: UInt8 = 2
    private var h264 = H264Depacketizer()
    private var h265 = H265Depacketizer()

    public init(url: URL) {
        self.url = url
        if let user = url.user {
            auth = RTSPAuthenticator(username: user.removingPercentEncoding ?? user,
                                     password: url.password?.removingPercentEncoding ?? "")
        }
    }

    public func setHandlers(video: (@Sendable (AccessUnit) -> Void)?, audio: (@Sendable ([UInt8], UInt32) -> Void)?) {
        onVideo = video; onAudio = audio
    }

    private var requestURL: String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.user = nil; c?.password = nil
        return c?.string ?? url.absoluteString
    }

    public func start() async throws {
        guard let host = url.host else { throw ClientError.badURL }
        state = .connecting
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { tcp.noDelay = true }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(url.port ?? 554))!, using: params)
        connection = conn
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            conn.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready: if once.fire() { cont.resume() }
                case .failed(let e), .waiting(let e):
                    if once.fire() { cont.resume(throwing: e) }
                    Task { await self?.fail("\(e)") }
                case .cancelled: Task { await self?.fail("closed") }
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
        receiveNext()

        _ = try? await request("OPTIONS", uri: requestURL)
        let desc = try await request("DESCRIBE", uri: requestURL, headers: [("Accept", "application/sdp")])
        let base = desc.header("Content-Base") ?? desc.header("Content-Location") ?? requestURL
        let media = SDPParser.parse(String(decoding: desc.body, as: UTF8.self))
        tracks.video = media.first { $0.type == "video" && ($0.codec == .h264 || $0.codec == .h265) }
        tracks.audio = media.first { $0.type == "audio" && $0.codec == .aac }
        guard tracks.video != nil || tracks.audio != nil else { throw ClientError.noMedia }

        var ch: UInt8 = 0
        if let v = tracks.video {
            try await setup(SDPParser.resolve(control: v.control, base: base), channel: ch); videoChannel = ch; ch += 2
        }
        if let a = tracks.audio {
            try await setup(SDPParser.resolve(control: a.control, base: base), channel: ch); audioChannel = ch
        }
        _ = try await request("PLAY", uri: base.hasSuffix("/") ? String(base.dropLast()) : base, headers: [("Range", "npt=0.000-")])
        state = .playing
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                let t = max(5, (await self?.sessionTimeout ?? 60) / 2)
                try? await Task.sleep(nanoseconds: UInt64(t) * 1_000_000_000)
                guard let self, await self.state == .playing else { return }
                _ = try? await self.request("GET_PARAMETER", uri: await self.requestURL, timeout: 5)
            }
        }
    }

    public func stop() async {
        keepAlive?.cancel()
        if state == .playing { _ = try? await request("TEARDOWN", uri: requestURL, timeout: 2) }
        connection?.cancel(); connection = nil
        state = .idle
    }

    private func setup(_ uri: String, channel: UInt8) async throws {
        let r = try await request("SETUP", uri: uri, headers: [("Transport", "RTP/AVP/TCP;unicast;interleaved=\(channel)-\(channel + 1)")])
        if session == nil, let s = r.header("Session") {
            let parts = s.split(separator: ";")
            session = parts.first.map { $0.trimmingCharacters(in: .whitespaces) }
            if let t = parts.first(where: { $0.contains("timeout=") }), let v = Int(t.split(separator: "=").last ?? "") { sessionTimeout = v }
        }
    }

    private func fail(_ reason: String) {
        if case .idle = state { return }
        state = .failed(reason)
        pending?.resume(throwing: ClientError.connectionClosed); pending = nil
    }

    // MARK: Request / response

    @discardableResult
    func request(_ method: String, uri: String, headers: [(String, String)] = [], timeout: Double = 10) async throws -> RTSPResponse {
        let r = try await send(method, uri: uri, headers: headers, timeout: timeout)
        if r.statusCode == 401, var a = auth, let ch = r.header("WWW-Authenticate") {
            a.consume(challenge: ch); auth = a
            let r2 = try await send(method, uri: uri, headers: headers, timeout: timeout)
            guard (200..<300).contains(r2.statusCode) else { throw ClientError.status(r2.statusCode, r2.reason) }
            return r2
        }
        guard (200..<300).contains(r.statusCode) else { throw ClientError.status(r.statusCode, r.reason) }
        return r
    }

    private func send(_ method: String, uri: String, headers: [(String, String)], timeout: Double) async throws -> RTSPResponse {
        // One request in flight at a time (keep-alive may race with TEARDOWN).
        while pending != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        cseq += 1
        var h: [(String, String)] = [("CSeq", "\(cseq)"), ("User-Agent", "DTDStudio/1.0")]
        if let session { h.append(("Session", session)) }
        if var a = auth, let v = a.authorization(method: method, uri: uri) { auth = a; h.append(("Authorization", v)) }
        connection?.send(content: RTSPRequest(method: method, uri: uri, headers: h + headers).serialized(), completion: .idempotent)
        let t = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            await self?.timeoutPending()
        }
        defer { t.cancel() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    private func timeoutPending() { pending?.resume(throwing: ClientError.timeout); pending = nil }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            Task {
                guard let self else { return }
                if let data { await self.handle(data) }
                if done || error != nil { await self.fail(error.map { "\($0)" } ?? "eof"); return }
                await self.receiveNext()
            }
        }
    }

    private func handle(_ data: Data) {
        for (ch, bytes) in demux.append(data) {
            guard let p = RTPPacket.parse(bytes) else { continue } // odd channels = RTCP, ignored
            if ch == videoChannel, let v = tracks.video {
                let aus = v.codec == .h265 ? h265.push(p) : h264.push(p)
                aus.forEach { onVideo?($0) }
            } else if ch == audioChannel, let a = tracks.audio {
                for au in AACDepacketizer.accessUnits(p, sizeLength: a.aacSizeLength, indexLength: a.aacIndexLength) {
                    onAudio?(au, p.timestamp)
                }
            }
        }
        for r in demux.takeResponses() { pending?.resume(returning: r); pending = nil }
    }
}

final class OnceFlag: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
}
#endif

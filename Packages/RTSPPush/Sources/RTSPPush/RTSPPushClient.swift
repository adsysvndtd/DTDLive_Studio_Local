#if canImport(Network)
import Foundation
import Network

/// Publishes H.264 + AAC to an RTSP server using ANNOUNCE / SETUP / RECORD
/// with RTP interleaved over the RTSP TCP connection (works through NAT/firewalls).
///
/// Tested target servers: MediaMTX (rtsp://host:8554/path), Wowza, GStreamer rtsp-server (record).
public actor RTSPPushClient {
    public enum State: Equatable { case idle, connecting, recording, failed(String) }
    public enum ClientError: Error { case badURL, connectionClosed, status(Int, String), timeout }

    public private(set) var state: State = .idle

    private let url: URL
    private var connection: NWConnection?
    private var cseq = 0
    private var session: String?
    private var auth: RTSPAuthenticator?
    private var receiveBuffer = Data()
    private var pending: CheckedContinuation<RTSPResponse, Error>?
    private var keepAliveTask: Task<Void, Never>?
    private var sessionTimeout: Int = 60

    private var video = H264RTPPacketizer()
    private var audio = AACRTPPacketizer()
    private var audioClockRate: Int = 48000
    private var hasAudio = false
    private var videoBaseTime: Double?
    private var audioBaseTime: Double?

    /// Bytes queued but not yet acknowledged by the TCP stack, used to drop frames under congestion.
    private var inFlight = 0
    public var maxInFlightBytes = 4 * 1024 * 1024

    public init(url: URL) {
        self.url = url
        if let user = url.user {
            auth = RTSPAuthenticator(username: user.removingPercentEncoding ?? user,
                                     password: url.password?.removingPercentEncoding ?? "")
        }
    }

    /// URL with credentials stripped (credentials must never appear in the request line).
    private var requestURL: String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.user = nil; c?.password = nil
        return c?.string ?? url.absoluteString
    }

    // MARK: - Lifecycle

    public func start(sdp: SDPDescription) async throws {
        guard let host = url.host else { throw ClientError.badURL }
        state = .connecting
        hasAudio = sdp.audio != nil
        audioClockRate = sdp.audio?.sampleRate ?? 48000
        let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 554))!
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
        connection = conn
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let e), .waiting(let e):
                    if !resumed { resumed = true; cont.resume(throwing: e) }
                    Task { await self?.fail("\(e)") }
                case .cancelled:
                    Task { await self?.fail("closed") }
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
        receiveLoop()

        _ = try await request("OPTIONS", uri: requestURL)
        _ = try await request("ANNOUNCE", uri: requestURL,
                              headers: [("Content-Type", "application/sdp")], body: sdp.render())
        var channel: UInt8 = 0
        if sdp.video != nil {
            try await setup(track: SDPDescription.videoTrack, channel: channel); channel += 2
        }
        if sdp.audio != nil {
            try await setup(track: SDPDescription.audioTrack, channel: channel)
        }
        _ = try await request("RECORD", uri: requestURL, headers: [("Range", "npt=0.000-")])
        state = .recording
        startKeepAlive()
    }

    public func stop() async {
        keepAliveTask?.cancel()
        if state == .recording {
            _ = try? await request("TEARDOWN", uri: requestURL, timeout: 2)
        }
        connection?.cancel()
        connection = nil
        state = .idle
    }

    private func setup(track: String, channel: UInt8) async throws {
        let base = requestURL.hasSuffix("/") ? requestURL : requestURL + "/"
        let resp = try await request("SETUP", uri: base + track,
                                     headers: [("Transport", "RTP/AVP/TCP;unicast;interleaved=\(channel)-\(channel + 1);mode=record")])
        if session == nil, let s = resp.header("Session") {
            let parts = s.split(separator: ";")
            session = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) }
            if let t = parts.first(where: { $0.contains("timeout=") }), let v = Int(t.split(separator: "=").last ?? "") {
                sessionTimeout = v
            }
        }
    }

    private func startKeepAlive() {
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = max(5, (await self?.sessionTimeout ?? 60) / 2)
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard let self, await self.state == .recording else { return }
                _ = try? await self.request("GET_PARAMETER", uri: await self.requestURL, timeout: 5)
            }
        }
    }

    private func fail(_ reason: String) {
        if case .idle = state { return }
        state = .failed(reason)
        pending?.resume(throwing: ClientError.connectionClosed)
        pending = nil
    }

    // MARK: - Media

    /// - Parameters:
    ///   - nalUnits: NAL units of one access unit (no start codes / length prefixes).
    ///   - pts: presentation time in seconds.
    public func sendVideo(nalUnits: [ArraySlice<UInt8>], pts: Double, isKeyframe: Bool) {
        guard state == .recording else { return }
        if inFlight > maxInFlightBytes && !isKeyframe { return } // congestion: drop non-key frames
        let base = videoBaseTime ?? pts
        videoBaseTime = base
        let ts = UInt32(truncatingIfNeeded: Int64((pts - base) * 90000))
        let packets = video.packetize(nalUnits: nalUnits, timestamp: ts)
        var out = [UInt8]()
        for p in packets { out += InterleavedFrame.wrap(channel: 0, p.serialized()) }
        write(out)
    }

    /// - Parameter accessUnit: one raw AAC frame (no ADTS header).
    public func sendAudio(accessUnit: [UInt8], pts: Double) {
        guard state == .recording, hasAudio else { return }
        let base = audioBaseTime ?? pts
        audioBaseTime = base
        let ts = UInt32(truncatingIfNeeded: Int64((pts - base) * Double(audioClockRate)))
        guard let p = audio.packetize(accessUnit: accessUnit, timestamp: ts) else { return }
        write(InterleavedFrame.wrap(channel: 2, p.serialized()))
    }

    private func write(_ bytes: [UInt8]) {
        guard let connection else { return }
        inFlight += bytes.count
        let n = bytes.count
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] _ in
            Task { await self?.ack(n) }
        })
    }

    private func ack(_ n: Int) { inFlight -= n }

    // MARK: - RTSP request/response

    @discardableResult
    func request(_ method: String, uri: String, headers: [(String, String)] = [], body: String? = nil, timeout: Double = 10) async throws -> RTSPResponse {
        let resp = try await send(method, uri: uri, headers: headers, body: body, timeout: timeout)
        if resp.statusCode == 401, var a = auth, let challenge = resp.header("WWW-Authenticate") {
            a.consume(challenge: challenge)
            auth = a
            let retry = try await send(method, uri: uri, headers: headers, body: body, timeout: timeout)
            guard (200..<300).contains(retry.statusCode) else { throw ClientError.status(retry.statusCode, retry.reason) }
            return retry
        }
        guard (200..<300).contains(resp.statusCode) else { throw ClientError.status(resp.statusCode, resp.reason) }
        return resp
    }

    private func send(_ method: String, uri: String, headers: [(String, String)], body: String?, timeout: Double) async throws -> RTSPResponse {
        cseq += 1
        var h: [(String, String)] = [("CSeq", "\(cseq)"), ("User-Agent", "DTDStudio/1.0")]
        if let session { h.append(("Session", session)) }
        if var a = auth, let v = a.authorization(method: method, uri: uri) { auth = a; h.append(("Authorization", v)) }
        h += headers
        let req = RTSPRequest(method: method, uri: uri, headers: h, body: body)
        connection?.send(content: req.serialized(), completion: .idempotent)
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.timeoutPending()
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    private func timeoutPending() {
        pending?.resume(throwing: ClientError.timeout)
        pending = nil
    }

    private nonisolated func receiveLoop() {
        Task { await self.receiveNext() }
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            Task {
                guard let self else { return }
                if let data { await self.handle(data) }
                if done || error != nil { await self.fail(error.map { "\($0)" } ?? "eof"); return }
                await self.receiveNext()
            }
        }
    }

    private func handle(_ data: Data) {
        receiveBuffer.append(data)
        while let resp = RTSPResponse.parse(&receiveBuffer) {
            pending?.resume(returning: resp)
            pending = nil
        }
        // Drop leftover interleaved frames (RTCP RR) so the buffer doesn't grow.
        if receiveBuffer.count > 1 << 20 { receiveBuffer.removeAll() }
    }
}
#endif

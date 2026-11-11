import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct RTSPRequest {
    public var method: String
    public var uri: String
    public var headers: [(String, String)] = []
    public var body: String?

    public init(method: String, uri: String, headers: [(String, String)] = [], body: String? = nil) {
        self.method = method; self.uri = uri; self.headers = headers; self.body = body
    }

    public func serialized() -> Data {
        var s = "\(method) \(uri) RTSP/1.0\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        if let body {
            s += "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        } else {
            s += "\r\n"
        }
        return Data(s.utf8)
    }
}

public struct RTSPResponse {
    public var statusCode: Int
    public var reason: String
    public var headers: [String: String] // lowercased keys
    public var body: Data

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Tries to parse one response from the front of `buffer`. Returns nil if incomplete.
    /// Skips interleaved '$' frames the server may send (RTCP RR).
    public static func parse(_ buffer: inout Data) -> RTSPResponse? {
        while let first = buffer.first, first == 0x24 {
            guard buffer.count >= 4 else { return nil }
            let len = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
            guard buffer.count >= 4 + len else { return nil }
            buffer.removeFirst(4 + len)
        }
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[buffer.startIndex..<range.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let status = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard status.count >= 2, status[0].hasPrefix("RTSP/"), let code = Int(status[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = headers[key].map { $0 + ", " + value } ?? value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = range.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let body = buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)]
        let resp = RTSPResponse(statusCode: code, reason: status.count > 2 ? String(status[2]) : "", headers: headers, body: Data(body))
        buffer.removeSubrange(buffer.startIndex..<buffer.index(bodyStart, offsetBy: length))
        return resp
    }
}

/// Basic + Digest (RFC 2617, MD5, qop=auth or none) authorization.
public struct RTSPAuthenticator {
    public let username: String
    public let password: String
    private var realm: String?
    private var nonce: String?
    private var qop: String?
    private var opaque: String?
    private var isDigest = false
    private var nc: UInt32 = 0

    public init(username: String, password: String) { self.username = username; self.password = password }

    private var challengeSeen = false

    public mutating func consume(challenge: String) {
        challengeSeen = true
        let lower = challenge.lowercased()
        // Prefer Digest if several schemes are offered.
        if let r = lower.range(of: "digest ") {
            isDigest = true
            let params = Self.params(String(challenge[r.upperBound...]))
            realm = params["realm"]; nonce = params["nonce"]; qop = params["qop"]; opaque = params["opaque"]
        } else {
            isDigest = false
            realm = Self.params(challenge)["realm"] ?? ""
        }
    }

    public mutating func authorization(method: String, uri: String) -> String? {
        guard challengeSeen else { return nil }
        if !isDigest {
            return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        }
        guard let realm, let nonce else { return nil }
        let ha1 = Self.md5("\(username):\(realm):\(password)")
        let ha2 = Self.md5("\(method):\(uri)")
        var header = "Digest username=\"\(username)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\""
        if let qop, qop.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("auth") {
            nc += 1
            let ncs = String(format: "%08x", nc)
            let cnonce = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
            let response = Self.md5("\(ha1):\(nonce):\(ncs):\(cnonce):auth:\(ha2)")
            header += ", qop=auth, nc=\(ncs), cnonce=\"\(cnonce)\", response=\"\(response)\""
        } else {
            header += ", response=\"\(Self.md5("\(ha1):\(nonce):\(ha2)"))\""
        }
        if let opaque { header += ", opaque=\"\(opaque)\"" }
        return header
    }

    static func params(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var key = "", value = "", inKey = true, inQuote = false
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces).lowercased()
            if !k.isEmpty { out[k] = value.trimmingCharacters(in: .whitespaces) }
            key = ""; value = ""; inKey = true
        }
        for ch in s {
            if inKey {
                if ch == "=" { inKey = false } else if ch == "," { flush() } else { key.append(ch) }
            } else {
                if ch == "\"" { inQuote.toggle() } else if ch == "," && !inQuote { flush() } else { value.append(ch) }
            }
        }
        flush()
        return out
    }

    static func md5(_ s: String) -> String {
        #if canImport(CryptoKit)
        return Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return MD5Fallback.hex(Array(s.utf8))
        #endif
    }
}

/// Minimal MD5 for platforms without CryptoKit (Linux test runs).
enum MD5Fallback {
    static func hex(_ message: [UInt8]) -> String {
        var s: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
        let k: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0)) }
        var a0: UInt32 = 0x67452301, b0: UInt32 = 0xefcdab89, c0: UInt32 = 0x98badcfe, d0: UInt32 = 0x10325476
        var msg = message
        let bitLen = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(UInt8((bitLen >> (8 * UInt64(i))) & 0xFF)) }
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let b = chunk + i * 4
                m[i] = UInt32(msg[b]) | UInt32(msg[b + 1]) << 8 | UInt32(msg[b + 2]) << 16 | UInt32(msg[b + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32, g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ k[i] &+ m[g]
                a = d; d = c; c = b
                b = b &+ (f << s[i] | f >> (32 - s[i]))
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
        }
        s.removeAll()
        return [a0, b0, c0, d0].flatMap { v in (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
            .map { String(format: "%02x", $0) }.joined()
    }
}

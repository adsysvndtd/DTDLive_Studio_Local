import Foundation

/// Minimal SDP parser for RTSP DESCRIBE responses.
public struct SDPMedia: Equatable {
    public enum Codec: Equatable { case h264, h265, aac, other(String) }
    public var type: String              // "video" / "audio"
    public var payloadType: UInt8
    public var codec: Codec
    public var clockRate: Int
    public var channels: Int
    public var control: String?
    public var fmtp: [String: String] = [:]

    /// H.264: [SPS, PPS]; H.265: [VPS, SPS, PPS]
    public var parameterSets: [[UInt8]] {
        func b64(_ s: String) -> [UInt8]? { Data(base64Encoded: s.trimmingCharacters(in: .whitespaces)).map(Array.init) }
        switch codec {
        case .h264:
            return (fmtp["sprop-parameter-sets"] ?? "").split(separator: ",").compactMap { b64(String($0)) }
        case .h265:
            return ["sprop-vps", "sprop-sps", "sprop-pps"].compactMap { fmtp[$0].flatMap(b64) }
        default:
            return []
        }
    }

    public var aacConfig: [UInt8] {
        guard let hex = fmtp["config"] else { return [] }
        var out: [UInt8] = []
        var i = hex.startIndex
        while let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), i < hex.endIndex {
            if let v = UInt8(hex[i..<j], radix: 16) { out.append(v) }
            i = j
        }
        return out
    }

    public var aacSizeLength: Int { Int(fmtp["sizelength"] ?? "13") ?? 13 }
    public var aacIndexLength: Int { Int(fmtp["indexlength"] ?? "3") ?? 3 }
}

public enum SDPParser {
    public static func parse(_ text: String) -> [SDPMedia] {
        var media: [SDPMedia] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                let p = line.dropFirst(2).split(separator: " ")
                guard p.count >= 4, let pt = UInt8(p[3]) else { continue }
                media.append(SDPMedia(type: String(p[0]), payloadType: pt, codec: .other(""), clockRate: 90000, channels: 1))
            } else if line.hasPrefix("a=rtpmap:"), !media.isEmpty {
                let p = line.dropFirst(9).split(separator: " ", maxSplits: 1)
                guard p.count == 2, UInt8(p[0]) == media[media.count - 1].payloadType else { continue }
                let enc = p[1].split(separator: "/")
                let name = enc.first.map { $0.uppercased() } ?? ""
                media[media.count - 1].codec = name == "H264" ? .h264 : (name == "H265" || name == "HEVC") ? .h265
                    : name == "MPEG4-GENERIC" ? .aac : .other(name)
                if enc.count > 1 { media[media.count - 1].clockRate = Int(enc[1]) ?? 90000 }
                if enc.count > 2 { media[media.count - 1].channels = Int(enc[2]) ?? 1 }
            } else if line.hasPrefix("a=fmtp:"), !media.isEmpty {
                guard let sp = line.firstIndex(of: " ") else { continue }
                for kv in line[line.index(after: sp)...].split(separator: ";") {
                    let pair = kv.split(separator: "=", maxSplits: 1)
                    guard pair.count == 2 else { continue }
                    media[media.count - 1].fmtp[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                        pair[1].trimmingCharacters(in: .whitespaces)
                }
            } else if line.hasPrefix("a=control:"), !media.isEmpty {
                media[media.count - 1].control = String(line.dropFirst(10))
            }
        }
        return media
    }

    /// Resolves a media control attribute against the RTSP base URL (RFC 2326 C.1.1).
    public static func resolve(control: String?, base: String) -> String {
        guard let c = control, c != "*" else { return base }
        if c.lowercased().hasPrefix("rtsp://") || c.lowercased().hasPrefix("rtsps://") { return c }
        return base.hasSuffix("/") ? base + c : base + "/" + c
    }
}

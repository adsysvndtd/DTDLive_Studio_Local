import Foundation

/// Builds the SDP body sent with ANNOUNCE.
public struct SDPDescription {
    public struct Video {
        public enum Codec { case h264, h265 }
        public var codec: Codec = .h264
        /// H.264: [SPS, PPS]; H.265: [VPS, SPS, PPS]
        public var parameterSets: [[UInt8]]
        public var payloadType: UInt8 = 96
        public var sps: [UInt8] { codec == .h264 ? (parameterSets.first ?? []) : (parameterSets.count > 1 ? parameterSets[1] : []) }
        public var pps: [UInt8] { parameterSets.last ?? [] }
        public init(sps: [UInt8], pps: [UInt8]) { parameterSets = [sps, pps] }
        public init(hevc vps: [UInt8], sps: [UInt8], pps: [UInt8]) { codec = .h265; parameterSets = [vps, sps, pps] }
    }

    public struct Audio {
        public var sampleRate: Int
        public var channels: Int
        /// AudioSpecificConfig (ISO 14496-3) bytes.
        public var audioSpecificConfig: [UInt8]
        public var payloadType: UInt8 = 97
        public init(sampleRate: Int, channels: Int, audioSpecificConfig: [UInt8]) {
            self.sampleRate = sampleRate; self.channels = channels; self.audioSpecificConfig = audioSpecificConfig
        }

        /// AAC-LC AudioSpecificConfig for a given sample rate / channel count.
        public static func aacLC(sampleRate: Int, channels: Int) -> Audio {
            let table = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
            let idx = UInt16(table.firstIndex(of: sampleRate) ?? 4)
            let objectType: UInt16 = 2 // AAC LC
            let v: UInt16 = (objectType << 11) | (idx << 7) | (UInt16(channels) << 3)
            return Audio(sampleRate: sampleRate, channels: channels, audioSpecificConfig: [UInt8(v >> 8), UInt8(v & 0xFF)])
        }
    }

    public var sessionName: String = "DTDStudio"
    public var originAddress: String = "0.0.0.0"
    public var video: Video?
    public var audio: Audio?

    public init(video: Video?, audio: Audio?) { self.video = video; self.audio = audio }

    /// Control URLs used in SETUP: "<base>/trackID=0" (video) and "<base>/trackID=1" (audio).
    public static let videoTrack = "trackID=0"
    public static let audioTrack = "trackID=1"

    public func render() -> String {
        var l: [String] = []
        let sid = UInt32.random(in: 1...UInt32.max)
        l.append("v=0")
        l.append("o=- \(sid) 1 IN IP4 \(originAddress)")
        l.append("s=\(sessionName)")
        l.append("c=IN IP4 0.0.0.0")
        l.append("t=0 0")
        l.append("a=control:*")
        if let v = video, v.codec == .h265 {
            func b64(_ b: [UInt8]) -> String { Data(b).base64EncodedString() }
            l.append("m=video 0 RTP/AVP \(v.payloadType)")
            l.append("a=rtpmap:\(v.payloadType) H265/90000")
            l.append("a=fmtp:\(v.payloadType) sprop-vps=\(b64(v.parameterSets[0])); sprop-sps=\(b64(v.parameterSets[1])); sprop-pps=\(b64(v.parameterSets[2]))")
            l.append("a=control:\(Self.videoTrack)")
        } else if let v = video {
            let profile = v.sps.count >= 4 ? String(format: "%02X%02X%02X", v.sps[1], v.sps[2], v.sps[3]) : "42E01F"
            let sprop = Data(v.sps).base64EncodedString() + "," + Data(v.pps).base64EncodedString()
            l.append("m=video 0 RTP/AVP \(v.payloadType)")
            l.append("a=rtpmap:\(v.payloadType) H264/90000")
            l.append("a=fmtp:\(v.payloadType) packetization-mode=1; profile-level-id=\(profile); sprop-parameter-sets=\(sprop)")
            l.append("a=control:\(Self.videoTrack)")
        }
        if let a = audio {
            let config = a.audioSpecificConfig.map { String(format: "%02X", $0) }.joined()
            l.append("m=audio 0 RTP/AVP \(a.payloadType)")
            l.append("a=rtpmap:\(a.payloadType) MPEG4-GENERIC/\(a.sampleRate)/\(a.channels)")
            l.append("a=fmtp:\(a.payloadType) profile-level-id=1; mode=AAC-hbr; sizelength=13; indexlength=3; indexdeltalength=3; config=\(config)")
            l.append("a=control:\(Self.audioTrack)")
        }
        return l.joined(separator: "\r\n") + "\r\n"
    }
}

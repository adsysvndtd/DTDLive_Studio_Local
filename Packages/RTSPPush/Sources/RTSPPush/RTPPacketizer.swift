import Foundation

/// One RTP packet (header + payload), ready to be framed on the wire.
public struct RTPPacket: Equatable {
    public var payloadType: UInt8
    public var marker: Bool
    public var sequenceNumber: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    public var payload: [UInt8]

    /// RFC 3550 §5.1 fixed 12-byte header, no CSRC, no extension.
    public func serialized() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(12 + payload.count)
        out.append(0x80) // V=2, P=0, X=0, CC=0
        out.append((marker ? 0x80 : 0x00) | (payloadType & 0x7F))
        out.append(UInt8(sequenceNumber >> 8)); out.append(UInt8(sequenceNumber & 0xFF))
        out.append(contentsOf: timestamp.bigEndianBytes)
        out.append(contentsOf: ssrc.bigEndianBytes)
        out.append(contentsOf: payload)
        return out
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8(self >> 24), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}

/// Splits Annex-B / AVCC access units into NAL units.
public enum NALUnitSplitter {
    /// AVCC (length-prefixed) as produced by VideoToolbox.
    public static func splitAVCC(_ data: [UInt8], lengthSize: Int = 4) -> [ArraySlice<UInt8>] {
        var result: [ArraySlice<UInt8>] = []
        var i = 0
        while i + lengthSize <= data.count {
            var len = 0
            for k in 0..<lengthSize { len = (len << 8) | Int(data[i + k]) }
            i += lengthSize
            guard len > 0, i + len <= data.count else { break }
            result.append(data[i..<(i + len)])
            i += len
        }
        return result
    }

    /// Annex-B (00 00 01 / 00 00 00 01 start codes).
    public static func splitAnnexB(_ data: [UInt8]) -> [ArraySlice<UInt8>] {
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        while i + 2 < data.count {
            if data[i] == 0, data[i + 1] == 0 {
                if data[i + 2] == 1 { starts.append((i, i + 3)); i += 3; continue }
                if i + 3 < data.count, data[i + 2] == 0, data[i + 3] == 1 { starts.append((i, i + 4)); i += 4; continue }
            }
            i += 1
        }
        var result: [ArraySlice<UInt8>] = []
        for (n, s) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].code : data.count
            if s.payload < end { result.append(data[s.payload..<end]) }
        }
        return result
    }
}

/// RFC 6184 H.264 packetizer: single NAL unit mode + FU-A (packetization-mode=1).
public struct H264RTPPacketizer {
    public let payloadType: UInt8
    public let ssrc: UInt32
    public let mtu: Int
    public private(set) var sequenceNumber: UInt16

    public init(payloadType: UInt8 = 96, ssrc: UInt32 = .random(in: 1...UInt32.max), mtu: Int = 1400, initialSequence: UInt16 = .random(in: 0...UInt16.max)) {
        self.payloadType = payloadType
        self.ssrc = ssrc
        self.mtu = mtu
        self.sequenceNumber = initialSequence
    }

    /// Packetizes all NAL units of one access unit. Marker bit set on the last packet.
    public mutating func packetize(nalUnits: [ArraySlice<UInt8>], timestamp: UInt32) -> [RTPPacket] {
        var packets: [RTPPacket] = []
        let maxPayload = mtu - 12
        for (index, nal) in nalUnits.enumerated() where !nal.isEmpty {
            let isLastNAL = index == nalUnits.count - 1
            if nal.count <= maxPayload {
                packets.append(make(payload: Array(nal), marker: isLastNAL, timestamp: timestamp))
                continue
            }
            // FU-A
            let header = nal[nal.startIndex]
            let fuIndicator = (header & 0xE0) | 28
            let nalType = header & 0x1F
            var offset = nal.startIndex + 1
            let chunk = maxPayload - 2
            var first = true
            while offset < nal.endIndex {
                let end = min(offset + chunk, nal.endIndex)
                let last = end == nal.endIndex
                var fuHeader = nalType
                if first { fuHeader |= 0x80 }
                if last { fuHeader |= 0x40 }
                var payload = [fuIndicator, fuHeader]
                payload.append(contentsOf: nal[offset..<end])
                packets.append(make(payload: payload, marker: last && isLastNAL, timestamp: timestamp))
                offset = end
                first = false
            }
        }
        return packets
    }

    private mutating func make(payload: [UInt8], marker: Bool, timestamp: UInt32) -> RTPPacket {
        defer { sequenceNumber &+= 1 }
        return RTPPacket(payloadType: payloadType, marker: marker, sequenceNumber: sequenceNumber, timestamp: timestamp, ssrc: ssrc, payload: payload)
    }
}

/// RFC 3640 AAC-hbr packetizer (mpeg4-generic, sizelength=13, indexlength=3, indexdeltalength=3).
/// One raw AAC access unit (no ADTS header) per packet.
public struct AACRTPPacketizer {
    public let payloadType: UInt8
    public let ssrc: UInt32
    public private(set) var sequenceNumber: UInt16

    public init(payloadType: UInt8 = 97, ssrc: UInt32 = .random(in: 1...UInt32.max), initialSequence: UInt16 = .random(in: 0...UInt16.max)) {
        self.payloadType = payloadType
        self.ssrc = ssrc
        self.sequenceNumber = initialSequence
    }

    public mutating func packetize(accessUnit: [UInt8], timestamp: UInt32) -> RTPPacket? {
        guard !accessUnit.isEmpty, accessUnit.count < (1 << 13) else { return nil }
        let size = UInt16(accessUnit.count)
        let auHeader = size << 3 // 13 bits size + 3 bits index (0)
        var payload: [UInt8] = [0x00, 0x10, UInt8(auHeader >> 8), UInt8(auHeader & 0xFF)] // AU-headers-length = 16 bits
        payload.append(contentsOf: accessUnit)
        defer { sequenceNumber &+= 1 }
        return RTPPacket(payloadType: payloadType, marker: true, sequenceNumber: sequenceNumber, timestamp: timestamp, ssrc: ssrc, payload: payload)
    }
}

/// RTSP interleaved binary framing (RFC 2326 §10.12): '$' channel len(16) data.
public enum InterleavedFrame {
    public static func wrap(channel: UInt8, _ data: [UInt8]) -> [UInt8] {
        precondition(data.count <= UInt16.max)
        var out: [UInt8] = [0x24, channel, UInt8(data.count >> 8), UInt8(data.count & 0xFF)]
        out.append(contentsOf: data)
        return out
    }
}

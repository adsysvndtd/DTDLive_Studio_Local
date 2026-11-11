import Foundation

extension RTPPacket {
    /// Parses an RTP packet (RFC 3550). Handles CSRC list, header extension and padding.
    public static func parse(_ b: [UInt8]) -> RTPPacket? {
        guard b.count >= 12, b[0] >> 6 == 2 else { return nil }
        let cc = Int(b[0] & 0x0F)
        var offset = 12 + cc * 4
        if b[0] & 0x10 != 0 { // extension
            guard b.count >= offset + 4 else { return nil }
            let words = Int(b[offset + 2]) << 8 | Int(b[offset + 3])
            offset += 4 + words * 4
        }
        var end = b.count
        if b[0] & 0x20 != 0, let pad = b.last { end -= Int(pad) }
        guard offset <= end else { return nil }
        let seq = UInt16(b[2]) << 8 | UInt16(b[3])
        let ts = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        let ssrc = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
        return RTPPacket(payloadType: b[1] & 0x7F, marker: b[1] & 0x80 != 0, sequenceNumber: seq,
                         timestamp: ts, ssrc: ssrc, payload: Array(b[offset..<end]))
    }
}

/// A reassembled video access unit.
public struct AccessUnit: Equatable {
    public var nalUnits: [[UInt8]]
    public var timestamp: UInt32
    public var isKeyframe: Bool
    public init(nalUnits: [[UInt8]], timestamp: UInt32, isKeyframe: Bool) {
        self.nalUnits = nalUnits; self.timestamp = timestamp; self.isKeyframe = isKeyframe
    }
}

/// RFC 6184 depacketizer: single NAL, STAP-A (24), FU-A (28). Emits one access unit
/// per RTP timestamp (on marker bit or timestamp change). Drops a frame that lost a fragment.
public struct H264Depacketizer {
    private var current: [[UInt8]] = []
    private var currentTS: UInt32?
    private var fu: [UInt8]?
    private var lastSeq: UInt16?
    private var broken = false

    public init() {}

    public mutating func push(_ p: RTPPacket) -> [AccessUnit] {
        var out: [AccessUnit] = []
        // A sequence gap taints both the frame in progress (may have lost its tail)
        // and the new one (may have lost its head).
        let gap = lastSeq.map { p.sequenceNumber != $0 &+ 1 } ?? false
        lastSeq = p.sequenceNumber
        if gap { broken = true; fu = nil }
        if let ts = currentTS, ts != p.timestamp, let au = flush() { out.append(au) }
        if gap { broken = true }
        currentTS = p.timestamp
        let pl = p.payload
        guard let h = pl.first else { return out }
        switch h & 0x1F {
        case 1...23:
            current.append(pl)
        case 24: // STAP-A
            var i = 1
            while i + 2 <= pl.count {
                let n = Int(pl[i]) << 8 | Int(pl[i + 1]); i += 2
                guard i + n <= pl.count else { break }
                current.append(Array(pl[i..<(i + n)])); i += n
            }
        case 28: // FU-A
            guard pl.count > 2 else { break }
            let fuh = pl[1]
            if fuh & 0x80 != 0 { fu = [(h & 0xE0) | (fuh & 0x1F)] }
            if fu != nil { fu! += pl[2...] }
            if fuh & 0x40 != 0, let nal = fu { current.append(nal); fu = nil }
        default:
            break
        }
        if p.marker, let au = flush() { out.append(au) }
        return out
    }

    private mutating func flush() -> AccessUnit? {
        defer { current = []; currentTS = nil; broken = false }
        guard !current.isEmpty, !broken, let ts = currentTS else { return nil }
        let key = current.contains { ($0.first ?? 0) & 0x1F == 5 }
        return AccessUnit(nalUnits: current, timestamp: ts, isKeyframe: key)
    }
}

/// RFC 7798 depacketizer: single NAL, AP (48), FU (49).
public struct H265Depacketizer {
    private var current: [[UInt8]] = []
    private var currentTS: UInt32?
    private var fu: [UInt8]?
    private var lastSeq: UInt16?
    private var broken = false

    public init() {}

    public mutating func push(_ p: RTPPacket) -> [AccessUnit] {
        var out: [AccessUnit] = []
        // A sequence gap taints both the frame in progress (may have lost its tail)
        // and the new one (may have lost its head).
        let gap = lastSeq.map { p.sequenceNumber != $0 &+ 1 } ?? false
        lastSeq = p.sequenceNumber
        if gap { broken = true; fu = nil }
        if let ts = currentTS, ts != p.timestamp, let au = flush() { out.append(au) }
        if gap { broken = true }
        currentTS = p.timestamp
        let pl = p.payload
        guard pl.count >= 2 else { return out }
        let type = (pl[0] >> 1) & 0x3F
        switch type {
        case 48: // AP
            var i = 2
            while i + 2 <= pl.count {
                let n = Int(pl[i]) << 8 | Int(pl[i + 1]); i += 2
                guard i + n <= pl.count else { break }
                current.append(Array(pl[i..<(i + n)])); i += n
            }
        case 49: // FU
            guard pl.count > 3 else { break }
            let fuh = pl[2]
            if fuh & 0x80 != 0 { fu = [(pl[0] & 0x81) | ((fuh & 0x3F) << 1), pl[1]] }
            if fu != nil { fu! += pl[3...] }
            if fuh & 0x40 != 0, let nal = fu { current.append(nal); fu = nil }
        default:
            current.append(pl)
        }
        if p.marker, let au = flush() { out.append(au) }
        return out
    }

    private mutating func flush() -> AccessUnit? {
        defer { current = []; currentTS = nil; broken = false }
        guard !current.isEmpty, !broken, let ts = currentTS else { return nil }
        let key = current.contains { t in let k = ((t.first ?? 0) >> 1) & 0x3F; return k >= 16 && k <= 21 }
        return AccessUnit(nalUnits: current, timestamp: ts, isKeyframe: key)
    }
}

/// RFC 7798 packetizer (single NAL + FU), mirrors H264RTPPacketizer.
public struct H265RTPPacketizer {
    public let payloadType: UInt8
    public let ssrc: UInt32
    public let mtu: Int
    public private(set) var sequenceNumber: UInt16

    public init(payloadType: UInt8 = 96, ssrc: UInt32 = .random(in: 1...UInt32.max), mtu: Int = 1400, initialSequence: UInt16 = .random(in: 0...UInt16.max)) {
        self.payloadType = payloadType; self.ssrc = ssrc; self.mtu = mtu; self.sequenceNumber = initialSequence
    }

    public mutating func packetize(nalUnits: [ArraySlice<UInt8>], timestamp: UInt32) -> [RTPPacket] {
        var packets: [RTPPacket] = []
        let maxPayload = mtu - 12
        for (index, nal) in nalUnits.enumerated() where nal.count >= 2 {
            let lastNAL = index == nalUnits.count - 1
            if nal.count <= maxPayload {
                packets.append(make(Array(nal), lastNAL, timestamp)); continue
            }
            let h0 = nal[nal.startIndex], h1 = nal[nal.startIndex + 1]
            let type = (h0 >> 1) & 0x3F
            let ph0 = (h0 & 0x81) | (49 << 1)
            var offset = nal.startIndex + 2
            var first = true
            while offset < nal.endIndex {
                let end = min(offset + maxPayload - 3, nal.endIndex)
                let last = end == nal.endIndex
                var fuh = type
                if first { fuh |= 0x80 }
                if last { fuh |= 0x40 }
                packets.append(make([ph0, h1, fuh] + nal[offset..<end], last && lastNAL, timestamp))
                offset = end; first = false
            }
        }
        return packets
    }

    private mutating func make(_ payload: [UInt8], _ marker: Bool, _ ts: UInt32) -> RTPPacket {
        defer { sequenceNumber &+= 1 }
        return RTPPacket(payloadType: payloadType, marker: marker, sequenceNumber: sequenceNumber, timestamp: ts, ssrc: ssrc, payload: payload)
    }
}

/// RFC 3640 AAC-hbr depacketizer (sizelength=13, indexlength=3). Returns raw AAC frames.
public enum AACDepacketizer {
    public static func accessUnits(_ p: RTPPacket, sizeLength: Int = 13, indexLength: Int = 3) -> [[UInt8]] {
        let pl = p.payload
        guard pl.count >= 2 else { return [] }
        let headersBits = Int(pl[0]) << 8 | Int(pl[1])
        let headerBytes = (headersBits + 7) / 8
        let headerSize = sizeLength + indexLength
        guard headerSize > 0, pl.count >= 2 + headerBytes else { return [] }
        let count = headersBits / headerSize
        var sizes: [Int] = []
        var bit = 16
        for _ in 0..<count {
            var v = 0
            for _ in 0..<sizeLength {
                v = v << 1 | Int((pl[bit / 8] >> (7 - UInt8(bit % 8))) & 1); bit += 1
            }
            bit += indexLength
            sizes.append(v)
        }
        var out: [[UInt8]] = []
        var i = 2 + headerBytes
        for s in sizes where i + s <= pl.count { out.append(Array(pl[i..<(i + s)])); i += s }
        return out
    }
}

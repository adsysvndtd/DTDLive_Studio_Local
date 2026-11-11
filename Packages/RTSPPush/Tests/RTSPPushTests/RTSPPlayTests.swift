import XCTest
@testable import RTSPPush

final class RTSPPlayTests: XCTestCase {
    func testRTPParseRoundTrip() {
        let p = RTPPacket(payloadType: 96, marker: true, sequenceNumber: 7, timestamp: 9000, ssrc: 42, payload: [1, 2, 3])
        XCTAssertEqual(RTPPacket.parse(p.serialized()), p)
    }

    func testRTPParseWithExtensionAndPadding() {
        var b: [UInt8] = [0xB0, 0x60, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3] // V=2,P=1,X=1
        b += [0xBE, 0xDE, 0, 1, 9, 9, 9, 9]                        // 1-word extension
        b += [0xAA, 0xBB, 0, 0, 3]                                  // payload + 3 bytes padding
        let p = RTPPacket.parse(b)
        XCTAssertEqual(p?.payload, [0xAA, 0xBB])
        XCTAssertEqual(p?.timestamp, 2)
    }

    func testH264FUARoundTrip() {
        var pk = H264RTPPacketizer(ssrc: 1, mtu: 200, initialSequence: 100)
        let sps: [UInt8] = [0x67, 0x64, 0, 0x28], pps: [UInt8] = [0x68, 0xEE]
        let idr: [UInt8] = [0x65] + (0..<5000).map { UInt8($0 & 0xFF) }
        let packets = pk.packetize(nalUnits: [sps[...], pps[...], idr[...]], timestamp: 3000)
        var dp = H264Depacketizer()
        let aus = packets.flatMap { dp.push(RTPPacket.parse($0.serialized())!) }
        XCTAssertEqual(aus.count, 1)
        XCTAssertEqual(aus[0].nalUnits, [sps, pps, idr])
        XCTAssertTrue(aus[0].isKeyframe)
        XCTAssertEqual(aus[0].timestamp, 3000)
    }

    func testH264DropsFrameWithLoss() {
        var pk = H264RTPPacketizer(ssrc: 1, mtu: 100, initialSequence: 0)
        let nal: [UInt8] = [0x41] + [UInt8](repeating: 7, count: 1000)
        var packets = pk.packetize(nalUnits: [nal[...]], timestamp: 0)
        packets.remove(at: 3)
        var dp = H264Depacketizer()
        XCTAssertTrue(packets.flatMap { dp.push($0) }.isEmpty)
    }

    func testSTAPA() {
        let payload: [UInt8] = [0x18, 0, 2, 0x67, 1, 0, 1, 0x68]
        var dp = H264Depacketizer()
        let aus = dp.push(RTPPacket(payloadType: 96, marker: true, sequenceNumber: 0, timestamp: 1, ssrc: 1, payload: payload))
        XCTAssertEqual(aus.first?.nalUnits, [[0x67, 1], [0x68]])
    }

    func testH265RoundTrip() {
        var pk = H265RTPPacketizer(ssrc: 1, mtu: 300, initialSequence: 65530)
        let vps: [UInt8] = [0x40, 0x01, 0x0C], idr: [UInt8] = [0x26, 0x01] + [UInt8](repeating: 0x5A, count: 3000)
        let packets = pk.packetize(nalUnits: [vps[...], idr[...]], timestamp: 90)
        var dp = H265Depacketizer()
        let aus = packets.flatMap { dp.push($0) }
        XCTAssertEqual(aus.count, 1)
        XCTAssertEqual(aus[0].nalUnits, [vps, idr])
        XCTAssertTrue(aus[0].isKeyframe)
    }

    func testAACRoundTrip() {
        var pk = AACRTPPacketizer(ssrc: 1, initialSequence: 0)
        let au = [UInt8](repeating: 0x21, count: 371)
        XCTAssertEqual(AACDepacketizer.accessUnits(pk.packetize(accessUnit: au, timestamp: 0)!), [au])
    }

    func testSDPParse() {
        let sdp = """
        v=0\r
        m=video 0 RTP/AVP 96\r
        a=rtpmap:96 H264/90000\r
        a=fmtp:96 packetization-mode=1;profile-level-id=640028;sprop-parameter-sets=Z2QAKA==,aO4=\r
        a=control:trackID=1\r
        m=audio 0 RTP/AVP 97\r
        a=rtpmap:97 MPEG4-GENERIC/48000/2\r
        a=fmtp:97 streamtype=5; mode=AAC-hbr; config=1190; sizelength=13; indexlength=3\r
        a=control:rtsp://cam/stream/trackID=2\r
        """
        let m = SDPParser.parse(sdp)
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m[0].codec, .h264)
        XCTAssertEqual(m[0].parameterSets, [[0x67, 0x64, 0, 0x28], [0x68, 0xEE]])
        XCTAssertEqual(m[1].codec, .aac)
        XCTAssertEqual(m[1].clockRate, 48000)
        XCTAssertEqual(m[1].channels, 2)
        XCTAssertEqual(m[1].aacConfig, [0x11, 0x90])
        XCTAssertEqual(SDPParser.resolve(control: m[0].control, base: "rtsp://cam/stream/"), "rtsp://cam/stream/trackID=1")
        XCTAssertEqual(SDPParser.resolve(control: m[1].control, base: "rtsp://cam/stream"), "rtsp://cam/stream/trackID=2")
    }

    func testDemuxer() {
        var d = RTSPStreamDemuxer()
        var frames = d.append(Data([0x24, 0, 0, 2, 0xAA]))
        XCTAssertTrue(frames.isEmpty)
        frames = d.append(Data([0xBB]) + Data("RTSP/1.0 200 OK\r\nCSeq: 3\r\n\r\n".utf8) + Data([0x24, 1, 0, 1, 0xCC]))
        XCTAssertEqual(frames.map { $0.0 }, [0, 1])
        XCTAssertEqual(frames[0].1, [0xAA, 0xBB])
        XCTAssertEqual(d.takeResponses().map(\.statusCode), [200])
    }
}

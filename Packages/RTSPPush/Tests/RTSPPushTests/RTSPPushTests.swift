import XCTest
@testable import RTSPPush

final class RTSPPushTests: XCTestCase {
    func testRTPHeader() {
        let p = RTPPacket(payloadType: 96, marker: true, sequenceNumber: 0x1234, timestamp: 0xAABBCCDD, ssrc: 0x01020304, payload: [9])
        XCTAssertEqual(p.serialized(), [0x80, 0xE0, 0x12, 0x34, 0xAA, 0xBB, 0xCC, 0xDD, 1, 2, 3, 4, 9])
    }

    func testSingleNAL() {
        var pk = H264RTPPacketizer(ssrc: 1, mtu: 1400, initialSequence: 10)
        let nal: [UInt8] = [0x65] + Array(repeating: 0xAB, count: 100)
        let out = pk.packetize(nalUnits: [nal[...]], timestamp: 3000)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].payload, nal)
        XCTAssertTrue(out[0].marker)
        XCTAssertEqual(pk.sequenceNumber, 11)
    }

    func testFUAReassembles() {
        var pk = H264RTPPacketizer(ssrc: 1, mtu: 100, initialSequence: 65535)
        let body = (0..<1000).map { UInt8($0 & 0xFF) }
        let nal: [UInt8] = [0x65] + body
        let out = pk.packetize(nalUnits: [nal[...]], timestamp: 0)
        XCTAssertGreaterThan(out.count, 1)
        XCTAssertTrue(out.allSatisfy { $0.serialized().count <= 100 })
        XCTAssertEqual(out.first!.payload[1] & 0x80, 0x80) // start
        XCTAssertEqual(out.last!.payload[1] & 0x40, 0x40)  // end
        XCTAssertEqual(out.filter(\.marker).count, 1)
        XCTAssertEqual(out[0].sequenceNumber, 65535)
        XCTAssertEqual(out[1].sequenceNumber, 0) // wraps
        var rebuilt: [UInt8] = [(out[0].payload[0] & 0xE0) | (out[0].payload[1] & 0x1F)]
        for p in out { rebuilt += p.payload[2...] }
        XCTAssertEqual(rebuilt, nal)
    }

    func testAVCCSplit() {
        let data: [UInt8] = [0, 0, 0, 2, 0x67, 1, 0, 0, 0, 1, 0x68]
        let nals = NALUnitSplitter.splitAVCC(data)
        XCTAssertEqual(nals.map(Array.init), [[0x67, 1], [0x68]])
    }

    func testAnnexBSplit() {
        let data: [UInt8] = [0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 2]
        XCTAssertEqual(NALUnitSplitter.splitAnnexB(data).map(Array.init), [[0x67, 1], [0x68, 2]])
    }

    func testAACPacket() {
        var pk = AACRTPPacketizer(ssrc: 1, initialSequence: 0)
        let au = [UInt8](repeating: 1, count: 300)
        let p = pk.packetize(accessUnit: au, timestamp: 1024)!
        XCTAssertEqual(Array(p.payload[0..<4]), [0x00, 0x10, UInt8((300 << 3) >> 8), UInt8((300 << 3) & 0xFF)])
        XCTAssertEqual(p.payload.count, 304)
    }

    func testASC() {
        // AAC-LC 48kHz stereo -> 0x1190
        XCTAssertEqual(SDPDescription.Audio.aacLC(sampleRate: 48000, channels: 2).audioSpecificConfig, [0x11, 0x90])
        XCTAssertEqual(SDPDescription.Audio.aacLC(sampleRate: 44100, channels: 2).audioSpecificConfig, [0x12, 0x10])
    }

    func testSDP() {
        let sdp = SDPDescription(video: .init(sps: [0x67, 0x64, 0x00, 0x28], pps: [0x68, 0xEE]),
                                 audio: .aacLC(sampleRate: 48000, channels: 2)).render()
        XCTAssertTrue(sdp.contains("profile-level-id=640028"))
        XCTAssertTrue(sdp.contains("sprop-parameter-sets=Z2QAKA==,aO4="))
        XCTAssertTrue(sdp.contains("MPEG4-GENERIC/48000/2"))
        XCTAssertTrue(sdp.contains("config=1190"))
    }

    func testResponseParse() {
        var buf = Data("$\u{01}\u{00}\u{02}xxRTSP/1.0 200 OK\r\nCSeq: 2\r\nSession: ABC;timeout=60\r\nContent-Length: 3\r\n\r\nabcRTSP/1.0".utf8)
        let r = RTSPResponse.parse(&buf)
        XCTAssertEqual(r?.statusCode, 200)
        XCTAssertEqual(r?.header("session"), "ABC;timeout=60")
        XCTAssertEqual(r?.body, Data("abc".utf8))
        XCTAssertEqual(String(data: buf, encoding: .utf8), "RTSP/1.0")
        XCTAssertNil(RTSPResponse.parse(&buf))
    }

    func testDigest() {
        // RFC 2617 §3.5 example.
        var a = RTSPAuthenticator(username: "Mufasa", password: "Circle Of Life")
        a.consume(challenge: "Digest realm=\"testrealm@host.com\", nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\"")
        let h = a.authorization(method: "GET", uri: "/dir/index.html")!
        XCTAssertTrue(h.contains("response=\"670fd8c2df070c60b045671b8b24ff02\""), h)
        XCTAssertEqual(MD5Fallback.hex(Array("abc".utf8)), "900150983cd24fb0d6963f7d28e17f72")
    }
}

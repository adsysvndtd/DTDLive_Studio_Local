import Foundation
import Network

/// PTZ camera control over the network, independent of NDI:
/// - VISCA over IP (Sony/most Chinese PTZ, UDP 52381, 8-byte header)
/// - VISCA over TCP (PTZOptics/Lumens "raw VISCA", TCP 5678)
struct PTZConfig: Codable, Equatable {
    enum Transport: String, Codable, CaseIterable { case viscaUDP, viscaTCP }
    var host: String
    var port: UInt16 = 52381
    var transport: Transport = .viscaUDP
    var address: UInt8 = 1   // VISCA camera address 1...7
}

actor PTZController {
    let config: PTZConfig
    private var connection: NWConnection?
    private var sequence: UInt32 = 0

    init(config: PTZConfig) { self.config = config }

    private func ensureConnection() -> NWConnection {
        if let c = connection { return c }
        let params: NWParameters = config.transport == .viscaUDP ? .udp : .tcp
        let c = NWConnection(host: NWEndpoint.Host(config.host), port: NWEndpoint.Port(rawValue: config.port)!, using: params)
        c.start(queue: .global(qos: .userInitiated))
        connection = c
        return c
    }

    private func send(_ visca: [UInt8]) {
        var packet = visca
        if config.transport == .viscaUDP {
            sequence &+= 1
            let len = UInt16(visca.count)
            // payload type 0x0100 = VISCA command
            packet = [0x01, 0x00, UInt8(len >> 8), UInt8(len & 0xFF)] + sequence.bigEndianBytesArray + visca
        }
        ensureConnection().send(content: Data(packet), completion: .idempotent)
    }

    private var head: UInt8 { 0x80 | (config.address & 0x07) }

    /// Continuous move. pan/tilt/zoom in -1...1 (0 stops that axis).
    func move(pan: Double, tilt: Double, zoom: Double) {
        let ps = UInt8(max(1, min(0x18, Int(abs(pan) * 0x18))))
        let ts = UInt8(max(1, min(0x14, Int(abs(tilt) * 0x14))))
        let h: UInt8 = pan < -0.05 ? 0x01 : pan > 0.05 ? 0x02 : 0x03
        let v: UInt8 = tilt > 0.05 ? 0x01 : tilt < -0.05 ? 0x02 : 0x03
        send([head, 0x01, 0x06, 0x01, ps, ts, h, v, 0xFF])
        let zs = UInt8(max(0, min(7, Int(abs(zoom) * 7))))
        let z: UInt8 = zoom > 0.05 ? 0x20 | zs : zoom < -0.05 ? 0x30 | zs : 0x00
        send([head, 0x01, 0x04, 0x07, z, 0xFF])
    }

    func stop() { move(pan: 0, tilt: 0, zoom: 0) }

    func recallPreset(_ n: Int) { send([head, 0x01, 0x04, 0x3F, 0x02, UInt8(n & 0x7F), 0xFF]) }
    func storePreset(_ n: Int) { send([head, 0x01, 0x04, 0x3F, 0x01, UInt8(n & 0x7F), 0xFF]) }
    func home() { send([head, 0x01, 0x06, 0x04, 0xFF]) }
    func autoFocus(_ on: Bool) { send([head, 0x01, 0x04, 0x38, on ? 0x02 : 0x03, 0xFF]) }

    /// Tally lamp on cameras that support it (Sony-style command; ignored by others).
    func tally(_ on: Bool) { send([head, 0x01, 0x7E, 0x01, 0x0A, 0x00, on ? 0x02 : 0x03, 0xFF]) }

    func close() { connection?.cancel(); connection = nil }
}

private extension UInt32 {
    var bigEndianBytesArray: [UInt8] { [UInt8(self >> 24), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)] }
}

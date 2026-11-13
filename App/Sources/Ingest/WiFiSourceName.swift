import Foundation

/// DTDPAIR1's display field is one 64-byte ASCII token. Keep the bond and Bonjour service unchanged.
enum WiFiSourceName {
    static func clean(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }
    static func valid(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 45 && !s.unicodeScalars.contains {
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ||
                $0.value == 0x2028 || $0.value == 0x2029
        }
    }
    static func token(_ name: String) -> String? {
        let s = clean(name)
        guard valid(s) else { return nil }
        return "n1." + Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func display(_ peer: String) -> String? {
        guard peer.hasPrefix("n1."), peer.utf8.count <= 63 else { return nil }
        var encoded = String(peer.dropFirst(3)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let s = String(data: data, encoding: .utf8),
              token(s) == peer else { return nil }
        return s
    }
}

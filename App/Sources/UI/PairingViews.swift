import SwiftUI

/// Incoming pairing request: the operator compares the 6-digit ID with the one shown on the
/// camera device and accepts — no code to type.
struct PairingBanner: View {
    @ObservedObject var pairing: PairingManager
    var compact = false

    var body: some View {
        if let r = pairing.pending.first {
            VStack(spacing: compact ? 8 : 12) {
                HStack(spacing: 10) {
                    Image(systemName: r.model.lowercased().contains("ipad") ? "ipad" : "iphone")
                        .font(.system(size: compact ? 22 : 28)).foregroundStyle(DS.accent2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Thiết bị muốn kết nối").font(.caption.weight(.bold)).foregroundStyle(DS.text2)
                        Text(r.deviceName).font(compact ? .subheadline.weight(.bold) : .headline)
                        Text([r.app, r.protocols.first?.uppercased()].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(DS.text3)
                    }
                    Spacer()
                    if pairing.pending.count > 1 { Pill(text: "+\(pairing.pending.count - 1)") }
                }
                VStack(spacing: 2) {
                    Text("ID xác nhận").font(.caption2).foregroundStyle(DS.text3)
                    Text(r.confirmCode).font(.system(size: compact ? 30 : 40, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white).tracking(2)
                    Text("Chỉ chấp nhận nếu ID này trùng với ID trên màn hình thiết bị").font(.caption2).foregroundStyle(DS.text2)
                }
                HStack(spacing: 10) {
                    Button { pairing.reject(r) } label: { Text("Từ chối").frame(maxWidth: .infinity, minHeight: 40) }
                        .buttonStyle(.bordered).tint(DS.text2)
                    Button { pairing.accept(r) } label: { Text("Chấp nhận").font(.headline).frame(maxWidth: .infinity, minHeight: 40) }
                        .buttonStyle(.borderedProminent).tint(DS.pvw)
                }
            }
            .padding(compact ? 12 : 18)
            .frame(width: compact ? 340 : 420)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(DS.accent2.opacity(0.6), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.5), radius: 20)
            .transition(.scale.combined(with: .opacity))
        }
    }
}

/// Trusted devices + how cameras find this studio.
struct PairedDevicesSection: View {
    @ObservedObject var pairing: PairingManager
    var port: UInt16

    var body: some View {
        SectionCard("Ghép nối qua Wi-Fi", systemImage: "wifi") {
            Text("Mở DTDLive (hoặc app hỗ trợ DTD pairing) trên cùng mạng Wi-Fi → chọn DTD Studio → so ID xác nhận → Chấp nhận. Không cần nhập mã.")
                .font(.caption).foregroundStyle(DS.text2)
            HStack {
                Label(NetworkInfo.wifiIPv4().map { "\($0):\(port)" } ?? "Chưa có Wi-Fi", systemImage: "network")
                    .font(.caption.monospaced()).foregroundStyle(DS.text2)
                Spacer()
                Toggle("Tự kết nối thiết bị tin cậy", isOn: $pairing.autoAcceptTrusted).font(.caption).fixedSize()
            }
            if pairing.trusted.isEmpty {
                Text("Chưa có thiết bị nào được ghép nối").font(.caption).foregroundStyle(DS.text3)
            }
            ForEach(pairing.trusted) { d in
                HStack {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(DS.pvw)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.name).font(.subheadline.weight(.semibold))
                        Text("\(d.protocolUsed.uppercased())\(d.protocolUsed == "srt" ? " · cổng \(d.srtPort)" : "") · \(d.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(DS.text3)
                    }
                    Spacer()
                    Button("Gỡ", role: .destructive) { pairing.forget(d) }.font(.caption).buttonStyle(.bordered)
                }
            }
        }
    }
}

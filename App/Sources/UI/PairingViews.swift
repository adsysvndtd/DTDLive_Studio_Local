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
            .background(DS.surface, in: Rectangle())
            .overlay(Rectangle().stroke(DS.accent2.opacity(0.6), lineWidth: 1.5))
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

/// Push-to-Studio addresses: one port per protocol, each camera uses its own stream key.
struct IngestSection: View {
    @ObservedObject var ingest: IngestHub
    @ObservedObject var pairing: PairingManager

    var body: some View {
        SectionCard("Nhận camera (đẩy về DTD Studio)", systemImage: "antenna.radiowaves.left.and.right") {
            Text("Mỗi giao thức dùng chung một cổng; mỗi camera đặt một stream key riêng (cam1, cam2…) và tự hiện thành một nguồn.")
                .font(.caption).foregroundStyle(DS.text2)
            let ip = NetworkInfo.wifiIPv4() ?? "<IP iPad>"
            ForEach(ingest.urls(ip: ip)) { u in
                HStack(spacing: 8) {
                    Text(u.proto).font(.caption.weight(.heavy)).frame(width: 44, alignment: .leading).foregroundStyle(DS.accent)
                    Text(u.url).font(.caption.monospaced()).foregroundStyle(DS.text2).textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    if let err = ingest.listenErrors[u.proto.lowercased()] {
                        Label("lỗi cổng", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(DS.pgm).help(err)
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(DS.pvw)
                Text(ingest.dtdLive.listening ? "DTDLive: đang hiện tên \(DTDLiveLink.serviceName) — trên DTDLive chọn Gửi tới máy khác › \(DTDLiveLink.serviceName), so mã 6 số rồi Chấp nhận"
                                              : "DTDLive: đang tắt")
                    .font(.caption).foregroundStyle(DS.text2)
            }
            if !ingest.streams.isEmpty {
                Divider().overlay(DS.stroke)
                ForEach(ingest.streams) { s in
                    HStack(spacing: 8) {
                        Circle().fill(s.online ? Color.green : DS.text3).frame(width: 8, height: 8)
                        Text("\(s.proto.uppercased()) · \(s.key)").font(.caption.weight(.semibold))
                        Text(s.peer).font(.caption2.monospaced()).foregroundStyle(DS.text3)
                        Spacer()
                    }
                }
            }
        }
    }
}

/// Settings rows for the ingest servers (ports, SRT passphrase, protocol switches).
struct IngestSettingsRows: View {
    @ObservedObject var ingest: IngestHub
    @State private var draft = IngestHub.Settings()
    @State private var loaded = false

    var body: some View {
        Group {
            Toggle("SRT (một cổng, nhiều streamid)", isOn: $draft.srtEnabled)
            if draft.srtEnabled {
                portRow("Cổng SRT", $draft.srtPort)
                TextField("Mật khẩu SRT (để trống = không mã hoá, 10–79 ký tự)", text: $draft.srtPassphrase)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Stepper("Độ trễ SRT \(draft.srtLatencyMs) ms", value: $draft.srtLatencyMs, in: 20...2000, step: 20)
            }
            Toggle("RTMP (một cổng, nhiều stream key)", isOn: $draft.rtmpEnabled)
            if draft.rtmpEnabled { portRow("Cổng RTMP", $draft.rtmpPort) }
            Toggle("RTSP (ANNOUNCE/RECORD, nhiều đường dẫn)", isOn: $draft.rtspEnabled)
            if draft.rtspEnabled { portRow("Cổng RTSP", $draft.rtspPort) }
            Toggle("Cho phép DTDLive tìm và ghép nối", isOn: $draft.dtdLiveEnabled)
            if draft != ingest.settings {
                Button("Áp dụng (khởi động lại máy chủ nhận)") { ingest.settings = draft }
                    .disabled(!draft.srtPassphrase.isEmpty && !(10...79).contains(draft.srtPassphrase.count))
            }
            Button("Quên mọi DTDLive đã ghép", role: .destructive) { ingest.dtdLive.forgetAll() }
        }
        .onAppear { if !loaded { draft = ingest.settings; loaded = true } }
    }

    private func portRow(_ title: String, _ v: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: v, format: .number.grouping(.never))
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
        }
    }
}

import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var engine: StudioEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Chương trình (Program)") {
                    Picker("Độ phân giải", selection: Binding(
                        get: { engine.format.resolutionID },
                        set: { id in if let r = ProgramFormat.resolutions.first(where: { $0.id == id }) { engine.format.width = r.width; engine.format.height = r.height } })) {
                        ForEach(ProgramFormat.resolutions) { Text($0.label).tag($0.id) }
                    }
                    Picker("Tốc độ khung", selection: $engine.format.fps) {
                        ForEach(ProgramFormat.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    Picker("Codec", selection: $engine.encoder.codec) {
                        ForEach(VideoCodecChoice.allCases) { Text($0.label).tag($0) }
                    }
                    Stepper(String(format: "Bitrate: %.1f Mbps", Double(engine.encoder.bitrate) / 1e6),
                            value: $engine.encoder.bitrate, in: 1_000_000...40_000_000, step: 500_000)
                    Toggle("Bitrate thích ứng", isOn: $engine.encoder.adaptive)
                    Text("Đổi độ phân giải/fps khi đang phát: các đích tự kết nối lại với thông số mới.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Âm thanh") {
                    Picker("Đầu vào", selection: Binding(get: { engine.audioInputID ?? "" }, set: { engine.setAudioInput($0.isEmpty ? nil : $0) })) {
                        Text("Mặc định").tag("")
                        ForEach(engine.audioInputs) { Text($0.name).tag($0.id) }
                    }
                    Toggle("Nghe Program (tai nghe)", isOn: Binding(get: { engine.monitorProgram }, set: { engine.monitorProgram = $0 }))
                    Text("Chỉ bật khi dùng tai nghe — loa ngoài sẽ hú vào micro.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Màn hình") {
                    Toggle("Khung an toàn trên PVW/PGM", isOn: $engine.showSafeGuides)
                    Toggle("Thông số trên PGM", isOn: $engine.showMonitorInfo)
                    if engine.externalDisplayConnected {
                        Picker("Màn hình ngoài", selection: $engine.externalMode) {
                            Text("Program").tag(StudioEngine.ExternalMode.program)
                            Text("Multiview").tag(StudioEngine.ExternalMode.multiview)
                        }
                    }
                }
                Section("Điều khiển từ xa & ghép nối") {
                    let ip = NetworkInfo.wifiIPv4() ?? "—"
                    LabeledContent("Web remote", value: "http://\(ip):\(engine.controlPort)")
                    LabeledContent("OSC (UDP)", value: "\(ip):8000")
                    LabeledContent("Ghép nối camera", value: "Bonjour _dtdstudio._tcp")
                    Toggle("Tự kết nối thiết bị tin cậy", isOn: Binding(get: { engine.pairing.autoAcceptTrusted }, set: { engine.pairing.autoAcceptTrusted = $0 }))
                }
                .textSelection(.enabled)
                Section("Giới thiệu") {
                    LabeledContent("Ứng dụng", value: "DTD Studio")
                    LabeledContent("Phiên bản", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
                    LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "")
                    LabeledContent("NDI", value: NDIAvailability.isAvailable ? "Có" : "Chưa tích hợp SDK")
                }
            }
            .navigationTitle("Cài đặt")
            .toolbar { Button("Xong") { dismiss() } }
        }
    }
}

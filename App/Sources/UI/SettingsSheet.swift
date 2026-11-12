import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var engine: StudioEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsForm(engine: engine)
            .navigationTitle("Cài đặt")
            .toolbar { Button("Xong") { dismiss() } }
        }
    }
}

/// Settings content, shown both as a sheet and inline in the "Cài đặt" sidebar category.
struct SettingsForm: View {
    @ObservedObject var engine: StudioEngine
    var onOpenOutputs: (() -> Void)? = nil

    var body: some View {
            Form {
                Section(header: SettingsHeader("Phát trực tiếp")) {
                    if engine.outputs.isEmpty {
                        Text("Chưa có đích phát").foregroundStyle(.secondary)
                    }
                    ForEach(engine.outputs) { o in
                        LabeledContent(o.name.isEmpty ? o.proto.label : o.name, value: o.proto.label)
                    }
                    if let onOpenOutputs {
                        Button { onOpenOutputs() } label: { Label("Quản lý đích phát (RTMP · SRT · RTSP · YouTube · Facebook)", systemImage: "dot.radiowaves.left.and.right") }
                    }
                }
                Section(header: SettingsHeader("Chương trình (Program)")) {
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
                        .foregroundStyle(.secondary)
                }
                Section(header: SettingsHeader("Âm thanh")) {
                    Picker("Đầu vào", selection: Binding(get: { engine.audioInputID ?? "" }, set: { engine.setAudioInput($0.isEmpty ? nil : $0) })) {
                        Text("Mặc định").tag("")
                        ForEach(engine.audioInputs) { Text($0.name).tag($0.id) }
                    }
                    Toggle("Nghe nhạc, hiệu ứng, video trên loa máy", isOn: Binding(get: { engine.speakerMonitor }, set: { engine.speakerMonitor = $0 }))
                    Toggle("Nghe Program (tai nghe)", isOn: Binding(get: { engine.monitorProgram }, set: { engine.monitorProgram = $0 }))
                    VStack(alignment: .leading) {
                        Text("Trễ âm thanh Mic/Line: \(Int(engine.micDelayMs)) ms")
                        Slider(value: Binding(get: { engine.micDelayMs }, set: { engine.micDelayMs = $0 }), in: 0...500, step: 10)
                        Text("Kéo cho tiếng khớp với hình khi camera mạng bị trễ.").foregroundStyle(.secondary)
                    }
                    Text("Chỉ bật khi dùng tai nghe — loa ngoài sẽ hú vào micro.").foregroundStyle(.secondary)
                }
                Section(header: SettingsHeader("Thao tác")) {
                    Toggle("Vuốt PVW → PGM để chuyển", isOn: $engine.swipeToTake)
                    Text("Vuốt 1 ngón trên PVW về phía PGM = CUT · 2 ngón = AUTO").foregroundStyle(.secondary)
                }
                Section(header: SettingsHeader("Màn hình")) {
                    Toggle("Khung an toàn trên PVW/PGM", isOn: $engine.showSafeGuides)
                    Toggle("Khung an toàn trên màn hình ngoài", isOn: $engine.externalSafeGuides)
                    Toggle("Thông số trên PGM", isOn: $engine.showMonitorInfo)
                    if engine.externalDisplayConnected {
                        Picker("Màn hình ngoài", selection: $engine.externalMode) {
                            Text("Program").tag(StudioEngine.ExternalMode.program)
                            Text("Multiview").tag(StudioEngine.ExternalMode.multiview)
                        }
                    }
                }
                Section(header: SettingsHeader("Nhận camera: SRT · RTMP · RTSP · DTDLive")) {
                    IngestSettingsRows(ingest: engine.ingest)
                    let ip = NetworkInfo.wifiIPv4() ?? "<IP iPad>"
                    ForEach(engine.ingest.urls(ip: ip)) { u in
                        LabeledContent(u.proto, value: u.url)
                    }
                }
                .textSelection(.enabled)
                Section(header: SettingsHeader("Ngôn ngữ")) {
                    LanguagePicker()
                }
                Section(header: SettingsHeader("Tạo phiên live YouTube / Facebook")) {
                    PlatformKeyField(title: "Google OAuth Client ID (loại iOS)", key: PlatformLive.googleKey,
                                     hint: "xxxx.apps.googleusercontent.com — Google Cloud › Credentials, bật YouTube Data API v3")
                    PlatformKeyField(title: "Facebook App ID", key: PlatformLive.facebookKey,
                                     hint: "developers.facebook.com › App › quyền publish_video")
                    Text("Không muốn đăng ký app: dùng Đầu ra › Thêm đích › YouTube/Facebook (stream key).")
                        .foregroundStyle(.secondary)
                }
                Section(header: SettingsHeader("Đồ hoạ HTML5 (tải từ Git)")) {
                    GraphicsRepoRows(repo: engine.graphicsRepo)
                }
                Section(header: SettingsHeader("Điều khiển từ xa & ghép nối")) {
                    let ip = NetworkInfo.wifiIPv4() ?? "—"
                    LabeledContent("Web remote", value: "http://\(ip):\(engine.controlPort)")
                    LabeledContent("OSC (UDP)", value: "\(ip):8000")
                    LabeledContent("Ghép nối camera", value: "Bonjour _dtdstudio._tcp")
                    Toggle("Tự kết nối thiết bị tin cậy", isOn: Binding(get: { engine.pairing.autoAcceptTrusted }, set: { engine.pairing.autoAcceptTrusted = $0 }))
                }
                .textSelection(.enabled)
                Section(header: SettingsHeader("Giới thiệu")) {
                    LabeledContent("Ứng dụng", value: "DTD Studio")
                    LabeledContent("Phiên bản", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
                    LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "")
                    LabeledContent("NDI", value: NDIAvailability.isAvailable ? "Có" : "Chưa tích hợp SDK")
                }
            }
            .font(DS.settingsFont)
            .scrollContentBackground(.hidden)
            .background(DS.bg)
    }
}


/// One platform ID stored in UserDefaults (read by PlatformLive).
struct PlatformKeyField: View {
    let title: String
    let key: String
    let hint: String
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: $value)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onAppear { value = UserDefaults.standard.string(forKey: key) ?? "" }
                .onChange(of: value) { _, v in
                    UserDefaults.standard.set(v.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key)
                }
            Text(hint).foregroundStyle(.secondary)
        }
    }
}


/// In-app language (Tiếng Việt / English / follow iOS). Takes effect on next launch.
struct LanguagePicker: View {
    @AppStorage("dtd.language") private var lang = "system"
    @State private var changed = false
    var body: some View {
        Picker("Ngôn ngữ", selection: $lang) {
            Text(verbatim: "Theo iOS / System").tag("system")
            Text(verbatim: "Tiếng Việt").tag("vi")
            Text(verbatim: "English").tag("en")
        }
        .onChange(of: lang) { _, v in
            if v == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
            else { UserDefaults.standard.set([v], forKey: "AppleLanguages") }
            changed = true
        }
        if changed {
            Text(verbatim: "Mở lại app để đổi ngôn ngữ · Relaunch the app to apply").foregroundStyle(.secondary)
        }
    }
}

/// Settings section header — same size as every row (only colour/weight differ).
struct SettingsHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(LocalizedStringKey(title)).font(DS.settingsFont.weight(.semibold)).textCase(nil).foregroundStyle(DS.text2)
    }
}

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
                    BitrateControl(bitrate: $engine.encoder.bitrate)
                    let rec = StudioEngine.recommendedBitrate(engine.format, codec: engine.encoder.codec)
                    HStack {
                        Text(LF("Khuyến nghị cho %@×%@ %@ fps: %@ Mbps", "\(engine.format.width)", "\(engine.format.height)",
                                "\(engine.format.fps)", String(format: "%.1f", Double(rec) / 1e6)))
                            .foregroundStyle(engine.encoder.bitrate < rec * 3 / 4 ? .orange : .secondary)
                        Spacer()
                        if engine.encoder.bitrate != rec { Button("Dùng mức này") { engine.encoder.bitrate = rec } }
                    }
                    if engine.encoder.bitrate < rec * 3 / 4 {
                        Text("Bitrate thấp so với độ phân giải → hình trên YouTube/Facebook sẽ mờ, nhất là cảnh chuyển động.")
                            .foregroundStyle(.orange)
                    }
                    Button { engine.optimizeForBestQuality() } label: {
                        Label("Tối ưu chất lượng tốt nhất cho các đích phát", systemImage: "wand.and.stars")
                    }
                    Text("Đặt bitrate cao nhất YouTube khuyến nghị (Facebook: không vượt mức tối đa Facebook nhận), GOP 2 s, H.264 nếu có Facebook, bitrate thích ứng không xuống dưới 70 %.")
                        .foregroundStyle(.secondary)
                    Toggle("B-frame", isOn: $engine.encoder.bFrames)
                    Text("Bật: hình nét hơn ~10–15 % ở cùng bitrate (YouTube khuyến nghị), trễ thêm ~2 khung. Tắt: trễ thấp nhất, tương thích mọi máy chủ. Đổi khi đang phát: các đích tự kết nối lại.")
                        .foregroundStyle(.secondary)
                    Toggle("Bitrate thích ứng", isOn: $engine.encoder.adaptive)
                    Text("Bật: mạng chậm thì tự giảm bitrate (hình mềm hơn nhưng không đứng). Tắt: giữ nét, mạng chậm thì bỏ khung hình.")
                        .foregroundStyle(.secondary)
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
                Section(header: SettingsHeader("Tài khoản phát trực tiếp")) {
                    PlatformAccountRow(platform: .youtube)
                    PlatformAccountRow(platform: .facebook)
                    Text("Đăng nhập một lần; ở Đầu ra bấm Tạo live YouTube/Facebook để tự lấy URL + stream key.")
                        .foregroundStyle(.secondary)
                }
                Section(header: SettingsHeader("Tạo phiên live YouTube / Facebook")) {
                    PlatformKeyField(title: "Google OAuth Client ID (loại iOS)", key: PlatformLive.googleKey,
                                     hint: "xxxx.apps.googleusercontent.com — Google Cloud › Credentials, bật YouTube Data API v3")
                    PlatformKeyField(title: "Facebook App ID", key: PlatformLive.facebookKey,
                                     hint: "developers.facebook.com › App › quyền publish_video")
                    Text("Không muốn đăng ký app: dùng Đầu ra › Thêm đích › YouTube/Facebook (stream key).")
                        .foregroundStyle(.secondary)
                }
                Section(header: SettingsHeader("NDI®")) {
                    if NDIAvailability.isAvailable {
                        Toggle("Phát PGM qua NDI", isOn: $engine.ndiOutputOn)
                        TextField("Tên nguồn NDI", text: $engine.ndiName)
                        Text("Máy khác trong mạng (vMix, OBS, TriCaster…) thấy nguồn này. NDI® là thương hiệu của Vizrt NDI AB.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Chưa có NDI SDK. Trên Mac: cài \"NDI SDK for Apple\" từ ndi.video, chạy scripts/ndi-setup.sh rồi build lại — nhận & phát NDI sẽ tự bật.")
                            .foregroundStyle(.secondary)
                    }
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
                    // read from Info.plist directly (Bundle.main is re-classed for the in-app language switch)
                    let bid = (Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String)
                        ?? Bundle.main.bundleIdentifier ?? "vn.com.dtdsolution.DTDStudio"
                    HStack {
                        Text("Bundle ID")
                        Spacer(minLength: 12)
                        Text(verbatim: bid).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
                    }
                    LabeledContent("NDI®", value: L(NDIAvailability.isAvailable ? "Có" : "Chưa tích hợp SDK"))
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
    @AppStorage(AppLanguage.key) private var lang = "system"
    var body: some View {
        Picker("Ngôn ngữ", selection: Binding(get: { lang }, set: { v in
            AppLanguage.apply(v)   // switch the bundle first…
            lang = v               // …then the root view rebuilds in the new language
        })) {
            Text(verbatim: "Theo iOS / System").tag("system")
            Text(verbatim: "Tiếng Việt").tag("vi")
            Text(verbatim: "English").tag("en")
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

/// Sign in / out of YouTube or Facebook; shows the account name.
struct PlatformAccountRow: View {
    let platform: PlatformLive.Platform
    @ObservedObject private var live = PlatformLive.shared
    @State private var busy = false
    @State private var error: String?

    private var account: String? { platform == .youtube ? live.youtubeAccount : live.facebookAccount }
    private var signedIn: Bool { platform == .youtube ? live.youtubeSignedIn : live.facebookSignedIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: platform == .youtube ? "play.rectangle.fill" : "f.square.fill")
                    .foregroundStyle(platform == .youtube ? Color.red : Color.blue)
                Text(verbatim: platform == .youtube ? "YouTube" : "Facebook")
                Spacer()
                if busy { ProgressView() }
                else if signedIn, let account {
                    Text(verbatim: account).foregroundStyle(.secondary).lineLimit(1)
                    Button("Đăng xuất", role: .destructive) { live.signOut(platform) }
                } else {
                    Button("Đăng nhập") { signIn() }
                }
            }
            if let error { Text(verbatim: error).foregroundStyle(.red) }
        }
    }

    private func signIn() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await live.signIn(platform) } catch { self.error = error.localizedDescription }
        }
    }
}

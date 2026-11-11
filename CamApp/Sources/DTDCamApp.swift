@preconcurrency import AVFoundation
import HaishinKit
import Network
import RTMPHaishinKit
import SRTHaishinKit
import SwiftUI
import VideoToolbox

/// DTD Cam — companion camera app for iPhone/iPad.
/// Streams the camera to DTD Studio over SRT (default) or RTMP, shows tally
/// (red = on program, green = on preview) by polling the studio's HTTP API,
/// and discovers studios on the LAN via Bonjour.
@main
struct DTDCamApp: App {
    var body: some Scene {
        WindowGroup { CamView().preferredColorScheme(.dark) }
    }
}

@MainActor
final class CamModel: ObservableObject {
    enum Tally { case none, preview, program }

    @Published var studios: [String: String] = [:]  // name -> host
    @Published var studioHost = ""
    @Published var cameraName = UIDevice.current.name
    @Published var useSRT = true
    @Published var bitrate = 8_000_000
    @Published var isStreaming = false
    @Published var status = "Chưa kết nối"
    @Published var tally: Tally = .none
    @Published var useFront = false

    let mixer = MediaMixer()
    private var srtConnection: SRTConnection?
    private var srtStream: SRTStream?
    private var rtmpConnection: RTMPConnection?
    private var rtmpStream: RTMPStream?
    private var browser: NWBrowser?
    private var tallyTimer: Timer?

    init() {
        UIApplication.shared.isIdleTimerDisabled = true
        Task { await setupCapture() }
        browse()
    }

    func setupCapture() async {
        await mixer.setSessionPreset(.hd1920x1080)
        let pos: AVCaptureDevice.Position = useFront ? .front : .back
        try? await mixer.attachVideo(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos))
        try? await mixer.attachAudio(AVCaptureDevice.default(for: .audio))
        await mixer.startRunning()
    }

    func flipCamera() {
        useFront.toggle()
        Task { try? await mixer.attachVideo(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: useFront ? .front : .back)) }
    }

    /// Bonjour: DTD Studio advertises "_http._tcp" named "DTD Studio".
    private func browse() {
        let b = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint, name.hasPrefix("DTD Studio") else { continue }
                let c = NWConnection(to: r.endpoint, using: .tcp)
                c.stateUpdateHandler = { st in
                    if case .ready = st, case let .hostPort(host, _)? = c.currentPath?.remoteEndpoint {
                        let h = "\(host)".components(separatedBy: "%").first ?? "\(host)"
                        Task { @MainActor in
                            self?.studios[name] = h
                            if self?.studioHost.isEmpty == true { self?.studioHost = h }
                        }
                        c.cancel()
                    }
                }
                c.start(queue: .main)
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func toggleStream() {
        Task { isStreaming ? await stop() : await start() }
    }

    private func start() async {
        guard !studioHost.isEmpty else { status = "Chưa có địa chỉ studio"; return }
        let video = VideoCodecSettings(videoSize: CGSize(width: 1920, height: 1080), bitRate: bitrate,
                                       profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
                                       maxKeyFrameIntervalDuration: 1)
        status = "Đang kết nối…"
        do {
            if useSRT {
                // Studio side: add an SRT input "srt://0.0.0.0:<port>?mode=listener"; default port 9001.
                let c = SRTConnection(), s = SRTStream(connection: c)
                try await s.setVideoSettings(video)
                await mixer.addOutput(s)
                try await c.connect(URL(string: "srt://\(studioHost):9001?mode=caller&latency=120000&streamid=\(cameraName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "cam")"))
                await s.publish()
                srtConnection = c; srtStream = s
            } else {
                let c = RTMPConnection(), s = RTMPStream(connection: c)
                try await s.setVideoSettings(video)
                await mixer.addOutput(s)
                _ = try await c.connect("rtmp://\(studioHost)/live")
                _ = try await s.publish(cameraName)
                rtmpConnection = c; rtmpStream = s
            }
            isStreaming = true
            status = "Đang phát tới \(studioHost)"
            startTally()
        } catch {
            status = "Lỗi: \(error)"
            await stop()
        }
    }

    private func stop() async {
        tallyTimer?.invalidate(); tally = .none
        if let s = srtStream { await mixer.removeOutput(s); await s.close() }
        await srtConnection?.close()
        if let s = rtmpStream { await mixer.removeOutput(s); _ = try? await s.close() }
        try? await rtmpConnection?.close()
        srtStream = nil; srtConnection = nil; rtmpStream = nil; rtmpConnection = nil
        isStreaming = false
        if !status.hasPrefix("Lỗi") { status = "Đã dừng" }
    }

    private func startTally() {
        tallyTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollTally() }
        }
    }

    private func pollTally() async {
        let name = cameraName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "http://\(studioHost):8080/api/tally?name=\(name)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else { return }
        tally = obj["program"] == true ? .program : obj["preview"] == true ? .preview : .none
    }
}

struct CamView: View {
    @StateObject private var m = CamModel()

    var body: some View {
        ZStack {
            MTHKViewRepresentable(previewSource: MixerPreview(mixer: m.mixer), videoGravity: .resizeAspect)
                .ignoresSafeArea()
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(m.tally == .program ? Color.red : m.tally == .preview ? Color.green : .clear, lineWidth: 14)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Text(m.tally == .program ? "ON AIR" : m.tally == .preview ? "PREVIEW" : "")
                        .font(.headline.bold()).padding(6)
                        .background(m.tally == .program ? Color.red : Color.green.opacity(m.tally == .preview ? 1 : 0))
                    Spacer()
                    Text(m.status).font(.caption).padding(6).background(.black.opacity(0.5))
                }
                Spacer()
                HStack(spacing: 12) {
                    Menu {
                        ForEach(m.studios.keys.sorted(), id: \.self) { k in Button(k) { m.studioHost = m.studios[k] ?? "" } }
                    } label: { Image(systemName: "antenna.radiowaves.left.and.right") }
                    TextField("IP studio", text: $m.studioHost).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                    TextField("Tên camera", text: $m.cameraName).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                    Picker("", selection: $m.useSRT) { Text("SRT").tag(true); Text("RTMP").tag(false) }.pickerStyle(.segmented).frame(width: 130)
                    Button { m.flipCamera() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera") }
                    Button(m.isStreaming ? "Dừng" : "Phát") { m.toggleStream() }
                        .buttonStyle(.borderedProminent).tint(m.isStreaming ? .red : .accentColor)
                }
                .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
    }
}

struct MixerPreview: MTHKViewRepresentable.PreviewSource {
    let mixer: MediaMixer
    func connect(to view: MTHKView) { Task { await mixer.addOutput(view) } }
}

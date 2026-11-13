import CoreImage
import SwiftUI
import UIKit

/// One live-chat comment (YouTube now; Facebook once the app passes Meta's review).
struct ChatMessage: Identifiable, Equatable {
    enum Platform: String { case youtube, facebook }
    let id: String
    let platform: Platform
    let author: String
    let text: String
    let avatarURL: URL?
    /// Super Chat / Super Sticker amount text ("₫50.000"), nil for normal messages.
    let amount: String?
    let at: Date
}

/// Look of the chat overlay on PGM (kept between launches).
struct ChatOverlayStyle: Codable, Equatable {
    var rightSide = false
    var maxVisible = 5
    var duration: Double = 12      // seconds each comment stays
    var scale: Double = 1
    var bottom: Double = 120        // px at 1080p from the bottom edge
    var opacity: Double = 0.82      // bubble background
    var showAvatar = true
    var accentHex = "#FF3B30"
    var width: Double = 620         // max bubble width, px at 1080p
}

/// Polls YouTube live chat and feeds the overlay: automatically (every new comment) or by hand (tap a comment).
@MainActor
final class LiveChat: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published var overlayOn = false { didSet { renderer.setVisible(overlayOn) } }
    @Published var auto: Bool = UserDefaults.standard.object(forKey: "dtd.chat.auto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(auto, forKey: "dtd.chat.auto") }
    }
    @Published var style = ChatOverlayStyle() {
        didSet {
            if let d = try? JSONEncoder().encode(style) { UserDefaults.standard.set(d, forKey: "dtd.chat.style") }
            renderer.setStyle(style)
        }
    }
    /// Optional YouTube video link / ID (otherwise: the signed-in channel's active live).
    @Published var videoInput: String = UserDefaults.standard.string(forKey: "dtd.chat.video") ?? "" {
        didSet { UserDefaults.standard.set(videoInput, forKey: "dtd.chat.video") }
    }
    /// Comment IDs already put on PGM (shown ticked in the list).
    @Published private(set) var shownIDs: Set<String> = []
    /// Which platforms' comments are fetched, listed and put on PGM.
    @Published var useYouTube: Bool = UserDefaults.standard.object(forKey: "dtd.chat.yt") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useYouTube, forKey: "dtd.chat.yt"); if running { restart() } }
    }
    @Published var useFacebook: Bool = UserDefaults.standard.object(forKey: "dtd.chat.fb") as? Bool ?? false {
        didSet { UserDefaults.standard.set(useFacebook, forKey: "dtd.chat.fb"); if running { restart() } }
    }
    /// Optional Facebook live video ID / link (otherwise: the signed-in user's current live video).
    @Published var fbVideoInput: String = UserDefaults.standard.string(forKey: "dtd.chat.fbvideo") ?? "" {
        didSet { UserDefaults.standard.set(fbVideoInput, forKey: "dtd.chat.fbvideo") }
    }
    @Published private(set) var ytStatus = ""
    @Published private(set) var fbStatus = ""
    /// Comments of the enabled platforms (list + auto mode).
    var visibleMessages: [ChatMessage] {
        messages.filter { ($0.platform == .youtube && useYouTube) || ($0.platform == .facebook && useFacebook) }
    }

    let renderer = ChatOverlayRenderer()
    private var tasks: [Task<Void, Never>] = []
    private var avatars: [URL: UIImage] = [:]

    init() {
        if let d = UserDefaults.standard.data(forKey: "dtd.chat.style"), let s = try? JSONDecoder().decode(ChatOverlayStyle.self, from: d) { style = s }
        renderer.setStyle(style)
    }

    func start() {
        guard !running else { return }
        guard useYouTube || useFacebook else { status = L("Chọn ít nhất một nền tảng"); return }
        running = true
        status = ""
        if useYouTube { ytStatus = L("Đang tìm buổi live…"); tasks.append(Task { await self.youtubeLoop() }) }
        if useFacebook { fbStatus = L("Đang tìm buổi live…"); tasks.append(Task { await self.facebookLoop() }) }
    }

    func stop() {
        tasks.forEach { $0.cancel() }; tasks = []
        running = false
        ytStatus = ""; fbStatus = ""
        status = L("Đã dừng")
    }

    private func restart() { stop(); start() }

    /// Adds fetched comments; in auto mode new ones (not the backlog found on connect) go on PGM.
    private func ingest(_ new: [ChatMessage], backlog: Bool) {
        let fresh = new.filter { m in !messages.contains(where: { $0.id == m.id }) }
        guard !fresh.isEmpty else { return }
        messages.append(contentsOf: fresh)
        messages.sort { $0.at < $1.at }
        if messages.count > 400 { messages.removeFirst(messages.count - 400) }
        if auto, !backlog {
            for m in fresh where (m.platform == .youtube && useYouTube) || (m.platform == .facebook && useFacebook) { show(m) }
        }
    }

    /// Puts one comment on PGM (manual pick, or called for each new comment in auto mode).
    func show(_ m: ChatMessage) {
        shownIDs.insert(m.id)
        if !overlayOn { overlayOn = true }
        Task {
            let avatar = style.showAvatar ? await self.avatar(m.avatarURL) : nil
            self.renderer.push(m, avatar: avatar)
        }
    }

    func clearOverlay() { renderer.clear() }

    // MARK: YouTube

    private func youtubeLoop() async {
        do {
            let chatID = try await findChatID()
            ytStatus = L("Đang nhận")
            var page: String?
            var first = true
            while !Task.isCancelled {
                var url = "https://www.googleapis.com/youtube/v3/liveChat/messages?liveChatId=\(chatID)&part=snippet,authorDetails&maxResults=200"
                if let page { url += "&pageToken=\(page)" }
                let j = try await PlatformLive.shared.youtubeGET(url)
                page = j["nextPageToken"] as? String
                ingest(((j["items"] as? [[String: Any]]) ?? []).compactMap(Self.parse), backlog: first)
                first = false
                let wait = max(5.0, Double((j["pollingIntervalMillis"] as? Int) ?? 5000) / 1000)
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        } catch is CancellationError {
        } catch {
            ytStatus = LF("Lỗi: %@", error.localizedDescription)
        }
    }

    // MARK: Facebook (Graph API: comments of a live video)

    private func facebookLoop() async {
        do {
            let vid = try await findFacebookVideo()
            fbStatus = L("Đang nhận")
            var first = true
            while !Task.isCancelled {
                let j = try await PlatformLive.shared.facebookGET(
                    "\(vid)/comments?fields=id,message,created_time,from%7Bname,picture%7D&order=reverse_chronological&live_filter=no_filter&limit=50")
                let items = ((j["data"] as? [[String: Any]]) ?? []).compactMap(Self.parseFacebook)
                ingest(items, backlog: first)
                first = false
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        } catch is CancellationError {
        } catch {
            fbStatus = LF("Lỗi: %@", error.localizedDescription)
        }
    }

    private func findFacebookVideo() async throws -> String {
        let v = fbVideoInput.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty {
            // link like facebook.com/…/videos/123456 or a bare ID
            let digits = v.split(whereSeparator: { !$0.isNumber }).map(String.init).filter { $0.count >= 8 }
            return digits.last ?? v
        }
        let j = try await PlatformLive.shared.facebookGET("me/live_videos?broadcast_status=%5B%22LIVE%22%5D&fields=id,video%7Bid%7D&limit=1")
        if let first = (j["data"] as? [[String: Any]])?.first {
            if let video = first["video"] as? [String: Any], let id = video["id"] as? String { return id }
            if let id = first["id"] as? String { return id }
        }
        throw NSError(domain: "dtd", code: 3, userInfo: [NSLocalizedDescriptionKey:
            L("Không thấy live Facebook đang chạy — dán link/ID video live vào ô Facebook")])
    }

    private static func parseFacebook(_ it: [String: Any]) -> ChatMessage? {
        guard let id = it["id"] as? String, let text = it["message"] as? String, !text.isEmpty else { return nil }
        let from = it["from"] as? [String: Any]
        let pic = ((from?["picture"] as? [String: Any])?["data"] as? [String: Any])?["url"] as? String
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        let date = (it["created_time"] as? String).flatMap { fmt.date(from: $0) } ?? Date()
        return ChatMessage(id: "fb:" + id, platform: .facebook, author: (from?["name"] as? String) ?? "Facebook",
                           text: text, avatarURL: pic.flatMap(URL.init(string:)), amount: nil, at: date)
    }

    private func findChatID() async throws -> String {
        let v = videoInput.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty {
            let id = Self.videoID(v)
            let j = try await PlatformLive.shared.youtubeGET("https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=\(id)")
            if let d = ((j["items"] as? [[String: Any]])?.first?["liveStreamingDetails"]) as? [String: Any],
               let chat = d["activeLiveChatId"] as? String { return chat }
            throw NSError(domain: "dtd", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Video này không có chat trực tiếp đang mở")])
        }
        for st in ["active", "upcoming"] {
            let j = try await PlatformLive.shared.youtubeGET(
                "https://www.googleapis.com/youtube/v3/liveBroadcasts?part=snippet&broadcastStatus=\(st)&broadcastType=all&maxResults=5")
            if let s = ((j["items"] as? [[String: Any]])?.first?["snippet"]) as? [String: Any], let chat = s["liveChatId"] as? String {
                return chat
            }
        }
        throw NSError(domain: "dtd", code: 2, userInfo: [NSLocalizedDescriptionKey:
            L("Không thấy buổi live đang chạy trên kênh đã đăng nhập — dán link video live vào ô bên trên")])
    }

    /// "https://youtu.be/ID", "…watch?v=ID", "…/live/ID" or a bare ID.
    static func videoID(_ s: String) -> String {
        if let u = URLComponents(string: s) {
            if let v = u.queryItems?.first(where: { $0.name == "v" })?.value { return v }
            let last = u.path.split(separator: "/").last.map(String.init) ?? s
            if u.host != nil { return last }
        }
        return s
    }

    private static func parse(_ it: [String: Any]) -> ChatMessage? {
        guard let id = it["id"] as? String, let sn = it["snippet"] as? [String: Any],
              let au = it["authorDetails"] as? [String: Any] else { return nil }
        let text = (sn["displayMessage"] as? String) ?? ""
        var amount: String?
        if let sc = sn["superChatDetails"] as? [String: Any] { amount = sc["amountDisplayString"] as? String }
        if let ss = sn["superStickerDetails"] as? [String: Any] { amount = ss["amountDisplayString"] as? String }
        guard !text.isEmpty || amount != nil else { return nil }
        let date = (sn["publishedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        return ChatMessage(id: id, platform: .youtube, author: (au["displayName"] as? String) ?? "",
                           text: text, avatarURL: (au["profileImageUrl"] as? String).flatMap(URL.init(string:)),
                           amount: amount, at: date)
    }

    private func avatar(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        if let a = avatars[url] { return a }
        var req = URLRequest(url: url); req.timeoutInterval = 3
        guard let (d, _) = try? await URLSession.shared.data(for: req), let img = UIImage(data: d) else { return nil }
        avatars[url] = img
        return img
    }
}

/// Draws the chat overlay on PGM: comment bubbles rise from the bottom, newest at the bottom; each stays
/// `duration` seconds, then fades; older ones fade out at the top when more than `maxVisible`.
/// Bubbles are drawn once (UIKit) and only moved / faded per frame.
final class ChatOverlayRenderer: @unchecked Sendable {
    private struct Item {
        let id: String
        let image: CIImage          // drawn at 1080p size
        let addedAt: CFTimeInterval
        var y: CGFloat? = nil        // current bottom offset (animated)
        var removing: CFTimeInterval? = nil
    }
    private let lock = NSLock()
    private var items: [Item] = []
    private var style = ChatOverlayStyle()
    private var visible = false

    func setStyle(_ s: ChatOverlayStyle) { lock.lock(); style = s; lock.unlock() }
    func setVisible(_ v: Bool) { lock.lock(); visible = v; if !v { items.removeAll() }; lock.unlock() }
    func clear() { lock.lock(); items.removeAll(); lock.unlock() }

    func push(_ m: ChatMessage, avatar: UIImage?) {
        lock.lock(); let s = style; lock.unlock()
        guard let cg = Self.bubble(m, avatar: avatar, style: s).cgImage else { return }
        let item = Item(id: m.id, image: CIImage(cgImage: cg), addedAt: HostClock.now)
        lock.lock(); items.removeAll { $0.id == m.id }; items.append(item); lock.unlock()
    }

    /// Called on the render queue every program frame.
    func render(canvas: CGSize, now: CFTimeInterval) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        guard visible, !items.isEmpty else { return nil }
        let s = style
        let k = canvas.height / 1080 * CGFloat(s.scale)
        let gap = 12 * k
        // expire: past duration, or pushed beyond maxVisible
        for i in items.indices where items[i].removing == nil {
            let tooOld = now - items[i].addedAt > s.duration
            let overflow = items.count - i > s.maxVisible
            if tooOld || overflow { items[i].removing = now }
        }
        items.removeAll { $0.removing.map { now - $0 > 0.45 } ?? false }
        var out: CIImage?
        var stack: CGFloat = 0            // height of newer bubbles below (CI origin is bottom-left)
        let base = canvas.height / 1080 * CGFloat(s.bottom)
        for i in items.indices.reversed() {
            let img = items[i].image.transformed(by: CGAffineTransform(scaleX: k, y: k))
            let h = img.extent.height, w = img.extent.width
            let target = base + stack
            // rise: new bubbles start below their slot and glide up; others glide to their new slot
            var y = items[i].y ?? (target - h - 20 * k)
            y += (target - y) * 0.22
            items[i].y = y
            stack += h + gap
            var alpha = min(1, CGFloat((now - items[i].addedAt) / 0.3))
            if let r = items[i].removing { alpha *= max(0, 1 - CGFloat((now - r) / 0.45)) }
            if alpha <= 0.01 { continue }
            let x = s.rightSide ? canvas.width - w - 48 * k : 48 * k
            var placed = img.transformed(by: CGAffineTransform(translationX: x - img.extent.minX, y: y - img.extent.minY))
            if alpha < 0.999 {
                placed = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
                    "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0)])
            }
            out = out.map { placed.composited(over: $0) } ?? placed
        }
        return out?.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    /// One comment bubble at 1080p scale: [avatar] Name / message (wrapped), platform dot, Super Chat in gold.
    static func bubble(_ m: ChatMessage, avatar: UIImage?, style s: ChatOverlayStyle) -> UIImage {
        let maxW = CGFloat(s.width)
        let pad: CGFloat = 16, av: CGFloat = s.showAvatar ? 52 : 0
        let accent = UIColor(hex: s.accentHex)
        let nameFont = UIFont.systemFont(ofSize: 24, weight: .bold)
        let textFont = UIFont.systemFont(ofSize: 28, weight: .semibold)
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byWordWrapping
        let name = NSAttributedString(string: m.author + (m.amount.map { "  " + $0 } ?? ""),
                                      attributes: [.font: nameFont, .foregroundColor: m.amount != nil ? UIColor.black : accent.lighter(0.25)])
        let text = NSAttributedString(string: m.text, attributes: [.font: textFont, .foregroundColor: m.amount != nil ? UIColor.black : UIColor.white,
                                                                   .paragraphStyle: p])
        let textX = pad + (av > 0 ? av + 12 : 0)
        let textW = maxW - textX - pad
        let tr = text.boundingRect(with: CGSize(width: textW, height: 400), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let nameW = min(textW, name.size().width)
        let contentW = max(nameW, ceil(tr.width))
        let h = max(av + 2 * pad, pad + name.size().height + 2 + ceil(tr.height) + pad)
        let w = textX + contentW + pad
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { ctx in
            let r = CGRect(x: 0, y: 0, width: w, height: h)
            let bg: UIColor = m.amount != nil ? UIColor(hex: "#FFC93C") : UIColor(white: 0.06, alpha: CGFloat(s.opacity))
            bg.setFill(); UIBezierPath(roundedRect: r, cornerRadius: 18).fill()
            // platform stripe
            (m.platform == .youtube ? UIColor(hex: "#FF0033") : UIColor(hex: "#1877F2")).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 6, height: h), byRoundingCorners: [.topLeft, .bottomLeft],
                         cornerRadii: CGSize(width: 18, height: 18)).fill()
            if av > 0 {
                let ar = CGRect(x: pad, y: pad, width: av, height: av)
                ctx.cgContext.saveGState()
                UIBezierPath(ovalIn: ar).addClip()
                if let avatar { avatar.draw(in: ar) } else {
                    accent.setFill(); UIRectFill(ar)
                    let ini = String(m.author.prefix(1)).uppercased() as NSString
                    let f = UIFont.systemFont(ofSize: 26, weight: .heavy)
                    let sz = ini.size(withAttributes: [.font: f])
                    ini.draw(at: CGPoint(x: ar.midX - sz.width / 2, y: ar.midY - sz.height / 2), withAttributes: [.font: f, .foregroundColor: UIColor.white])
                }
                ctx.cgContext.restoreGState()
            }
            name.draw(with: CGRect(x: textX, y: pad, width: textW, height: name.size().height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            text.draw(with: CGRect(x: textX, y: pad + name.size().height + 2, width: textW, height: ceil(tr.height) + 2),
                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }
}

private extension UIColor {
    func lighter(_ k: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r + (1 - r) * k, green: g + (1 - g) * k, blue: b + (1 - b) * k, alpha: a)
    }
}

// MARK: - Panel

struct LiveChatPanel: View {
    @ObservedObject var chat: LiveChat
    var compact = false
    @State private var showStyle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { chat.running ? chat.stop() : chat.start() } label: {
                    Label(chat.running ? "Dừng nhận" : "Nhận bình luận", systemImage: chat.running ? "stop.fill" : "play.fill")
                        .font(DS.fBodyBold).padding(.horizontal, 12).frame(height: 32)
                        .foregroundStyle(.white).background(chat.running ? DS.pgm : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                }.buttonStyle(.plain)
                platformChip("YouTube", color: .red, on: $chat.useYouTube)
                platformChip("Facebook", color: .blue, on: $chat.useFacebook)
                Toggle(isOn: $chat.overlayOn) { Text("Hiện trên PGM").font(DS.fBodyBold) }.fixedSize()
                Picker("", selection: $chat.auto) {
                    Text("Tự động").tag(true)
                    Text("Chọn tay").tag(false)
                }
                .pickerStyle(.segmented).frame(width: 190)
                Spacer(minLength: 0)
                Button { chat.clearOverlay() } label: { Image(systemName: "xmark.bin") }.buttonStyle(.bordered).help("Xoá bình luận trên PGM")
                Button { showStyle.toggle() } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.bordered)
            }
            if chat.useYouTube {
                sourceRow("YouTube", .red, "Link/ID video YouTube (trống = live đang chạy trên kênh đã đăng nhập)", $chat.videoInput, chat.ytStatus)
            }
            if chat.useFacebook {
                sourceRow("Facebook", .blue, "Link/ID video Facebook (trống = live đang chạy của tài khoản đã đăng nhập)", $chat.fbVideoInput, chat.fbStatus)
            }
            if !chat.status.isEmpty { Text(chat.status).font(.caption).foregroundStyle(DS.text3) }
            if showStyle { styleRows }
            if chat.visibleMessages.isEmpty {
                Text(chat.auto ? "Bình luận mới sẽ tự chạy từ dưới lên trên PGM." : "Chạm một bình luận để đưa lên PGM.")
                    .font(DS.fBody).foregroundStyle(DS.text3).padding(.vertical, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(chat.visibleMessages) { m in
                            Button { chat.show(m) } label: { row(m) }.buttonStyle(.plain).id(m.id)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: compact ? 260 : 360)
                .onChange(of: chat.messages.count) { _, _ in
                    if let last = chat.visibleMessages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Text("Facebook: khi app còn ở chế độ phát triển chỉ đọc được bình luận live của chính tài khoản quản trị app; cho mọi người dùng cần Meta duyệt quyền (App Review).")
                .font(.caption2).foregroundStyle(DS.text3)
        }
    }

    private func platformChip(_ name: String, color: Color, on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: on.wrappedValue ? "checkmark.square.fill" : "square").font(.system(size: 12))
                Text(verbatim: name).font(.system(size: 12, weight: .bold))
            }
            .padding(.horizontal, 9).frame(height: 30)
            .foregroundStyle(on.wrappedValue ? .white : DS.text3)
            .background(on.wrappedValue ? color.opacity(0.75) : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
    }

    private func sourceRow(_ name: String, _ color: Color, _ hint: LocalizedStringKey, _ text: Binding<String>, _ status: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            TextField(hint, text: text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.system(size: 13)).padding(.horizontal, 8).frame(height: 30)
                .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
            Text(verbatim: status).font(.caption).foregroundStyle(DS.text3).lineLimit(2).frame(maxWidth: 220, alignment: .leading)
        }
    }

    private func row(_ m: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(m.platform == .youtube ? Color.red : Color.blue).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(m.author).font(.system(size: 12, weight: .bold)).foregroundStyle(DS.accent)
                    if let a = m.amount { Text(a).font(.system(size: 11, weight: .heavy)).padding(.horizontal, 4).background(Color.yellow.opacity(0.8), in: Capsule()).foregroundStyle(.black) }
                    Text(m.at, style: .time).font(.system(size: 10)).foregroundStyle(DS.text3)
                }
                Text(m.text).font(.system(size: 13)).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
            }
            if chat.shownIDs.contains(m.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.pgm).font(.system(size: 13)) }
            else { Image(systemName: "arrow.up.square").foregroundStyle(DS.text3).font(.system(size: 13)) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
    }

    @ViewBuilder private var styleRows: some View {
        VStack(spacing: 2) {
            HStack {
                Picker("", selection: $chat.style.rightSide) { Text("Bên trái").tag(false); Text("Bên phải").tag(true) }
                    .pickerStyle(.segmented).frame(width: 180)
                Toggle(isOn: $chat.style.showAvatar) { Text("Ảnh đại diện").font(DS.fBody) }.fixedSize()
                ColorPicker("", selection: Binding(get: { Color(UIColor(hex: chat.style.accentHex)) },
                                                   set: { chat.style.accentHex = UIColor($0).hexString }), supportsOpacity: false).labelsHidden()
                Spacer()
            }
            slider("Số bình luận", Binding(get: { Double(chat.style.maxVisible) }, set: { chat.style.maxVisible = Int($0) }), 1...10, step: 1) { "\(Int($0))" }
            slider("Thời gian hiện", $chat.style.duration, 4...60, step: 1) { "\(Int($0)) s" }
            slider("Cỡ", $chat.style.scale, 0.6...1.8, step: 0.05) { "\(Int($0 * 100))%" }
            slider("Rộng tối đa", $chat.style.width, 360...1100, step: 10) { "\(Int($0)) px" }
            slider("Cách đáy", $chat.style.bottom, 0...700, step: 5) { "\(Int($0)) px" }
            slider("Độ đậm nền", $chat.style.opacity, 0.2...1, step: 0.05) { "\(Int($0 * 100))%" }
        }
    }

    private func slider(_ t: LocalizedStringKey, _ v: Binding<Double>, _ r: ClosedRange<Double>, step: Double,
                        fmt: @escaping (Double) -> String) -> some View {
        HStack(spacing: 8) {
            Text(t).font(DS.fBody).foregroundStyle(DS.text2).frame(width: 104, alignment: .leading)
            Slider(value: v, in: r, step: step).tint(DS.accent).controlSize(.small)
            Text(verbatim: fmt(v.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(DS.text3).frame(width: 56, alignment: .trailing)
        }
        .frame(height: 28)
    }
}

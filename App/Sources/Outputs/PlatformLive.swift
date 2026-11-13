import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Creates a live event on YouTube / Facebook and returns an RTMP(S) destination,
/// so the operator doesn't have to copy stream keys by hand.
///
/// Configuration: Settings › Phát trực tiếp (UserDefaults), falling back to Info.plist (project.yml):
///   DTDGoogleClientID   — OAuth client of type "iOS" in Google Cloud (YouTube Data API v3 enabled)
///   DTDFacebookAppID    — Facebook app with "publish_video" permission (needs App Review for public use)
/// Sign-in is kept in the Keychain (Google refresh token, Facebook token with its expiry), so the operator
/// logs in once; each "Tạo live" then fetches a fresh RTMP URL + stream key automatically.
@MainActor
final class PlatformLive: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    enum Platform: String { case youtube, facebook }
    enum LiveError: LocalizedError {
        case notConfigured(String), cancelled, http(Int, String), badResponse, unsupportedOS
        var errorDescription: String? {
            switch self {
            case .notConfigured(let k):
                return k == PlatformLive.googleKey
                    ? L("Chưa nhập Google OAuth Client ID (iOS) — vào Cài đặt › Phát trực tiếp, hoặc dùng 'Thêm đích' với stream key YouTube")
                    : L("Chưa nhập Facebook App ID — vào Cài đặt › Phát trực tiếp, hoặc dùng 'Thêm đích' với stream key Facebook")
            case .cancelled: return L("Đã huỷ đăng nhập")
            case .http(let c, let m): return "HTTP \(c): \(m)"
            case .badResponse: return L("Phản hồi không hợp lệ")
            case .unsupportedOS: return L("Cần iPadOS/iOS 17.4 trở lên cho đăng nhập Facebook")
            }
        }
    }

    struct Destination { var name: String; var url: String; var watchURL: String? }

    static let googleKey = "DTDGoogleClientID"
    static let facebookKey = "DTDFacebookAppID"
    static let facebookConfigKey = "DTDFacebookConfigID"
    /// IDs entered in Settings win over the Info.plist values, so no rebuild is needed to configure them.
    static func configured(_ key: String) -> String? {
        let s = (UserDefaults.standard.string(forKey: key) ?? (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static let shared = PlatformLive()

    private var googleToken: String?
    private var googleExpiry = Date.distantPast
    private var facebookToken: String? = Keychain.get("dtd.facebook.token")
    private var facebookExpiry = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "dtd.facebook.expiry"))
    private var session: ASWebAuthenticationSession?

    /// Account names shown in Settings (nil = not signed in).
    @Published private(set) var youtubeAccount: String? = UserDefaults.standard.string(forKey: "dtd.youtube.account")
    @Published private(set) var facebookAccount: String? = UserDefaults.standard.string(forKey: "dtd.facebook.account")

    var youtubeSignedIn: Bool { Keychain.get("dtd.google.refresh") != nil || (googleToken != nil && googleExpiry > Date()) }
    var facebookSignedIn: Bool { facebookToken != nil && facebookExpiry > Date() }

    /// Explicit sign-in from Settings (also fetches the account name).
    func signIn(_ p: Platform) async throws {
        switch p {
        case .youtube:
            googleToken = nil; googleExpiry = .distantPast
            let t = try await googleAccessToken(interactive: true)
            let j = try await api("https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true", token: t, body: nil, method: "GET")
            let first = (j["items"] as? [[String: Any]])?.first
            let name = (first?["snippet"] as? [String: Any])?["title"] as? String ?? "YouTube"
            youtubeAccount = name; UserDefaults.standard.set(name, forKey: "dtd.youtube.account")
            if let cid = first?["id"] as? String { UserDefaults.standard.set(cid, forKey: "dtd.youtube.channel") }
        case .facebook:
            facebookToken = nil
            let t = try await facebookAccessToken()
            var req = URLRequest(url: URL(string: "https://graph.facebook.com/v19.0/me?fields=name&access_token=\(t)")!)
            req.httpMethod = "GET"
            let name = (try? await send(req))?["name"] as? String ?? "Facebook"
            facebookAccount = name; UserDefaults.standard.set(name, forKey: "dtd.facebook.account")
        }
    }

    /// Channel live page (always shows the channel's current live) — used as the watch link for stream-key outputs.
    static var youtubeChannelLiveURL: String? {
        UserDefaults.standard.string(forKey: "dtd.youtube.channel").map { "https://www.youtube.com/channel/\($0)/live" }
    }

    func signOut(_ p: Platform) {
        switch p {
        case .youtube:
            googleToken = nil; googleExpiry = .distantPast
            Keychain.set("", for: "dtd.google.refresh")
            youtubeAccount = nil; UserDefaults.standard.removeObject(forKey: "dtd.youtube.account")
        case .facebook:
            facebookToken = nil; Keychain.set("", for: "dtd.facebook.token")
            UserDefaults.standard.removeObject(forKey: "dtd.facebook.expiry")
            facebookAccount = nil; UserDefaults.standard.removeObject(forKey: "dtd.facebook.account")
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    // MARK: YouTube

    func createYouTube(title: String, privacy: String = "unlisted", vertical: Bool = false) async throws -> Destination {
        let token = try await googleAccessToken()
        let iso = ISO8601DateFormatter().string(from: Date())
        let broadcast = try await api("https://www.googleapis.com/youtube/v3/liveBroadcasts?part=snippet,status,contentDetails", token: token, body: [
            "snippet": ["title": title, "scheduledStartTime": iso],
            "status": ["privacyStatus": privacy, "selfDeclaredMadeForKids": false],
            "contentDetails": ["enableAutoStart": true, "enableAutoStop": true, "latencyPreference": "low"]
        ])
        let stream = try await api("https://www.googleapis.com/youtube/v3/liveStreams?part=snippet,cdn,contentDetails", token: token, body: [
            "snippet": ["title": "DTD Studio \(iso)"],
            "cdn": ["frameRate": "variable", "ingestionType": "rtmp", "resolution": "variable"],
            "contentDetails": ["isReusable": false]
        ])
        guard let bid = broadcast["id"] as? String, let sid = stream["id"] as? String,
              let cdn = stream["cdn"] as? [String: Any], let ingest = cdn["ingestionInfo"] as? [String: Any],
              let address = ingest["ingestionAddress"] as? String, let key = ingest["streamName"] as? String else {
            throw LiveError.badResponse
        }
        _ = try await api("https://www.googleapis.com/youtube/v3/liveBroadcasts/bind?id=\(bid)&part=id,contentDetails&streamId=\(sid)",
                          token: token, body: nil)
        return Destination(name: "YouTube: \(title)", url: "\(address)/\(key)", watchURL: "https://youtu.be/\(bid)")
    }

    private func googleAccessToken(interactive: Bool = false) async throws -> String {
        if let googleToken, googleExpiry > Date().addingTimeInterval(60) { return googleToken }
        guard let clientID = Self.configured(Self.googleKey) else { throw LiveError.notConfigured(Self.googleKey) }
        // silent refresh with the stored refresh token
        if !interactive, let refresh = Keychain.get("dtd.google.refresh") {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.form(["client_id": clientID, "refresh_token": refresh, "grant_type": "refresh_token"])
            if let json = try? await send(req), let token = json["access_token"] as? String {
                googleToken = token
                googleExpiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3500)
                return token
            }
            Keychain.set("", for: "dtd.google.refresh")       // revoked/expired → sign in again
        }
        // Installed-app flow with PKCE; redirect is the reversed client ID scheme.
        let scheme = clientID.split(separator: ".").reversed().joined(separator: ".")
        let redirect = "\(scheme):/oauth2redirect"
        let verifier = Self.randomURLSafe(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: "https://www.googleapis.com/auth/youtube"),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent select_account")
        ]
        let callback = try await authenticate(url: c.url!) { done in
            ASWebAuthenticationSession(url: c.url!, callbackURLScheme: scheme, completionHandler: done)
        }
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw LiveError.badResponse
        }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(["code": code, "client_id": clientID, "redirect_uri": redirect,
                                  "grant_type": "authorization_code", "code_verifier": verifier])
        let json = try await send(req)
        guard let token = json["access_token"] as? String else { throw LiveError.badResponse }
        googleToken = token
        googleExpiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3500)
        if let r = json["refresh_token"] as? String { Keychain.set(r, for: "dtd.google.refresh") }
        if youtubeAccount == nil { youtubeAccount = "YouTube"; UserDefaults.standard.set("YouTube", forKey: "dtd.youtube.account") }
        return token
    }

    // MARK: Facebook

    /// Creates a live video on the user's timeline (or a Page if `pageID` + page token flow is added later).
    /// privacy: "EVERYONE" (public), "ALL_FRIENDS", "SELF".
    func createFacebook(title: String, privacy: String = "EVERYONE") async throws -> Destination {
        let token = try await facebookAccessToken()
        var c = URLComponents(string: "https://graph.facebook.com/v19.0/me/live_videos")!
        c.queryItems = [.init(name: "status", value: "LIVE_NOW"), .init(name: "title", value: title),
                        .init(name: "description", value: title),
                        .init(name: "privacy", value: "{\"value\":\"\(privacy)\"}"),
                        .init(name: "access_token", value: token)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        let json = try await send(req)
        guard let url = (json["secure_stream_url"] as? String) ?? (json["stream_url"] as? String) else { throw LiveError.badResponse }
        // the viewer link is the live video's permalink (the live_video id itself is not a public URL)
        var watch: String?
        if let id = json["id"] as? String {
            var g = URLComponents(string: "https://graph.facebook.com/v19.0/\(id)")!
            g.queryItems = [.init(name: "fields", value: "permalink_url"), .init(name: "access_token", value: token)]
            if let j = try? await send(URLRequest(url: g.url!)), let p = j["permalink_url"] as? String {
                watch = p.hasPrefix("http") ? p : "https://www.facebook.com" + p
            }
        }
        return Destination(name: "Facebook: \(title)", url: url, watchURL: watch)
    }


    private func facebookAccessToken() async throws -> String {
        if let facebookToken, facebookExpiry > Date().addingTimeInterval(60) { return facebookToken }
        guard let appID = Self.configured(Self.facebookKey) else { throw LiveError.notConfigured(Self.facebookKey) }
        // Native-app redirect fb{appID}://authorize (needs the bundle ID under the app's iOS platform);
        // Facebook Login for Business uses a configuration (config_id) instead of a scope list.
        let scheme = "fb\(appID)"
        let redirect = "\(scheme)://authorize/"
        var c = URLComponents(string: "https://www.facebook.com/v19.0/dialog/oauth")!
        var items: [URLQueryItem] = [.init(name: "client_id", value: appID), .init(name: "redirect_uri", value: redirect),
                                     .init(name: "response_type", value: "token"), .init(name: "display", value: "touch")]
        if let cfg = Self.configured(Self.facebookConfigKey) { items.append(.init(name: "config_id", value: cfg)) }
        else { items.append(.init(name: "scope", value: "publish_video")) }
        c.queryItems = items
        let callback = try await authenticate(url: c.url!) { done in
            ASWebAuthenticationSession(url: c.url!, callbackURLScheme: scheme, completionHandler: done)
        }
        // Token comes back in the URL fragment.
        let fragment = URLComponents(string: "x://y?" + (callback.fragment ?? ""))
        guard let token = fragment?.queryItems?.first(where: { $0.name == "access_token" })?.value else { throw LiveError.badResponse }
        let secs = fragment?.queryItems?.first(where: { $0.name == "expires_in" })?.value.flatMap(Double.init) ?? 3600
        facebookToken = token
        facebookExpiry = Date().addingTimeInterval(secs > 0 ? secs : 3600)
        Keychain.set(token, for: "dtd.facebook.token")
        UserDefaults.standard.set(facebookExpiry.timeIntervalSince1970, forKey: "dtd.facebook.expiry")
        if facebookAccount == nil { facebookAccount = "Facebook"; UserDefaults.standard.set("Facebook", forKey: "dtd.facebook.account") }
        return token
    }

    func signOut() { signOut(.youtube); signOut(.facebook) }

    // MARK: Helpers

    private func authenticate(url: URL,
                              make: (@escaping ASWebAuthenticationSession.CompletionHandler) -> ASWebAuthenticationSession) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = make { result, error in
                if let result { cont.resume(returning: result) }
                else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { cont.resume(throwing: LiveError.cancelled) }
                else { cont.resume(throwing: error ?? LiveError.badResponse) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            s.start()
        }
    }

    /// Authenticated GET on the YouTube Data API (live chat etc.).
    func youtubeGET(_ url: String) async throws -> [String: Any] {
        let t = try await googleAccessToken()
        return try await api(url, token: t, body: nil, method: "GET")
    }

    /// GET on the Facebook Graph API with the signed-in user token (path like "me/live_videos?…").
    func facebookGET(_ path: String) async throws -> [String: Any] {
        let t = try await facebookAccessToken()
        let sep = path.contains("?") ? "&" : "?"
        var req = URLRequest(url: URL(string: "https://graph.facebook.com/v19.0/\(path)\(sep)access_token=\(t)")!)
        req.httpMethod = "GET"
        return try await send(req)
    }

    private func api(_ url: String, token: String, body: [String: Any]?, method: String = "POST") async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
            if code == 401 { googleToken = nil; facebookToken = nil }
            throw LiveError.http(code, msg)
        }
        return json
    }

    private static func form(_ d: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return Data(d.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }

    private static func randomURLSafe(_ n: Int) -> String {
        Data((0..<n).map { _ in UInt8.random(in: 0...255) }).base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

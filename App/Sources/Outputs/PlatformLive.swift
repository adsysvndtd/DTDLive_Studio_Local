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
/// Tokens are kept in memory only; the operator signs in once per app run.
@MainActor
final class PlatformLive: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    enum Platform: String { case youtube, facebook }
    enum LiveError: LocalizedError {
        case notConfigured(String), cancelled, http(Int, String), badResponse, unsupportedOS
        var errorDescription: String? {
            switch self {
            case .notConfigured(let k):
                return k == PlatformLive.googleKey
                    ? "Chưa nhập Google OAuth Client ID (iOS) — vào Cài đặt › Phát trực tiếp, hoặc dùng 'Thêm đích' với stream key YouTube"
                    : "Chưa nhập Facebook App ID — vào Cài đặt › Phát trực tiếp, hoặc dùng 'Thêm đích' với stream key Facebook"
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
    /// IDs entered in Settings win over the Info.plist values, so no rebuild is needed to configure them.
    static func configured(_ key: String) -> String? {
        let s = (UserDefaults.standard.string(forKey: key) ?? (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private var googleToken: String?
    private var facebookToken: String?
    private var session: ASWebAuthenticationSession?

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

    private func googleAccessToken() async throws -> String {
        if let googleToken { return googleToken }
        guard let clientID = Self.configured(Self.googleKey) else { throw LiveError.notConfigured(Self.googleKey) }
        // Installed-app flow with PKCE; redirect is the reversed client ID scheme.
        let scheme = clientID.split(separator: ".").reversed().joined(separator: ".")
        let redirect = "\(scheme):/oauth2redirect"
        let verifier = Self.randomURLSafe(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: "https://www.googleapis.com/auth/youtube"),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256")
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
        return token
    }

    // MARK: Facebook

    /// Creates a live video on the user's timeline (or a Page if `pageID` + page token flow is added later).
    func createFacebook(title: String) async throws -> Destination {
        let token = try await facebookAccessToken()
        var c = URLComponents(string: "https://graph.facebook.com/v19.0/me/live_videos")!
        c.queryItems = [.init(name: "status", value: "LIVE_NOW"), .init(name: "title", value: title),
                        .init(name: "access_token", value: token)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        let json = try await send(req)
        guard let url = (json["secure_stream_url"] as? String) ?? (json["stream_url"] as? String) else { throw LiveError.badResponse }
        return Destination(name: "Facebook: \(title)", url: url, watchURL: (json["id"] as? String).map { "https://www.facebook.com/\($0)" })
    }

    private func facebookAccessToken() async throws -> String {
        if let facebookToken { return facebookToken }
        guard let appID = Self.configured(Self.facebookKey) else { throw LiveError.notConfigured(Self.facebookKey) }
        guard #available(iOS 17.4, *) else { throw LiveError.unsupportedOS }
        // Manual login flow with the standard desktop redirect, intercepted by ASWebAuthenticationSession.
        let redirect = "https://www.facebook.com/connect/login_success.html"
        var c = URLComponents(string: "https://www.facebook.com/v19.0/dialog/oauth")!
        c.queryItems = [.init(name: "client_id", value: appID), .init(name: "redirect_uri", value: redirect),
                        .init(name: "response_type", value: "token"), .init(name: "scope", value: "publish_video"),
                        .init(name: "display", value: "touch")]
        let callback = try await authenticate(url: c.url!) { done in
            ASWebAuthenticationSession(url: c.url!, callback: .https(host: "www.facebook.com", path: "/connect/login_success.html"),
                                       completionHandler: done)
        }
        // Token comes back in the URL fragment.
        let fragment = URLComponents(string: "x://y?" + (callback.fragment ?? ""))
        guard let token = fragment?.queryItems?.first(where: { $0.name == "access_token" })?.value else { throw LiveError.badResponse }
        facebookToken = token
        return token
    }

    func signOut() { googleToken = nil; facebookToken = nil }

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

    private func api(_ url: String, token: String, body: [String: Any]?) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
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

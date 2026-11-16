import Foundation
import StoreKit

// DTDStudio plans: day / month / year.
//  • App Store / TestFlight builds: bought with In-App Purchase only (App Review 3.1.1) — a 1‑day pass
//    (non-renewing) and monthly / yearly auto-renewing subscriptions.
//  • Plans bought on the website / by bank transfer unlock by signing in to the DTD account (3.1.3(b)).
//  • Internal builds (Ad Hoc / development) can also buy by bank transfer (VietQR) from the license server.
// Nothing is locked yet: this only sells plans and shows their state.

/// Where this build came from. App Store / TestFlight builds carry no embedded provisioning profile.
enum Distribution {
    static let isStoreBuild: Bool = {
        #if DEBUG
        return false
        #else
        return Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") == nil
        #endif
    }()
}

// MARK: - App Store

@MainActor
final class StudioStore: ObservableObject {
    /// Must match the products created in App Store Connect.
    static let dayPass = "vn.com.dtdsolution.dtdstudio.day"          // Non-Renewing Subscription, 1 day
    static let monthly = "vn.com.dtdsolution.dtdstudio.monthly"      // Auto-Renewable (group "DTDStudio Pro")
    static let yearly = "vn.com.dtdsolution.dtdstudio.yearly"        // Auto-Renewable (same group)
    static let productIDs = [dayPass, monthly, yearly]

    @Published private(set) var products: [Product] = []
    @Published private(set) var loadError: String?
    @Published private(set) var loading = false
    @Published var purchasing: String?
    /// Active App Store plan (product id) and when it ends.
    @Published private(set) var activeProduct: String?
    @Published private(set) var until: Date?
    @Published private(set) var willRenew = false

    private var updates: Task<Void, Never>?
    /// Called after every refresh (StudioPlan links App Store purchases to the DTD account).
    var onChange: (() async -> Void)?

    init() {
        updates = Task { [weak self] in
            for await r in Transaction.updates {
                if case .verified(let t) = r { await t.finish() }
                await self?.refresh()
            }
        }
        Task { await load(); await refresh() }
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let order = Self.productIDs
            products = try await Product.products(for: Self.productIDs)
                .sorted { (order.firstIndex(of: $0.id) ?? 9) < (order.firstIndex(of: $1.id) ?? 9) }
            loadError = products.isEmpty
                ? L("Chưa tải được gói từ App Store (bản cài nội bộ, hoặc gói chưa được tạo trong App Store Connect).") : nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Subscriptions from current entitlements; day passes stack (each adds 24 h from the later of
    /// its purchase or the end of the previous pass).
    func refresh() async {
        var best: (String, Date)?
        for await r in Transaction.currentEntitlements {
            guard case .verified(let t) = r, t.revocationDate == nil,
                  t.productID == Self.monthly || t.productID == Self.yearly,
                  let e = t.expirationDate, e > Date() else { continue }
            if best == nil || e > best!.1 { best = (t.productID, e) }
        }
        var passes: [Date] = []
        for await r in Transaction.all {
            guard case .verified(let t) = r, t.productID == Self.dayPass, t.revocationDate == nil else { continue }
            passes.append(t.purchaseDate)
        }
        var passEnd: Date?
        for p in passes.sorted() {
            let start = max(p, passEnd ?? p)
            passEnd = start.addingTimeInterval(86_400)
        }
        if let pe = passEnd, pe > Date(), best == nil || pe > best!.1 { best = (Self.dayPass, pe) }
        activeProduct = best?.0
        until = best?.1
        willRenew = false
        if let id = best?.0, id != Self.dayPass, let p = products.first(where: { $0.id == id }),
           let st = try? await p.subscription?.status.first, case .verified(let info) = st.renewalInfo {
            willRenew = info.willAutoRenew
        }
        await onChange?()
    }

    /// Signed transactions to link to the DTD account: running subscriptions and day passes from the last 2 days.
    func entitlementJWS() async -> [String] {
        var out: [String] = []
        for await r in Transaction.currentEntitlements {
            guard case .verified(let t) = r, t.productID == Self.monthly || t.productID == Self.yearly else { continue }
            out.append(r.jwsRepresentation)
        }
        let since = Date().addingTimeInterval(-2 * 86_400)
        for await r in Transaction.all {
            guard case .verified(let t) = r, t.productID == Self.dayPass, t.purchaseDate > since else { continue }
            out.append(r.jwsRepresentation)
        }
        return Array(out.prefix(50))
    }

    /// Error message, or nil (bought or cancelled by the user).
    func purchase(_ p: Product) async -> String? {
        purchasing = p.id
        defer { purchasing = nil }
        do {
            switch try await p.purchase() {
            case .success(let v):
                guard case .verified(let t) = v else { return L("Không xác thực được giao dịch") }
                await t.finish()
                await refresh()
                return nil
            case .pending: return L("Giao dịch đang chờ duyệt")
            case .userCancelled: return nil
            @unknown default: return nil
            }
        } catch { return error.localizedDescription }
    }

    func restore() async -> String? {
        do {
            try await AppStore.sync()
            await refresh()
            return activeProduct == nil ? L("Không tìm thấy gói DTDStudio đã mua với Apple ID này") : nil
        } catch { return error.localizedDescription }
    }

    static func periodLabel(_ p: Product) -> String {
        switch p.id {
        case dayPass: return L("1 ngày")
        case monthly: return L("1 tháng · tự gia hạn")
        case yearly: return L("1 năm · tự gia hạn")
        default: return ""
        }
    }
}

// MARK: - DTD account (license server, shared with DTDLive)

struct StudioMe: Codable, Equatable {
    var email: String
    var role: String
    var pro: Bool
    var proUntil: Date?
    var plan: String?
    var isAdmin: Bool { role == "admin" }
}

struct StudioBank: Codable, Equatable {
    var bin: String
    var account: String
    var accountName: String
    var bankName: String
}

struct StudioServerPlan: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var days: Int
    var amount: Int64
    var desc: String?
}

struct StudioPlansResponse: Codable {
    var plans: [StudioServerPlan]
    var bank: StudioBank
    var bankReady: Bool
}

struct StudioOrder: Codable, Identifiable, Equatable {
    var code: String
    var plan: String
    var amount: Int64
    var status: String
    var createdAt: Date
    var expiresAt: Date
    var qr: String?
    var bank: StudioBank?
    var proUntil: Date?
    var id: String { code }
}

enum StudioAccountError: LocalizedError {
    case server(String), http(Int), decode
    var errorDescription: String? {
        switch self {
        case .server(let m): return m
        case .http(let c): return LF("Máy chủ trả lỗi %@", "\(c)")
        case .decode: return L("Phản hồi máy chủ không hợp lệ")
        }
    }
}

@MainActor
final class StudioAccount: ObservableObject {
    static let server = URL(string: "https://api.dtdsolution.com.vn")!
    static let app = "dtdstudio"
    private static let tokenKey = "dtd.studio.account.token"
    private static let cacheKey = "dtd.studio.account.me"

    @Published private(set) var me: StudioMe?
    @Published private(set) var busy = false

    private var token: String { Keychain.get(Self.tokenKey) ?? "" }
    var signedIn: Bool { !token.isEmpty && me != nil }
    /// DTDStudio plan from the account (offline: last known expiry against the device clock).
    var until: Date? {
        guard let me, me.pro, let u = me.proUntil, u > Date() else { return nil }
        return u
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: c)
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if s.hasPrefix("0001-") { return .distantPast }          // Go zero time
            if let v = frac.date(from: s) ?? plain.date(from: s) { return v }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: s))
        }
        return d
    }()

    init() {
        if !token.isEmpty, let raw = UserDefaults.standard.data(forKey: Self.cacheKey),
           let m = try? Self.decoder.decode(StudioMe.self, from: raw) { me = m }
        if !token.isEmpty { Task { await refresh() } }
    }

    private struct ErrBody: Decodable { var error: String? }
    private struct Empty: Decodable {}
    private struct AuthResp: Decodable { var token: String; var me: StudioMe }

    private func call<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:],
                                    body: [String: Any]? = nil, auth: Bool = true) async throws -> T {
        var comps = URLComponents(url: Self.server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if auth, !token.isEmpty { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401 && auth { signOut() }
            if let e = try? Self.decoder.decode(ErrBody.self, from: data), let m = e.error { throw StudioAccountError.server(m) }
            throw StudioAccountError.http(code)
        }
        do { return try Self.decoder.decode(T.self, from: data) } catch { throw StudioAccountError.decode }
    }

    func signIn(email: String, password: String, register: Bool) async throws {
        busy = true
        defer { busy = false }
        let r: AuthResp = try await call("POST", register ? "api/auth/register" : "api/auth/login",
                                         body: ["email": email.trimmingCharacters(in: .whitespaces), "password": password], auth: false)
        Keychain.set(r.token, for: Self.tokenKey)
        await refresh()   // the login answer carries the DTDLive plan; ask for DTDStudio's
        if me == nil { setMe(r.me) }
    }

    func refresh() async {
        guard !token.isEmpty else { return }
        if let m: StudioMe = try? await call("GET", "api/me", query: ["app": Self.app]) { setMe(m) }
    }

    func signOut() {
        Keychain.set("", for: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        me = nil
    }

    private func setMe(_ m: StudioMe) {
        me = m
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(m) { UserDefaults.standard.set(d, forKey: Self.cacheKey) }
    }

    // Bank transfer (internal builds only)
    func plans() async throws -> StudioPlansResponse {
        try await call("GET", "api/plans", query: ["app": Self.app], auth: false)
    }
    func createOrder(plan: String) async throws -> StudioOrder {
        try await call("POST", "api/orders", body: ["plan": plan, "app": Self.app])
    }
    func order(_ code: String) async throws -> StudioOrder {
        let o: StudioOrder = try await call("GET", "api/orders/\(code)")
        if o.status == "paid" { await refresh() }
        return o
    }
    func cancelOrder(_ code: String) async {
        let _: Empty? = try? await call("POST", "api/orders/\(code)/cancel", body: [:])
    }

    /// Link App Store purchases to this account (the server checks Apple's signature). A DTDStudio
    /// plan then also unlocks DTDLive Pro on the same account.
    private struct SyncResp: Decodable { var me: StudioMe; var errors: [String]? }
    @discardableResult
    func syncAppStore(_ jws: [String]) async -> [String] {
        guard signedIn, !jws.isEmpty else { return [] }
        do {
            let r: SyncResp = try await call("POST", "api/appstore/sync", body: ["transactions": jws, "app": Self.app])
            setMe(r.me)
            return r.errors ?? []
        } catch { return [error.localizedDescription] }
    }
}

// MARK: - Combined state

@MainActor
final class StudioPlan: ObservableObject {
    static let shared = StudioPlan()
    let store = StudioStore()
    let account = StudioAccount()

    init() {
        store.onChange = { [weak self] in await self?.syncStore() }
    }

    /// Sends the App Store plan to the DTD account (if signed in), so it shows in DTDLive too.
    func syncStore() async {
        guard account.signedIn else { return }
        let jws = await store.entitlementJWS()
        if !jws.isEmpty { await account.syncAppStore(jws) }
    }

    /// The later of the App Store plan and the account plan.
    var until: Date? {
        [store.until, account.until].compactMap { $0 }.max()
    }
    var active: Bool { until != nil }
    var sourceLabel: String {
        guard let u = until else { return "" }
        return u == store.until ? "App Store" : L("Tài khoản DTD")
    }
}

enum VND {
    static func format(_ v: Int64) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "."
        return (f.string(from: NSNumber(value: v)) ?? "\(v)") + " đ"
    }
}

// MARK: - Plan list shown to the buyer (always all three, even before the App Store answers)

struct StudioPlanInfo: Identifiable {
    let id: String          // App Store product id
    let title: String
    let period: String
    /// Price in VND (same as the bank-transfer price on the license server).
    let vnd: Int64

    static var all: [StudioPlanInfo] {
        [StudioPlanInfo(id: StudioStore.dayPass, title: L("Gói ngày"), period: L("1 ngày"), vnd: 25_000),
         StudioPlanInfo(id: StudioStore.monthly, title: L("Gói tháng"), period: L("1 tháng · tự gia hạn"), vnd: 400_000),
         StudioPlanInfo(id: StudioStore.yearly, title: L("Gói năm"), period: L("1 năm · tự gia hạn"), vnd: 2_999_000)]
    }
}

/// VND ⇄ USD for showing prices in both currencies. Starts from a built-in rate and refreshes from a public
/// rate feed at most twice a day (cached); without network the last known rate is used.
@MainActor
final class ExchangeRate: ObservableObject {
    static let shared = ExchangeRate()
    /// VND per 1 USD.
    @Published private(set) var vndPerUSD: Double
    @Published private(set) var updated: Date?

    private let key = "dtd.fx.usdvnd"
    private init() {
        let d = UserDefaults.standard
        let saved = d.double(forKey: key)
        vndPerUSD = saved > 1000 ? saved : 26_300       // mid-market rate, Nov 2026
        updated = d.object(forKey: key + ".at") as? Date
    }

    func refreshIfNeeded() async {
        if let u = updated, Date().timeIntervalSince(u) < 12 * 3600 { return }
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { return }
        do {
            var req = URLRequest(url: url); req.timeoutInterval = 8
            let (data, _) = try await URLSession.shared.data(for: req)
            struct R: Decodable { let rates: [String: Double] }
            guard let v = try JSONDecoder().decode(R.self, from: data).rates["VND"], v > 1000, v < 100_000 else { return }
            vndPerUSD = v; updated = Date()
            UserDefaults.standard.set(v, forKey: key); UserDefaults.standard.set(updated, forKey: key + ".at")
        } catch {}
    }

    func usd(fromVND v: Double) -> String { Self.usdString(v / vndPerUSD) }
    func vnd(fromUSD v: Double) -> String { VND.format(Int64((v * vndPerUSD / 1000).rounded()) * 1000) }

    static func usdString(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "USD"; f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = 2; f.minimumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
    }

    /// "≈ $15.21" for a VND price, "≈ 400.000 đ" for a USD one, nil for other currencies.
    func other(price: Decimal, currency: String) -> String? {
        let v = NSDecimalNumber(decimal: price).doubleValue
        switch currency.uppercased() {
        case "VND": return "≈ " + usd(fromVND: v)
        case "USD": return "≈ " + vnd(fromUSD: v)
        default: return nil
        }
    }
}

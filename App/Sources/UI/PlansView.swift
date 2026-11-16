import CoreImage.CIFilterBuiltins
import StoreKit
import SwiftUI

/// "Gói DTDStudio": plan status, App Store day / month / year, DTD account sign-in,
/// and (internal builds only) bank transfer with VietQR.
struct PlansView: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var account: StudioAccount
    @ObservedObject private var fx = ExchangeRate.shared
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var manage = false

    init() {
        _store = ObservedObject(wrappedValue: StudioPlan.shared.store)
        _account = ObservedObject(wrappedValue: StudioPlan.shared.account)
    }

    private var until: Date? { [store.until, account.until].compactMap { $0 }.max() }

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Gói DTDStudio dùng được cả DTDLive Pro: đăng nhập cùng tài khoản DTD trên DTDLive.")) { statusRow }

                Section(header: SettingsHeader("Mua qua App Store"),
                        footer: Text("Gói tháng / năm tự gia hạn cho tới khi huỷ trong Cài đặt › Apple ID › Đăng ký, ít nhất 24 giờ trước khi hết kỳ; tiền trừ vào tài khoản Apple ID khi xác nhận mua. Gói ngày dùng 24 giờ, không tự gia hạn.")) {
                    // all three plans, always: App Store price when the store has answered, the list price otherwise
                    ForEach(StudioPlanInfo.all) { info in planRow(info, store.products.first { $0.id == info.id }) }
                    if store.products.isEmpty {
                        HStack(spacing: 8) {
                            if store.loading { ProgressView() }
                            Text(verbatim: store.loadError ?? L("Đang tải giá từ App Store…")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Text(verbatim: LF("Tỉ giá tham khảo: 1 USD ≈ %@", VND.format(Int64(fx.vndPerUSD.rounded()))))
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Button("Khôi phục giao dịch") { Task { error = await store.restore() } }
                        Spacer()
                        if store.activeProduct == StudioStore.monthly || store.activeProduct == StudioStore.yearly {
                            Button("Quản lý gói") { manage = true }
                        }
                    }
                    .buttonStyle(.borderless)
                    if let error { Text(verbatim: error).font(.footnote).foregroundStyle(.red) }
                }

                Section(header: SettingsHeader("Tài khoản DTD")) {
                    StudioAccountRows(account: account)
                }

                if !Distribution.isStoreBuild && account.signedIn {
                    Section(header: SettingsHeader("Chuyển khoản ngân hàng (VietQR)")) {
                        StudioBankRows(account: account)
                    }
                }

                Section {
                    Link("Chính sách quyền riêng tư", destination: URL(string: "https://dtdsolution.com.vn/dtdstudio/privacy.html")!)
                    Link("Điều khoản sử dụng (EULA)", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                }
            }
            .navigationTitle("Gói DTDStudio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Xong") { dismiss() } } }
            .manageSubscriptionsSheet(isPresented: $manage)
            .task { await store.refresh(); await account.refresh() }
            .task { await fx.refreshIfNeeded() }
            .task { if store.products.isEmpty { await store.load() } }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: until != nil ? "checkmark.seal.fill" : "seal")
                .font(.title2).foregroundStyle(until != nil ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let until {
                    Text("Đang dùng gói").font(.headline)
                    Text(verbatim: LF("Đến %@", until.formatted(date: .abbreviated, time: .shortened))
                         + " · " + (until == store.until ? "App Store" : L("Tài khoản DTD")))
                        .font(.footnote).foregroundStyle(.secondary)
                    if store.willRenew, until == store.until {
                        Text("Tự gia hạn").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Chưa có gói").font(.headline)
                    Text("Hiện mọi tính năng vẫn dùng được.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// One plan: name, period, price (App Store price if loaded, else the list price) and the other currency.
    private func planRow(_ info: StudioPlanInfo, _ p: Product?) -> some View {
        let active = store.activeProduct == info.id
        let price = p?.displayPrice ?? VND.format(info.vnd)
        let other = p.flatMap { fx.other(price: $0.price, currency: $0.priceFormatStyle.currencyCode) }
            ?? "≈ " + fx.usd(fromVND: Double(info.vnd))
        return Button {
            guard let p else { return }
            Task { error = await store.purchase(p) }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: info.title).font(.headline)
                    Text(verbatim: info.period).font(.caption).foregroundStyle(.secondary)
                    if let d = p?.description, !d.isEmpty { Text(verbatim: d).font(.caption).foregroundStyle(.secondary) }
                    if p == nil, !store.loading {
                        Text("Chưa mở bán trên App Store").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer()
                if store.purchasing == info.id { ProgressView() }
                else if active { Text("Đang dùng").font(.subheadline.bold()).foregroundStyle(.green) }
                else {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(verbatim: price).font(.headline).monospacedDigit()
                        Text(verbatim: other).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        // a day pass can be bought again (it adds 24 h); a running subscription can't
        .disabled(p == nil || store.purchasing != nil || (active && info.id != StudioStore.dayPass))
    }
}

/// Sign in / register / sign out of the DTD account (plans bought on the website unlock here).
struct StudioAccountRows: View {
    @ObservedObject var account: StudioAccount
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        if let me = account.me, account.signedIn {
            LabeledContent("Email", value: me.email)
            if let u = account.until {
                LabeledContent("Gói DTDStudio", value: LF("Đến %@", u.formatted(date: .abbreviated, time: .shortened)))
            } else {
                LabeledContent("Gói DTDStudio", value: L("Chưa có"))
            }
            Button("Làm mới") { Task { await account.refresh() } }
            Button("Đăng xuất", role: .destructive) { account.signOut() }
        } else {
            Text("Đã có gói DTDStudio trên tài khoản DTD? Đăng nhập để dùng.").font(.footnote).foregroundStyle(.secondary)
            TextField("Email", text: $email)
                .keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Mật khẩu", text: $password).textContentType(.password)
            HStack {
                Button("Đăng nhập") { go(register: false) }
                Spacer()
                Button("Tạo tài khoản") { go(register: true) }
            }
            .buttonStyle(.borderless)
            .disabled(account.busy || email.isEmpty || password.count < 8)
            if account.busy { ProgressView() }
            if let error { Text(verbatim: error).font(.footnote).foregroundStyle(.red) }
        }
    }

    private func go(register: Bool) {
        error = nil
        Task {
            do {
                try await account.signIn(email: email, password: password, register: register); password = ""
                await StudioPlan.shared.syncStore()   // link an App Store plan bought on this device
            }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Bank transfer purchase (internal builds only): plans from the license server, VietQR, status polling.
struct StudioBankRows: View {
    @ObservedObject var account: StudioAccount
    @State private var plans: StudioPlansResponse?
    @State private var order: StudioOrder?
    @State private var creating: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let order {
                StudioTransferRows(account: account, order: order) { self.order = nil }
            } else if let plans {
                if !plans.bankReady {
                    Text("Máy chủ chưa cấu hình tài khoản nhận tiền.").font(.footnote).foregroundStyle(.orange)
                }
                ForEach(plans.plans) { p in
                    Button {
                        Task {
                            creating = p.id; error = nil
                            do { order = try await account.createOrder(plan: p.id) } catch { self.error = error.localizedDescription }
                            creating = nil
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: p.name).font(.headline)
                                Text(verbatim: LF("%@ ngày", "\(p.days)")).font(.caption).foregroundStyle(.secondary)
                                if let d = p.desc, !d.isEmpty { Text(verbatim: d).font(.caption.bold()).foregroundStyle(.green) }
                            }
                            Spacer()
                            if creating == p.id { ProgressView() } else {
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(verbatim: VND.format(p.amount)).font(.headline).monospacedDigit()
                                    Text(verbatim: "≈ " + ExchangeRate.shared.usd(fromVND: Double(p.amount)))
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                    .disabled(!plans.bankReady || creating != nil)
                }
                if plans.plans.isEmpty { Text("Chưa có gói DTDStudio trên máy chủ.").font(.footnote).foregroundStyle(.secondary) }
            } else {
                ProgressView()
            }
            if let error { Text(verbatim: error).font(.footnote).foregroundStyle(.red) }
        }
        .task {
            do { plans = try await account.plans() } catch { self.error = error.localizedDescription }
        }
    }
}

struct StudioTransferRows: View {
    @ObservedObject var account: StudioAccount
    @State var order: StudioOrder
    let done: () -> Void

    var body: some View {
        switch order.status {
        case "paid":
            Label("Đã nhận tiền — gói đã kích hoạt", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            Button("Xong", action: done)
        case "expired", "cancelled":
            Label("Đơn đã hết hạn hoặc bị huỷ", systemImage: "xmark.circle").foregroundStyle(.orange)
            Button("Chọn lại gói", action: done)
        default:
            if let qr = order.qr, !qr.isEmpty, let img = Self.qrImage(qr) {
                HStack {
                    Spacer()
                    Image(uiImage: img).interpolation(.none).resizable().frame(width: 220, height: 220)
                        .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10))
                    Spacer()
                }
                Text("Quét bằng app ngân hàng bất kỳ – số tiền và nội dung đã điền sẵn").font(.footnote).foregroundStyle(.secondary)
            }
            if let b = order.bank {
                LabeledContent("Ngân hàng", value: b.bankName)
                LabeledContent("Số tài khoản", value: b.account).textSelection(.enabled)
                LabeledContent("Chủ tài khoản", value: b.accountName)
            }
            LabeledContent("Số tiền", value: VND.format(order.amount))
            LabeledContent("Nội dung", value: order.code).textSelection(.enabled)
            HStack(spacing: 8) {
                ProgressView()
                Text("Đang chờ ngân hàng xác nhận…").font(.subheadline)
            }
            Button("Huỷ đơn", role: .destructive) { Task { await account.cancelOrder(order.code); done() } }
                .task(id: order.code) { await poll() }
        }
    }

    private func poll() async {
        while !Task.isCancelled && order.status == "pending" {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let o = try? await account.order(order.code) else { continue }
            order = o
        }
    }

    static func qrImage(_ payload: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(payload.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Settings row: plan status + open the plans screen.
struct PlanSettingsRows: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var account: StudioAccount
    @State private var open = false

    init() {
        _store = ObservedObject(wrappedValue: StudioPlan.shared.store)
        _account = ObservedObject(wrappedValue: StudioPlan.shared.account)
    }

    var body: some View {
        let until = [store.until, account.until].compactMap { $0 }.max()
        LabeledContent("Trạng thái", value: until.map { LF("Đến %@", $0.formatted(date: .abbreviated, time: .omitted)) } ?? L("Chưa có gói"))
        Button { open = true } label: { Label("Mua gói ngày / tháng / năm", systemImage: "cart") }
            .sheet(isPresented: $open) { PlansView() }
    }
}

import SwiftUI

/// HTML5 graphics: pick a template (arms it), edit its fields live, update from Git.
/// It goes on air with the "HTML On" key in the right column.
struct HTMLGraphicsPanel: View {
    @ObservedObject var html: HTMLGraphics
    @ObservedObject var repo: GraphicsRepo
    var compact = false

    var body: some View {
        SectionCard("Đồ hoạ HTML5", systemImage: "chevron.left.forwardslash.chevron.right") {
            HStack(spacing: 8) {
                Button {
                    Task { await repo.sync() }
                } label: {
                    Label(repo.syncing ? "Đang tải…" : "Cập nhật từ Git", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: compact ? 28 : 32)
                        .foregroundStyle(.white).background(DS.surface2, in: Rectangle())
                }
                .buttonStyle(.plain).disabled(repo.syncing)
                Text(repo.status.isEmpty ? "\(repo.settings.owner)/\(repo.settings.repo) › \(repo.settings.path)" : repo.status)
                    .font(.caption2).foregroundStyle(DS.text3).lineLimit(1)
                Spacer()
                if html.loadedID != nil {
                    Button { html.next() } label: {
                        Label("Next", systemImage: "forward.frame").font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).frame(height: compact ? 28 : 32)
                            .foregroundStyle(.white).background(DS.surface2, in: Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(html.templates) { t in
                        let loaded = html.loadedID == t.id
                        Button { html.load(t.id) } label: {
                            Text(t.name).font(.system(size: compact ? 12 : 13, weight: .semibold)).lineLimit(1)
                                .padding(.horizontal, 12).frame(height: compact ? 30 : 36)
                                .foregroundStyle(loaded ? .black : .white)
                                .background(loaded ? (html.onAir ? DS.pgm : DS.accent) : DS.surface2, in: Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let t = html.templates.first(where: { $0.id == html.loadedID }) {
                ForEach(t.fields) { f in
                    if f.isColor {
                        ColorPicker(f.label, selection: Binding(get: { Color(UIColor(hex: html.value(t, f))) },
                                                                set: { html.setValue(t, f, UIColor($0).hexString) }),
                                    supportsOpacity: false)
                            .font(.caption.weight(.semibold)).foregroundStyle(DS.text2)
                    } else {
                        TextField(f.label, text: Binding(get: { html.value(t, f) }, set: { html.setValue(t, f, $0) }))
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 8).frame(height: 34)
                            .background(DS.surface2, in: Rectangle())
                    }
                }
            }
        }
    }
}

/// Git source for HTML5 graphics (Settings).
struct GraphicsRepoRows: View {
    @ObservedObject var repo: GraphicsRepo
    @State private var token = ""

    var body: some View {
        Group {
            TextField("Chủ repo (owner)", text: $repo.settings.owner).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Repo", text: $repo.settings.repo).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Nhánh", text: $repo.settings.branch).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Thư mục đồ hoạ", text: $repo.settings.path).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Token (chỉ cần cho repo private)", text: $token)
                .onSubmit { repo.token = token }
                .onAppear { token = repo.token }
            HStack {
                Button(repo.syncing ? "Đang tải…" : "Cập nhật từ Git") { repo.token = token; Task { await repo.sync(force: true) } }
                    .disabled(repo.syncing)
                Spacer()
                Text(repo.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

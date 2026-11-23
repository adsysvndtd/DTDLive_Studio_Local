import SwiftUI

/// Chroma key → "Nền thay thế": what replaces the green / blue screen. A picture or video from the
/// library (added as an input without touching PVW/PGM), a solid colour, any input, or transparent.
struct KeyBackgroundRow: View {
    @ObservedObject var engine: StudioEngine
    let id: UUID
    let p: SourceProcessing
    @State private var picking: LibraryKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Nền thay thế").font(DS.fBody).foregroundStyle(DS.text2)
                Spacer()
                Menu {
                    Button { set(nil, nil) } label: { Label("Trong suốt", systemImage: "checkerboard.rectangle") }
                    Button { set(nil, p.keyBackgroundHex ?? "#1E3A8A") } label: { Label("Màu đơn sắc", systemImage: "paintpalette") }
                    Button { picking = .picture } label: { Label("Ảnh từ thư viện…", systemImage: "photo") }
                    Button { picking = .movie } label: { Label("Video từ thư viện…", systemImage: "film") }
                    let others = engine.sources.filter { $0.id != id }
                    if !others.isEmpty {
                        Section("Nguồn đang có") {
                            ForEach(others, id: \.id) { s in
                                Button { set(s.id, nil) } label: { Text(verbatim: s.name) }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        swatch
                        Text(verbatim: currentName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                }
            }
            if p.keyBackgroundID == nil, let hex = p.keyBackgroundHex {
                ColorPicker(selection: Binding(get: { Color(UIColor(hex: hex)) },
                                               set: { set(nil, UIColor($0).hexString) }), supportsOpacity: false) {
                    Text("Màu nền").font(DS.fBody).foregroundStyle(DS.text2)
                }
            }
            Text(hint).font(.system(size: 11)).foregroundStyle(DS.text3)
        }
        .sheet(item: $picking) { kind in
            KeyBackgroundLibraryPicker(library: engine.library, kind: kind) { url in
                if let bid = engine.libraryInput(url, movie: kind == .movie) { set(bid, nil) }
            }
        }
    }

    private var currentName: String {
        if let bid = p.keyBackgroundID {
            return engine.sources.first { $0.id == bid }?.name ?? L("Nguồn đã bị xoá")
        }
        return p.keyBackgroundHex != nil ? L("Màu đơn sắc") : L("Trong suốt")
    }

    @ViewBuilder private var swatch: some View {
        if p.keyBackgroundID == nil, let hex = p.keyBackgroundHex {
            RoundedRectangle(cornerRadius: 3).fill(Color(UIColor(hex: hex))).frame(width: 16, height: 16)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.4)))
        } else {
            Image(systemName: p.keyBackgroundID == nil ? "checkerboard.rectangle" : "photo.on.rectangle").font(.system(size: 12))
        }
    }

    private var hint: LocalizedStringKey {
        if p.keyBackgroundID != nil { return "Phần phông xanh được thay bằng nguồn này (phủ kín khung, giữ tỉ lệ)." }
        if p.keyBackgroundHex != nil { return "Phần phông xanh được thay bằng màu này." }
        return "Trong suốt: phần phông xanh để trống — dùng khi nguồn này làm lớp chồng (PiP / layout / key)."
    }

    private func set(_ bid: UUID?, _ hex: String?) {
        var n = p
        n.keyBackgroundID = bid
        n.keyBackgroundHex = bid == nil ? hex : nil
        engine.setProcessing(id, n)
    }
}

/// Grid of library pictures or videos to put behind a chroma key.
struct KeyBackgroundLibraryPicker: View {
    @ObservedObject var library: MediaLibrary
    let kind: LibraryKind
    var onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                let files = library.items[kind] ?? []
                if files.isEmpty {
                    Text(kind == .movie ? L("Thư viện Video chưa có video. Nhập ở mục Video › Video từ Ảnh / Từ Tệp.")
                                        : L("Thư viện chưa có ảnh. Nhập ở mục Ảnh › Ảnh từ Thư viện / Từ Tệp."))
                        .font(.system(size: 13)).foregroundStyle(DS.text3).padding()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(files, id: \.self) { u in
                        Button { onPick(u); dismiss() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                ZStack {
                                    Color.black
                                    if let t = MediaLibrary.thumbnail(u, kind: kind) { Image(uiImage: t).resizable().scaledToFill() }
                                }
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(verbatim: u.deletingPathExtension().lastPathComponent).font(.system(size: 12)).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
            .navigationTitle(kind == .movie ? L("Chọn video làm nền") : L("Chọn ảnh làm nền"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } } }
        }
    }
}

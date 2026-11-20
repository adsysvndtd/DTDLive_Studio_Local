import SwiftUI

/// Import video → build the list → schedule → stream connections open at the start time.
struct PlayoutSheet: View {
    @ObservedObject var playout: PlayoutController
    @ObservedObject var engine: StudioEngine
    @ObservedObject var library: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var confirmStop = false

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                listSection
                scheduleSection
                flowSection
            }
            .navigationTitle("Danh sách phát")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }
        .onAppear { playout.loadDurations() }
        .onChange(of: playout.plan.files) { _, _ in playout.loadDurations() }
        .sheet(isPresented: $picking) {
            MoviePickerSheet(files: library.items[.movie] ?? []) { names in
                playout.plan.files.append(contentsOf: names)
            }
        }
        .confirmationDialog("Dừng danh sách phát?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Dừng", role: .destructive) { playout.stop() }
        } message: {
            Text("PGM không tự đổi: nếu danh sách đang trên PGM, hình đứng ở khung hiện tại cho đến khi anh bấm chuyển cảnh.")
        }
    }

    // MARK: Status / controls

    @ViewBuilder private var statusSection: some View {
        Section {
            switch playout.state {
            case .idle:
                HStack(spacing: 10) {
                    bigButton("Đưa lên PVW", "rectangle.on.rectangle", DS.pvw) { playout.cue() }
                    if playout.plan.scheduled {
                        bigButton("Hẹn giờ", "clock.badge.checkmark", DS.accent) { playout.arm() }
                    }
                }
                .disabled(playout.plan.files.isEmpty)
            case .armed:
                VStack(alignment: .leading, spacing: 6) {
                    Label(LF("Lên PVW lúc %@", Self.dateTime.string(from: playout.plan.startAt)), systemImage: "clock.badge.checkmark")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.accent)
                    Text(LF("Còn %@", Self.clock(playout.plan.startAt.timeIntervalSince(playout.now))))
                        .font(.system(size: 24, weight: .bold).monospacedDigit())
                }
                HStack(spacing: 10) {
                    bigButton("Đưa lên PVW ngay", "rectangle.on.rectangle", DS.pvw) { playout.cue() }
                    bigButton("Huỷ hẹn giờ", "xmark", DS.surface2) { playout.cancelSchedule() }
                }
            case .cued:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Sẵn sàng trên PVW", systemImage: "rectangle.on.rectangle").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.pvw)
                    Text(verbatim: playout.source?.currentName ?? "").font(.system(size: 14)).lineLimit(1)
                    Text("Bấm CUT / AUTO / kéo T-bar để đưa lên PGM — danh sách bắt đầu chạy khi lên PGM.")
                        .font(.system(size: 12)).foregroundStyle(DS.text3)
                }
                HStack(spacing: 10) {
                    bigButton("Clip trước", "backward.end.fill", DS.surface2) { playout.skip(-1) }
                    bigButton("Clip sau", "forward.end.fill", DS.surface2) { playout.skip(1) }
                    bigButton("Huỷ", "xmark", DS.surface2) { playout.stop() }
                }
            case .playing:
                nowPlaying
                HStack(spacing: 10) {
                    bigButton("Clip trước", "backward.end.fill", DS.surface2) { playout.skip(-1) }
                    bigButton("Clip sau", "forward.end.fill", DS.surface2) { playout.skip(1) }
                    bigButton("Dừng", "stop.fill", DS.pgm) { confirmStop = true }
                }
            case .finished:
                Label("Đã phát hết — đang giữ khung cuối", systemImage: "checkmark.circle").foregroundStyle(DS.text2)
                HStack(spacing: 10) {
                    bigButton("Đưa lại lên PVW", "arrow.counterclockwise", DS.pvw) { playout.cue() }
                    bigButton("Đóng danh sách", "xmark", DS.surface2) { playout.stop() }
                }
            }
        } footer: {
            if playout.isActive {
                Text("Giữ DTDStudio mở trên màn hình cho đến khi phát xong: iPad không cho ứng dụng xử lý hình khi ở nền. Màn hình được giữ sáng tự động.")
            }
        }
    }

    @ViewBuilder private var nowPlaying: some View {
        let n = playout.source?.urls.count ?? playout.plan.files.count
        let pos = playout.source?.currentSeconds ?? 0
        let dur = playout.source?.durationSeconds ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: "● " + L("ĐANG PHÁT")).font(.system(size: 12, weight: .bold)).foregroundStyle(DS.pgm)
                Text(verbatim: "\(playout.index + 1)/\(n)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DS.text2)
                Spacer()
                if playout.plan.loop { Label("Lặp lại", systemImage: "repeat").font(.system(size: 11)).foregroundStyle(DS.text3) }
            }
            Text(verbatim: playout.source?.currentName ?? "").font(.system(size: 16, weight: .semibold)).lineLimit(1)
            ProgressView(value: dur > 0 ? min(pos / dur, 1) : 0).tint(DS.pgm)
            HStack {
                Text(verbatim: Self.clock(pos)).font(.system(size: 11).monospacedDigit())
                Spacer()
                Text(verbatim: "−" + Self.clock(max(0, dur - pos))).font(.system(size: 11).monospacedDigit())
            }
            .foregroundStyle(DS.text3)
            .id(playout.now)                                // refreshed by the one-second tick
        }
    }

    // MARK: List

    private var listSection: some View {
        Section {
            if playout.plan.files.isEmpty {
                Text("Chưa có video. Nhập video ở mục Video (Từ Ảnh / Từ Tệp), rồi thêm vào đây.")
                    .font(.system(size: 13)).foregroundStyle(DS.text3)
            }
            ForEach(Array(playout.plan.files.enumerated()), id: \.offset) { i, f in
                row(i, f)
            }
            .onDelete { playout.plan.files.remove(atOffsets: $0) }
            .onMove { playout.plan.files.move(fromOffsets: $0, toOffset: $1) }
            Button { picking = true } label: { Label("Thêm video từ thư viện", systemImage: "plus.circle.fill") }
            Toggle("Lặp lại cả danh sách", isOn: $playout.plan.loop)
        } header: {
            Text(LF("Danh sách · %@ video · %@", "\(playout.plan.files.count)", Self.clock(playout.totalDuration)))
        } footer: {
            if playout.state == .playing {
                Text("Thay đổi danh sách áp dụng cho lần phát sau. Chạm vào một clip để chuyển ngay sang clip đó.")
            } else {
                Text("Vuốt sang trái để xoá, giữ và kéo để đổi thứ tự.")
            }
        }
    }

    private func row(_ i: Int, _ f: String) -> some View {
        let url = playout.url(f)
        let missing = !playout.exists(f)
        let current = (playout.state == .playing || playout.state == .cued) && playout.index == i && playout.source?.urls.count == playout.plan.files.count
        return HStack(spacing: 10) {
            Text(verbatim: "\(i + 1)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(DS.text3).frame(width: 22)
            ZStack {
                Color.black
                if let t = MediaLibrary.thumbnail(url, kind: .movie) { Image(uiImage: t).resizable().scaledToFill() }
            }
            .frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: url.deletingPathExtension().lastPathComponent).font(.system(size: 14, weight: current ? .bold : .regular))
                    .lineLimit(1).foregroundStyle(missing ? DS.text3 : (current ? DS.pgm : .primary))
                HStack(spacing: 8) {
                    if missing {
                        Text("Không còn trong thư viện").foregroundStyle(.orange)
                    } else {
                        Text(verbatim: playout.durations[f].map(Self.clock) ?? "—")
                        if playout.plan.scheduled || playout.state == .playing {
                            Text(verbatim: "▸ " + Self.time.string(from: playout.plannedStart(of: i)))
                        }
                    }
                }
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(DS.text3)
            }
            Spacer(minLength: 4)
            if current { Image(systemName: "speaker.wave.2.fill").foregroundStyle(DS.pgm) }
            Menu {
                Button { move(i, -1) } label: { Label("Lên trên", systemImage: "arrow.up") }.disabled(i == 0)
                Button { move(i, 1) } label: { Label("Xuống dưới", systemImage: "arrow.down") }
                    .disabled(i == playout.plan.files.count - 1)
                Button { playout.plan.files.insert(f, at: i + 1) } label: { Label("Nhân đôi", systemImage: "plus.square.on.square") }
                Button(role: .destructive) { playout.plan.files.remove(at: i) } label: { Label("Xoá khỏi danh sách", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(DS.text2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if (playout.state == .playing || playout.state == .cued) && !missing { playout.playClip(i) } }
    }

    private func move(_ i: Int, _ d: Int) {
        let j = i + d
        guard playout.plan.files.indices.contains(i), playout.plan.files.indices.contains(j) else { return }
        playout.plan.files.swapAt(i, j)
    }

    // MARK: Schedule

    private var scheduleSection: some View {
        Section {
            Picker("Bắt đầu", selection: $playout.plan.scheduled) {
                Text("Khi bấm Bắt đầu").tag(false)
                Text("Hẹn giờ").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(playout.isActive)
            if playout.plan.scheduled {
                DatePicker("Giờ lên PVW", selection: $playout.plan.startAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .disabled(playout.state != .idle && playout.state != .finished)
                if !playout.plan.loop && playout.totalDuration > 0 {
                    LabeledContent("Kết thúc dự kiến",
                                   value: Self.dateTime.string(from: playout.plan.startAt.addingTimeInterval(playout.totalDuration)))
                }
            }
        } header: {
            Text("Lịch phát")
        } footer: {
            if playout.plan.loop {
                Text("Đang bật Lặp lại: danh sách phát mãi cho đến khi bấm Dừng.")
            } else {
                Text("Đến giờ hẹn, danh sách lên PVW và dừng ở khung đầu. Hết danh sách thì giữ khung cuối.")
            }
        }
    }

    // MARK: Flow

    private var flowSection: some View {
        Section {
            flowStep("1", "Đưa lên PVW", "Bấm Đưa lên PVW (hoặc đến giờ hẹn): danh sách chờ ở khung đầu.")
            flowStep("2", "Chuyển cảnh lên PGM", "CUT / AUTO / T-bar / stinger: danh sách bắt đầu chạy.")
            flowStep("3", "Phát", "Bật kết nối ở mục Đầu ra (YouTube, Facebook, RTMP, SRT…) như bình thường.")
        } header: {
            Text("Quy trình")
        } footer: {
            Text("Bấm vào nguồn hay danh sách chỉ đưa lên PVW; chỉ các nút chuyển cảnh mới đổi PGM. Logo, title và bảng tỉ số vẫn hiện trên hình phát.")
        }
    }

    private func flowStep(_ n: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: n).font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                .frame(width: 22, height: 22).background(DS.accent, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.system(size: 14, weight: .semibold))
                Text(LocalizedStringKey(detail)).font(.system(size: 12)).foregroundStyle(DS.text3)
            }
        }
    }

    // MARK: Helpers

    private func bigButton(_ title: String, _ icon: String, _ bg: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(title), systemImage: icon)
                .font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 44)
                .foregroundStyle(bg == DS.surface2 ? Color.white : Color.black)
                .background(bg, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
    }

    static func clock(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "00:00" }
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }

    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    static let dateTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm · dd/MM"; return f }()
}

/// Pick several videos from the library (in the order they are tapped).
private struct MoviePickerSheet: View {
    let files: [URL]
    var onAdd: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [String] = []

    var body: some View {
        NavigationStack {
            List {
                if files.isEmpty {
                    Text("Thư viện Video chưa có video. Nhập ở mục Video › Video từ Ảnh / Từ Tệp.")
                        .font(.system(size: 13)).foregroundStyle(DS.text3)
                }
                ForEach(files, id: \.self) { u in
                    let name = u.lastPathComponent
                    let order = picked.firstIndex(of: name)
                    Button {
                        if let k = order { picked.remove(at: k) } else { picked.append(name) }
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                Color.black
                                if let t = MediaLibrary.thumbnail(u, kind: .movie) { Image(uiImage: t).resizable().scaledToFill() }
                            }
                            .frame(width: 72, height: 40).clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(verbatim: u.deletingPathExtension().lastPathComponent).lineLimit(1)
                            Spacer()
                            if let k = order {
                                Text(verbatim: "\(k + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                                    .frame(width: 24, height: 24).background(DS.accent, in: Circle())
                            } else {
                                Image(systemName: "circle").foregroundStyle(DS.text3)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Chọn video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? L("Thêm") : LF("Thêm (%@)", "\(picked.count)")) { onAdd(picked); dismiss() }
                        .disabled(picked.isEmpty)
                }
            }
        }
    }
}

/// Compact line on the Video tab while a list is scheduled / playing.
struct PlayoutStatusBar: View {
    @ObservedObject var playout: PlayoutController
    var open: () -> Void

    var body: some View {
        if playout.state != .idle {
            Button(action: open) {
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundStyle(tint)
                    Text(verbatim: text).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text("Mở").font(.system(size: 12)).foregroundStyle(DS.text3)
                }
                .padding(.horizontal, 10).frame(height: 36)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: DS.radius))
                .overlay(RoundedRectangle(cornerRadius: DS.radius).stroke(tint.opacity(0.5)))
            }
            .buttonStyle(.plain)
        }
    }

    private var icon: String {
        switch playout.state {
        case .armed: return "clock.badge.checkmark"
        case .cued: return "rectangle.on.rectangle"
        case .playing: return "play.rectangle.fill"
        default: return "checkmark.circle"
        }
    }
    private var tint: Color { playout.state == .playing ? DS.pgm : playout.state == .cued ? DS.pvw : DS.accent }
    private var text: String {
        switch playout.state {
        case .armed:
            return LF("Danh sách phát: lên PVW lúc %@ · còn %@", PlayoutSheet.dateTime.string(from: playout.plan.startAt),
                      PlayoutSheet.clock(playout.plan.startAt.timeIntervalSince(playout.now)))
        case .cued:
            return L("Danh sách phát sẵn sàng trên PVW — chuyển cảnh để phát")
        case .playing:
            let n = playout.source?.urls.count ?? 0
            return LF("Danh sách phát %@/%@: %@", "\(playout.index + 1)", "\(n)", playout.source?.currentName ?? "")
        default:
            return L("Danh sách phát đã phát hết")
        }
    }
}

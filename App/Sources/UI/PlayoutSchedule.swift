import SwiftUI

/// "Lịch theo ngày": the day's time slots, each with its own video list. At a slot's time its list is cued
/// on PVW (first frame); a transition puts it on PGM, where it starts rolling.
struct DayScheduleSections: View {
    @ObservedObject var playout: PlayoutController
    @ObservedObject var library: MediaLibrary
    @State private var day = Date()
    @State private var editing: SlotRef?

    struct SlotRef: Identifiable { let id: UUID }

    var body: some View {
        Section {
            Toggle(isOn: $playout.scheduleOn) {
                Label("Chạy lịch tự động", systemImage: "calendar.badge.clock")
            }
            if let n = playout.nextFire(after: playout.now) {
                LabeledContent("Tiếp theo") {
                    Text(verbatim: nextLabel(n.slot, n.at)).multilineTextAlignment(.trailing)
                }
            } else {
                Text("Chưa có khung giờ nào sắp tới").font(.system(size: 13)).foregroundStyle(DS.text3)
            }
        } header: {
            Text("Lịch theo ngày")
        } footer: {
            Text("Đến giờ của mỗi khung, danh sách của khung đó lên PVW (dừng ở khung đầu); bấm chuyển cảnh để phát. Giữ DTDStudio mở trên màn hình khi lịch đang chạy.")
        }

        Section {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
                    .buttonStyle(.borderless)
                Spacer()
                DatePicker("", selection: $day, displayedComponents: .date).labelsHidden()
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 32, height: 32) }
                    .buttonStyle(.borderless)
            }
            if !Calendar.current.isDateInToday(day) {
                Button("Về hôm nay") { day = Date() }
            }
            let slots = playout.slots(on: day)
            if slots.isEmpty {
                Text("Chưa có khung giờ nào trong ngày này.").font(.system(size: 13)).foregroundStyle(DS.text3)
            }
            ForEach(Array(slots.enumerated()), id: \.element.id) { i, s in
                slotRow(s, next: i + 1 < slots.count ? slots[i + 1] : nil)
            }
            Button { addSlot() } label: { Label("Thêm khung giờ", systemImage: "plus.circle.fill") }
        } header: {
            Text(verbatim: Self.dayTitle.string(from: day))
        } footer: {
            Text("Chạm vào một khung để sửa giờ, video, lặp lại theo ngày / theo thứ.")
        }
        .sheet(item: $editing) { ref in
            SlotEditorSheet(playout: playout, library: library, slotID: ref.id)
        }
        .onAppear { playout.loadDurations() }
    }

    // MARK: Rows

    private func slotRow(_ s: ScheduleSlot, next: ScheduleSlot?) -> some View {
        let cal = Calendar.current
        let start = s.fireTime(on: day, cal)
        let dur = playout.duration(of: s.files)
        let end = start.addingTimeInterval(dur)
        let overlap = !s.loop && dur > 0 && (next.map { end > $0.fireTime(on: day, cal) } ?? false)
        return Button { editing = SlotRef(id: s.id) } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: PlayoutController.hm.string(from: start))
                        .font(.system(size: 17, weight: .bold).monospacedDigit())
                    if dur > 0 && !s.loop {
                        Text(verbatim: "→ " + PlayoutController.hm.string(from: end))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(DS.text3)
                    }
                }
                .frame(width: 62, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: s.name.isEmpty ? L("Danh sách phát") : s.name)
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(s.enabled ? Color.primary : DS.text3)
                    Text(verbatim: LF("%@ video · %@", "\(s.files.count)", PlayoutSheet.clock(dur)) + (s.loop ? " · " + L("Lặp lại") : ""))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(DS.text3)
                    HStack(spacing: 6) {
                        badge(Self.repeatLabel(s), DS.text2)
                        if !s.enabled { badge(L("Đang tắt"), DS.text3) }
                        if s.files.isEmpty { badge(L("Chưa có video"), .orange) }
                        if overlap { badge(L("Chồng giờ với khung sau"), .orange) }
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(DS.text3).padding(.top, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    // MARK: Actions

    private func shift(_ d: Int) {
        day = Calendar.current.date(byAdding: .day, value: d, to: day) ?? day
    }

    /// New slot: after the last one of the day (rounded up to 5 min), else the next hour today / 08:00.
    private func addSlot() {
        let cal = Calendar.current
        var start: Date
        if let last = playout.slots(on: day).last {
            let end = last.fireTime(on: day, cal).addingTimeInterval(max(playout.duration(of: last.files), 300))
            start = Date(timeIntervalSince1970: (end.timeIntervalSince1970 / 300).rounded(.up) * 300)
        } else if cal.isDateInToday(day) {
            let h = min(23, cal.component(.hour, from: Date()) + 1)
            start = cal.date(bySettingHour: h, minute: 0, second: 0, of: day) ?? day
        } else {
            start = cal.date(bySettingHour: 8, minute: 0, second: 0, of: day) ?? day
        }
        if !cal.isDate(start, inSameDayAs: day) { start = cal.date(bySettingHour: 23, minute: 55, second: 0, of: day) ?? day }
        var s = ScheduleSlot()
        s.start = start
        s.name = LF("Khung %@", PlayoutController.hm.string(from: start))
        playout.schedule.append(s)
        editing = SlotRef(id: s.id)
    }

    private func nextLabel(_ s: ScheduleSlot, _ at: Date) -> String {
        let name = s.name.isEmpty ? L("Danh sách phát") : s.name
        let cal = Calendar.current
        let when = cal.isDateInToday(at) ? PlayoutController.hm.string(from: at)
            : Self.shortDay.string(from: at) + " " + PlayoutController.hm.string(from: at)
        return when + " · " + name + " · " + LF("còn %@", PlayoutSheet.clock(at.timeIntervalSince(playout.now)))
    }

    static let weekdays: [(day: Int, label: String)] = [(2, "T2"), (3, "T3"), (4, "T4"), (5, "T5"), (6, "T6"), (7, "T7"), (1, "CN")]

    static func repeatLabel(_ s: ScheduleSlot) -> String {
        if s.repeatDays.isEmpty { return L("Chỉ ngày này") }
        if Set(s.repeatDays).count == 7 { return L("Hằng ngày") }
        return weekdays.filter { s.repeatDays.contains($0.day) }.map(\.label).joined(separator: " ")
    }

    static let dayTitle: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE, dd/MM/yyyy"; return f }()
    static let shortDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE dd/MM"; return f }()
}

/// Edit one time slot: name, start, repeat (once / daily / weekdays), its videos.
struct SlotEditorSheet: View {
    @ObservedObject var playout: PlayoutController
    @ObservedObject var library: MediaLibrary
    let slotID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var confirmDelete = false

    private var slot: Binding<ScheduleSlot> {
        Binding(get: { playout.schedule.first { $0.id == slotID } ?? ScheduleSlot() },
                set: { nv in
                    if let i = playout.schedule.firstIndex(where: { $0.id == slotID }) { playout.schedule[i] = nv }
                })
    }

    /// 0 only that day · 1 every day · 2 chosen weekdays
    private var repeatMode: Binding<Int> {
        Binding(get: {
            let d = slot.wrappedValue.repeatDays
            return d.isEmpty ? 0 : (Set(d).count == 7 ? 1 : 2)
        }, set: { m in
            switch m {
            case 0: slot.wrappedValue.repeatDays = []
            case 1: slot.wrappedValue.repeatDays = [1, 2, 3, 4, 5, 6, 7]
            default:
                let d = slot.wrappedValue.repeatDays
                if d.isEmpty || Set(d).count == 7 { slot.wrappedValue.repeatDays = [2, 3, 4, 5, 6] }
            }
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tên khung giờ (ví dụ: Bản tin trưa)", text: slot.name)
                    DatePicker("Bắt đầu", selection: slot.start, displayedComponents: [.date, .hourAndMinute])
                    Toggle("Bật khung giờ này", isOn: slot.enabled)
                }
                Section {
                    Picker("Lặp lại", selection: repeatMode) {
                        Text("Chỉ ngày này").tag(0)
                        Text("Hằng ngày").tag(1)
                        Text("Chọn thứ").tag(2)
                    }
                    .pickerStyle(.segmented)
                    if repeatMode.wrappedValue == 2 {
                        HStack(spacing: 6) {
                            ForEach(DayScheduleSections.weekdays, id: \.day) { w in dayChip(w.day, w.label) }
                        }
                    }
                } header: {
                    Text("Lặp lại")
                } footer: {
                    if repeatMode.wrappedValue != 0 {
                        Text("Lặp lại từ ngày bắt đầu trở đi, cùng giờ.")
                    }
                }
                videosSection
                Section {
                    Button {
                        let s = slot.wrappedValue
                        playout.cue(files: s.files, loop: s.loop, name: s.name.isEmpty ? L("Danh sách phát") : s.name)
                        dismiss()
                    } label: { Label("Đưa lên PVW ngay", systemImage: "rectangle.on.rectangle") }
                    .disabled(slot.wrappedValue.files.isEmpty)
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Xoá khung giờ", systemImage: "trash") }
                }
            }
            .navigationTitle("Khung giờ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }
        .onAppear { playout.loadDurations(slot.wrappedValue.files) }
        .onChange(of: slot.wrappedValue.files) { _, f in playout.loadDurations(f) }
        .sheet(isPresented: $picking) {
            MoviePickerSheet(files: library.items[.movie] ?? []) { names in slot.wrappedValue.files.append(contentsOf: names) }
        }
        .confirmationDialog("Xoá khung giờ này?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Xoá", role: .destructive) {
                playout.schedule.removeAll { $0.id == slotID }
                dismiss()
            }
        }
    }

    private var videosSection: some View {
        let files = slot.wrappedValue.files
        let dur = playout.duration(of: files)
        return Section {
            if files.isEmpty {
                Text("Chưa có video trong khung giờ này.").font(.system(size: 13)).foregroundStyle(DS.text3)
            }
            ForEach(Array(files.enumerated()), id: \.offset) { i, f in
                videoRow(i, f)
            }
            .onDelete { slot.wrappedValue.files.remove(atOffsets: $0) }
            .onMove { slot.wrappedValue.files.move(fromOffsets: $0, toOffset: $1) }
            Button { picking = true } label: { Label("Thêm video từ thư viện", systemImage: "plus.circle.fill") }
            Toggle("Lặp lại cả danh sách", isOn: slot.loop)
        } header: {
            Text(LF("Video · %@ · %@", "\(files.count)", PlayoutSheet.clock(dur)))
        } footer: {
            if slot.wrappedValue.loop {
                Text("Lặp lại: danh sách chạy mãi cho đến khi khung giờ sau lên PVW và anh chuyển cảnh, hoặc bấm Dừng.")
            } else if dur > 0 {
                Text(verbatim: LF("Kết thúc khoảng %@", PlayoutController.hm.string(from: slot.wrappedValue.start.addingTimeInterval(dur))))
            }
        }
    }

    private func videoRow(_ i: Int, _ f: String) -> some View {
        let url = playout.url(f)
        let missing = !playout.exists(f)
        return HStack(spacing: 10) {
            Text(verbatim: "\(i + 1)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(DS.text3).frame(width: 22)
            ZStack {
                Color.black
                if let t = MediaLibrary.thumbnail(url, kind: .movie) { Image(uiImage: t).resizable().scaledToFill() }
            }
            .frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: url.deletingPathExtension().lastPathComponent).font(.system(size: 14)).lineLimit(1)
                    .foregroundStyle(missing ? DS.text3 : Color.primary)
                if missing {
                    Text("Không còn trong thư viện").font(.system(size: 11)).foregroundStyle(.orange)
                } else {
                    Text(verbatim: playout.durations[f].map(PlayoutSheet.clock) ?? "—")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(DS.text3)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button { move(i, -1) } label: { Label("Lên trên", systemImage: "arrow.up") }.disabled(i == 0)
                Button { move(i, 1) } label: { Label("Xuống dưới", systemImage: "arrow.down") }
                    .disabled(i == slot.wrappedValue.files.count - 1)
                Button { slot.wrappedValue.files.insert(f, at: i + 1) } label: { Label("Nhân đôi", systemImage: "plus.square.on.square") }
                Button(role: .destructive) { slot.wrappedValue.files.remove(at: i) } label: { Label("Xoá khỏi danh sách", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(DS.text2) }
        }
    }

    private func move(_ i: Int, _ d: Int) {
        var f = slot.wrappedValue.files
        let j = i + d
        guard f.indices.contains(i), f.indices.contains(j) else { return }
        f.swapAt(i, j)
        slot.wrappedValue.files = f
    }

    private func dayChip(_ d: Int, _ label: String) -> some View {
        let on = slot.wrappedValue.repeatDays.contains(d)
        return Button {
            var days = slot.wrappedValue.repeatDays
            if on { days.removeAll { $0 == d } } else { days.append(d) }
            slot.wrappedValue.repeatDays = days.sorted()
        } label: {
            Text(verbatim: label).font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 32)
                .foregroundStyle(on ? Color.black : Color.white)
                .background(on ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
    }
}

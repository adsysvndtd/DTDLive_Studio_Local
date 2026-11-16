import SwiftUI

// MARK: - Sport picker (chip in the scoreboard bar)

/// Chọn môn / luật cho bảng tỉ số. Đổi môn giữa trận sẽ hỏi lại vì tỉ số bị xoá.
struct SportPickerMenu: View {
    @ObservedObject var engine: StudioEngine
    var compact = false
    @State private var pendingTemplate: SportTemplate?? = nil

    private var currentTitle: String {
        guard let i = engine.scoreboardIndex, let raw = engine.titles[i].sb.sportTemplate,
              let t = SportTemplate(rawValue: raw) else { return L("Tự do") }
        return t.title(.current)
    }

    var body: some View {
        Menu {
            Button { choose(nil) } label: { Label("Tự do (+/−)", systemImage: "plusminus") }
            ForEach(SportTemplate.groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { t in
                        Button(t.title(.current)) { choose(t) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: currentTitle).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(.black)
            .background(DS.accent, in: Capsule())
        }
        .confirmationDialog("Đổi môn sẽ bắt đầu trận mới (tỉ số hiện tại bị xoá).",
                            isPresented: Binding(get: { pendingTemplate != nil }, set: { if !$0 { pendingTemplate = nil } }),
                            titleVisibility: .visible) {
            Button("Đổi môn", role: .destructive) {
                if let p = pendingTemplate { engine.setScoreboardSport(p) }
                pendingTemplate = nil
            }
        }
    }

    private func choose(_ t: SportTemplate?) {
        // hỏi lại nếu đang có trận theo luật đã bắt đầu
        if engine.scoreboardSport != nil && engine.sportCanUndo { pendingTemplate = .some(t) }
        else { engine.setScoreboardSport(t) }
    }
}

// MARK: - Quick buttons in the scoreboard bar (sport mode)

struct SportQuickBar: View {
    @ObservedObject var engine: StudioEngine
    var onOpenPad: () -> Void

    var body: some View {
        if let i = engine.scoreboardIndex, let sp = engine.titles[i].sportBoard {
            let t = engine.titles[i]
            let d = sp.display(lang: .current, at: Date())
            let cs = sp.controls(lang: .current).filter { $0.role == .primary }
            HStack(spacing: 8) {
                ForEach(Side.allCases, id: \.self) { s in
                    let row = d.rows[s.rawValue]
                    let c = cs.first { $0.side == s } ?? cs.first { $0.side == nil }
                    Button {
                        guard let c, c.enabled else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if c.inputPrompt != nil { engine.sportApply(c.make(nil)) } else { engine.sportApply(c.make(nil)) }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(DS.accent).frame(width: 7, height: 7).opacity(row.isServing ? 1 : 0)
                            Text(verbatim: String((s == .home ? t.line1 : t.line2).prefix(6)).uppercased())
                                .font(.system(size: 12, weight: .bold)).lineLimit(1)
                            Text(verbatim: row.main).font(.system(size: 20, weight: .heavy, design: .rounded)).monospacedDigit()
                            Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        }
                        .padding(.horizontal, 10).frame(height: 36)
                        .foregroundStyle(.black)
                        .background(c?.enabled == true ? DS.accent : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                    }
                    .buttonStyle(.plain)
                }
                Button { engine.sportUndo() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 12, weight: .bold)).frame(width: 30, height: 30)
                        .background(DS.surface2, in: Circle())
                }
                .buttonStyle(.plain).disabled(!engine.sportCanUndo)
                Button(action: onOpenPad) {
                    Label("Nhập điểm", systemImage: "square.grid.2x2").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Score pad (form overlay)

/// Bảng nhập điểm đầy đủ: xem trước đúng hình lên sóng, nút theo luật của môn (rally, bàn thắng, thẻ,
/// hết hiệp, luân lưu, rack, đổi lượt…), hoàn tác / làm lại, bật tắt trên sóng.
struct SportScorePad: View {
    @ObservedObject var engine: StudioEngine
    @Environment(\.dismiss) private var dismiss
    @State private var pending: SportControlItem?
    @State private var input = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                if let i = engine.scoreboardIndex {
                    let t = engine.titles[i]
                    VStack(alignment: .leading, spacing: 14) {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Image(uiImage: ScoreboardRenderer.render(t, now: ctx.date))
                                .resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 130)
                                .padding(8)
                                .background(CheckerBackground().opacity(0.5).clipShape(Rectangle()))
                        }
                        HStack {
                            SportPickerMenu(engine: engine)
                            Spacer()
                            Toggle(isOn: Binding(get: { t.visible }, set: { engine.setTitleVisible(t.id, $0) })) {
                                Text("Trên sóng").font(.system(size: 13, weight: .bold))
                            }
                            .toggleStyle(.button).tint(DS.pgm)
                        }
                        if let sp = t.sportBoard {
                            sportControls(sp, t)
                        } else {
                            freeControls(t)
                        }
                    }
                    .padding()
                }
            }
            .background(DS.bg)
            .navigationTitle("Nhập điểm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { engine.sportUndo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!engine.sportCanUndo)
                    Button { engine.sportRedo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!engine.sportCanRedo)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Xong") { dismiss() } }
            }
            .alert(Text(verbatim: pending?.inputPrompt ?? ""), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                TextField("", text: $input)
                // quick picks (e.g. players who already have a card, when removing one)
                ForEach(pending?.choices.prefix(6).map { $0 } ?? [], id: \.self) { name in
                    Button(name) {
                        if let p = pending { engine.sportApply(p.make(name)) }
                        pending = nil
                    }
                }
                Button("OK") {
                    if let p = pending { engine.sportApply(p.make(input)) }
                    pending = nil
                }
                Button("Huỷ", role: .cancel) { pending = nil }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    @ViewBuilder
    private func sportControls(_ sp: SportBoard, _ t: TitleItem) -> some View {
        let cs = sp.controls(lang: .current)
        let shared = cs.filter { $0.side == nil }
        if !shared.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                ForEach(shared.filter { $0.minusOf == nil }) { button($0) }
            }
        }
        HStack(alignment: .top, spacing: 12) {
            ForEach(Side.allCases, id: \.self) { s in
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(UIColor(hex: s == .home ? t.sb.homeColor : t.sb.awayColor)))
                            .frame(width: 10, height: 10)
                        Text(verbatim: s == .home ? t.line1 : t.line2).font(.headline).lineLimit(1)
                    }
                    let mine = cs.filter { $0.side == s }
                    ForEach(mine.filter { $0.minusOf == nil }) { c in
                        if let m = mine.first(where: { $0.minusOf == c.id }) { stepper(c, minus: m) } else { button(c) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        if let detail = sp.display(lang: .current, at: Date()).detail {
            Text(verbatim: detail).font(.footnote).foregroundStyle(DS.text2)
        }
        Button(role: .destructive) { engine.restartSportMatch() } label: {
            Label("Trận mới (giữ luật)", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func freeControls(_ t: TitleItem) -> some View {
        HStack(spacing: 16) {
            ForEach(Side.allCases, id: \.self) { s in
                VStack(spacing: 6) {
                    Text(verbatim: s == .home ? t.line1 : t.line2).font(.headline)
                    Text(verbatim: "\(s == .home ? t.scoreA : t.scoreB)").font(.system(size: 34, weight: .heavy, design: .rounded))
                    HStack {
                        Button { engine.setScore(a: s == .home ? t.scoreA - 1 : nil, b: s == .away ? t.scoreB - 1 : nil) } label: {
                            Image(systemName: "minus").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered)
                        Button { engine.setScore(a: s == .home ? t.scoreA + 1 : nil, b: s == .away ? t.scoreB + 1 : nil) } label: {
                            Image(systemName: "plus").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func tap(_ c: SportControlItem) {
        UIImpactFeedbackGenerator(style: c.role == .primary ? .medium : .light).impactOccurred()
        if c.inputPrompt != nil { input = ""; pending = c } else { engine.sportApply(c.make(nil)) }
    }

    /// Counted item (cards, fouls): [ − ]  Thẻ vàng 2  [ + ]
    private func stepper(_ plus: SportControlItem, minus: SportControlItem) -> some View {
        let tint: Color = plus.id.hasPrefix("yc-") ? Color(red: 1, green: 0.84, blue: 0.04)
            : plus.id.hasPrefix("rc-") ? Color.red.opacity(0.85) : Color.gray.opacity(0.45)
        let ink: Color = plus.id.hasPrefix("yc-") ? .black : .white
        return HStack(spacing: 6) {
            Button { tap(minus) } label: {
                Image(systemName: "minus").font(.headline).frame(width: 40, height: 38)
            }
            .buttonStyle(.bordered).disabled(!minus.enabled)
            .accessibilityLabel(Text(verbatim: minus.title))
            HStack(spacing: 6) {
                Text(verbatim: plus.title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                if let v = plus.value {
                    Text(verbatim: v).font(.headline.monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .foregroundStyle(ink)
            .background(tint, in: RoundedRectangle(cornerRadius: 8))
            Button { tap(plus) } label: {
                Image(systemName: "plus").font(.headline).frame(width: 40, height: 38)
            }
            .buttonStyle(.borderedProminent).tint(tint).foregroundStyle(ink).disabled(!plus.enabled)
            .accessibilityLabel(Text(verbatim: plus.title))
        }
    }

    private func button(_ c: SportControlItem) -> some View {
        Button { tap(c) } label: {
            Text(verbatim: c.title)
                .font(c.role == .primary ? .headline : .subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: c.role == .primary ? 56 : 38)
        }
        .buttonStyle(.borderedProminent)
        .tint(c.role == .primary ? DS.accent : (c.role == .destructive ? Color.red.opacity(0.75) : Color.gray.opacity(0.45)))
        .foregroundStyle(c.role == .primary ? Color.black : Color.white)
        .disabled(!c.enabled)
    }
}

// MARK: - Rules editor (inside "Sửa bảng tỉ số")

struct SportRulesEditor: View {
    @ObservedObject var engine: StudioEngine

    var body: some View {
        if let sp = engine.scoreboardSport {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("LUẬT THI ĐẤU").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.text3)
                    Spacer()
                    SportPickerMenu(engine: engine, compact: true)
                }
                Group {
                    switch sp {
                    case .pickleball(let e): pickleball(e.config)
                    case .badminton(let e): badminton(e.config)
                    case .volleyball(let e): volleyball(e.config)
                    case .football(let e): football(e.config)
                    case .billiards(let e): billiards(e.config)
                    }
                }
                .font(.system(size: 13))
                Text("Đổi luật giữa trận áp dụng từ điểm tiếp theo. Dùng \"Trận mới\" để bắt đầu lại với luật này.")
                    .font(.caption2).foregroundStyle(DS.text3)
            }
            .padding(8)
            .background(DS.surface, in: Rectangle())
        } else {
            HStack {
                Text("Chấm điểm tự do. Chọn môn để tính điểm, set, game theo luật:").font(.caption).foregroundStyle(DS.text2)
                Spacer()
                SportPickerMenu(engine: engine, compact: true)
            }
            .padding(8)
            .background(DS.surface, in: Rectangle())
        }
    }

    // generic binding into the engine config of the current board
    private func bind<C>(_ get: @escaping () -> C, _ set: @escaping (inout SportBoard, C) -> Void) -> Binding<C> {
        Binding(get: get, set: { v in engine.updateSportBoard { set(&$0, v) } })
    }

    private func pickleball(_ c: PickleballConfig) -> some View {
        let b = bind({ c }) { sp, n in if case .pickleball(var e) = sp { e.config = n; sp = .pickleball(e) } }
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Thể thức", selection: b.format) { Text("Đôi").tag(PickleballConfig.Format.doubles); Text("Đơn").tag(PickleballConfig.Format.singles) }
                .pickerStyle(.segmented)
            Picker("Tính điểm", selection: b.scoring) {
                Text("Side-out (chỉ bên giao ghi điểm)").tag(PickleballConfig.Scoring.sideOut)
                Text("Rally (mọi rally đều ra điểm)").tag(PickleballConfig.Scoring.rally)
            }
            Stepper("Game đến \(c.target.points) điểm, cách \(c.target.winBy)", value: b.target.points, in: 5...25)
            bestOf(b.bestOf, [1, 3, 5])
            Stepper("Hội ý mỗi game: \(c.timeoutsPerGame)", value: b.timeoutsPerGame, in: 0...5)
            Toggle("Đổi sân giữa game quyết định", isOn: b.switchEndsInDecider)
        }
    }

    private func badminton(_ c: BadmintonConfig) -> some View {
        let b = bind({ c }) { sp, n in if case .badminton(var e) = sp { e.config = n; sp = .badminton(e) } }
        let fmt = Binding<Int>(get: { c.target.points >= 21 ? 21 : 15 },
                               set: { v in var n = v == 21 ? BadmintonConfig.bwf3x21 : BadmintonConfig.bwf3x15; n.bestOf = c.bestOf; b.wrappedValue = n })
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Hệ điểm", selection: fmt) { Text("3×15 (BWF 2027)").tag(15); Text("3×21").tag(21) }.pickerStyle(.segmented)
            Text(verbatim: c.target.points >= 21 ? L("Game 21, cách 2, chạm 30 thắng; nghỉ ở 11.") : L("Game 15, cách 2, chạm 21 thắng; nghỉ ở 8."))
                .font(.caption).foregroundStyle(DS.text2)
            bestOf(b.bestOf, [1, 3, 5])
        }
    }

    private func volleyball(_ c: VolleyballConfig) -> some View {
        let b = bind({ c }) { sp, n in if case .volleyball(var e) = sp { e.config = n; sp = .volleyball(e) } }
        let beach = Binding<Bool>(get: { c.switchEvery != nil }, set: { b.wrappedValue = $0 ? .beach : .indoor })
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Loại", selection: beach) { Text("Trong nhà").tag(false); Text("Bãi biển").tag(true) }.pickerStyle(.segmented)
            bestOf(b.bestOf, [3, 5])
            Stepper("Set đến \(c.setPoints) điểm", value: b.setPoints, in: 11...30)
            Stepper("Set quyết định đến \(c.decidingSetPoints) điểm", value: b.decidingSetPoints, in: 7...25)
            Stepper("Hội ý mỗi set: \(c.timeoutsPerSet)", value: b.timeoutsPerSet, in: 0...3)
            if c.switchEvery == nil {
                Stepper("Thay người mỗi set: \(c.substitutionsPerSet)", value: b.substitutionsPerSet, in: 0...12)
            }
        }
    }

    private func football(_ c: FootballConfig) -> some View {
        let b = bind({ c }) { sp, n in if case .football(var e) = sp { e.config = n; sp = .football(e) } }
        let fouls = Binding<Bool>(get: { c.foulLimit != nil }, set: { var n = c; n.foulLimit = $0 ? 5 : nil; b.wrappedValue = n })
        let foulN = Binding<Int>(get: { c.foulLimit ?? 5 }, set: { var n = c; n.foulLimit = $0; b.wrappedValue = n })
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Sân", selection: b.playersPerSide) { Text("Sân 5").tag(5); Text("Sân 7").tag(7); Text("Sân 11").tag(11) }
                .pickerStyle(.segmented)
            Stepper("Số hiệp: \(c.halves)", value: b.halves, in: 1...4)
            Stepper("Mỗi hiệp \(c.halfMinutes) phút", value: b.halfMinutes, in: 5...60)
            Toggle("Đồng hồ đếm ngược (futsal)", isOn: b.countDown)
            Toggle("Lỗi tích lũy", isOn: fouls)
            if c.foulLimit != nil { Stepper("Giới hạn lỗi mỗi hiệp: \(c.foulLimit ?? 5)", value: foulN, in: 3...10) }
            Stepper("Hội ý mỗi hiệp: \(c.timeoutsPerHalf)", value: b.timeoutsPerHalf, in: 0...2)
            Picker("Khi hoà", selection: b.tieBreak) {
                Text("Kết thúc hoà").tag(FootballConfig.TieBreak.none)
                Text("Đá luân lưu").tag(FootballConfig.TieBreak.penalties)
                Text("Hiệp phụ rồi luân lưu").tag(FootballConfig.TieBreak.extraTimeThenPenalties)
            }
            if c.tieBreak == .extraTimeThenPenalties {
                Stepper("Hiệp phụ \(c.extraHalves) × \(c.extraMinutes) phút", value: b.extraMinutes, in: 1...30)
            }
            if c.tieBreak != .none {
                Stepper("Luân lưu \(c.shootoutKicks) lượt rồi đột tử", value: b.shootoutKicks, in: 1...5)
            }
        }
    }

    private func billiards(_ c: BilliardsConfig) -> some View {
        let b = bind({ c }) { sp, n in if case .billiards(var e) = sp { e.config = n; sp = .billiards(e) } }
        let clockOn = Binding<Bool>(get: { c.shotClockSeconds != nil }, set: { on in
            engine.updateSportBoard { if case .billiards(var e) = $0 { e.setShotClock(seconds: on ? (c.isCarom ? 40 : 30) : nil); $0 = .billiards(e) } }
        })
        let clockSec = Binding<Int>(get: { c.shotClockSeconds ?? 30 }, set: { s in
            engine.updateSportBoard { if case .billiards(var e) = $0 { e.setShotClock(seconds: s); $0 = .billiards(e) } }
        })
        let limitOn = Binding<Bool>(get: { c.inningLimit != nil }, set: { var n = c; n.inningLimit = $0 ? 50 : nil; b.wrappedValue = n })
        let limitN = Binding<Int>(get: { c.inningLimit ?? 50 }, set: { var n = c; n.inningLimit = $0; b.wrappedValue = n })
        return VStack(alignment: .leading, spacing: 6) {
            if c.isCarom {
                Stepper("Đánh đến \(c.caromTarget) điểm", value: b.caromTarget, in: 5...300, step: 5)
                Toggle("Giới hạn lượt", isOn: limitOn)
                if c.inningLimit != nil { Stepper("Tối đa \(c.inningLimit ?? 50) lượt", value: limitN, in: 5...100, step: 5) }
                Toggle("Lượt cân bằng (người sau được đánh lượt cuối)", isOn: b.equalizingInning)
            } else {
                Stepper("Chạm \(c.raceTo) rack", value: b.raceTo, in: 1...25)
                Picker("Quyền phá", selection: b.breakRule) {
                    Text("Luân phiên").tag(BilliardsConfig.BreakRule.alternate)
                    Text("Thắng rack được phá").tag(BilliardsConfig.BreakRule.winner)
                }
                .pickerStyle(.segmented)
            }
            Toggle("Đồng hồ cơ", isOn: clockOn)
            if c.shotClockSeconds != nil {
                Stepper("\(c.shotClockSeconds ?? 30) giây / cú, gia hạn \(c.extensionSeconds) giây", value: clockSec, in: 15...90, step: 5)
            }
        }
    }

    private func bestOf(_ v: Binding<Int>, _ options: [Int]) -> some View {
        Picker("Số ván / set", selection: v) {
            ForEach(options, id: \.self) { n in Text(verbatim: n == 1 ? L("1 ván") : LF("Thắng %@/%@", "\(n / 2 + 1)", "\(n)")).tag(n) }
        }
        .pickerStyle(.segmented)
    }
}

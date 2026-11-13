import PhotosUI
import SwiftUI

/// Live scoreboard bar (same controls as DTDLive): ON AIR, −/+ per team, match clock start/pause,
/// layout (wide strip / compact corner, 6 positions, size), reset / swap sides, edit.
struct ScoreboardControl: View {
    @ObservedObject var engine: StudioEngine
    var compact = false
    @State private var showLayout = false
    @State private var editing = false

    var body: some View {
        if let i = engine.scoreboardIndex {
            let t = engine.titles[i]
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                HStack(spacing: 8) {
                    Image(systemName: "sportscourt.fill").font(compact ? .caption : .body).foregroundStyle(DS.accent)
                    Text("Bảng tỉ số").font(compact ? .caption.weight(.bold) : .subheadline.weight(.bold))
                    Spacer()
                    if t.visible { Text("TRÊN SÓNG").font(.caption2.weight(.heavy)).foregroundStyle(DS.pgm) }
                    assign("→ Title", on: (engine.armedTitleID ?? engine.titles.first?.id) == t.id) { engine.armedTitleID = t.id }
                    assign("→ Title 2", on: engine.secondTitle?.id == t.id) { engine.armedTitle2ID = t.id }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { teams(t); clock(t); tools(t) }
                    VStack(alignment: .leading, spacing: 8) { teams(t); HStack(spacing: 10) { clock(t); tools(t) } }
                }
                if showLayout { layoutPanel(t) }
            }
            .padding(compact ? 8 : 12)
            .background(DS.surface, in: Rectangle())
            .overlay(Rectangle().stroke(t.visible ? DS.pgm : DS.stroke, lineWidth: t.visible ? 1.5 : 1))
            .sheet(isPresented: $editing) {
                NavigationStack {
                    ScrollView {
                        ScoreboardEditor(item: Binding(get: { engine.titles.first { $0.id == t.id } ?? t },
                                                       set: { n in engine.updateScoreboard { $0 = n } }))
                            .padding()
                    }
                    .background(DS.bg)
                    .navigationTitle("Sửa bảng tỉ số")
                    .toolbar { Button("Xong") { editing = false } }
                }
                .presentationDetents([.large])
            }
        } else {
            Button { engine.ensureScoreboard() } label: {
                Label("Thêm bảng tỉ số", systemImage: "sportscourt").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func teams(_ t: TitleItem) -> some View {
        HStack(spacing: 8) {
            team(name: t.line1, score: t.scoreA, home: true)
            Text("–").foregroundStyle(DS.text3)
            team(name: t.line2, score: t.scoreB, home: false)
        }
    }

    private func team(name: String, score: Int, home: Bool) -> some View {
        HStack(spacing: 5) {
            Text(String(name.prefix(5)).uppercased()).font(.system(size: 12, weight: .bold)).lineLimit(1).frame(minWidth: 34)
            Button { bump(home, -1) } label: {
                Image(systemName: "minus").font(.system(size: 12, weight: .bold)).frame(width: 30, height: 30)
                    .background(DS.surface2, in: Circle())
            }.buttonStyle(.plain)
            Text("\(score)").font(.system(size: 20, weight: .heavy, design: .rounded)).monospacedDigit().frame(minWidth: 26)
            Button { bump(home, 1) } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold)).frame(width: 30, height: 30)
                    .foregroundStyle(.black).background(DS.accent, in: Circle())
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private func clock(_ t: TitleItem) -> some View {
        let b = t.sb
        if b.showClock {
            HStack(spacing: 4) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(b.clockText(ctx.date)).font(.system(size: 15, weight: .semibold, design: .monospaced))
                }
                Button { engine.scoreboardClockToggle() } label: {
                    Image(systemName: b.running ? "pause.fill" : "play.fill").font(.system(size: 12)).frame(width: 30, height: 30)
                        .background(b.running ? DS.pgm.opacity(0.7) : DS.surface2, in: Circle())
                }.buttonStyle(.plain)
            }
        }
    }

    private func tools(_ t: TitleItem) -> some View {
        HStack(spacing: 6) {
            iconButton("pencil", on: false) { editing = true }
            iconButton("rectangle.3.group", on: showLayout) { withAnimation(.easeOut(duration: 0.15)) { showLayout.toggle() } }
            Menu {
                Button("Sửa tên, logo, màu…") { editing = true }
                Button("Đặt lại đồng hồ") { engine.scoreboardClockReset() }
                Button("Đặt lại tỉ số 0 - 0") { engine.updateScoreboard { $0.scoreA = 0; $0.scoreB = 0 } }
                Button("Đổi bên (tên, tỉ số, logo)") { engine.updateScoreboard { $0.swapScoreboardSides() } }
                Divider()
                Button("Xoá bảng tỉ số", role: .destructive) { engine.removeTitle(t.id) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 16)).frame(width: 30, height: 30)
            }
        }
        .foregroundStyle(DS.text2)
    }

    private func assign(_ t: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(t)).font(DS.fBodyBold).padding(.horizontal, 9).padding(.vertical, 5)
                .foregroundStyle(on ? .black : DS.text2)
                .background(on ? Color.white : DS.surface2, in: Rectangle())
        }.buttonStyle(.plain)
    }

    private func iconButton(_ icon: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                .background(on ? DS.accent.opacity(0.6) : DS.surface2, in: Circle())
        }.buttonStyle(.plain)
    }

    private func layoutPanel(_ t: TitleItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { t.sb.compact }, set: { engine.setScoreboardCompact($0) })) {
                Text("Dải ngang").tag(false)
                Text("Gọn ở góc").tag(true)
            }
            .pickerStyle(.segmented)
            if !t.sb.compact {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ScoreboardStyle.allCases) { st in
                            let on = t.sb.look == st
                            Button { engine.setScoreboardStyle(st) } label: {
                                VStack(spacing: 3) {
                                    Image(uiImage: ScoreboardRenderer.preview(st))
                                        .resizable().scaledToFit().frame(width: compact ? 130 : 170)
                                    Text(verbatim: st.label).font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(on ? .black : .white)
                                }
                                .padding(4)
                                .background(on ? DS.accent : DS.surface2, in: Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if t.sb.look != .classic {
                    TextField("Dòng chữ dưới (vd LIVE MATCH DAY)", text: Binding(get: { t.sb.banner }, set: { engine.setScoreboardBanner($0) }))
                        .font(.system(size: 13)).padding(.horizontal, 8).frame(height: 30)
                        .background(DS.surface2, in: Rectangle())
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        pos("arrow.up.left") { engine.placeScoreboard(x: 0, top: true) }
                        pos("arrow.up") { engine.placeScoreboard(x: 0.5, top: true) }
                        pos("arrow.up.right") { engine.placeScoreboard(x: 1, top: true) }
                    }
                    GridRow {
                        pos("arrow.down.left") { engine.placeScoreboard(x: 0, top: false) }
                        pos("arrow.down") { engine.placeScoreboard(x: 0.5, top: false) }
                        pos("arrow.down.right") { engine.placeScoreboard(x: 1, top: false) }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: LF("Cỡ %@%% bề rộng", "\(Int(engine.scoreboardFraction(t).width * 100))")).font(.caption2).foregroundStyle(DS.text3)
                    HStack(spacing: 6) {
                        Button { engine.setScoreboardScale(t.scale - 0.05) } label: { Image(systemName: "minus").frame(width: 26, height: 26) }
                        Slider(value: Binding(get: { Double(t.scale) }, set: { engine.setScoreboardScale(CGFloat($0)) }), in: 0.3...1.6)
                            .tint(DS.accent)
                        Button { engine.setScoreboardScale(t.scale + 0.05) } label: { Image(systemName: "plus").frame(width: 26, height: 26) }
                    }
                    .font(.system(size: 12, weight: .bold))
                }
            }
        }
        .padding(8)
        .background(DS.surface2.opacity(0.5), in: Rectangle())
    }

    private func pos(_ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .frame(width: compact ? 40 : 52, height: 28)
                .background(DS.surface2, in: Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func bump(_ home: Bool, _ d: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        engine.updateScoreboard { t in
            if home { t.scoreA = max(0, t.scoreA + d) } else { t.scoreB = max(0, t.scoreB + d) }
        }
    }
}

/// Full scoreboard editor: both teams (logo, name, sub line, score, colour bar), score-box and name
/// colours, period, match clock (count up / count down with duration).
struct ScoreboardEditor: View {
    @Binding var item: TitleItem
    @State private var homePick: PhotosPickerItem?
    @State private var awayPick: PhotosPickerItem?

    private var board: Binding<ScoreboardData> {
        Binding(get: { item.sb }, set: { item.sb = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            preview
            teamBlock("Đội nhà", name: $item.line1, sub: board.homeSub, score: $item.scoreA, logo: item.sb.homeLogo,
                      pick: $homePick, color: board.homeColor) { var b = item.sb; b.homeLogo = nil; item.sb = b }
            teamBlock("Đội khách", name: $item.line2, sub: board.awaySub, score: $item.scoreB, logo: item.sb.awayLogo,
                      pick: $awayPick, color: board.awayColor) { var b = item.sb; b.awayLogo = nil; item.sb = b }
            HStack(spacing: 14) {
                colorPick("Ô tỉ số", board.centerColor)
                colorPick("Nền tên", board.nameBg)
                colorPick("Chữ tên", board.nameText)
            }
            HStack(spacing: 8) {
                TextField("Hiệp (vd H1, Q2)", text: $item.period).font(.system(size: 14))
                    .padding(.horizontal, 8).frame(height: 34)
                    .background(DS.surface2, in: Rectangle())
                Toggle("Đồng hồ", isOn: board.showClock).toggleStyle(.button).controlSize(.small)
                Toggle("Đếm ngược", isOn: board.countDown).toggleStyle(.button).controlSize(.small)
            }
            if item.sb.countDown {
                Stepper("Thời lượng \(item.sb.clockLimitSec / 60) phút", value: board.clockLimitSec, in: 60...(180 * 60), step: 60)
                    .font(.system(size: 13))
            }
            Picker("Kiểu", selection: board.compact) {
                Text("Dải ngang").tag(false)
                Text("Gọn ở góc").tag(true)
            }
            .pickerStyle(.segmented)
        }
        .onChange(of: homePick) { _, p in load(p) { var b = item.sb; b.homeLogo = $0; item.sb = b } }
        .onChange(of: awayPick) { _, p in load(p) { var b = item.sb; b.awayLogo = $0; item.sb = b } }
    }

    /// Live preview of the drawn board (same renderer as program output).
    private var preview: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Image(uiImage: ScoreboardRenderer.render(item, now: ctx.date))
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 110)
                .padding(8)
                .background(CheckerBackground().opacity(0.5).clipShape(Rectangle()))
        }
    }

    private func teamBlock(_ title: String, name: Binding<String>, sub: Binding<String>, score: Binding<Int>, logo: String?,
                           pick: Binding<PhotosPickerItem?>, color: Binding<String>, clearLogo: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.text3)
            HStack(spacing: 8) {
                PhotosPicker(selection: pick, matching: .images) {
                    ZStack {
                        Rectangle().fill(DS.surface2)
                        if let ui = ScoreboardLogos.image(logo) {
                            Image(uiImage: ui).resizable().scaledToFit().padding(3)
                        } else {
                            Image(systemName: "shield.lefthalf.filled").font(.system(size: 15)).foregroundStyle(DS.text3)
                        }
                    }
                    .frame(width: 38, height: 38)
                }
                .contextMenu { if logo != nil { Button("Bỏ logo", role: .destructive, action: clearLogo) } }
                TextField("Tên đội", text: name).font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 8).frame(height: 34)
                    .background(DS.surface2, in: Rectangle())
                Stepper("\(score.wrappedValue)", value: score, in: 0...999).font(.system(size: 14, weight: .bold)).fixedSize()
            }
            HStack(spacing: 8) {
                TextField("Dòng phụ (tuỳ chọn)", text: sub).font(.system(size: 13))
                    .padding(.horizontal, 8).frame(height: 30)
                    .background(DS.surface2, in: Rectangle())
                colorPick("Màu dải", color)
            }
        }
        .padding(8)
        .background(DS.surface, in: Rectangle())
    }

    private func colorPick(_ title: String, _ hex: Binding<String>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(UIColor(hex: hex.wrappedValue)) },
                                              set: { hex.wrappedValue = UIColor($0).hexString }), supportsOpacity: false)
            .font(.system(size: 12)).foregroundStyle(DS.text2).fixedSize()
    }

    private func load(_ p: PhotosPickerItem?, _ done: @escaping (String) -> Void) {
        Task {
            if let d = try? await p?.loadTransferable(type: Data.self), let name = ScoreboardLogos.save(d) {
                await MainActor.run { done(name) }
            }
        }
    }
}

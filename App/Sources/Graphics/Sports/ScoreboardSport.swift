//
//  ScoreboardSport.swift
//
//  Nối engine luật thể thao (Sports/*.swift) vào bảng tỉ số hiện có của DTD Studio:
//  • ScoreboardData.sport giữ trạng thái trận; TitleItem (line1/line2/scoreA/scoreB/period) vẫn là
//    nguồn cho web remote cũ, OSC, HTTP API → được đồng bộ sau mỗi thao tác.
//  • adaptedForSport(now:) đổi trạng thái trận thành dữ liệu vẽ (tỉ số, set đã xong, chấm giao bóng,
//    đồng hồ, callout) cho ScoreboardRenderer — mọi kiểu vẽ hiện có (cổ điển, chrome, lửa đỏ… / gọn ở góc)
//    đều dùng được cho mọi môn.
//  • Undo/redo điểm số riêng (không lẫn với undo đồ hoạ).
//

import Foundation

extension ScoreLang {
    /// Theo ngôn ngữ app (Cài đặt → Ngôn ngữ).
    static var current: ScoreLang {
        switch AppLanguage.current {
        case "en": return .en
        case "vi": return .vi
        default: return (Locale.preferredLanguages.first ?? "vi").hasPrefix("vi") ? .vi : .en
        }
    }
}

extension SportTemplate {
    /// Nhóm môn để hiển thị trong menu.
    var sportGroup: String {
        switch self {
        case .pickleballDoubles, .pickleballSingles, .pickleballRally21: return "Pickleball"
        case .badminton3x15, .badminton3x21: return L("Cầu lông")
        case .volleyballIndoor, .volleyballBeach: return L("Bóng chuyền")
        case .football5, .football7, .futsal, .football11: return L("Bóng đá")
        case .pool9Ball, .pool8Ball, .pool10Ball, .carom3Cushion, .caromStraightRail: return L("Bi-a")
        }
    }
    static var groups: [(String, [SportTemplate])] {
        var out: [(String, [SportTemplate])] = []
        for t in allCases {
            if let i = out.firstIndex(where: { $0.0 == t.sportGroup }) { out[i].1.append(t) } else { out.append((t.sportGroup, [t])) }
        }
        return out
    }
}

// MARK: - TitleItem ↔ sport

extension TitleItem {
    /// Đội lấy từ tên / màu đang hiện trên scoreboard (để callout dùng đúng tên).
    var sportTeams: Pair<TeamInfo> {
        let b = sb
        func team(_ name: String, _ color: String, _ fallback: String) -> TeamInfo {
            let n = name.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : name
            return TeamInfo(name: n, shortName: String(n.prefix(4)).uppercased(), colorHex: color)
        }
        return Pair(team(line1, b.homeColor, "A"), team(line2, b.awayColor, "B"))
    }

    var sportBoard: SportBoard? {
        guard style == .scoreBug, var sp = board?.sport else { return nil }
        sp.teams = sportTeams
        return sp
    }

    func sportDisplay(now: Date = Date(), lang: ScoreLang = .current) -> SportDisplay? {
        sportBoard?.display(lang: lang, at: now)
    }

    /// Bản sao đã điền số liệu của môn thể thao để vẽ; không có môn → trả nguyên.
    func adaptedForSport(now: Date) -> TitleItem {
        guard let d = sportDisplay(now: now), d.rows.count == 2 else { return self }
        var t = self
        var b = t.sb
        t.scoreA = Int(d.rows[0].main) ?? t.scoreA
        t.scoreB = Int(d.rows[1].main) ?? t.scoreB
        t.period = d.shortPeriod
        b.overrideClock = d.clock
        b.showClock = d.clock != nil
        b.servingSide = d.rows.firstIndex { $0.isServing }
        b.callout = d.callout
        if b.compact {
            b.homeColumns = d.rows[0].columns
            b.awayColumns = d.rows[1].columns
        } else {
            // dải ngang: set đã xong + thẻ / lỗi / hội ý đi vào dòng phụ dưới tên đội
            let named = d.columnHeaders.count > 0 && d.columnHeaders.allSatisfy { !$0.isEmpty }
            func line(_ r: SportDisplay.Row, _ sub: String) -> String {
                var parts: [String] = sub.isEmpty ? [] : [sub]
                if !r.columns.isEmpty {
                    parts.append(named && d.columnHeaders.count == r.columns.count
                        ? zip(d.columnHeaders, r.columns).map { "\($0) \($1)" }.joined(separator: " · ")
                        : r.columns.joined(separator: "  "))
                }
                let badges = r.badges.map { bd -> String in
                    switch bd.style {
                    case .yellowCard: return L("Thẻ vàng") + " \(bd.text)"
                    case .redCard: return L("Thẻ đỏ") + " \(bd.text)"
                    default: return bd.text
                    }
                }
                if !badges.isEmpty { parts.append(badges.joined(separator: " · ")) }
                return parts.joined(separator: " · ")
            }
            b.homeSub = line(d.rows[0], b.homeSub)
            b.awaySub = line(d.rows[1], b.awaySub)
            if b.look != .classic, let co = d.callout, !co.isEmpty { b.banner = co }
        }
        t.sb = b
        return t
    }
}

// MARK: - Score undo / redo (separate from graphics undo)

@MainActor
final class SportHistory {
    static let shared = SportHistory()
    var undo: [SportBoard] = []
    var redo: [SportBoard] = []
    let limit = 300
    func clear() { undo.removeAll(); redo.removeAll() }
}

// MARK: - StudioEngine API

extension StudioEngine {
    var scoreboardSport: SportBoard? { scoreboardIndex.flatMap { titles[$0].sportBoard } }
    var sportCanUndo: Bool { !SportHistory.shared.undo.isEmpty }
    var sportCanRedo: Bool { !SportHistory.shared.redo.isEmpty }

    /// Chọn môn (template luật). nil = chấm điểm tự do (+/−) như trước.
    func setScoreboardSport(_ tpl: SportTemplate?) {
        ensureScoreboard()
        updateScoreboard { t in
            var b = t.sb
            b.sport = tpl?.make(teams: t.sportTeams)
            b.sportTemplate = tpl?.rawValue
            if tpl != nil {
                // đồng hồ cũ không dùng khi môn có đồng hồ riêng; xoá tỉ số tự do
                b.clockStart = nil
            }
            t.sb = b
            if tpl != nil { t.scoreA = 0; t.scoreB = 0 }
            Self.syncSport(&t)
        }
        SportHistory.shared.clear()
        objectWillChange.send()
    }

    /// Bắt đầu lại trận với cùng luật.
    func restartSportMatch() {
        guard let i = scoreboardIndex, let raw = titles[i].sb.sportTemplate, let tpl = SportTemplate(rawValue: raw),
              let old = titles[i].sb.sport else { return }
        var fresh = tpl.make(teams: titles[i].sportTeams)
        fresh.copyConfig(from: old)
        pushSport(fresh)
    }

    func sportApply(_ action: SportAction, at now: Date = Date()) {
        guard let i = scoreboardIndex, let before = titles[i].sportBoard else { return }
        var next = before
        next.apply(action, at: now)
        guard next != before else { return }
        pushSport(next)
    }

    /// Thực hiện một nút điều khiển (theo id) – dùng cho bảng nhập điểm, web remote, OSC.
    @discardableResult
    func sportPerform(controlID: String, input: String? = nil) -> Bool {
        guard let sp = scoreboardSport,
              let c = sp.controls(lang: .current).first(where: { $0.id == controlID }), c.enabled else { return false }
        sportApply(c.make(input))
        return true
    }

    /// Nút chính "+1" của một bên (rally / bàn thắng / rack…); carom: +1 cho người đang đánh.
    func sportPrimary(_ side: Side) {
        guard let sp = scoreboardSport else { return }
        let cs = sp.controls(lang: .current).filter { $0.enabled && $0.role == .primary }
        if let c = cs.first(where: { $0.side == side }) { sportApply(c.make(nil)) }
        else if let c = cs.first(where: { $0.side == nil && $0.id == "point" }) { sportApply(c.make(nil)) }
    }

    /// Sửa luật / cấu hình giữa trận (từ màn hình sửa scoreboard).
    func updateSportBoard(_ f: (inout SportBoard) -> Void) {
        guard let i = scoreboardIndex, var sp = titles[i].sportBoard else { return }
        f(&sp)
        updateScoreboard { t in var b = t.sb; b.sport = sp; t.sb = b; Self.syncSport(&t) }
    }

    func sportUndo() {
        guard let i = scoreboardIndex, let cur = titles[i].sb.sport, let prev = SportHistory.shared.undo.popLast() else { return }
        SportHistory.shared.redo.append(cur)
        setSportState(prev)
    }

    func sportRedo() {
        guard let i = scoreboardIndex, let cur = titles[i].sb.sport, let next = SportHistory.shared.redo.popLast() else { return }
        SportHistory.shared.undo.append(cur)
        setSportState(next)
    }

    private func pushSport(_ next: SportBoard) {
        guard let i = scoreboardIndex, let cur = titles[i].sb.sport else { return }
        let h = SportHistory.shared
        h.undo.append(cur)
        if h.undo.count > h.limit { h.undo.removeFirst(h.undo.count - h.limit) }
        h.redo.removeAll()
        setSportState(next)
    }

    private func setSportState(_ sp: SportBoard) {
        updateScoreboard { t in var b = t.sb; b.sport = sp; t.sb = b; Self.syncSport(&t) }
    }

    /// Ghi tỉ số / hiệp hiện tại vào TitleItem để API cũ (/api/state, OSC) đọc đúng.
    static func syncSport(_ t: inout TitleItem) {
        guard t.sportBoard != nil else { return }
        let a = t.adaptedForSport(now: Date())
        t.scoreA = a.scoreA
        t.scoreB = a.scoreB
        t.period = a.period
    }

    // MARK: Web remote JSON

    func scoreboardJSON() async -> Data {
        let lang = ScoreLang.current
        var obj: [String: Any] = [
            "lang": lang.rawValue,
            "templates": SportTemplate.allCases.map { ["id": $0.rawValue, "title": $0.title(lang), "group": $0.sportGroup] },
            "canUndo": sportCanUndo, "canRedo": sportCanRedo
        ]
        if let i = scoreboardIndex {
            let t = titles[i], b = t.sb
            obj["exists"] = true
            obj["id"] = t.id.uuidString
            obj["visible"] = t.visible
            obj["home"] = t.line1
            obj["away"] = t.line2
            obj["homeColor"] = b.homeColor
            obj["awayColor"] = b.awayColor
            obj["scoreA"] = t.scoreA
            obj["scoreB"] = t.scoreB
            obj["period"] = t.period
            obj["clock"] = b.showClock ? b.clockText() : ""
            obj["clockRunning"] = b.running
            obj["template"] = b.sportTemplate ?? ""
            if let sp = t.sportBoard {
                let d = sp.display(lang: lang, at: Date())
                obj["display"] = [
                    "title": d.sportTitle, "period": d.period, "clock": d.clock ?? "", "callout": d.callout ?? "",
                    "detail": d.detail ?? "", "headers": d.columnHeaders, "mainHeader": d.mainHeader, "finished": d.isFinished,
                    "rows": d.rows.map { r in
                        ["name": r.name, "color": r.colorHex, "columns": r.columns, "main": r.main, "serving": r.isServing,
                         "winner": r.isWinner, "badges": r.badges.map { ["text": $0.text, "style": $0.style.rawValue] }] as [String: Any]
                    }
                ] as [String: Any]
                obj["controls"] = sp.controls(lang: lang).map { c in
                    ["id": c.id, "title": c.title, "side": c.side.map { $0 == .home ? "home" : "away" } ?? "",
                     "role": c.role.rawValue, "enabled": c.enabled, "prompt": c.inputPrompt ?? "",
                     "choices": c.choices, "minusOf": c.minusOf ?? "", "value": c.value ?? ""] as [String: Any]
                }
            }
        } else {
            obj["exists"] = false
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }
}

extension SportBoard {
    /// Giữ cấu hình luật (khi bắt đầu lại trận).
    mutating func copyConfig(from o: SportBoard) {
        switch (self, o) {
        case (.pickleball(let e), .pickleball(let x)): self = .pickleball(PickleballEngine(config: x.config, teams: e.teams))
        case (.badminton(let e), .badminton(let x)): self = .badminton(BadmintonEngine(config: x.config, teams: e.teams))
        case (.volleyball(let e), .volleyball(let x)): self = .volleyball(VolleyballEngine(config: x.config, teams: e.teams))
        case (.football(let e), .football(let x)): self = .football(FootballEngine(config: x.config, teams: e.teams))
        case (.billiards(let e), .billiards(let x)): self = .billiards(BilliardsEngine(config: x.config, teams: e.teams))
        default: break
        }
    }
}

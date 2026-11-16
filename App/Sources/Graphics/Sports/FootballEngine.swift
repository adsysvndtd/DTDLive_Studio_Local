//
//  FootballEngine.swift  –  Bóng đá phủi (sân 5 / sân 7 / futsal / sân 11)
//
//  • Trận chia hiệp (mặc định 2 hiệp), đồng hồ đếm lên (thời gian trận, hiệp 2 bắt đầu từ 25:00…)
//    hoặc đếm ngược (futsal). Bù giờ: "+n".
//  • Bàn thắng ghi phút ("23'", "25+2'"), cầu thủ, phản lưới.
//  • Thẻ vàng / đỏ; thẻ vàng thứ 2 cho cùng cầu thủ → tự động thẻ đỏ.
//  • Lỗi tích lũy (futsal: 5 lỗi/hiệp, từ lỗi thứ 6 đá phạt 10 m). Reset mỗi hiệp chính;
//    hiệp phụ cộng tiếp từ hiệp 2.
//  • Hội ý (futsal: 1 lần/hiệp/đội) – dừng đồng hồ.
//  • Hòa sau thời gian chính: tùy cấu hình – kết thúc hòa / luân lưu / hiệp phụ rồi luân lưu.
//  • Luân lưu: N lượt (mặc định 5) rồi đột tử; tự kết thúc sớm khi một đội không thể đuổi kịp.
//

import Foundation

struct FootballConfig: Codable, Equatable {
    enum TieBreak: String, Codable { case none, penalties, extraTimeThenPenalties }

    var playersPerSide: Int = 7
    var halves: Int = 2
    var halfMinutes: Int = 25
    var extraHalves: Int = 2
    var extraMinutes: Int = 5
    var countDown: Bool = false
    var foulLimit: Int? = nil
    var timeoutsPerHalf: Int = 0
    var tieBreak: TieBreak = .none
    var shootoutKicks: Int = 5

    init(playersPerSide: Int = 7, halves: Int = 2, halfMinutes: Int = 25,
                extraHalves: Int = 2, extraMinutes: Int = 5, countDown: Bool = false,
                foulLimit: Int? = nil, timeoutsPerHalf: Int = 0,
                tieBreak: TieBreak = .none, shootoutKicks: Int = 5) {
        self.playersPerSide = playersPerSide
        self.halves = halves
        self.halfMinutes = halfMinutes
        self.extraHalves = extraHalves
        self.extraMinutes = extraMinutes
        self.countDown = countDown
        self.foulLimit = foulLimit
        self.timeoutsPerHalf = timeoutsPerHalf
        self.tieBreak = tieBreak
        self.shootoutKicks = shootoutKicks
    }

    static let san5 = FootballConfig(playersPerSide: 5, halfMinutes: 20)
    static let san7 = FootballConfig(playersPerSide: 7, halfMinutes: 25)
    static let futsal = FootballConfig(playersPerSide: 5, halfMinutes: 20, countDown: true,
                                              foulLimit: 5, timeoutsPerHalf: 1)
    static let san11 = FootballConfig(playersPerSide: 11, halfMinutes: 45, extraMinutes: 15)
}

struct GoalRecord: Codable, Equatable {
    var side: Side          // đội được tính bàn
    var minuteLabel: String // "23'", "25+2'"
    var player: String?
    var ownGoal: Bool
}

struct CardRecord: Codable, Equatable {
    var side: Side
    var player: String
    var kind: CardKind
    var minuteLabel: String
}

enum FootballPeriod: Codable, Equatable {
    case pregame
    case playing(Int)          // 1…halves = hiệp chính, sau đó là hiệp phụ
    case interval(after: Int)  // nghỉ sau hiệp n
    case penalties
    case finished
}

enum FootballAction: Codable, Equatable {
    case startClock
    case stopClock
    case adjustClock(seconds: Int)
    case setAddedTime(minutes: Int)
    case goal(Side, player: String?, ownGoal: Bool)
    case foul(Side)
    case cancelFoul(Side)
    case card(Side, player: String, kind: CardKind)
    case timeout(Side)
    case endPeriod
    case startNextPeriod
    case startShootout(first: Side)
    case kick(Side, scored: Bool)
}

struct FootballEngine: SportEngine {
    var config: FootballConfig
    var teams: Pair<TeamInfo>

    private(set) var period: FootballPeriod = .pregame
    private(set) var goals = Pair(0, 0)
    private(set) var goalLog: [GoalRecord] = []
    private(set) var cards: [CardRecord] = []
    private(set) var fouls = Pair(0, 0)
    private(set) var timeoutsUsed = Pair(0, 0)
    private(set) var clock = GameClock()
    private(set) var addedMinutes = 0
    private(set) var kicks = Pair<[Bool]>([], [])
    private(set) var shootoutFirst: Side = .home
    private(set) var lastEvent: ScoreEvent = .none

    init(config: FootballConfig = .san7, teams: Pair<TeamInfo> = TeamInfo.defaultPair) {
        self.config = config
        self.teams = teams
    }

    // MARK: Derived

    var periodCount: Int {
        config.halves + (config.tieBreak == .extraTimeThenPenalties ? config.extraHalves : 0)
    }

    func periodMinutes(_ n: Int) -> Int { n <= config.halves ? config.halfMinutes : config.extraMinutes }

    func minutesBefore(_ n: Int) -> Int { (1..<max(1, n)).reduce(0) { $0 + periodMinutes($1) } }

    func nextIsShootout(after n: Int) -> Bool {
        n >= config.halves && (config.tieBreak == .penalties || n >= periodCount)
    }

    var isFinished: Bool { period == .finished }
    var needsTicking: Bool { clock.isRunning }

    var shootoutScore: Pair<Int> {
        Pair(kicks.home.filter { $0 }.count, kicks.away.filter { $0 }.count)
    }

    var nextKicker: Side {
        if kicks.home.count == kicks.away.count { return shootoutFirst }
        return kicks.home.count < kicks.away.count ? .home : .away
    }

    var shootoutWinner: Side? {
        let k = config.shootoutKicks
        let a = kicks.home, b = kicks.away
        let sa = shootoutScore.home, sb = shootoutScore.away
        if a.count <= k && b.count <= k {
            let remA = k - a.count, remB = k - b.count
            if sa > sb + remB { return .home }
            if sb > sa + remA { return .away }
            return nil
        }
        // Đột tử: so sau khi hai đội đá cùng số lượt
        if a.count == b.count && sa != sb { return sa > sb ? .home : .away }
        return nil
    }

    var winner: Side? {
        guard isFinished else { return nil }
        if goals.home != goals.away { return goals.home > goals.away ? .home : .away }
        return shootoutWinner
    }

    func minuteLabel(at now: Date) -> String {
        guard case .playing(let n) = period else { return "" }
        let m = Int(clock.elapsed(at: now)) / 60 + 1
        let len = periodMinutes(n)
        let base = minutesBefore(n)
        return m > len ? "\(base + len)+\(m - len)'" : "\(base + m)'"
    }

    // MARK: Apply

    mutating func apply(_ action: FootballAction, at now: Date) {
        guard !isFinished else { return }
        lastEvent = .none
        switch action {
        case .startClock:
            if period == .pregame { period = .playing(1) }
            if case .playing = period { clock.start(at: now) }

        case .stopClock:
            clock.stop(at: now)

        case .adjustClock(let sec):
            clock.adjust(by: TimeInterval(sec), at: now)

        case .setAddedTime(let m):
            addedMinutes = max(0, m)

        case .goal(let s, let player, let own):
            guard case .playing = period else { return }
            goals[s] += 1
            goalLog.append(GoalRecord(side: s, minuteLabel: minuteLabel(at: now),
                                      player: player?.trimmedNonEmpty, ownGoal: own))
            lastEvent = .goal(s)

        case .foul(let s):
            guard case .playing = period else { return }
            fouls[s] += 1
            if let lim = config.foulLimit, fouls[s] == lim { lastEvent = .foulLimit(s) }

        case .cancelFoul(let s):
            fouls[s] = max(0, fouls[s] - 1)

        case .card(let s, let player, let kind):
            let name = player.trimmedNonEmpty ?? "?"
            let minute = minuteLabel(at: now)
            let alreadyYellow = cards.contains {
                $0.side == s && $0.kind == .yellow && $0.player.caseInsensitiveCompare(name) == .orderedSame && name != "?"
            }
            cards.append(CardRecord(side: s, player: name, kind: kind, minuteLabel: minute))
            if kind == .yellow && alreadyYellow {
                cards.append(CardRecord(side: s, player: name, kind: .red, minuteLabel: minute))
                lastEvent = .card(s, .red)
            } else {
                lastEvent = .card(s, kind)
            }

        case .timeout(let s):
            guard case .playing = period, timeoutsUsed[s] < config.timeoutsPerHalf else { return }
            clock.stop(at: now)
            timeoutsUsed[s] += 1
            lastEvent = .timeout(s)

        case .endPeriod:
            guard case .playing(let n) = period else { return }
            clock.stop(at: now)
            let tied = goals.home == goals.away
            if n < config.halves || (n > config.halves && n < periodCount) {
                period = .interval(after: n)
                lastEvent = .periodEnded
            } else if tied && config.tieBreak != .none {
                period = .interval(after: n)   // tiếp theo: hiệp phụ hoặc luân lưu
                lastEvent = .periodEnded
            } else {
                period = .finished
                if let w = winner { lastEvent = .matchWon(w) } else { lastEvent = .draw }
            }

        case .startNextPeriod:
            guard case .interval(let n) = period, !nextIsShootout(after: n) else { return }
            period = .playing(n + 1)
            clock.reset()
            addedMinutes = 0
            if n + 1 <= config.halves { fouls = Pair(0, 0) }
            timeoutsUsed = Pair(0, 0)

        case .startShootout(let first):
            guard case .interval(let n) = period, nextIsShootout(after: n) else { return }
            period = .penalties
            shootoutFirst = first
            kicks = Pair([], [])

        case .kick(let s, let scored):
            guard period == .penalties, s == nextKicker else { return }
            kicks[s].append(scored)
            if let w = shootoutWinner {
                period = .finished
                lastEvent = .matchWon(w)
            }
        }
    }

    // MARK: Display

    func display(lang: ScoreLang, at now: Date) -> SportDisplay {
        let inShootout = period == .penalties || !kicks.home.isEmpty || !kicks.away.isEmpty
        let maxKicks = max(kicks.home.count, kicks.away.count)

        let rows: [SportDisplay.Row] = Side.allCases.map { s in
            var badges: [SportDisplay.Badge] = []
            let y = cards.filter { $0.side == s && $0.kind == .yellow }.count
            let r = cards.filter { $0.side == s && $0.kind == .red }.count
            if y > 0 { badges.append(.init("\(y)", .yellowCard)) }
            if r > 0 { badges.append(.init("\(r)", .redCard)) }
            if config.foulLimit != nil || fouls[s] > 0 {
                let over = config.foulLimit.map { fouls[s] >= $0 } ?? false
                badges.append(.init(lang.t("Lỗi \(fouls[s])", "F \(fouls[s])"), over ? .danger : .normal))
            }
            if config.timeoutsPerHalf > 0, case .playing = period {
                let left = config.timeoutsPerHalf - timeoutsUsed[s]
                badges.append(.init("TO \(left)", left == 0 ? .warning : .normal))
            }
            var cols: [String] = []
            if inShootout {
                cols = kicks[s].map { $0 ? "●" : "✕" }
                cols += Array(repeating: "·", count: max(0, max(maxKicks, config.shootoutKicks) - kicks[s].count))
                cols.append("(\(shootoutScore[s]))")
            }
            return .init(side: s, team: teams[s], columns: cols, main: "\(goals[s])",
                         isServing: period == .penalties && nextKicker == s,
                         badges: badges, isWinner: winner == s)
        }

        // Period + clock
        var periodText = ""
        var clockText: String? = nil
        var timeUp = false
        switch period {
        case .pregame:
            periodText = lang.t("CHUẨN BỊ", "PRE-MATCH")
            clockText = config.countDown ? formatClock(Double(periodMinutes(1) * 60)) : "00:00"
        case .playing(let n):
            periodText = periodName(n, lang: lang)
            let e = clock.elapsed(at: now)
            let len = Double(periodMinutes(n) * 60)
            if config.countDown {
                clockText = formatClock(len - e)
            } else {
                clockText = formatClock(Double(minutesBefore(n) * 60) + e)
            }
            if addedMinutes > 0 { clockText! += " +\(addedMinutes)" }
            timeUp = e >= len + Double(addedMinutes * 60)
        case .interval(let n):
            if n < config.halves { periodText = lang.t("NGHỈ GIỮA HIỆP", "HALF-TIME") }
            else if nextIsShootout(after: n) { periodText = lang.t("CHỜ LUÂN LƯU", "PENALTIES NEXT") }
            else if n == config.halves { periodText = lang.t("HẾT GIỜ CHÍNH THỨC", "FULL-TIME · EXTRA TIME NEXT") }
            else { periodText = lang.t("NGHỈ HIỆP PHỤ", "EXTRA-TIME BREAK") }
        case .penalties:
            periodText = lang.t("LUÂN LƯU", "PENALTIES")
        case .finished:
            periodText = lang.t("KẾT THÚC", "FULL-TIME")
        }

        var callout = Callouts.text(lastEvent, teams: teams, lang: lang)
        if callout == nil, timeUp, clock.isRunning { callout = lang.t("HẾT GIỜ", "TIME") }
        if callout == nil, let lim = config.foulLimit {
            if let s = Side.allCases.first(where: { fouls[$0] >= lim }) {
                callout = lang.t("\(teams[s].shortName): lỗi tiếp theo đá phạt 10 m",
                                 "\(teams[s].shortName): next foul = 10 m kick")
            }
        }

        var detail: String? = nil
        if let g = goalLog.last {
            let who = g.player ?? teams[g.side].name
            detail = "⚽ \(g.minuteLabel) \(who)" + (g.ownGoal ? lang.t(" (phản lưới)", " (OG)") : "")
        }

        return SportDisplay(
            sportTitle: config.foulLimit != nil ? "FUTSAL"
                : lang.t("BÓNG ĐÁ SÂN \(config.playersPerSide)", "\(config.playersPerSide)-A-SIDE FOOTBALL"),
            columnHeaders: inShootout ? Array(repeating: "", count: rows[0].columns.count) : [],
            mainHeader: "",
            rows: rows,
            period: periodText,
            shortPeriod: periodText,
            clock: clockText,
            callout: callout,
            detail: detail,
            isFinished: isFinished
        )
    }

    func periodName(_ n: Int, lang: ScoreLang) -> String {
        if n <= config.halves { return lang.t("HIỆP \(n)", n == 1 ? "1ST HALF" : (n == 2 ? "2ND HALF" : "PERIOD \(n)")) }
        let e = n - config.halves
        return lang.t("HIỆP PHỤ \(e)", "EXTRA TIME \(e)")
    }

    // MARK: Controls

    func controls(lang: ScoreLang) -> [SportControl<FootballAction>] {
        var c: [SportControl<FootballAction>] = []
        var playing = false
        if case .playing = period { playing = true }

        // Nút chung
        switch period {
        case .pregame:
            c.append(.init(id: "kickoff", title: lang.t("Giao bóng (bắt đầu)", "Kick-off"), side: nil,
                           role: .primary, action: .startClock))
        case .playing:
            c.append(.init(id: "clock", title: clock.isRunning ? lang.t("Dừng giờ", "Stop clock")
                                                               : lang.t("Chạy giờ", "Start clock"),
                           side: nil, role: .primary,
                           action: clock.isRunning ? .stopClock : .startClock))
            c.append(.init(id: "minus10", title: "−10s", side: nil, action: .adjustClock(seconds: -10)))
            c.append(.init(id: "plus10", title: "+10s", side: nil, action: .adjustClock(seconds: 10)))
            c.append(.init(id: "added", title: lang.t("Bù giờ +1'", "Added +1'"), side: nil,
                           action: .setAddedTime(minutes: addedMinutes + 1)))
            c.append(.init(id: "end", title: lang.t("Hết hiệp", "End period"), side: nil,
                           role: .destructive, action: .endPeriod))
        case .interval(let n):
            if nextIsShootout(after: n) {
                for s in Side.allCases {
                    c.append(.init(id: "so-\(s)", title: lang.t("Luân lưu: \(teams[s].shortName) đá trước",
                                                                "Shootout: \(teams[s].shortName) first"),
                                   side: nil, role: .primary, action: .startShootout(first: s)))
                }
            } else {
                c.append(.init(id: "next", title: lang.t("Bắt đầu hiệp tiếp", "Start next period"), side: nil,
                               role: .primary, action: .startNextPeriod))
            }
        case .penalties, .finished:
            break
        }

        for s in Side.allCases {
            if period == .penalties {
                let mine = nextKicker == s
                c.append(.init(id: "pk-in-\(s)", title: lang.t("Sút vào", "Scored"), side: s,
                               role: .primary, enabled: mine, action: .kick(s, scored: true)))
                c.append(.init(id: "pk-out-\(s)", title: lang.t("Sút hỏng", "Missed"), side: s,
                               role: .destructive, enabled: mine, action: .kick(s, scored: false)))
                continue
            }
            c.append(.init(id: "goal-\(s)", title: lang.t("Bàn thắng", "Goal"), side: s, role: .primary,
                           enabled: playing, inputPrompt: lang.t("Cầu thủ ghi bàn (có thể bỏ trống)", "Scorer (optional)"),
                           make: { .goal(s, player: $0, ownGoal: false) }))
            c.append(.init(id: "og-\(s)", title: lang.t("Phản lưới (+1)", "Own goal (+1)"), side: s,
                           enabled: playing, inputPrompt: lang.t("Cầu thủ đội bạn đá phản", "Player (optional)"),
                           make: { .goal(s, player: $0, ownGoal: true) }))
            c.append(.init(id: "foul-\(s)", title: lang.t("Lỗi", "Foul"), side: s,
                           enabled: playing, action: .foul(s)))
            c.append(.init(id: "unfoul-\(s)", title: lang.t("Bớt lỗi", "Foul −1"), side: s,
                           enabled: fouls[s] > 0, action: .cancelFoul(s)))
            c.append(.init(id: "yc-\(s)", title: lang.t("Thẻ vàng", "Yellow"), side: s,
                           enabled: !isFinished, inputPrompt: lang.t("Tên / số áo", "Name / number"),
                           make: { .card(s, player: $0 ?? "", kind: .yellow) }))
            c.append(.init(id: "rc-\(s)", title: lang.t("Thẻ đỏ", "Red"), side: s, role: .destructive,
                           enabled: !isFinished, inputPrompt: lang.t("Tên / số áo", "Name / number"),
                           make: { .card(s, player: $0 ?? "", kind: .red) }))
            if config.timeoutsPerHalf > 0 {
                c.append(.init(id: "to-\(s)", title: lang.t("Hội ý", "Timeout"), side: s,
                               enabled: playing && timeoutsUsed[s] < config.timeoutsPerHalf,
                               action: .timeout(s)))
            }
        }
        return c
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

//
//  VolleyballEngine.swift
//
//  • Bóng chuyền trong nhà (FIVB): rally scoring, set 1–4 đến 25, set quyết định (set 5) đến 15,
//    cách 2, không giới hạn trần. Thắng 3/5 set. 2 hội ý / set / đội, 6 lần thay người / set / đội.
//    Set quyết định: đổi sân khi một đội chạm 8.
//    Bên thắng rally mà đang không giao → giành quyền giao (side out, xoay vòng).
//    Set mới: đổi bên giao trước so với set trước; set quyết định bốc thăm lại (nút "Giao trước").
//  • Bóng chuyền bãi biển: set đến 21, set 3 đến 15, thắng 2/3. Đổi sân mỗi 7 điểm (tổng),
//    set 3 mỗi 5 điểm. 1 hội ý / set. Tạm dừng kỹ thuật khi tổng điểm = 21 ở set 1–2
//    (tắt được bằng technicalTimeoutAtTotal = nil nếu giải không dùng).
//

import Foundation

struct VolleyballConfig: Codable, Equatable {
    var bestOf: Int
    var setPoints: Int
    var decidingSetPoints: Int
    var winBy: Int
    var timeoutsPerSet: Int
    var substitutionsPerSet: Int
    /// Trong nhà: đổi sân ở set quyết định khi một đội chạm mốc này.
    var decidingSwitchAt: Int?
    /// Bãi biển: đổi sân mỗi N điểm (tổng 2 đội).
    var switchEvery: Int?
    var decidingSwitchEvery: Int?
    var technicalTimeoutAtTotal: Int?

    static let indoor = VolleyballConfig(bestOf: 5, setPoints: 25, decidingSetPoints: 15, winBy: 2,
                                                timeoutsPerSet: 2, substitutionsPerSet: 6,
                                                decidingSwitchAt: 8, switchEvery: nil,
                                                decidingSwitchEvery: nil, technicalTimeoutAtTotal: nil)
    static let beach = VolleyballConfig(bestOf: 3, setPoints: 21, decidingSetPoints: 15, winBy: 2,
                                               timeoutsPerSet: 1, substitutionsPerSet: 0,
                                               decidingSwitchAt: nil, switchEvery: 7,
                                               decidingSwitchEvery: 5, technicalTimeoutAtTotal: 21)
}

enum VolleyballAction: Codable, Equatable {
    case rally(winner: Side)
    case setFirstServer(Side)   // trước rally đầu tiên của set
    case timeout(Side)
    case substitution(Side)
}

struct VolleyballEngine: SportEngine {
    var config: VolleyballConfig
    var teams: Pair<TeamInfo>

    private(set) var completed: [Pair<Int>] = []
    private(set) var points = Pair(0, 0)
    private(set) var serving: Side = .home
    private(set) var firstServerOfSet: Side = .home
    private(set) var timeoutsUsed = Pair(0, 0)
    private(set) var subsUsed = Pair(0, 0)
    /// Vị trí xoay vòng (1…6) – tăng mỗi khi đội giành lại quyền giao.
    private(set) var rotation = Pair(1, 1)
    private(set) var switchedInDecider = false
    private(set) var ralliesInSet = 0
    private(set) var lastEvent: ScoreEvent = .none

    init(config: VolleyballConfig = .indoor, teams: Pair<TeamInfo> = TeamInfo.defaultPair) {
        self.config = config
        self.teams = teams
    }

    var setsNeeded: Int { config.bestOf / 2 + 1 }
    var setsWon: Pair<Int> { MatchMath.wins(completed) }
    var winner: Side? { Side.allCases.first { setsWon[$0] >= setsNeeded } }
    var isFinished: Bool { winner != nil }
    var setNumber: Int { completed.count + 1 }
    var isDecidingSet: Bool { setsWon.home == setsNeeded - 1 && setsWon.away == setsNeeded - 1 }
    var target: GameTarget {
        GameTarget(points: isDecidingSet ? config.decidingSetPoints : config.setPoints, winBy: config.winBy)
    }

    var pressure: (side: Side, isMatch: Bool)? {
        guard !isFinished else { return nil }
        for s in [serving, serving.other] where target.wouldWin(points, scorer: s) {
            return (s, setsWon[s] + 1 >= setsNeeded)
        }
        return nil
    }

    mutating func apply(_ action: VolleyballAction, at now: Date) {
        guard !isFinished else { return }
        lastEvent = .none
        switch action {
        case .setFirstServer(let s):
            guard ralliesInSet == 0 else { return }
            firstServerOfSet = s
            serving = s

        case .timeout(let s):
            guard timeoutsUsed[s] < config.timeoutsPerSet else { return }
            timeoutsUsed[s] += 1
            lastEvent = .timeout(s)

        case .substitution(let s):
            guard subsUsed[s] < config.substitutionsPerSet else { return }
            subsUsed[s] += 1

        case .rally(let w):
            ralliesInSet += 1
            points[w] += 1
            if w != serving {
                serving = w
                rotation[w] = rotation[w] % 6 + 1
                lastEvent = .sideOut
            }
            if let sw = target.winner(points) {
                finishSet(sw)
                return
            }
            let total = points.home + points.away
            if isDecidingSet, let at = config.decidingSwitchAt, !switchedInDecider,
               max(points.home, points.away) >= at {
                switchedInDecider = true
                lastEvent = .switchEnds
            }
            if let every = (isDecidingSet ? config.decidingSwitchEvery : config.switchEvery),
               every > 0, total % every == 0 {
                lastEvent = .switchEnds
            }
            if !isDecidingSet, let tto = config.technicalTimeoutAtTotal, total == tto {
                lastEvent = .technicalTimeout
            }
        }
    }

    private mutating func finishSet(_ w: Side) {
        completed.append(points)
        if isFinished {
            lastEvent = .matchWon(w)
            return
        }
        lastEvent = .gameWon(w)
        points = Pair(0, 0)
        timeoutsUsed = Pair(0, 0)
        subsUsed = Pair(0, 0)
        rotation = Pair(1, 1)
        switchedInDecider = false
        ralliesInSet = 0
        firstServerOfSet = firstServerOfSet.other
        serving = firstServerOfSet
    }

    func display(lang: ScoreLang, at now: Date) -> SportDisplay {
        let wins = setsWon
        let rows: [SportDisplay.Row] = Side.allCases.map { s in
            var badges: [SportDisplay.Badge] = []
            if !isFinished {
                let to = config.timeoutsPerSet - timeoutsUsed[s]
                badges.append(.init("TO \(to)", to == 0 ? .warning : .normal))
                if config.substitutionsPerSet > 0 {
                    let sub = config.substitutionsPerSet - subsUsed[s]
                    badges.append(.init("SUB \(sub)", sub == 0 ? .warning : .normal))
                }
            }
            return .init(side: s, team: teams[s],
                         columns: completed.map { "\($0[s])" },
                         main: isFinished ? "\(wins[s])" : "\(points[s])",
                         isServing: !isFinished && serving == s,
                         badges: badges,
                         isWinner: winner == s)
        }
        var callout = Callouts.text(lastEvent, teams: teams, lang: lang, unitVI: "SET", unitEN: "SET")
        if callout == nil, let p = pressure {
            callout = p.isMatch ? "MATCH POINT" : "SET POINT"
        }
        return SportDisplay(
            sportTitle: config.switchEvery != nil ? lang.t("BÓNG CHUYỀN BÃI BIỂN", "BEACH VOLLEYBALL")
                                                   : lang.t("BÓNG CHUYỀN", "VOLLEYBALL"),
            columnHeaders: completed.indices.map { "S\($0 + 1)" },
            mainHeader: isFinished ? "SET" : lang.t("ĐIỂM", "PTS"),
            rows: rows,
            period: isFinished ? lang.t("KẾT THÚC", "FINAL")
                               : "SET \(setNumber)" + lang.t(" · tỉ số set \(wins.home)-\(wins.away)",
                                                             " · sets \(wins.home)-\(wins.away)"),
            shortPeriod: isFinished ? lang.t("KẾT THÚC", "FINAL") : "SET \(setNumber)",
            clock: nil,
            callout: callout,
            detail: nil,
            isFinished: isFinished
        )
    }

    func controls(lang: ScoreLang) -> [SportControl<VolleyballAction>] {
        var c: [SportControl<VolleyballAction>] = []
        for s in Side.allCases {
            c.append(.init(id: "rally-\(s)", title: lang.t("+1 điểm", "+1 point"), side: s,
                           role: .primary, enabled: !isFinished, action: .rally(winner: s)))
            c.append(.init(id: "to-\(s)", title: lang.t("Hội ý", "Timeout"), side: s,
                           enabled: !isFinished && timeoutsUsed[s] < config.timeoutsPerSet,
                           action: .timeout(s)))
            if config.substitutionsPerSet > 0 {
                c.append(.init(id: "sub-\(s)", title: lang.t("Thay người", "Substitution"), side: s,
                               enabled: !isFinished && subsUsed[s] < config.substitutionsPerSet,
                               action: .substitution(s)))
            }
            c.append(.init(id: "first-\(s)", title: lang.t("Giao trước", "Serves first"), side: s,
                           enabled: !isFinished && ralliesInSet == 0, action: .setFirstServer(s)))
        }
        return c
    }
}

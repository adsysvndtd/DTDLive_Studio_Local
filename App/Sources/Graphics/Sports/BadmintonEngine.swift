//
//  BadmintonEngine.swift
//
//  Luật BWF – rally scoring, bên thắng rally được giao:
//  • 3×15 (BWF áp dụng từ 04/01/2027): game 15 điểm, cách 2, 20-20 thì điểm thứ 21 thắng
//    (setting to 21); nghỉ / đổi sân game quyết định khi bên dẫn chạm 8.
//  • 3×21 (luật cũ, vẫn phổ biến ở giải phong trào): game 21, cách 2, 29-29 thì điểm 30 thắng;
//    nghỉ / đổi sân game quyết định khi bên dẫn chạm 11.
//  • Thắng 2/3 game. Bên thắng game giao trước ở game sau. Đổi sân sau mỗi game.
//  • Ô giao: điểm của bên giao chẵn → ô phải, lẻ → ô trái.
//

import Foundation

struct BadmintonConfig: Codable, Equatable {
    var target: GameTarget
    var bestOf: Int
    /// Điểm của bên dẫn để nghỉ giữa game (và đổi sân ở game quyết định).
    var intervalAt: Int

    init(target: GameTarget, bestOf: Int = 3, intervalAt: Int) {
        self.target = target
        self.bestOf = bestOf
        self.intervalAt = intervalAt
    }

    static let bwf3x15 = BadmintonConfig(target: GameTarget(points: 15, winBy: 2, cap: 21), intervalAt: 8)
    static let bwf3x21 = BadmintonConfig(target: GameTarget(points: 21, winBy: 2, cap: 30), intervalAt: 11)
}

enum BadmintonAction: Codable, Equatable {
    case rally(winner: Side)
    case setFirstServer(Side)   // chỉ trước rally đầu tiên của trận
}

struct BadmintonEngine: SportEngine {
    var config: BadmintonConfig
    var teams: Pair<TeamInfo>

    private(set) var completed: [Pair<Int>] = []
    private(set) var points = Pair(0, 0)
    private(set) var serving: Side = .home
    private(set) var ralliesInGame = 0
    private(set) var intervalDone = false
    private(set) var lastEvent: ScoreEvent = .none

    init(config: BadmintonConfig = .bwf3x15, teams: Pair<TeamInfo> = TeamInfo.defaultPair) {
        self.config = config
        self.teams = teams
    }

    var gamesNeeded: Int { config.bestOf / 2 + 1 }
    var gamesWon: Pair<Int> { MatchMath.wins(completed) }
    var winner: Side? { Side.allCases.first { gamesWon[$0] >= gamesNeeded } }
    var isFinished: Bool { winner != nil }
    var isDecidingGame: Bool { gamesWon.home == gamesNeeded - 1 && gamesWon.away == gamesNeeded - 1 }
    /// Ô giao hiện tại: true = ô phải.
    var servesFromRight: Bool { points[serving] % 2 == 0 }

    var pressure: (side: Side, isMatch: Bool)? {
        guard !isFinished else { return nil }
        // Rally scoring: ưu tiên bên giao (thường là bên dẫn); nếu cả hai cùng game point (20-20 ở 3x15) thì báo của bên giao.
        for s in [serving, serving.other] where config.target.wouldWin(points, scorer: s) {
            return (s, gamesWon[s] + 1 >= gamesNeeded)
        }
        return nil
    }

    mutating func apply(_ action: BadmintonAction, at now: Date) {
        guard !isFinished else { return }
        lastEvent = .none
        switch action {
        case .setFirstServer(let s):
            guard completed.isEmpty, ralliesInGame == 0 else { return }
            serving = s

        case .rally(let w):
            ralliesInGame += 1
            points[w] += 1
            serving = w
            if let gw = config.target.winner(points) {
                completed.append(points)
                if isFinished {
                    lastEvent = .matchWon(gw)
                } else {
                    lastEvent = .gameWon(gw)
                    points = Pair(0, 0)
                    ralliesInGame = 0
                    intervalDone = false
                    serving = gw          // bên thắng game giao trước game sau
                }
            } else if !intervalDone, max(points.home, points.away) == config.intervalAt {
                intervalDone = true
                lastEvent = isDecidingGame ? .switchEnds : .interval
            }
        }
    }

    func display(lang: ScoreLang, at now: Date) -> SportDisplay {
        let wins = gamesWon
        let rows: [SportDisplay.Row] = Side.allCases.map { s in
            .init(side: s, team: teams[s],
                  columns: completed.map { "\($0[s])" },
                  main: isFinished ? "\(wins[s])" : "\(points[s])",
                  isServing: !isFinished && serving == s,
                  badges: [],
                  isWinner: winner == s)
        }
        var callout = Callouts.text(lastEvent, teams: teams, lang: lang)
        if case .switchEnds = lastEvent {
            callout = lang.t("NGHỈ · ĐỔI SÂN", "INTERVAL · CHANGE ENDS")
        }
        if callout == nil, let p = pressure {
            callout = p.isMatch ? "MATCH POINT" : "GAME POINT"
        }
        let detail: String? = isFinished ? nil
            : (servesFromRight ? lang.t("Giao ô phải", "Serving from right")
                               : lang.t("Giao ô trái", "Serving from left"))
        let fmt = "\(config.bestOf)×\(config.target.points)"
        return SportDisplay(
            sportTitle: lang.t("CẦU LÔNG", "BADMINTON"),
            columnHeaders: completed.indices.map { lang.t("V\($0 + 1)", "G\($0 + 1)") },
            mainHeader: isFinished ? lang.t("VÁN", "GAMES") : lang.t("ĐIỂM", "PTS"),
            rows: rows,
            period: isFinished ? lang.t("KẾT THÚC", "FINAL")
                               : lang.t("VÁN \(completed.count + 1) · \(fmt)", "GAME \(completed.count + 1) · \(fmt)"),
            shortPeriod: isFinished ? lang.t("KẾT THÚC", "FINAL") : lang.t("VÁN \(completed.count + 1)", "GAME \(completed.count + 1)"),
            clock: nil,
            callout: callout,
            detail: detail,
            isFinished: isFinished
        )
    }

    func controls(lang: ScoreLang) -> [SportControl<BadmintonAction>] {
        var c: [SportControl<BadmintonAction>] = []
        for s in Side.allCases {
            c.append(.init(id: "rally-\(s)", title: lang.t("+1 điểm", "+1 point"), side: s,
                           role: .primary, enabled: !isFinished, action: .rally(winner: s)))
            c.append(.init(id: "first-\(s)", title: lang.t("Giao trước", "Serves first"), side: s,
                           enabled: !isFinished && completed.isEmpty && ralliesInGame == 0,
                           action: .setFirstServer(s)))
        }
        return c
    }
}

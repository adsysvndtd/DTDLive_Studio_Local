//
//  PickleballEngine.swift
//
//  Luật (USA Pickleball / tương đương):
//  • Side-out scoring (truyền thống): chỉ bên GIAO mới ghi điểm.
//    – Đánh đôi: mỗi bên có 2 người giao (server 1, 2). Đầu game bắt đầu "0-0-2"
//      (bên giao đầu tiên chỉ có 1 người giao). Bên giao thua rally: server 1 → server 2,
//      server 2 → side out (đổi giao sang đối phương, bắt đầu từ server 1).
//    – Đánh đơn: bên giao thua rally là side out ngay.
//    – Score call: "điểm bên giao – điểm bên nhận – số người giao" (đơn: 2 số).
//  • Rally scoring (tuỳ chọn, thường game 21): rally nào cũng ra điểm, bên thắng rally giao.
//  • Game 11 (hoặc 15/21) cách 2; trận best-of-1/3/5.
//  • Game quyết định: đổi sân khi một bên chạm điểm giữa (6 khi game 11, 8 khi 15, 11 khi 21).
//  • Hội ý: 2/game (game 11), 3/game (game 15, 21).
//  • Sang game mới: đảo bên giao trước (người điều khiển có thể sửa trước rally đầu).
//

import Foundation

struct PickleballConfig: Codable, Equatable {
    enum Format: String, Codable { case doubles, singles }
    enum Scoring: String, Codable { case sideOut, rally }

    var format: Format
    var scoring: Scoring
    var target: GameTarget
    var bestOf: Int
    var timeoutsPerGame: Int
    var switchEndsInDecider: Bool

    init(format: Format = .doubles, scoring: Scoring = .sideOut, points: Int = 11,
                winBy: Int = 2, cap: Int? = nil, bestOf: Int = 3,
                timeoutsPerGame: Int? = nil, switchEndsInDecider: Bool = true) {
        self.format = format
        self.scoring = scoring
        self.target = GameTarget(points: points, winBy: winBy, cap: cap)
        self.bestOf = bestOf
        self.timeoutsPerGame = timeoutsPerGame ?? (points >= 15 ? 3 : 2)
        self.switchEndsInDecider = switchEndsInDecider
    }

    static let doubles11 = PickleballConfig()
    static let singles11 = PickleballConfig(format: .singles)
    static let rally21 = PickleballConfig(scoring: .rally, points: 21)
}

enum PickleballAction: Codable, Equatable {
    case rally(winner: Side)
    case setFirstServer(Side)   // chỉ hợp lệ trước rally đầu tiên của game
    case timeout(Side)
}

struct PickleballEngine: SportEngine {
    var config: PickleballConfig
    var teams: Pair<TeamInfo>

    private(set) var completed: [Pair<Int>] = []
    private(set) var points = Pair(0, 0)
    private(set) var serving: Side = .home
    private(set) var serverNumber: Int = 2
    private(set) var firstServerOfGame: Side = .home
    private(set) var timeoutsUsed = Pair(0, 0)
    private(set) var switchedInDecider = false
    private(set) var ralliesInGame = 0
    private(set) var lastEvent: ScoreEvent = .none

    init(config: PickleballConfig = .doubles11, teams: Pair<TeamInfo> = TeamInfo.defaultPair) {
        self.config = config
        self.teams = teams
        self.serverNumber = startServerNumber
    }

    // MARK: Derived

    var startServerNumber: Int {
        (config.format == .doubles && config.scoring == .sideOut) ? 2 : 1
    }
    var gamesNeeded: Int { config.bestOf / 2 + 1 }
    var gamesWon: Pair<Int> { MatchMath.wins(completed) }
    var winner: Side? { Side.allCases.first { gamesWon[$0] >= gamesNeeded } }
    var isFinished: Bool { winner != nil }
    var gameNumber: Int { completed.count + 1 }
    var isDecidingGame: Bool {
        gamesWon.home == gamesNeeded - 1 && gamesWon.away == gamesNeeded - 1
    }
    var midpoint: Int { (config.target.points + 1) / 2 }

    /// Bên đang có game/match point (side-out: chỉ bên giao mới ghi điểm được).
    var pressure: (side: Side, isMatch: Bool)? {
        guard !isFinished else { return nil }
        let candidates: [Side] = config.scoring == .sideOut ? [serving] : Side.allCases
        for s in candidates where config.target.wouldWin(points, scorer: s) {
            return (s, gamesWon[s] + 1 >= gamesNeeded)
        }
        return nil
    }

    /// Score call đọc to trước mỗi quả giao.
    var scoreCall: String? {
        guard !isFinished, config.scoring == .sideOut else { return nil }
        let a = points[serving], b = points[serving.other]
        return config.format == .doubles ? "\(a)-\(b)-\(serverNumber)" : "\(a)-\(b)"
    }

    // MARK: Apply

    mutating func apply(_ action: PickleballAction, at now: Date) {
        guard !isFinished else { return }
        lastEvent = .none
        switch action {
        case .setFirstServer(let s):
            guard ralliesInGame == 0 else { return }
            firstServerOfGame = s
            serving = s
            serverNumber = startServerNumber

        case .timeout(let s):
            guard timeoutsUsed[s] < config.timeoutsPerGame else { return }
            timeoutsUsed[s] += 1
            lastEvent = .timeout(s)

        case .rally(let w):
            ralliesInGame += 1
            switch config.scoring {
            case .rally:
                points[w] += 1
                if w != serving {
                    serving = w
                    lastEvent = .sideOut
                }
            case .sideOut:
                if w == serving {
                    points[w] += 1
                } else if config.format == .doubles && serverNumber == 1 {
                    serverNumber = 2
                    lastEvent = .secondServer
                } else {
                    serving = serving.other
                    serverNumber = 1
                    lastEvent = .sideOut
                }
            }

            if let gw = config.target.winner(points) {
                finishGame(gw)
            } else if config.switchEndsInDecider, isDecidingGame, !switchedInDecider,
                      max(points.home, points.away) >= midpoint {
                switchedInDecider = true
                lastEvent = .switchEnds
            }
        }
    }

    private mutating func finishGame(_ w: Side) {
        completed.append(points)
        if isFinished {
            lastEvent = .matchWon(w)
            return
        }
        lastEvent = .gameWon(w)
        points = Pair(0, 0)
        timeoutsUsed = Pair(0, 0)
        switchedInDecider = false
        ralliesInGame = 0
        firstServerOfGame = firstServerOfGame.other
        serving = firstServerOfGame
        serverNumber = startServerNumber
    }

    // MARK: Display

    func display(lang: ScoreLang, at now: Date) -> SportDisplay {
        let wins = gamesWon
        let rows: [SportDisplay.Row] = Side.allCases.map { s in
            var badges: [SportDisplay.Badge] = []
            if !isFinished {
                let left = config.timeoutsPerGame - timeoutsUsed[s]
                badges.append(.init("TO \(left)", left == 0 ? .warning : .normal))
                if serving == s && config.format == .doubles && config.scoring == .sideOut {
                    badges.append(.init(lang.t("Người giao \(serverNumber)", "Server \(serverNumber)"), .highlight))
                }
            }
            return .init(side: s, team: teams[s],
                         columns: completed.map { "\($0[s])" },
                         main: isFinished ? "\(wins[s])" : "\(points[s])",
                         isServing: !isFinished && serving == s,
                         badges: badges,
                         isWinner: winner == s)
        }

        var callout = Callouts.text(lastEvent, teams: teams, lang: lang)
        if callout == nil, let p = pressure {
            callout = p.isMatch ? "MATCH POINT" : "GAME POINT"
        }

        let mode = config.scoring == .rally ? lang.t("Rally", "Rally") : lang.t("Side-out", "Side-out")
        return SportDisplay(
            sportTitle: "PICKLEBALL",
            columnHeaders: completed.indices.map { lang.t("V\($0 + 1)", "G\($0 + 1)") },
            mainHeader: isFinished ? lang.t("VÁN", "GAMES") : lang.t("ĐIỂM", "PTS"),
            rows: rows,
            period: isFinished ? lang.t("KẾT THÚC", "FINAL")
                               : lang.t("VÁN \(gameNumber) · \(config.target.points) điểm · \(mode)",
                                        "GAME \(gameNumber) · TO \(config.target.points) · \(mode)"),
            shortPeriod: isFinished ? lang.t("KẾT THÚC", "FINAL") : lang.t("VÁN \(gameNumber)", "GAME \(gameNumber)"),
            clock: nil,
            callout: callout,
            detail: scoreCall,
            isFinished: isFinished
        )
    }

    // MARK: Controls

    func controls(lang: ScoreLang) -> [SportControl<PickleballAction>] {
        var c: [SportControl<PickleballAction>] = []
        for s in Side.allCases {
            c.append(.init(id: "rally-\(s)", title: lang.t("Thắng rally", "Rally won"), side: s,
                           role: .primary, enabled: !isFinished, action: .rally(winner: s)))
            c.append(.init(id: "to-\(s)", title: lang.t("Hội ý", "Timeout"), side: s,
                           enabled: !isFinished && timeoutsUsed[s] < config.timeoutsPerGame,
                           action: .timeout(s)))
            c.append(.init(id: "first-\(s)", title: lang.t("Giao trước", "Serves first"), side: s,
                           enabled: !isFinished && ralliesInGame == 0, action: .setFirstServer(s)))
        }
        return c
    }
}

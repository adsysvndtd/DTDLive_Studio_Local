//
//  BilliardsEngine.swift
//
//  Hai họ luật trong một engine:
//
//  POOL (8 bi, 9 bi, 10 bi) – thi đấu "race to N" (chạm N rack):
//  • Mỗi rack thắng +1. Ai chạm N trước thắng trận. Hill-hill khi cả hai còn 1 rack.
//  • Quyền phá: luân phiên (alternate break – WPA) hoặc người thắng rack phá (winner breaks).
//  • Đồng hồ cơ (tùy chọn, ví dụ 30 s) + gia hạn (extension) 30 s, 1 lần mỗi rack mỗi người.
//
//  CAROM (3 băng / tự do) – đánh đến số điểm (ví dụ 40):
//  • Mỗi lần ghi điểm +1 và cộng series (run) hiện tại; đánh hỏng → kết thúc lượt, đổi người.
//  • Thống kê: số lượt (innings), series cao nhất (HR), điểm trung bình (TB = điểm / lượt).
//  • Lượt cân bằng (equalizing inning – tùy chọn): người khai cuộc chạm đích thì đối thủ được
//    đánh lượt cuối; nếu cũng chạm đích → hòa.
//  • Giới hạn lượt (tùy chọn): hết lượt thì so điểm.
//  • Đồng hồ cơ (ví dụ 40 s) tự khởi động lại sau mỗi cú; gia hạn tính theo trận.
//

import Foundation

struct BilliardsConfig: Codable, Equatable {
    enum Game: String, Codable, CaseIterable { case eightBall, nineBall, tenBall, threeCushion, straightRail }
    enum BreakRule: String, Codable { case alternate, winner }

    var game: Game
    var raceTo: Int = 9
    var caromTarget: Int = 40
    var inningLimit: Int? = nil
    var equalizingInning: Bool = true
    var breakRule: BreakRule = .alternate
    var shotClockSeconds: Int? = nil
    var extensionSeconds: Int = 30
    var extensionsPerUnit: Int = 1   // pool: mỗi rack; carom: mỗi trận

    var isCarom: Bool { game == .threeCushion || game == .straightRail }

    init(game: Game, raceTo: Int = 9, caromTarget: Int = 40, inningLimit: Int? = nil,
                equalizingInning: Bool = true, breakRule: BreakRule = .alternate,
                shotClockSeconds: Int? = nil, extensionSeconds: Int = 30, extensionsPerUnit: Int = 1) {
        self.game = game
        self.raceTo = raceTo
        self.caromTarget = caromTarget
        self.inningLimit = inningLimit
        self.equalizingInning = equalizingInning
        self.breakRule = breakRule
        self.shotClockSeconds = shotClockSeconds
        self.extensionSeconds = extensionSeconds
        self.extensionsPerUnit = extensionsPerUnit
    }

    static let nineBall = BilliardsConfig(game: .nineBall, raceTo: 9, shotClockSeconds: 30)
    static let eightBall = BilliardsConfig(game: .eightBall, raceTo: 7)
    static let tenBall = BilliardsConfig(game: .tenBall, raceTo: 9, shotClockSeconds: 30)
    static let threeCushion = BilliardsConfig(game: .threeCushion, caromTarget: 40,
                                                     shotClockSeconds: 40, extensionSeconds: 40)
    static let straightRail = BilliardsConfig(game: .straightRail, caromTarget: 100)
}

enum BilliardsAction: Codable, Equatable {
    case setBreaker(Side)       // pool: người phá rack hiện tại; carom: người khai cuộc (trước điểm đầu)
    case rackWon(Side)          // pool
    case point                  // carom: +1 cho người đang đánh
    case endInning              // carom: đánh hỏng → đổi lượt
    case shotClockStart
    case shotClockStop
    case shotClockReset
    case useExtension(Side)
}

struct BilliardsEngine: SportEngine {
    var config: BilliardsConfig
    var teams: Pair<TeamInfo>

    // Pool
    private(set) var racks = Pair(0, 0)
    private(set) var breaker: Side = .home
    // Carom
    private(set) var score = Pair(0, 0)
    private(set) var shooter: Side = .home
    private(set) var starter: Side = .home
    private(set) var innings = Pair(0, 0)
    private(set) var currentRun = 0
    private(set) var highRun = Pair(0, 0)
    private(set) var finalInning = false
    // Chung
    private(set) var started = false
    private(set) var finished = false
    private(set) var result: Side? = nil     // nil + finished = hòa
    private(set) var shotClock: ShotClock?
    private(set) var extensionsUsed = Pair(0, 0)
    private(set) var lastEvent: ScoreEvent = .none

    init(config: BilliardsConfig = .nineBall, teams: Pair<TeamInfo> = TeamInfo.defaultPair) {
        self.config = config
        self.teams = teams
        if let s = config.shotClockSeconds { shotClock = ShotClock(limit: TimeInterval(s)) }
    }

    var isFinished: Bool { finished }
    var needsTicking: Bool { shotClock?.isRunning ?? false }
    var rackNumber: Int { racks.home + racks.away + 1 }

    /// Lượt hiện tại (theo người khai cuộc).
    var currentInning: Int { innings[starter] + (shooter == starter && !finished ? 1 : 0) }

    func average(_ s: Side) -> Double {
        innings[s] > 0 ? Double(score[s]) / Double(innings[s]) : 0
    }

    /// Bật/tắt hoặc đổi thời gian đồng hồ cơ (từ màn hình cài đặt luật).
    mutating func setShotClock(seconds: Int?) {
        config.shotClockSeconds = seconds
        shotClock = seconds.map { ShotClock(limit: TimeInterval($0)) }
    }

    // MARK: Apply

    mutating func apply(_ action: BilliardsAction, at now: Date) {
        guard !finished else { return }
        lastEvent = .none
        switch action {
        case .setBreaker(let s):
            if config.isCarom {
                guard !started else { return }
                starter = s
                shooter = s
            } else {
                breaker = s
            }

        case .rackWon(let w):
            guard !config.isCarom else { return }
            started = true
            racks[w] += 1
            extensionsUsed = Pair(0, 0)
            shotClock?.reset(running: false, at: now)
            if racks[w] >= config.raceTo {
                finish(w)
            } else {
                lastEvent = .rackWon(w)
                breaker = config.breakRule == .alternate ? breaker.other : w
            }

        case .point:
            guard config.isCarom else { return }
            started = true
            score[shooter] += 1
            currentRun += 1
            highRun[shooter] = max(highRun[shooter], currentRun)
            if score[shooter] >= config.caromTarget {
                closeInning(reachedTarget: true, at: now)
            } else {
                shotClock?.reset(running: true, at: now)
            }

        case .endInning:
            guard config.isCarom else { return }
            started = true
            closeInning(reachedTarget: false, at: now)

        case .shotClockStart:
            shotClock?.start(at: now)
        case .shotClockStop:
            shotClock?.stop(at: now)
        case .shotClockReset:
            shotClock?.reset(running: false, at: now)

        case .useExtension(let s):
            guard shotClock != nil, extensionsUsed[s] < config.extensionsPerUnit else { return }
            extensionsUsed[s] += 1
            shotClock?.add(TimeInterval(config.extensionSeconds), at: now)
        }
    }

    private mutating func closeInning(reachedTarget: Bool, at now: Date) {
        innings[shooter] += 1
        currentRun = 0
        let wasStarter = shooter == starter

        if reachedTarget {
            if wasStarter && config.equalizingInning {
                shooter = shooter.other
                finalInning = true
                lastEvent = .finalInning
                shotClock?.reset(running: true, at: now)
            } else if finalInning && score[starter] >= config.caromTarget {
                finish(nil)   // cả hai chạm đích cùng số lượt → hòa
            } else {
                finish(shooter)
            }
            return
        }

        if finalInning {           // người đánh sau không cân bằng được
            finish(starter)
            return
        }
        if !wasStarter, let limit = config.inningLimit, innings[shooter] >= limit {
            if score.home == score.away { finish(nil) } else { finish(score.home > score.away ? .home : .away) }
            return
        }
        shooter = shooter.other
        shotClock?.reset(running: true, at: now)
    }

    private mutating func finish(_ w: Side?) {
        finished = true
        result = w
        shotClock?.reset(running: false, at: Date())
        if let w = w { lastEvent = .matchWon(w) } else { lastEvent = .draw }
    }

    // MARK: Display

    func display(lang: ScoreLang, at now: Date) -> SportDisplay {
        let clockText = shotClock.map { String(Int($0.remaining(at: now).rounded(.up))) }
        var callout = Callouts.text(lastEvent, teams: teams, lang: lang)

        if config.isCarom {
            let rows: [SportDisplay.Row] = Side.allCases.map { s in
                var badges: [SportDisplay.Badge] = []
                if shotClock != nil && !finished {
                    let left = config.extensionsPerUnit - extensionsUsed[s]
                    if left > 0 { badges.append(.init("EXT \(left)")) }
                }
                return .init(side: s, team: teams[s],
                             columns: ["\(innings[s])", "\(highRun[s])", String(format: "%.3f", average(s))],
                             main: "\(score[s])",
                             isServing: !finished && shooter == s,
                             badges: badges,
                             isWinner: finished && result == s)
            }
            if callout == nil && finalInning && !finished {
                callout = lang.t("LƯỢT CÂN BẰNG", "EQUALIZING INNING")
            }
            let limitText = config.inningLimit.map { "/\($0)" } ?? ""
            let gameName = config.game == .threeCushion ? lang.t("CAROM 3 BĂNG", "3-CUSHION")
                                                        : lang.t("CAROM TỰ DO", "STRAIGHT RAIL")
            return SportDisplay(
                sportTitle: gameName,
                columnHeaders: [lang.t("LƯỢT", "INN"), "HR", lang.t("TB", "AVG")],
                mainHeader: lang.t("ĐIỂM", "PTS"),
                rows: rows,
                period: finished ? lang.t("KẾT THÚC", "FINAL")
                    : lang.t("LƯỢT \(currentInning)\(limitText) · ĐẾN \(config.caromTarget)",
                             "INNING \(currentInning)\(limitText) · TO \(config.caromTarget)"),
                shortPeriod: finished ? lang.t("KẾT THÚC", "FINAL") : lang.t("LƯỢT \(currentInning)", "INN \(currentInning)"),
                clock: finished ? nil : clockText,
                callout: callout,
                detail: currentRun > 0 ? lang.t("Series \(currentRun)", "Run \(currentRun)") : nil,
                isFinished: finished
            )
        }

        // Pool
        let rows: [SportDisplay.Row] = Side.allCases.map { s in
            var badges: [SportDisplay.Badge] = []
            if !finished && breaker == s { badges.append(.init(lang.t("PHÁ", "BREAK"), .highlight)) }
            if shotClock != nil && !finished {
                let left = config.extensionsPerUnit - extensionsUsed[s]
                if left > 0 { badges.append(.init("EXT")) }
            }
            return .init(side: s, team: teams[s], columns: [], main: "\(racks[s])",
                         isServing: !finished && breaker == s, badges: badges,
                         isWinner: finished && result == s)
        }
        if callout == nil && !finished {
            let hill = config.raceTo - 1
            if racks.home == hill && racks.away == hill { callout = "HILL-HILL" }
            else if racks.home == hill || racks.away == hill { callout = lang.t("CÒN 1 RACK", "ON THE HILL") }
        }
        let gameName: String
        switch config.game {
        case .eightBall: gameName = lang.t("BI-A 8 BI", "8-BALL")
        case .nineBall: gameName = lang.t("BI-A 9 BI", "9-BALL")
        case .tenBall: gameName = lang.t("BI-A 10 BI", "10-BALL")
        default: gameName = "POOL"
        }
        return SportDisplay(
            sportTitle: gameName,
            columnHeaders: [],
            mainHeader: "",
            rows: rows,
            period: finished ? lang.t("KẾT THÚC", "FINAL")
                : lang.t("CHẠM \(config.raceTo) · RACK \(rackNumber)", "RACE TO \(config.raceTo) · RACK \(rackNumber)"),
            shortPeriod: finished ? lang.t("KẾT THÚC", "FINAL") : lang.t("CHẠM \(config.raceTo)", "RACE TO \(config.raceTo)"),
            clock: finished ? nil : clockText,
            callout: callout,
            detail: config.breakRule == .alternate ? lang.t("Phá luân phiên", "Alternate break")
                                                   : lang.t("Thắng rack được phá", "Winner breaks"),
            isFinished: finished
        )
    }

    // MARK: Controls

    func controls(lang: ScoreLang) -> [SportControl<BilliardsAction>] {
        var c: [SportControl<BilliardsAction>] = []
        if config.isCarom {
            c.append(.init(id: "point", title: lang.t("+1 điểm (\(teams[shooter].shortName))", "+1 point (\(teams[shooter].shortName))"),
                           side: nil, role: .primary, enabled: !finished, action: .point))
            c.append(.init(id: "miss", title: lang.t("Hỏng – đổi lượt", "Miss – end inning"), side: nil,
                           role: .destructive, enabled: !finished, action: .endInning))
        }
        if shotClock != nil {
            let running = shotClock?.isRunning ?? false
            c.append(.init(id: "sc", title: running ? lang.t("Dừng đồng hồ", "Stop clock") : lang.t("Chạy đồng hồ", "Start clock"),
                           side: nil, enabled: !finished, action: running ? .shotClockStop : .shotClockStart))
            c.append(.init(id: "scr", title: lang.t("Đặt lại đồng hồ", "Reset clock"), side: nil,
                           enabled: !finished, action: .shotClockReset))
        }
        for s in Side.allCases {
            if !config.isCarom {
                c.append(.init(id: "rack-\(s)", title: lang.t("Thắng rack", "Rack won"), side: s,
                               role: .primary, enabled: !finished, action: .rackWon(s)))
                c.append(.init(id: "brk-\(s)", title: lang.t("Quyền phá", "Breaks"), side: s,
                               enabled: !finished, action: .setBreaker(s)))
            } else {
                c.append(.init(id: "brk-\(s)", title: lang.t("Khai cuộc", "Opens"), side: s,
                               enabled: !started, action: .setBreaker(s)))
            }
            if shotClock != nil {
                c.append(.init(id: "ext-\(s)", title: lang.t("Gia hạn", "Extension"), side: s,
                               enabled: !finished && extensionsUsed[s] < config.extensionsPerUnit,
                               action: .useExtension(s)))
            }
        }
        return c
    }
}

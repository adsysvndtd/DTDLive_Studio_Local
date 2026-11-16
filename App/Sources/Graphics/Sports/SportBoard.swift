//
//  SportBoard.swift
//
//  Type-erasure cho 5 engine + danh sách template (undo/redo do StudioEngine giữ).
//

import Foundation

// MARK: - Erased board / action / control

enum SportBoard: Codable, Equatable {
    case pickleball(PickleballEngine)
    case badminton(BadmintonEngine)
    case volleyball(VolleyballEngine)
    case football(FootballEngine)
    case billiards(BilliardsEngine)
}

enum SportAction: Codable, Equatable {
    case pickleball(PickleballAction)
    case badminton(BadmintonAction)
    case volleyball(VolleyballAction)
    case football(FootballAction)
    case billiards(BilliardsAction)
}

struct SportControlItem: Identifiable {
    let id: String
    let title: String
    let side: Side?
    let role: SportControlRole
    let enabled: Bool
    let inputPrompt: String?
    let make: (String?) -> SportAction
}

private func erase<A>(_ controls: [SportControl<A>], _ wrap: @escaping (A) -> SportAction) -> [SportControlItem] {
    controls.map { c in
        SportControlItem(id: c.id, title: c.title, side: c.side, role: c.role, enabled: c.enabled,
                        inputPrompt: c.inputPrompt, make: { wrap(c.make($0)) })
    }
}

extension SportBoard {
    var teams: Pair<TeamInfo> {
        get {
            switch self {
            case .pickleball(let e): return e.teams
            case .badminton(let e): return e.teams
            case .volleyball(let e): return e.teams
            case .football(let e): return e.teams
            case .billiards(let e): return e.teams
            }
        }
        set {
            switch self {
            case .pickleball(var e): e.teams = newValue; self = .pickleball(e)
            case .badminton(var e): e.teams = newValue; self = .badminton(e)
            case .volleyball(var e): e.teams = newValue; self = .volleyball(e)
            case .football(var e): e.teams = newValue; self = .football(e)
            case .billiards(var e): e.teams = newValue; self = .billiards(e)
            }
        }
    }

    var isFinished: Bool {
        switch self {
        case .pickleball(let e): return e.isFinished
        case .badminton(let e): return e.isFinished
        case .volleyball(let e): return e.isFinished
        case .football(let e): return e.isFinished
        case .billiards(let e): return e.isFinished
        }
    }

    var needsTicking: Bool {
        switch self {
        case .pickleball(let e): return e.needsTicking
        case .badminton(let e): return e.needsTicking
        case .volleyball(let e): return e.needsTicking
        case .football(let e): return e.needsTicking
        case .billiards(let e): return e.needsTicking
        }
    }

    func display(lang: ScoreLang, at now: Date = Date()) -> SportDisplay {
        switch self {
        case .pickleball(let e): return e.display(lang: lang, at: now)
        case .badminton(let e): return e.display(lang: lang, at: now)
        case .volleyball(let e): return e.display(lang: lang, at: now)
        case .football(let e): return e.display(lang: lang, at: now)
        case .billiards(let e): return e.display(lang: lang, at: now)
        }
    }

    func controls(lang: ScoreLang) -> [SportControlItem] {
        switch self {
        case .pickleball(let e): return erase(e.controls(lang: lang)) { .pickleball($0) }
        case .badminton(let e): return erase(e.controls(lang: lang)) { .badminton($0) }
        case .volleyball(let e): return erase(e.controls(lang: lang)) { .volleyball($0) }
        case .football(let e): return erase(e.controls(lang: lang)) { .football($0) }
        case .billiards(let e): return erase(e.controls(lang: lang)) { .billiards($0) }
        }
    }

    /// Áp dụng action; action khác môn bị bỏ qua.
    mutating func apply(_ action: SportAction, at now: Date = Date()) {
        switch (self, action) {
        case (.pickleball(var e), .pickleball(let a)): e.apply(a, at: now); self = .pickleball(e)
        case (.badminton(var e), .badminton(let a)): e.apply(a, at: now); self = .badminton(e)
        case (.volleyball(var e), .volleyball(let a)): e.apply(a, at: now); self = .volleyball(e)
        case (.football(var e), .football(let a)): e.apply(a, at: now); self = .football(e)
        case (.billiards(var e), .billiards(let a)): e.apply(a, at: now); self = .billiards(e)
        default: break
        }
    }
}

// MARK: - Templates

enum SportTemplate: String, CaseIterable, Identifiable, Codable {
    case pickleballDoubles, pickleballSingles, pickleballRally21
    case badminton3x15, badminton3x21
    case volleyballIndoor, volleyballBeach
    case football5, football7, futsal, football11
    case pool9Ball, pool8Ball, pool10Ball, carom3Cushion, caromStraightRail

    var id: String { rawValue }

    func title(_ lang: ScoreLang) -> String {
        switch self {
        case .pickleballDoubles: return lang.t("Pickleball đôi · 11 điểm", "Pickleball doubles · to 11")
        case .pickleballSingles: return lang.t("Pickleball đơn · 11 điểm", "Pickleball singles · to 11")
        case .pickleballRally21: return lang.t("Pickleball rally · 21 điểm", "Pickleball rally · to 21")
        case .badminton3x15: return lang.t("Cầu lông 3×15 (BWF 2027)", "Badminton 3×15 (BWF 2027)")
        case .badminton3x21: return lang.t("Cầu lông 3×21", "Badminton 3×21")
        case .volleyballIndoor: return lang.t("Bóng chuyền trong nhà (5 set)", "Indoor volleyball (best of 5)")
        case .volleyballBeach: return lang.t("Bóng chuyền bãi biển (3 set)", "Beach volleyball (best of 3)")
        case .football5: return lang.t("Bóng đá phủi sân 5 · 2×20'", "5-a-side · 2×20'")
        case .football7: return lang.t("Bóng đá phủi sân 7 · 2×25'", "7-a-side · 2×25'")
        case .futsal: return lang.t("Futsal · 2×20' đếm ngược, lỗi tích lũy", "Futsal · 2×20' countdown, fouls")
        case .football11: return lang.t("Bóng đá sân 11 · 2×45'", "11-a-side · 2×45'")
        case .pool9Ball: return lang.t("Bi-a 9 bi · chạm 9", "9-ball · race to 9")
        case .pool8Ball: return lang.t("Bi-a 8 bi · chạm 7", "8-ball · race to 7")
        case .pool10Ball: return lang.t("Bi-a 10 bi · chạm 9", "10-ball · race to 9")
        case .carom3Cushion: return lang.t("Carom 3 băng · 40 điểm", "3-cushion · to 40")
        case .caromStraightRail: return lang.t("Carom tự do · 100 điểm", "Straight rail · to 100")
        }
    }

    func make(teams: Pair<TeamInfo> = TeamInfo.defaultPair) -> SportBoard {
        switch self {
        case .pickleballDoubles: return .pickleball(PickleballEngine(config: .doubles11, teams: teams))
        case .pickleballSingles: return .pickleball(PickleballEngine(config: .singles11, teams: teams))
        case .pickleballRally21: return .pickleball(PickleballEngine(config: .rally21, teams: teams))
        case .badminton3x15: return .badminton(BadmintonEngine(config: .bwf3x15, teams: teams))
        case .badminton3x21: return .badminton(BadmintonEngine(config: .bwf3x21, teams: teams))
        case .volleyballIndoor: return .volleyball(VolleyballEngine(config: .indoor, teams: teams))
        case .volleyballBeach: return .volleyball(VolleyballEngine(config: .beach, teams: teams))
        case .football5: return .football(FootballEngine(config: .san5, teams: teams))
        case .football7: return .football(FootballEngine(config: .san7, teams: teams))
        case .futsal: return .football(FootballEngine(config: .futsal, teams: teams))
        case .football11: return .football(FootballEngine(config: .san11, teams: teams))
        case .pool9Ball: return .billiards(BilliardsEngine(config: .nineBall, teams: teams))
        case .pool8Ball: return .billiards(BilliardsEngine(config: .eightBall, teams: teams))
        case .pool10Ball: return .billiards(BilliardsEngine(config: .tenBall, teams: teams))
        case .carom3Cushion: return .billiards(BilliardsEngine(config: .threeCushion, teams: teams))
        case .caromStraightRail: return .billiards(BilliardsEngine(config: .straightRail, teams: teams))
        }
    }
}

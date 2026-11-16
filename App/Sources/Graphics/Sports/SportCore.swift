//
//  ScoreboardCore.swift
//  DTD Studio – Scoreboard engine
//
//  Lõi chung cho mọi môn: Side, Pair, mô hình hiển thị (SportDisplay),
//  đồng hồ trận / đồng hồ cơ, sự kiện & giao thức SportEngine.
//  Toàn bộ engine là value type (struct) + Codable → undo/redo chỉ là lưu snapshot,
//  lưu/khôi phục khi app crash chỉ là encode JSON.
//

import Foundation

// MARK: - Side / Pair

enum Side: Int, Codable, CaseIterable, Hashable {
    case home = 0, away = 1
    var other: Side { self == .home ? .away : .home }
}

/// Cặp giá trị cho 2 bên (đội nhà / đội khách).
struct Pair<T: Codable & Equatable>: Codable, Equatable {
    var home: T
    var away: T

    init(_ home: T, _ away: T) {
        self.home = home
        self.away = away
    }

    init(repeating value: T) {
        self.init(value, value)
    }

    subscript(_ side: Side) -> T {
        get { side == .home ? home : away }
        set {
            if side == .home { home = newValue } else { away = newValue }
        }
    }
}

// MARK: - Language

enum ScoreLang: String, Codable, CaseIterable {
    case vi, en
    /// Chọn chuỗi theo ngôn ngữ.
    func t(_ vi: String, _ en: String) -> String { self == .vi ? vi : en }
}

// MARK: - Team

struct TeamInfo: Codable, Equatable {
    var name: String
    var shortName: String
    var colorHex: String

    init(name: String, shortName: String? = nil, colorHex: String) {
        self.name = name
        self.shortName = shortName ?? String(name.prefix(3)).uppercased()
        self.colorHex = colorHex
    }

    static let defaultHome = TeamInfo(name: "Đội A", shortName: "A", colorHex: "#E53935")
    static let defaultAway = TeamInfo(name: "Đội B", shortName: "B", colorHex: "#1E88E5")
    static let defaultPair = Pair(defaultHome, defaultAway)
}

// MARK: - Rally-game math (pickleball, cầu lông, bóng chuyền)

/// Điều kiện thắng 1 game/set: đạt `points`, cách biệt `winBy`, chạm `cap` thì thắng ngay.
struct GameTarget: Codable, Equatable {
    var points: Int
    var winBy: Int
    var cap: Int?

    init(points: Int, winBy: Int = 2, cap: Int? = nil) {
        self.points = points
        self.winBy = winBy
        self.cap = cap
    }

    func winner(_ p: Pair<Int>) -> Side? {
        for s in Side.allCases {
            let a = p[s], b = p[s.other]
            if let cap = cap, a >= cap, a > b { return s }
            if a >= points && a - b >= winBy { return s }
        }
        return nil
    }

    /// Nếu `scorer` ghi thêm 1 điểm thì có thắng game không? (dùng cho GAME/SET/MATCH POINT)
    func wouldWin(_ p: Pair<Int>, scorer: Side) -> Bool {
        var q = p
        q[scorer] += 1
        return winner(q) == scorer
    }
}

enum MatchMath {
    /// Đếm số game/set mỗi bên đã thắng từ danh sách tỉ số đã kết thúc.
    static func wins(_ completed: [Pair<Int>]) -> Pair<Int> {
        var w = Pair(0, 0)
        for g in completed {
            if g.home > g.away { w.home += 1 } else if g.away > g.home { w.away += 1 }
        }
        return w
    }
}

// MARK: - Clocks

/// Đồng hồ trận (đếm lên). Lưu mốc thời gian tuyệt đối nên chạy đúng cả khi app ở background
/// và khi undo/redo.
struct GameClock: Codable, Equatable {
    var accumulated: TimeInterval = 0
    var startedAt: Date? = nil

    init() {}

    var isRunning: Bool { startedAt != nil }

    func elapsed(at now: Date) -> TimeInterval {
        guard let s = startedAt else { return accumulated }
        return accumulated + max(0, now.timeIntervalSince(s))
    }

    mutating func start(at now: Date) {
        guard startedAt == nil else { return }
        startedAt = now
    }

    mutating func stop(at now: Date) {
        accumulated = elapsed(at: now)
        startedAt = nil
    }

    mutating func adjust(by seconds: TimeInterval, at now: Date) {
        let running = isRunning
        accumulated = max(0, elapsed(at: now) + seconds)
        startedAt = running ? now : nil
    }

    mutating func reset() {
        accumulated = 0
        startedAt = nil
    }
}

/// Đồng hồ cơ (shot clock) đếm ngược – bi-a.
struct ShotClock: Codable, Equatable {
    var limit: TimeInterval
    var remainingWhenStopped: TimeInterval
    var startedAt: Date? = nil

    init(limit: TimeInterval) {
        self.limit = limit
        self.remainingWhenStopped = limit
    }

    var isRunning: Bool { startedAt != nil }

    func remaining(at now: Date) -> TimeInterval {
        guard let s = startedAt else { return remainingWhenStopped }
        return max(0, remainingWhenStopped - now.timeIntervalSince(s))
    }

    mutating func start(at now: Date) {
        guard startedAt == nil else { return }
        startedAt = now
    }

    mutating func stop(at now: Date) {
        remainingWhenStopped = remaining(at: now)
        startedAt = nil
    }

    mutating func reset(running: Bool, at now: Date) {
        remainingWhenStopped = limit
        startedAt = running ? now : nil
    }

    mutating func add(_ seconds: TimeInterval, at now: Date) {
        let running = isRunning
        remainingWhenStopped = remaining(at: now) + seconds
        startedAt = running ? now : nil
    }
}

func formatClock(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    return String(format: "%02d:%02d", s / 60, s % 60)
}

// MARK: - Events (callout ngắn hiện trên scoreboard sau mỗi thao tác)

enum CardKind: String, Codable, Equatable {
    case yellow, red
}

enum ScoreEvent: Codable, Equatable {
    case none
    case sideOut                 // đổi giao bóng
    case secondServer            // pickleball đôi: chuyển người giao thứ 2
    case switchEnds              // đổi sân
    case interval                // nghỉ giữa game (cầu lông)
    case technicalTimeout        // tạm dừng kỹ thuật (bóng chuyền bãi biển)
    case timeout(Side)
    case gameWon(Side)
    case matchWon(Side)
    case draw
    case goal(Side)
    case card(Side, CardKind)
    case foulLimit(Side)         // đủ số lỗi tích lũy (futsal)
    case periodEnded
    case rackWon(Side)
    case finalInning             // carom: lượt cân bằng
}

// MARK: - Display model (renderer dùng chung cho mọi môn)

struct SportDisplay: Equatable {
    enum BadgeStyle: String, Equatable {
        case normal, warning, danger, yellowCard, redCard, highlight
    }

    struct Badge: Equatable, Hashable {
        var text: String
        var style: BadgeStyle
        init(_ text: String, _ style: BadgeStyle = .normal) {
            self.text = text
            self.style = style
        }
    }

    struct Row: Equatable {
        var side: Side
        var name: String
        var shortName: String
        var colorHex: String
        /// Cột phụ: tỉ số các set/game đã xong, hoặc chỉ số (lượt, HR, TB…), hoặc lượt đá luân lưu.
        var columns: [String]
        /// Ô số lớn: điểm hiện tại / bàn thắng / số rack.
        var main: String
        /// Chấm giao bóng / quyền phá / người đang đánh.
        var isServing: Bool
        var badges: [Badge]
        var isWinner: Bool
    }

    var sportTitle: String
    var columnHeaders: [String]
    var mainHeader: String
    var rows: [Row]
    /// "VÁN 2", "SET 5", "HIỆP 2", "RACK 7"…
    var period: String
    /// Bản ngắn cho ô giữa scoreboard: "VÁN 2", "SET 5", "HIỆP 2", "CHẠM 9"…
    var shortPeriod: String
    var clock: String?
    /// Dòng nổi bật: MATCH POINT, ĐỔI SÂN, VÀO!, HẾT GIỜ…
    var callout: String?
    /// Dòng phụ: score call "4-2-1", "Giao ô phải", "Series 5", cầu thủ ghi bàn…
    var detail: String?
    var isFinished: Bool
}

extension SportDisplay.Row {
    init(side: Side, team: TeamInfo, columns: [String], main: String,
         isServing: Bool, badges: [SportDisplay.Badge] = [], isWinner: Bool = false) {
        self.init(side: side, name: team.name, shortName: team.shortName, colorHex: team.colorHex,
                  columns: columns, main: main, isServing: isServing, badges: badges, isWinner: isWinner)
    }
}

// MARK: - Controls (nút điều khiển do engine tự sinh theo trạng thái)

enum SportControlRole: String {
    case primary, secondary, destructive
}

struct SportControl<A>: Identifiable {
    let id: String
    let title: String
    /// nil = nút chung (đồng hồ, hết hiệp…)
    let side: Side?
    let role: SportControlRole
    let enabled: Bool
    /// Nếu khác nil, UI hỏi thêm 1 chuỗi (tên cầu thủ) trước khi thực hiện.
    let inputPrompt: String?
    let make: (String?) -> A

    init(id: String, title: String, side: Side?, role: SportControlRole = .secondary,
                enabled: Bool = true, inputPrompt: String? = nil, make: @escaping (String?) -> A) {
        self.id = id
        self.title = title
        self.side = side
        self.role = role
        self.enabled = enabled
        self.inputPrompt = inputPrompt
        self.make = make
    }

    init(id: String, title: String, side: Side?, role: SportControlRole = .secondary,
                enabled: Bool = true, action: A) {
        self.init(id: id, title: title, side: side, role: role, enabled: enabled,
                  inputPrompt: nil, make: { _ in action })
    }
}

// MARK: - Engine protocol

protocol SportEngine: Codable, Equatable {
    associatedtype Action: Codable, Equatable

    var teams: Pair<TeamInfo> { get set }
    var isFinished: Bool { get }
    /// Có đồng hồ đang chạy cần cập nhật overlay liên tục không (để tiết kiệm pin khi không cần).
    var needsTicking: Bool { get }

    mutating func apply(_ action: Action, at now: Date)
    func display(lang: ScoreLang, at now: Date) -> SportDisplay
    func controls(lang: ScoreLang) -> [SportControl<Action>]
}

extension SportEngine {
    var needsTicking: Bool { false }
}

// MARK: - Shared callout helpers

enum Callouts {
    /// Văn bản callout cho sự kiện; `unit` là tên đơn vị ("VÁN"/"GAME", "SET"…).
    static func text(_ e: ScoreEvent, teams: Pair<TeamInfo>, lang: ScoreLang,
                     unitVI: String = "VÁN", unitEN: String = "GAME") -> String? {
        switch e {
        case .none: return nil
        case .sideOut: return lang.t("ĐỔI GIAO", "SIDE OUT")
        case .secondServer: return lang.t("NGƯỜI GIAO THỨ 2", "SECOND SERVER")
        case .switchEnds: return lang.t("ĐỔI SÂN", "CHANGE ENDS")
        case .interval: return lang.t("NGHỈ GIỮA \(unitVI)", "INTERVAL")
        case .technicalTimeout: return lang.t("TẠM DỪNG KỸ THUẬT", "TECHNICAL TIMEOUT")
        case .timeout(let s): return lang.t("HỘI Ý · \(teams[s].shortName)", "TIMEOUT · \(teams[s].shortName)")
        case .gameWon(let s): return lang.t("\(teams[s].name) THẮNG \(unitVI)", "\(unitEN) · \(teams[s].name)")
        case .matchWon(let s): return lang.t("\(teams[s].name) THẮNG CHUNG CUỘC", "\(teams[s].name) WINS")
        case .draw: return lang.t("HÒA", "DRAW")
        case .goal(let s): return lang.t("VÀO! · \(teams[s].shortName)", "GOAL! · \(teams[s].shortName)")
        case .card(let s, let k):
            return k == .red ? lang.t("THẺ ĐỎ · \(teams[s].shortName)", "RED CARD · \(teams[s].shortName)")
                             : lang.t("THẺ VÀNG · \(teams[s].shortName)", "YELLOW CARD · \(teams[s].shortName)")
        case .foulLimit(let s): return lang.t("\(teams[s].shortName) ĐỦ LỖI TÍCH LŨY", "\(teams[s].shortName) FOUL LIMIT")
        case .periodEnded: return lang.t("HẾT HIỆP", "END OF PERIOD")
        case .rackWon(let s): return lang.t("RACK · \(teams[s].shortName)", "RACK · \(teams[s].shortName)")
        case .finalInning: return lang.t("LƯỢT CÂN BẰNG", "EQUALIZING INNING")
        }
    }

    static func pressure(gamePoint side: Side?, isMatch: Bool, unitEN: String) -> String? {
        guard side != nil else { return nil }
        return isMatch ? "MATCH POINT" : "\(unitEN) POINT"
    }
}

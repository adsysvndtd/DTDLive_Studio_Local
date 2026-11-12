import Foundation
import ObjectiveC
import SwiftUI

/// In-app language switch (vi / en / follow iOS) that applies immediately, without relaunch.
/// Bundle.main is re-classed so every lookup — SwiftUI Text, NSLocalizedString, L() — reads the chosen .lproj.
enum AppLanguage {
    static let key = "dtd.language"
    private static var bundleKey: UInt8 = 0

    /// "system", "vi" or "en".
    static var current: String { UserDefaults.standard.string(forKey: key) ?? "system" }

    static var locale: Locale {
        current == "system" ? .autoupdatingCurrent : Locale(identifier: current)
    }

    static func apply(_ code: String) {
        UserDefaults.standard.set(code, forKey: key)
        if code == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([code], forKey: "AppleLanguages") }   // also used by system UI on next launch
        object_setClass(Bundle.main, LanguageBundle.self)
        let override = code == "system" ? nil
            : Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
        objc_setAssociatedObject(Bundle.main, &bundleKey, override, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    fileprivate static var overrideBundle: Bundle? {
        objc_getAssociatedObject(Bundle.main, &bundleKey) as? Bundle
    }
}

private final class LanguageBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let b = AppLanguage.overrideBundle { return b.localizedString(forKey: key, value: value, table: tableName) }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

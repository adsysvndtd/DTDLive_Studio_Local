import SwiftUI

@main
struct DTDStudioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(AppLanguage.key) private var language = "system"
    /// Owned here (not in StudioView) so a language switch rebuilds the UI without restarting cameras/outputs.
    @StateObject private var engine = StudioEngine()

    init() {
        // Keep the screen on while producing.
        UIApplication.shared.isIdleTimerDisabled = true
        AppLanguage.apply(AppLanguage.current)
    }

    var body: some Scene {
        WindowGroup {
            StudioView(engine: engine)
                .persistentSystemOverlays(.hidden)
                .environment(\.locale, AppLanguage.locale)
                .id(language)          // rebuild the UI so every string re-reads the chosen language
        }
    }
}

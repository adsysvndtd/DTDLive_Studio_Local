import SwiftUI

@main
struct DTDStudioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(AppLanguage.key) private var language = "system"
    /// Owned here (not in StudioView) so a language switch rebuilds the UI without restarting cameras/outputs.
    @StateObject private var engine = StudioEngine()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The screen is kept on while streaming / recording (or always, if set) — see StudioEngine.updateIdleTimer.
        AppLanguage.apply(AppLanguage.current)
    }

    var body: some Scene {
        WindowGroup {
            StudioView(engine: engine)
                .persistentSystemOverlays(.hidden)
                .environment(\.locale, AppLanguage.locale)
                .id(language)          // rebuild the UI so every string re-reads the chosen language
                // start the App Store transaction listener at launch (renewals, purchases from other devices)
                .task { _ = StudioPlan.shared; engine.watchScreens() }
        }
        // "PGM output" window: on an iPad using the HDMI / USB‑C screen as an extended Stage Manager display
        // (no external scene for apps), the operator moves this window there and makes it full screen.
        WindowGroup(id: "pgm-output") {
            ExternalProgramView(engine: engine)
                .persistentSystemOverlays(.hidden)
                .environment(\.locale, AppLanguage.locale)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: engine.appDidEnterBackground()
            case .active: engine.appDidBecomeActive()
            default: break
            }
        }
    }
}

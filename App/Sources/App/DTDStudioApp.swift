import SwiftUI

@main
struct DTDStudioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Keep the screen on while producing.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            StudioView()
                .persistentSystemOverlays(.hidden)
        }
    }
}

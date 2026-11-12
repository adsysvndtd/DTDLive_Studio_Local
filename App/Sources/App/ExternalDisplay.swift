import SwiftUI
import UIKit

/// Program (or multiview) full-screen on an HDMI adapter or AirPlay screen mirroring target.
/// Uses the non-interactive external display scene role, so the iPad keeps its own UI.
final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene, let engine = StudioEngine.shared else { return }
        let w = UIWindow(windowScene: ws)
        w.rootViewController = UIHostingController(rootView: ExternalProgramView(engine: engine))
        w.isHidden = false
        window = w
        Task { @MainActor in engine.externalDisplayConnected = true }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        Task { @MainActor in StudioEngine.shared?.externalDisplayConnected = false }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Landscape only on iPhone and iPad, whatever the Info.plist says (the switcher layout has no portrait form).
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscape
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if session.role == .windowExternalDisplayNonInteractive {
            let c = UISceneConfiguration(name: "External", sessionRole: session.role)
            c.delegateClass = ExternalDisplaySceneDelegate.self
            return c
        }
        // Main scene: a fresh configuration WITHOUT delegateClass. SwiftUI installs its own scene
        // delegate and forwards to `delegateClass` when one is set; returning `session.configuration`
        // (whose delegateClass is SwiftUI's own AppSceneDelegate) made it forward to itself forever
        // → infinite recursion in scene(_:willConnectTo:) and a frozen app at launch.
        return UISceneConfiguration(name: nil, sessionRole: session.role)
    }
}

struct ExternalProgramView: View {
    @ObservedObject var engine: StudioEngine
    var body: some View {
        ZStack {
            Color.black
            switch engine.externalMode {
            case .program:
                MonitorView(store: engine.switcher.programMonitor, maxFPS: 60)
                    .aspectRatio(CGFloat(engine.format.width) / CGFloat(engine.format.height), contentMode: .fit)
                    .overlay { if engine.externalSafeGuides { SafeGuides() } }
            case .multiview:
                MultiviewGrid(engine: engine)
            }
        }
        .ignoresSafeArea()
    }
}

/// 2x2 / 3x3 multiview with PGM/PVW tally borders (external monitor or iPhone).
struct MultiviewGrid: View {
    @ObservedObject var engine: StudioEngine
    var body: some View {
        let cols = engine.sources.count <= 4 ? 2 : 3
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                MonitorView(store: engine.switcher.previewMonitor).border(.green, width: 3)
                MonitorView(store: engine.switcher.programMonitor).border(.red, width: 3)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: cols), spacing: 2) {
                ForEach(Array(engine.sources.enumerated()), id: \.element.id) { i, s in
                    MonitorView(store: s.frames, maxFPS: 15)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .border(engine.programID == s.id ? .red : engine.previewID == s.id ? .green : .gray,
                                width: engine.programID == s.id || engine.previewID == s.id ? 3 : 1)
                        .overlay(alignment: .bottomLeading) { Text("\(i + 1) \(s.name)").font(.caption).padding(3).background(.black.opacity(0.6)) }
                }
            }
        }
    }
}

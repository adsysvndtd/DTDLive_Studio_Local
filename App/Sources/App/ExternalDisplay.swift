import SwiftUI
import UIKit

/// Program (or multiview) full-screen on an HDMI adapter or AirPlay screen mirroring target.
/// Uses the non-interactive external display scene role, so the iPad keeps its own UI.
@objc(ExternalDisplaySceneDelegate)   // plain class name, referenced from Info.plist (UISceneConfigurations)
final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.backgroundColor = .black
        w.rootViewController = UIViewController()
        w.rootViewController?.view.backgroundColor = .black
        w.isHidden = false
        window = w
        attach(ws, attempt: 0)
    }

    /// The HDMI screen can connect before the engine exists (cable in at launch): wait for it.
    private func attach(_ ws: UIWindowScene, attempt: Int) {
        guard let engine = StudioEngine.shared else {
            if attempt < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.attach(ws, attempt: attempt + 1) } }
            return
        }
        window?.rootViewController = UIHostingController(rootView: ExternalProgramView(engine: engine))
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

/// Multiview: PVW | PGM on top, then a fixed number of input tiles (4, 8, 10 or 16 — empty slots stay
/// black), every picture at the program aspect, the whole wall sized to fit the screen (no scrolling).
/// Tap a tile = preview, double-tap = take (in the app; the external monitor is display only).
struct MultiviewGrid: View {
    @ObservedObject var engine: StudioEngine
    var interactive = false

    private var aspect: CGFloat { CGFloat(engine.format.width) / CGFloat(max(engine.format.height, 1)) }

    var body: some View {
        let layout = engine.multiviewLayout
        let slots = layout.slots, cols = layout.columns, rows = (slots + cols - 1) / cols
        GeometryReader { g in
            // width units: top row = 2 tiles of W/2, bottom = rows of W/cols; height = W/2/a + rows·W/cols/a
            let gap: CGFloat = 2
            let a = aspect
            let wFit = g.size.width
            let hFor = { (w: CGFloat) in w / 2 / a + CGFloat(rows) * (w / CGFloat(cols)) / a + gap * CGFloat(rows) }
            let W = min(wFit, wFit * g.size.height / max(hFor(wFit), 1))
            let big = (W - gap) / 2, small = (W - gap * CGFloat(cols - 1)) / CGFloat(cols)
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    tile(store: engine.switcher.previewMonitor, label: "PVW", border: DS.pvw, width: big, fps: 30)
                    tile(store: engine.switcher.programMonitor, label: "PGM", border: DS.pgm, width: big, fps: 30)
                }
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<cols, id: \.self) { c in
                            let i = r * cols + c
                            if i < slots { inputTile(i, width: small) }
                        }
                    }
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .background(Color.black)
    }

    private func tile(store: FrameStore, label: String, border: Color, width: CGFloat, fps: Int) -> some View {
        MonitorView(store: store, maxFPS: fps)
            .frame(width: width, height: width / aspect)
            .overlay { Rectangle().stroke(border, lineWidth: 3) }
            .overlay(alignment: .bottomLeading) { tag(label, color: border) }
    }

    @ViewBuilder private func inputTile(_ i: Int, width: CGFloat) -> some View {
        let h = width / aspect
        if i < engine.sources.count {
            let s = engine.sources[i]
            let onPGM = engine.programID == s.id, onPVW = engine.previewID == s.id
            MonitorView(store: s.frames, maxFPS: 12)
                .frame(width: width, height: h)
                .overlay { Rectangle().stroke(onPGM ? DS.pgm : onPVW ? DS.pvw : Color.white.opacity(0.25), lineWidth: onPGM || onPVW ? 3 : 1) }
                .overlay(alignment: .bottomLeading) { tag("\(i + 1)  \(s.name)", color: onPGM ? DS.pgm : onPVW ? DS.pvw : .black.opacity(0.6)) }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if interactive { engine.take(s.id) } }
                .onTapGesture { if interactive { engine.select(s.id) } }
        } else {
            Color(white: 0.06)
                .frame(width: width, height: h)
                .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
                .overlay(alignment: .bottomLeading) { tag("\(i + 1)", color: .black.opacity(0.6)) }
        }
    }

    private func tag(_ t: String, color: Color) -> some View {
        Text(verbatim: t).font(.system(size: 11, weight: .bold)).lineLimit(1)
            .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2)
            .background(color, in: Rectangle()).padding(3)
    }
}

/// Full-screen multiview inside the app.
struct MultiviewScreen: View {
    @ObservedObject var engine: StudioEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MultiviewGrid(engine: engine, interactive: true).ignoresSafeArea()
            HStack(spacing: 8) {
                Picker("Ô đầu vào", selection: $engine.multiviewLayout) {
                    ForEach(StudioEngine.MultiviewLayout.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 260)
                Button("Cut") { engine.cut() }.buttonStyle(.borderedProminent).tint(DS.pgm)
                Button("Auto") { engine.autoTransition() }.buttonStyle(.bordered)
                Button { dismiss() } label: { Image(systemName: "xmark").font(.headline) }.buttonStyle(.bordered)
            }
            .padding(8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10)).padding(10)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }
}

import SwiftUI

/// Drag PiP and logo directly on the PGM monitor (snaps to edges, thirds and the 5% safe margin).
struct ArrangeOverlay: View {
    @ObservedObject var engine: StudioEngine

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.15)
                if let pip = engine.pip, pip.visible {
                    box(pip.rect, in: g.size, color: DS.accent2, label: "PiP", resizable: true) { engine.setOverlayRect(pip: true, $0) }
                }
                if let logo = engine.logo, logo.visible {
                    box(logo.rect, in: g.size, color: DS.accent, label: "Logo", resizable: true) { engine.setOverlayRect(pip: false, $0) }
                }
                Text("Kéo để di chuyển · kéo góc để đổi cỡ").font(.caption2.weight(.semibold))
                    .padding(5).background(.black.opacity(0.6), in: Capsule()).padding(6)
            }
        }
    }

    private func box(_ r: CGRect, in size: CGSize, color: Color, label: String, resizable: Bool,
                     update: @escaping (CGRect) -> Void) -> some View {
        let frame = CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
        return ZStack(alignment: .bottomTrailing) {
            Rectangle().strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .background(color.opacity(0.12))
                .overlay(alignment: .topLeading) {
                    Text(label).font(.caption2.weight(.heavy)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(color, in: Rectangle()).foregroundStyle(.black).padding(3)
                }
                .gesture(DragGesture().onChanged { v in
                    var n = r
                    n.origin.x = min(max(0, r.minX + v.translation.width / size.width), 1 - r.width)
                    n.origin.y = min(max(0, r.minY + v.translation.height / size.height), 1 - r.height)
                    update(n)
                })
            if resizable {
                Circle().fill(color).frame(width: 18, height: 18).offset(x: 9, y: 9)
                    .gesture(DragGesture().onChanged { v in
                        let aspect = r.height / max(r.width, 0.001)
                        var w = max(0.06, min(1 - r.minX, r.width + v.translation.width / size.width))
                        var h = w * aspect
                        if r.minY + h > 1 { h = 1 - r.minY; w = h / aspect }
                        update(CGRect(x: r.minX, y: r.minY, width: w, height: h))
                    })
            }
        }
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
    }
}

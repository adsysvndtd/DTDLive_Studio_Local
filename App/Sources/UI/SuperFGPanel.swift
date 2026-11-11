import SwiftUI

/// SuperFG templates: pick a design, edit its two lines and accent colour; changes go live while it is on.
struct SuperFGPanel: View {
    @ObservedObject var engine: StudioEngine
    var compact = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: compact ? 120 : 190, maximum: compact ? 180 : 280), spacing: compact ? 6 : 10)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle("SuperFG trên Program", isOn: $engine.foregroundOn).disabled(engine.foreground == nil).fixedSize()
                Spacer()
                if engine.foreground != nil {
                    Button("Bỏ SuperFG") { engine.clearForeground() }
                        .buttonStyle(.bordered).font(.caption)
                }
            }
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    field("Dòng 1", text: Binding(get: { engine.superFG.line1 }, set: { engine.superFG.line1 = $0 }))
                    ColorPicker("Màu", selection: Binding(get: { Color(UIColor(hex: engine.superFG.accentHex)) },
                                                          set: { engine.superFG.accentHex = UIColor($0).hexString }),
                                supportsOpacity: false)
                        .font(.caption).foregroundStyle(DS.text2).fixedSize()
                }
                field("Dòng 2", text: Binding(get: { engine.superFG.line2 }, set: { engine.superFG.line2 = $0 }))
            }
            LazyVGrid(columns: columns, spacing: compact ? 6 : 10) {
                ForEach(SuperFGTemplate.all) { t in
                    let active = engine.superFGActiveTemplate == t.id && engine.foregroundOn
                    Button { engine.applySuperFG(t.id) } label: {
                        VStack(spacing: 0) {
                            ZStack {
                                LinearGradient(colors: [Color(white: 0.30), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                                Image(uiImage: SuperFGThumbs.image(t, engine.superFG)).resizable().scaledToFit()
                            }
                            .aspectRatio(16 / 9, contentMode: .fit)
                            Text(t.name).font(.caption.weight(.semibold)).lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 24).background(DS.surface)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? DS.pgm : DS.stroke, lineWidth: active ? 3 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Chạm một mẫu để đưa lên Program; sửa chữ, màu sẽ cập nhật ngay. Phím SUPER FG ở cột phải để bật/tắt.")
                .font(.caption2).foregroundStyle(DS.text3)
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 8).frame(height: 34)
            .background(DS.surface2, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Small template previews, cached per (template, text, colour) so mixer meters re-rendering the view cost nothing.
enum SuperFGThumbs {
    private static let cache = NSCache<NSString, UIImage>()
    static func image(_ t: SuperFGTemplate, _ c: SuperFGConfig) -> UIImage {
        let key = "\(t.id)|\(c.line1)|\(c.line2)|\(c.accentHex)" as NSString
        if let i = cache.object(forKey: key) { return i }
        let i = t.render(c, size: CGSize(width: 480, height: 270))
        cache.setObject(i, forKey: key)
        return i
    }
}

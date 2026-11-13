import SwiftUI

/// SuperFG cards: pick a card (arms it), edit its text and colour; SuperFG On plays it with its own transition.
struct SuperFGPanel: View {
    @ObservedObject var engine: StudioEngine
    var compact = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: compact ? 120 : 190, maximum: compact ? 180 : 280), spacing: compact ? 6 : 10)]
    }
    private var selected: SuperFGTemplate? { SuperFGTemplate.all.first { $0.id == engine.superFG.templateID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label(!engine.superFGArmed ? "Chưa nạp SuperFG" : (engine.foregroundOn ? "SuperFG đang trên PGM" : "Đã nạp — bấm SuperFG On ở cột phải"),
                      systemImage: "square.3.layers.3d").font(DS.fBody).foregroundStyle(engine.foregroundOn ? DS.pgm : DS.text2)
                Spacer()
                if engine.superFGArmed {
                    Button("Bỏ SuperFG") { engine.clearForeground() }
                        .buttonStyle(.bordered).font(DS.fBody)
                }
            }
            if let t = selected, engine.superFGActiveTemplate == t.id {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        field("Dòng 1", text: line(t, 0))
                        field("Dòng 2 (để trống = 1 dòng)", text: line(t, 1))
                        ColorPicker("", selection: Binding(get: { Color(engine.superFG.accent(t)) },
                                                           set: { engine.superFG.accents[t.id] = UIColor($0).hexString }),
                                    supportsOpacity: false).labelsHidden()
                        Button {
                            engine.superFG.texts[t.id] = nil; engine.superFG.accents[t.id] = nil
                        } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.bordered).font(DS.fBody)
                    }
                    HStack(spacing: 10) {
                        Picker("", selection: $engine.superFG.playOnce) {
                            Text("Chạy một lần").tag(true)
                            Text("Giữ đến khi tắt").tag(false)
                        }
                        .pickerStyle(.segmented).frame(maxWidth: 260)
                        if engine.superFG.playOnce {
                            Stepper(value: $engine.superFG.hold, in: 1...15, step: 0.5) {
                                Text(LF("Giữ %@ giây", String(format: "%.1f", engine.superFG.hold))).font(DS.fBody).foregroundStyle(DS.text2)
                            }
                            .fixedSize()
                        }
                        Spacer(minLength: 0)
                    }
                    Toggle(isOn: $engine.superFG.takeOnCover) {
                        Text("Dùng làm chuyển cảnh: cắt PVW lên PGM khi thẻ phủ kín").font(DS.fBody).foregroundStyle(DS.text2)
                    }
                }
            }
            LazyVGrid(columns: columns, spacing: compact ? 6 : 10) {
                ForEach(SuperFGTemplate.all) { t in
                    let active = engine.superFGActiveTemplate == t.id
                    Button { engine.applySuperFG(t.id) } label: {
                        VStack(spacing: 0) {
                            Image(uiImage: SuperFGThumbs.image(t, engine.superFG)).resizable().scaledToFit()
                                .aspectRatio(16 / 9, contentMode: .fit)
                            HStack(spacing: 4) {
                                Text(t.name).font(DS.fBodyBold).lineLimit(1)
                                Image(systemName: Self.icon(t.motion)).font(.system(size: 10)).foregroundStyle(DS.text3)
                            }
                            .frame(maxWidth: .infinity, minHeight: 24).background(DS.surface)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: DS.radius))
                        .overlay(RoundedRectangle(cornerRadius: DS.radius)
                            .stroke(active ? (engine.foregroundOn ? DS.pgm : DS.pvw) : DS.stroke, lineWidth: active ? 3 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Chạm một thẻ để nạp; SuperFG On chạy hiệu ứng vào của thẻ, rồi tự ra (hoặc giữ đến khi tắt). Biểu tượng nhỏ cho biết kiểu chuyển cảnh.")
                .font(.caption2).foregroundStyle(DS.text3)
        }
    }

    static func icon(_ m: SuperFGMotion) -> String {
        switch m {
        case .wipe: return "line.diagonal"
        case .slide: return "arrow.right"
        case .zoom: return "arrow.up.left.and.arrow.down.right"
        case .split: return "arrow.up.and.down"
        case .rise: return "arrow.up"
        }
    }

    private func line(_ t: SuperFGTemplate, _ i: Int) -> Binding<String> {
        Binding(get: { let l = engine.superFG.lines(t); return i < l.count ? l[i] : "" },
                set: { v in
                    var l = engine.superFG.lines(t)
                    while l.count <= i { l.append("") }
                    l[i] = v
                    engine.superFG.texts[t.id] = l
                })
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 8).frame(height: 34)
            .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
    }
}

/// Small template previews, cached per (template, text, colour) so mixer meters re-rendering the view cost nothing.
enum SuperFGThumbs {
    private static let cache = NSCache<NSString, UIImage>()
    static func image(_ t: SuperFGTemplate, _ c: SuperFGConfig) -> UIImage {
        let key = "\(t.id)|\(c.lines(t).joined(separator: "¦"))|\(c.accentHex(t))" as NSString
        if let i = cache.object(forKey: key) { return i }
        let i = t.render(c, size: CGSize(width: 480, height: 270))
        cache.setObject(i, forKey: key)
        return i
    }
}

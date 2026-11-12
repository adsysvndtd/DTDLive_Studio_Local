import SwiftUI

/// Design tokens + small reusable controls so every screen looks consistent.
enum DS {
    static let bg = Color(red: 0.055, green: 0.06, blue: 0.075)
    static let surface = Color(red: 0.10, green: 0.105, blue: 0.125)
    static let surface2 = Color(red: 0.145, green: 0.15, blue: 0.175)
    static let stroke = Color.white.opacity(0.08)
    static let text2 = Color.white.opacity(0.62)
    static let text3 = Color.white.opacity(0.38)
    static let pgm = Color(red: 0.93, green: 0.17, blue: 0.17)
    static let pvw = Color(red: 0.16, green: 0.78, blue: 0.38)
    static let accent = Color(red: 0.98, green: 0.45, blue: 0.13)   // logo orange
    static let accent2 = Color(red: 0.10, green: 0.80, blue: 0.86)  // logo cyan
    static let radius: CGFloat = 0
    static let gap: CGFloat = 10
}

/// Rounded, titled card used for every inspector section.
struct SectionCard<Content: View>: View {
    let title: String
    var systemImage: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String, systemImage: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.systemImage = systemImage; self.trailing = trailing; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(DS.accent) }
                Text(LocalizedStringKey(title)).textCase(.uppercase).font(.caption.weight(.bold)).foregroundStyle(DS.text2).tracking(0.6)
                Spacer()
                trailing
            }
            content
        }
        .padding(12)
        .background(DS.surface, in: Rectangle())
        .overlay(Rectangle().stroke(DS.stroke))
    }
}

/// Slider with a visible label and value, never an unlabeled bar.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(DS.text2)
                Spacer()
                Text(format(value)).font(.caption.monospacedDigit()).foregroundStyle(DS.text3)
            }
            Slider(value: $value, in: range).tint(DS.accent)
        }
    }
}

/// Text field with a small caption above it.
struct CaptionField: View {
    let title: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(title)).font(.caption2).foregroundStyle(DS.text3)
            TextField(title, text: $text)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(DS.surface2, in: Rectangle())
        }
    }
}

/// Status pill (LIVE, REC, bitrate…).
struct Pill: View {
    let text: String
    var color: Color = DS.surface2
    var dot: Color?
    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(text).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(color, in: Rectangle())
    }
}

/// Square-ish toolbar button with icon over a short label.
struct ToolButton: View {
    let title: String
    let systemImage: String
    var active = false
    var tint: Color = .white
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
                Text(LocalizedStringKey(title)).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: 58, height: 40)
            .foregroundStyle(active ? .black : tint)
            .background(active ? DS.accent : DS.surface2, in: Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Big hardware-style switcher key.
struct KeyButton: View {
    let title: String
    var color: Color = DS.surface2
    var textColor: Color = .white
    var width: CGFloat = 72
    var height: CGFloat = 56
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(title)).font(.system(size: 15, weight: .heavy))
                .frame(width: width, height: height)
                .foregroundStyle(textColor)
                .background(color, in: Rectangle())
                .overlay(Rectangle().stroke(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI

/// Video bitrate editor: exact value (typed), ±0.5 Mbps stepper, slider 1–40 Mbps and quick presets.
/// Default is 6 Mbps; every change applies live to the encoder.
struct BitrateControl: View {
    @Binding var bitrate: Int
    @State private var text = ""
    @FocusState private var typing: Bool
    private static let presets: [Double] = [3, 4.5, 6, 8, 10, 12, 15, 20]
    private static let range = 1_000_000...40_000_000

    private var mbps: Double { Double(bitrate) / 1e6 }
    private func set(_ m: Double) {
        let v = Int((m * 2).rounded() / 2 * 1e6)               // 0.5 Mbps grid
        bitrate = min(Self.range.upperBound, max(Self.range.lowerBound, v))
        text = String(format: "%.1f", Double(bitrate) / 1e6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bitrate video")
                Spacer()
                TextField("6.0", text: $text)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .focused($typing).frame(width: 64)
                    .onSubmit { commit() }
                    .onChange(of: typing) { _, f in if !f { commit() } }
                Text("Mbps").foregroundStyle(.secondary)
                Stepper("", onIncrement: { set(mbps + 0.5) }, onDecrement: { set(mbps - 0.5) }).labelsHidden()
            }
            Slider(value: Binding(get: { mbps }, set: { set($0) }), in: 1...40, step: 0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.presets, id: \.self) { p in
                        let on = abs(mbps - p) < 0.01
                        Button { set(p) } label: {
                            Text(p == 6 ? String(format: L("%@ (mặc định)"), "6") : (p.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(p))" : String(format: "%.1f", p)))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .foregroundStyle(on ? Color.black : .primary)
                                .background(on ? DS.accent : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: DS.radius))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onAppear { text = String(format: "%.1f", mbps) }
        .onChange(of: bitrate) { _, _ in if !typing { text = String(format: "%.1f", mbps) } }
    }

    private func commit() {
        if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { set(v) } else { text = String(format: "%.1f", mbps) }
    }
}

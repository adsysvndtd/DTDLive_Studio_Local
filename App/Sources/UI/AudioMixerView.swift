import SwiftUI

/// Console-style mixer: one vertical strip per channel (fader with dB scale, level meter,
/// mute / long-press solo, AFV), plus the Program master.
struct AudioMixerView: View {
    @ObservedObject var engine: StudioEngine
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                let afvAll = !sourceChannels.isEmpty && sourceChannels.allSatisfy(\.followVideo)
                chip(afvAll ? "AFV: BẬT" : "AFV: TẮT", on: afvAll, color: DS.accent2) { engine.setAFVAll(!afvAll) }
                Text("Âm thanh theo hình: kênh của nguồn đang lên PGM được mở, các kênh khác tắt").font(.caption2).foregroundStyle(DS.text3)
                    .lineLimit(2)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("Trễ Mic/Line \(Int(engine.micDelayMs)) ms").font(.caption2).foregroundStyle(DS.text2)
                    Slider(value: Binding(get: { engine.micDelayMs }, set: { engine.micDelayMs = $0 }), in: 0...500, step: 10)
                        .frame(width: compact ? 120 : 200).tint(DS.accent)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: compact ? 6 : 10) {
                    ForEach(engine.audioChannels) { c in
                        ChannelStrip(name: c.name, gain: Double(c.gain), level: c.level, muted: c.muted, solo: c.solo,
                                     afv: c.followVideo, compact: compact,
                                     onGain: { var n = c; n.gain = Float($0); engine.updateAudioChannel(n) },
                                     onMute: { var n = c; n.muted.toggle(); engine.updateAudioChannel(n) },
                                     onSolo: { var n = c; n.solo.toggle(); engine.updateAudioChannel(n) },
                                     onAFV: { var n = c; n.followVideo.toggle(); engine.updateAudioChannel(n) })
                    }
                    Divider().frame(height: compact ? 180 : 260).overlay(DS.stroke)
                    ChannelStrip(name: "PGM", gain: Double(engine.masterGain), level: engine.audioLevel, muted: false, solo: false,
                                 afv: false, compact: compact, isMaster: true,
                                 onGain: { engine.masterGain = Float($0) }, onMute: {}, onSolo: {}, onAFV: {})
                }
                .padding(.vertical, 4)
            }
            Text("Chạm nút tên kênh để tắt/mở tiếng · giữ để SOLO").font(.caption2).foregroundStyle(DS.text3)
        }
    }

    private var sourceChannels: [AudioChannelState] {
        engine.audioChannels.filter { $0.id != AudioCapture.micID && $0.id != AudioCapture.musicID }
    }

    private func chip(_ t: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.caption.weight(.heavy)).padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(on ? .black : .white).background(on ? color : DS.surface2, in: Capsule())
        }.buttonStyle(.plain)
    }
}

struct ChannelStrip: View {
    let name: String
    let gain: Double        // linear 0...2  (0 dB = 1)
    let level: Float        // dBFS
    let muted: Bool
    let solo: Bool
    let afv: Bool
    var compact = false
    var isMaster = false
    let onGain: (Double) -> Void
    let onMute: () -> Void
    let onSolo: () -> Void
    let onAFV: () -> Void

    private var height: CGFloat { compact ? 150 : 220 }
    private let marks: [Double] = [6, 3, 0, -6, -12, -24, -48]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                if !isMaster {
                    Button(action: onAFV) {
                        Text("AFV").font(.system(size: 9, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 2)
                            .foregroundStyle(afv ? .black : DS.text3).background(afv ? DS.accent2 : DS.surface2, in: Capsule())
                    }.buttonStyle(.plain)
                }
                Text(String(format: "%+.0f", gainDB)).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(DS.text2)
            }
            HStack(alignment: .top, spacing: 4) {
                scale
                fader
                meter
            }
            .frame(height: height)
            Button(action: onMute) {
                HStack(spacing: 3) {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 10))
                    Text(name).font(.system(size: 11, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(width: compact ? 66 : 84, height: 30)
                .foregroundStyle(muted ? DS.text2 : (solo ? .black : .white))
                .background(solo ? Color.yellow : (muted ? DS.surface2 : (isMaster ? DS.pgm.opacity(0.6) : DS.surface2.opacity(0.6))),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(muted ? DS.pgm.opacity(0.6) : DS.stroke))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in if !isMaster { onSolo() } })
        }
        .padding(6)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var gainDB: Double { 20 * log10(max(gain, 0.0001)) }

    /// dB → 0...1 position (−60 dB bottom, +6 dB top, roughly linear in dB).
    private func pos(_ db: Double) -> CGFloat { CGFloat((max(-60, min(6, db)) + 60) / 66) }

    private var scale: some View {
        GeometryReader { g in
            ForEach(marks, id: \.self) { m in
                Text(m > 0 ? "+\(Int(m))" : "\(Int(m))").font(.system(size: 8, design: .monospaced)).foregroundStyle(DS.text3)
                    .position(x: 10, y: g.size.height * (1 - pos(m)))
            }
        }
        .frame(width: 20)
    }

    private var fader: some View {
        GeometryReader { g in
            let h = g.size.height
            ZStack(alignment: .top) {
                Capsule().fill(Color.black).frame(width: 4)
                RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.55)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 26, height: 14)
                    .overlay(Rectangle().fill(Color.black.opacity(0.6)).frame(height: 1.5))
                    .offset(y: (1 - pos(gainDB)) * (h - 14))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let p = 1 - max(0, min(1, v.location.y / h))
                let db = Double(p) * 66 - 60
                onGain(db <= -59 ? 0 : pow(10, db / 20))
            })
            .onTapGesture(count: 2) { onGain(1) } // double tap = 0 dB
        }
        .frame(width: 30)
    }

    private var meter: some View {
        GeometryReader { g in
            let p = pos(Double(level))
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black)
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(stops: [.init(color: .green, location: 0), .init(color: .green, location: 0.7),
                                                 .init(color: .yellow, location: 0.85), .init(color: .red, location: 1)],
                                         startPoint: .bottom, endPoint: .top))
                    .mask(alignment: .bottom) { Rectangle().frame(height: g.size.height * p) }
            }
        }
        .frame(width: 8)
    }
}

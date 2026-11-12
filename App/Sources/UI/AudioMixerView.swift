import SwiftUI

/// Console-style mixer: header keys AFV1 / AFV2 / Gain, one strip per channel (fader scale, fader,
/// meter with its own dB scale, ▲▼ gain nudge, mute / long-press solo) and the PGM master.
/// Gain mode swaps the fader for the channel's input trim (−12…+24 dB).
struct AudioMixerView: View {
    @ObservedObject var engine: StudioEngine
    @ObservedObject var library: MediaLibrary
    var compact = false
    @State private var gainMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: compact ? 4 : 8) {
                    ForEach(engine.audioChannels) { c in
                        ChannelStrip(name: c.name,
                                     db: gainMode ? Double(c.trim) : dB(c.gain),
                                     gainMode: gainMode,
                                     level: c.level, muted: c.muted, solo: c.solo, afv: c.followVideo, compact: compact,
                                     delayMs: c.id == AudioCapture.micID ? engine.micDelayMs : nil,
                                     onDB: { v in
                                         var n = c
                                         if gainMode { n.trim = Float(v) } else { n.gain = v <= -59 ? 0 : Float(pow(10, v / 20)) }
                                         engine.updateAudioChannel(n)
                                     },
                                     onNudge: { d in gainMode ? engine.nudgeTrim(c.id, dB: Float(d)) : engine.nudgeGain(c.id, dB: Float(d)) },
                                     onMute: { var n = c; n.muted.toggle(); engine.updateAudioChannel(n) },
                                     onSolo: { var n = c; n.solo.toggle(); engine.updateAudioChannel(n) },
                                     onAFV: { var n = c; n.followVideo.toggle(); engine.updateAudioChannel(n) },
                                     onDelay: { engine.micDelayMs = min(500, max(0, engine.micDelayMs + $0)) })
                    }
                    ChannelStrip(name: "PGM", db: dB(engine.masterGain), gainMode: false, level: engine.audioLevel,
                                 muted: false, solo: false, afv: false, compact: compact, isMaster: true,
                                 onDB: { v in engine.masterGain = v <= -59 ? 0 : Float(pow(10, v / 20)) },
                                 onNudge: { engine.masterNudge(Float($0)) },
                                 onMute: {}, onSolo: {}, onAFV: {}, onDelay: { _ in })
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func dB(_ g: Float) -> Double { 20 * log10(max(Double(g), 0.0001)) }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                modeKey("AFV1", on: engine.afvMode == .afv1) { engine.setAFVMode(engine.afvMode == .afv1 ? nil : .afv1) }
                modeKey("AFV2", on: engine.afvMode == .afv2) { engine.setAFVMode(engine.afvMode == .afv2 ? nil : .afv2) }
                modeKey("Gain", on: gainMode) { gainMode.toggle() }
            }
            .padding(3)
            .background(DS.surface2, in: Rectangle())
            Spacer()
            // first four sound effects as quick pads
            HStack(spacing: 4) {
                ForEach(library.list(.sound).prefix(4), id: \.self) { url in
                    Button { engine.playEffect(url) } label: {
                        Image(systemName: "waveform").font(.system(size: 14, weight: .semibold))
                            .frame(width: compact ? 34 : 42, height: compact ? 28 : 32)
                            .background(DS.surface2, in: Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(url.deletingPathExtension().lastPathComponent)
                }
            }
            .foregroundStyle(DS.text2)
        }
    }

    private func modeKey(_ t: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: compact ? 12 : 14, weight: .bold))
                .padding(.horizontal, compact ? 10 : 14).frame(height: compact ? 28 : 32)
                .foregroundStyle(on ? .black : .white)
                .background(on ? Color.white : Color.clear, in: Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ChannelStrip: View {
    let name: String
    let db: Double            // fader position in dB (or trim in Gain mode)
    let gainMode: Bool
    let level: Float          // dBFS
    let muted: Bool
    let solo: Bool
    let afv: Bool
    var compact = false
    var isMaster = false
    var delayMs: Double? = nil
    let onDB: (Double) -> Void
    let onNudge: (Double) -> Void
    let onMute: () -> Void
    let onSolo: () -> Void
    let onAFV: () -> Void
    let onDelay: (Double) -> Void

    private var height: CGFloat { compact ? 130 : 230 }
    private var faderMarks: [Double] { gainMode ? [24, 12, 6, 0, -6, -12] : [6, 3, 0, -3, -6, -12, -24, -60] }
    private let meterMarks: [Double] = [0, -12, -24, -36, -48, -60]

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                if !isMaster {
                    Button(action: onAFV) {
                        Image(systemName: afv ? "link.circle.fill" : "link.circle").font(.system(size: 16))
                            .foregroundStyle(afv ? DS.accent2 : DS.text3)
                    }.buttonStyle(.plain).accessibilityLabel("AFV")
                }
                Text(db <= -59 && !gainMode ? "−∞" : String(format: "%+.0f", db))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(gainMode ? DS.accent : DS.text2)
            }
            HStack(alignment: .top, spacing: 2) {
                scale(faderMarks, pos: faderPos)
                fader
                meter
                scale(meterMarks, pos: meterPos)
            }
            .frame(height: height)
            HStack(spacing: 4) {
                nudge("chevron.down") { onNudge(-1) }
                nudge("chevron.up") { onNudge(1) }
            }
            Group {
                if let delayMs {
                    HStack(spacing: 2) {
                        Button { onDelay(-10) } label: { Image(systemName: "minus").frame(width: 18, height: 18) }
                        Text("Delay \(Int(delayMs))ms").font(.system(size: 9, weight: .medium).monospacedDigit()).lineLimit(1)
                        Button { onDelay(10) } label: { Image(systemName: "plus").frame(width: 18, height: 18) }
                    }
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(DS.text2).buttonStyle(.plain)
                } else {
                    Color.clear
                }
            }
            .frame(height: 20)
            Button(action: onMute) {
                HStack(spacing: 3) {
                    Image(systemName: muted ? "speaker.slash" : "speaker.wave.1").font(.system(size: 11))
                    Text(name).font(.system(size: compact ? 11 : 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(width: compact ? 66 : 86, height: compact ? 28 : 34)
                .foregroundStyle(solo ? .black : (muted ? DS.pgm : .white))
                .background(solo ? Color.yellow : DS.surface2, in: Rectangle())
                .overlay(Rectangle().stroke(muted ? DS.pgm.opacity(0.7) : DS.stroke))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in if !isMaster { onSolo() } })
        }
        .padding(.horizontal, 4).padding(.vertical, 6)
    }

    private func nudge(_ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
                .frame(width: compact ? 28 : 36, height: compact ? 22 : 26)
                .background(DS.surface2, in: Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(DS.text2)
    }

    /// Fader: −60…+6 dB (Gain mode: −12…+24 dB), roughly linear in dB.
    private func faderPos(_ v: Double) -> CGFloat {
        gainMode ? CGFloat((max(-12, min(24, v)) + 12) / 36) : CGFloat((max(-60, min(6, v)) + 60) / 66)
    }
    private func faderValue(_ p: CGFloat) -> Double { gainMode ? Double(p) * 36 - 12 : Double(p) * 66 - 60 }
    private func meterPos(_ v: Double) -> CGFloat { CGFloat((max(-60, min(0, v)) + 60) / 60) }

    private func scale(_ marks: [Double], pos: @escaping (Double) -> CGFloat) -> some View {
        GeometryReader { g in
            ForEach(marks, id: \.self) { m in
                Text(m <= -60 ? "-∞" : m > 0 ? "\(Int(m))" : "\(Int(m))")
                    .font(.system(size: compact ? 8 : 10, design: .monospaced)).foregroundStyle(DS.text3)
                    .position(x: g.size.width / 2, y: 6 + (g.size.height - 12) * (1 - pos(m)))
            }
        }
        .frame(width: compact ? 18 : 24)
    }

    private var fader: some View {
        GeometryReader { g in
            let h = g.size.height, cap: CGFloat = compact ? 22 : 28
            ZStack(alignment: .top) {
                Rectangle().fill(Color.black).frame(width: 5).padding(.vertical, cap / 2)
                Rectangle()
                    .fill(LinearGradient(colors: [Color(white: 0.75), Color(white: 0.45), Color(white: 0.7)], startPoint: .top, endPoint: .bottom))
                    .frame(width: compact ? 22 : 26, height: cap)
                    .overlay(Rectangle().fill(isMaster ? DS.pgm : (gainMode ? DS.accent : Color.green)).frame(height: 2))
                    .offset(y: (1 - faderPos(db)) * (h - cap))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                onDB(faderValue(1 - max(0, min(1, (v.location.y - cap / 2) / (h - cap)))))
            })
            .onTapGesture(count: 2) { onDB(0) }
        }
        .frame(width: compact ? 26 : 32)
    }

    private var meter: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.black)
                Rectangle()
                    .fill(LinearGradient(stops: [.init(color: .green, location: 0), .init(color: .green, location: 0.7),
                                                 .init(color: .yellow, location: 0.85), .init(color: .red, location: 1)],
                                         startPoint: .bottom, endPoint: .top))
                    .mask(alignment: .bottom) { Rectangle().frame(height: g.size.height * meterPos(Double(level))) }
            }
        }
        .frame(width: compact ? 5 : 7)
        .padding(.vertical, 6)
    }
}

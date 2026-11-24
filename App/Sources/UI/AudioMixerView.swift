import SwiftUI

/// Console-style mixer (vision-mixer layout): one strip per channel with its ON AIR lamp, name, AFV,
/// fader whose scale lights up blue up to the fader, an L/R input meter (after trim, before the fader —
/// shows what a source carries even while AFV keeps it off air), the level in % / trim in dB,
/// ▲▼ nudge, Mute and Solo; the PGM master meters the program after the mixer (what goes out).
/// Header keys: AFV1 / AFV2 for every source, Gain swaps the faders to input trim (−12…+24 dB).
struct AudioMixerView: View {
    @ObservedObject var engine: StudioEngine
    @ObservedObject var library: MediaLibrary
    var compact = false
    @State private var gainMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: compact ? 2 : 3) {
                    ForEach(engine.audioChannels) { c in
                        MixerMeters(meters: engine.meters, id: c.id) { lr, onAir, peak in
                            ChannelStrip(name: c.name,
                                         note: c.id == AudioCapture.micID && c.followVideo ? L("theo Cam iPad") : nil,
                                         gain: Double(c.gain), trim: Double(c.trim),
                                         gainMode: gainMode, level: lr, peak: peak, onAir: onAir,
                                         muted: c.muted, solo: c.solo, afv: c.followVideo, compact: compact,
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
                    }
                    Rectangle().fill(DS.stroke).frame(width: 1).padding(.vertical, 4)
                    MixerMeters(meters: engine.meters, id: nil) { lr, _, peak in
                        ChannelStrip(name: "PGM", note: nil, gain: Double(engine.masterGain), trim: 0, gainMode: false,
                                     level: lr, peak: peak, onAir: engine.isAnyLive || engine.isRecording,
                                     muted: false, solo: false, afv: false, compact: compact, isMaster: true,
                                     onDB: { v in engine.masterGain = v <= -59 ? 0 : Float(pow(10, v / 20)) },
                                     onNudge: { engine.masterNudge(Float($0)) },
                                     onMute: {}, onSolo: {}, onAFV: {}, onDelay: { _ in })
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                modeKey("AFV1", on: engine.afvMode == .afv1) { engine.setAFVMode(engine.afvMode == .afv1 ? nil : .afv1) }
                modeKey("AFV2", on: engine.afvMode == .afv2) { engine.setAFVMode(engine.afvMode == .afv2 ? nil : .afv2) }
                modeKey("Gain", on: gainMode) { gainMode.toggle() }
            }
            .padding(2)
            .background(DS.surface2, in: Rectangle())
            Spacer()
            // first four sound effects as quick pads
            HStack(spacing: 4) {
                ForEach(library.list(.sound).prefix(4), id: \.self) { url in
                    Button { engine.playEffect(url) } label: {
                        Image(systemName: "waveform").font(.system(size: 14, weight: .semibold))
                            .frame(width: compact ? 30 : 36, height: compact ? 24 : 28)
                            .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
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
            Text(LocalizedStringKey(t)).font(.system(size: compact ? 11 : 13, weight: .bold))
                .padding(.horizontal, compact ? 8 : 11).frame(height: compact ? 24 : 28)
                .foregroundStyle(on ? .black : .white)
                .background(on ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
    }
}

/// Only the strips re-render up to twenty times a second (not the whole production view): levels + ON AIR.
struct MixerMeters<Content: View>: View {
    @ObservedObject var meters: LiveMeters
    let id: UUID?
    @ViewBuilder var content: ((Float, Float), Bool, (Float, Float)) -> Content
    var body: some View {
        if let id { content(meters.input(id), meters.onAir.contains(id), meters.peak(id, preFader: true)) }
        else { content(meters.stereo(nil), false, meters.peak(nil)) }
    }
}

struct ChannelStrip: View {
    let name: String
    var note: String?
    let gain: Double          // linear 0…2 (fader)
    let trim: Double          // input trim dB
    let gainMode: Bool
    let level: (Float, Float) // L/R dBFS
    var peak: (Float, Float) = (-60, -60)
    let onAir: Bool
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


    private static let faderBlue = Color(red: 0.30, green: 0.55, blue: 0.98)
    private var height: CGFloat { compact ? 110 : 170 }
    private var width: CGFloat { compact ? 68 : 84 }
    /// Fader value shown on the scale: dB of the fader (or trim in Gain mode).
    private var db: Double { gainMode ? trim : 20 * log10(max(gain, 0.0001)) }
    private var faderMarks: [Double] { gainMode ? [24, 18, 12, 6, 0, -6, -12] : [6, 0, -6, -12, -18, -24, -30, -40, -50, -60] }
    private var labelled: Set<Double> { gainMode ? [24, 12, 0, -12] : [6, 0, -12, -24, -40, -60] }
    /// Not heard in the program right now (muted, or AFV with its source off PGM).
    private var dimmed: Bool { !isMaster && (muted || !onAir) }

    var body: some View {
        VStack(spacing: 3) {
            // ON AIR lamp
            Capsule().fill(onAir ? DS.pgm : Color(white: 0.28))
                .frame(width: compact ? 22 : 28, height: 4)
                .shadow(color: onAir ? DS.pgm.opacity(0.8) : .clear, radius: 3)
            // AFV + name on one line
            HStack(spacing: 2) {
                if !isMaster {
                    Button(action: onAFV) {
                        Image(systemName: afv ? "link.circle.fill" : "link.circle").font(.system(size: compact ? 11 : 12))
                            .foregroundStyle(afv ? DS.accent2 : DS.text3)
                    }
                    .buttonStyle(.plain).accessibilityLabel("AFV")
                }
                Text(verbatim: name).font(.system(size: compact ? 9 : 10, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(.white)
            }
            .frame(height: 14)
            Text(verbatim: note ?? (isMaster ? "MASTER" : " ")).font(.system(size: 7, weight: .semibold))
                .foregroundStyle(isMaster ? DS.text3 : DS.accent2).lineLimit(1).frame(height: 8)
            HStack(alignment: .top, spacing: 1) {
                scaleLabels
                fader
                meter
            }
            .frame(height: height)
            .opacity(dimmed ? 0.45 : 1)
            // value: % of unity gain (Gain mode: trim dB)
            Text(verbatim: gainMode ? String(format: "%+.0f dB", trim) : (gain <= 0.001 ? "−∞" : "\(Int((gain * 100).rounded()))%"))
                .font(.system(size: compact ? 9 : 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(gainMode ? DS.accent : .white)
            // ▼ ▲ and M S on one row
            HStack(spacing: 2) {
                nudge("chevron.down") { onNudge(-1) }
                nudge("chevron.up") { onNudge(1) }
                if !isMaster {
                    key("M", on: muted, color: DS.pgm, action: onMute)
                    key("S", on: solo, color: .yellow, action: onSolo)
                }
            }
            Group {
                if let delayMs {
                    HStack(spacing: 1) {
                        Button { onDelay(-10) } label: { Image(systemName: "minus").frame(width: 14, height: 14) }
                        Text(verbatim: "\(Int(delayMs))ms").font(.system(size: 8, weight: .medium).monospacedDigit()).lineLimit(1)
                        Button { onDelay(10) } label: { Image(systemName: "plus").frame(width: 14, height: 14) }
                    }
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(DS.text2).buttonStyle(.plain)
                    .accessibilityLabel("Delay")
                } else {
                    Color.clear
                }
            }
            .frame(height: 14)
        }
        .frame(width: width)
        .padding(.vertical, 3)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 4))
    }

    private func key(_ t: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: t).font(.system(size: compact ? 9 : 10, weight: .heavy))
                .frame(width: compact ? 12 : 15, height: compact ? 18 : 20)
                .foregroundStyle(on ? .black : DS.text2)
                .background(on ? color : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
    }

    private func nudge(_ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: compact ? 8 : 9, weight: .bold))
                .frame(width: compact ? 12 : 15, height: compact ? 18 : 20)
                .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain).foregroundStyle(DS.text2)
    }

    // MARK: Fader

    /// Fader: −60…+6 dB (Gain mode: −12…+24 dB), linear in dB.
    private func faderPos(_ v: Double) -> CGFloat {
        gainMode ? CGFloat((max(-12, min(24, v)) + 12) / 36) : CGFloat((max(-60, min(6, v)) + 60) / 66)
    }
    private func faderValue(_ p: CGFloat) -> Double { gainMode ? Double(p) * 36 - 12 : Double(p) * 66 - 60 }
    private var cap: CGFloat { compact ? 12 : 14 }

    private var scaleLabels: some View {
        GeometryReader { g in
            let travel = g.size.height - cap
            ForEach(faderMarks.filter { labelled.contains($0) }, id: \.self) { m in
                Text(verbatim: !gainMode && m <= -60 ? "-∞" : (m > 0 ? "+\(Int(m))" : "\(Int(m))"))
                    .font(.system(size: compact ? 7 : 8, design: .monospaced)).foregroundStyle(DS.text3)
                    .position(x: g.size.width / 2, y: cap / 2 + travel * (1 - faderPos(m)))
            }
        }
        .frame(width: compact ? 13 : 16)
    }

    private var fader: some View {
        GeometryReader { g in
            let h = g.size.height, travel = h - cap, w = g.size.width
            let p = faderPos(db)
            let capY = travel * (1 - p)               // top of the cap
            ZStack(alignment: .topLeading) {
                // track
                Rectangle().fill(Color(white: 0.05)).frame(width: 6)
                    .position(x: w / 2, y: h / 2)
                // scale lines across the track: lit blue up to the fader, dim above it
                ForEach(faderMarks, id: \.self) { m in
                    let y = cap / 2 + travel * (1 - faderPos(m))
                    let lit = faderPos(m) <= p + 0.0001
                    Rectangle().fill(lit ? Self.faderBlue.opacity(0.95) : Color.white.opacity(0.18))
                        .frame(width: w * 0.8, height: 1)
                        .position(x: w / 2, y: y)
                }
                // level fill from the bottom to the fader
                Rectangle().fill(Self.faderBlue)
                    .frame(width: 6, height: max(0, h - capY - cap / 2))
                    .position(x: w / 2, y: capY + cap / 2 + max(0, h - capY - cap / 2) / 2)
                // cap
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.30)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(isMaster ? DS.pgm : (gainMode ? DS.accent : Self.faderBlue), lineWidth: 1.5))
                    .overlay(Rectangle().fill(Color.white.opacity(0.8)).frame(height: 1))
                    .frame(width: w * 0.9, height: cap)
                    .position(x: w / 2, y: capY + cap / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                onDB(faderValue(1 - max(0, min(1, (v.location.y - cap / 2) / travel))))
            })
            .onTapGesture(count: 2) { onDB(0) }
        }
        .frame(width: compact ? 22 : 28)
    }

    // MARK: Meter (L/R, same scale and colours as the monitor VU meters)

    private var meter: some View {
        HStack(spacing: 2) {
            bar(level.0, peak.0)
            bar(level.1, peak.1)
        }
        .overlay(alignment: .trailing) {
            GeometryReader { g in
                ForEach([0, -6, -18, -30, -60], id: \.self) { db in
                    Text(verbatim: "\(db)").font(.system(size: 6, design: .monospaced))
                        .foregroundStyle(DS.text2).fixedSize()
                        .position(x: g.size.width + 9, y: min(max(4, g.size.height * (1 - MonitorVU.pos(Float(db)))), max(4, g.size.height - 4)))
                }
            }.allowsHitTesting(false)
        }
        .padding(.trailing, 17)
        .padding(.vertical, cap / 2)
    }

    private func bar(_ db: Float, _ pk: Float) -> some View {
        VUBarCanvas(level: db, peak: pk).frame(width: compact ? 3 : 4)
    }
}

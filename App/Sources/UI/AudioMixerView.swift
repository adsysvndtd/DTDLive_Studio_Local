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
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: compact ? 3 : 6) {
                    ForEach(engine.audioChannels) { c in
                        MixerMeters(meters: engine.meters, id: c.id) { lr, onAir in
                            ChannelStrip(name: c.name,
                                         note: c.id == AudioCapture.micID && c.followVideo ? L("theo Cam iPad") : nil,
                                         gain: Double(c.gain), trim: Double(c.trim),
                                         gainMode: gainMode, level: lr, onAir: onAir,
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
                    Rectangle().fill(DS.stroke).frame(width: 1).padding(.vertical, 8)
                    MixerMeters(meters: engine.meters, id: nil) { lr, _ in
                        ChannelStrip(name: "PGM", note: nil, gain: Double(engine.masterGain), trim: 0, gainMode: false,
                                     level: lr, onAir: engine.isAnyLive || engine.isRecording,
                                     muted: false, solo: false, afv: false, compact: compact, isMaster: true,
                                     onDB: { v in engine.masterGain = v <= -59 ? 0 : Float(pow(10, v / 20)) },
                                     onNudge: { engine.masterNudge(Float($0)) },
                                     onMute: {}, onSolo: {}, onAFV: {}, onDelay: { _ in })
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

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
            Text(LocalizedStringKey(t)).font(.system(size: compact ? 12 : 14, weight: .bold))
                .padding(.horizontal, compact ? 10 : 14).frame(height: compact ? 28 : 32)
                .foregroundStyle(on ? .black : .white)
                .background(on ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
    }
}

/// Only the strips re-render ten times a second (not the whole production view): levels + ON AIR.
struct MixerMeters<Content: View>: View {
    @ObservedObject var meters: LiveMeters
    let id: UUID?
    @ViewBuilder var content: ((Float, Float), Bool) -> Content
    var body: some View {
        if let id { content(meters.input(id), meters.onAir.contains(id)) }
        else { content(meters.stereo(nil), false) }
    }
}

struct ChannelStrip: View {
    let name: String
    var note: String?
    let gain: Double          // linear 0…2 (fader)
    let trim: Double          // input trim dB
    let gainMode: Bool
    let level: (Float, Float) // L/R dBFS
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

    @State private var peak: (Float, Float) = (-60, -60)
    @State private var peakAt = Date.distantPast

    private static let faderBlue = Color(red: 0.30, green: 0.55, blue: 0.98)
    private var height: CGFloat { compact ? 130 : 220 }
    private var width: CGFloat { compact ? 70 : 92 }
    /// Fader value shown on the scale: dB of the fader (or trim in Gain mode).
    private var db: Double { gainMode ? trim : 20 * log10(max(gain, 0.0001)) }
    private var faderMarks: [Double] { gainMode ? [24, 18, 12, 6, 0, -6, -12] : [6, 0, -6, -12, -18, -24, -30, -40, -50, -60] }
    private var labelled: Set<Double> { gainMode ? [24, 12, 0, -12] : [6, 0, -12, -24, -40, -60] }
    /// Not heard in the program right now (muted, or AFV with its source off PGM).
    private var dimmed: Bool { !isMaster && (muted || !onAir) }

    var body: some View {
        VStack(spacing: 5) {
            // ON AIR lamp
            Capsule().fill(onAir ? DS.pgm : Color(white: 0.28))
                .frame(width: compact ? 28 : 36, height: 6)
                .shadow(color: onAir ? DS.pgm.opacity(0.8) : .clear, radius: 4)
            Text(verbatim: name).font(.system(size: compact ? 10 : 12, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(.white)
            HStack(spacing: 4) {
                if !isMaster {
                    Button(action: onAFV) {
                        HStack(spacing: 2) {
                            Image(systemName: afv ? "link.circle.fill" : "link.circle").font(.system(size: 13))
                            Text("AFV").font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(afv ? DS.accent2 : DS.text3)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("MASTER").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.text3)
                }
            }
            .frame(height: 14)
            Text(verbatim: note ?? " ").font(.system(size: 8)).foregroundStyle(DS.accent2).lineLimit(1).frame(height: 10)
            HStack(alignment: .top, spacing: 3) {
                scaleLabels
                fader
                meter
            }
            .frame(height: height)
            .opacity(dimmed ? 0.45 : 1)
            // value: % of unity gain (Gain mode: trim dB)
            Text(verbatim: gainMode ? String(format: "%+.0f dB", trim) : (gain <= 0.001 ? "−∞" : "\(Int((gain * 100).rounded()))%"))
                .font(.system(size: compact ? 10 : 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(gainMode ? DS.accent : .white)
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
            if !isMaster {
                HStack(spacing: 4) {
                    key("M", on: muted, color: DS.pgm, action: onMute)
                    key("S", on: solo, color: .yellow, action: onSolo)
                }
            } else {
                Color.clear.frame(height: compact ? 26 : 30)
            }
        }
        .frame(width: width)
        .padding(.vertical, 6)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 6))
        .onChange(of: level.0) { _, _ in updatePeak() }
        .onChange(of: level.1) { _, _ in updatePeak() }
    }

    private func key(_ t: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: t).font(.system(size: compact ? 11 : 13, weight: .heavy))
                .frame(width: compact ? 28 : 36, height: compact ? 26 : 30)
                .foregroundStyle(on ? .black : DS.text2)
                .background(on ? color : DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
    }

    private func nudge(_ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
                .frame(width: compact ? 28 : 36, height: compact ? 22 : 26)
                .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain).foregroundStyle(DS.text2)
    }

    private func updatePeak() {
        let now = Date()
        if level.0 >= peak.0 || level.1 >= peak.1 || now.timeIntervalSince(peakAt) > 1.5 {
            peak = (max(level.0, now.timeIntervalSince(peakAt) > 1.5 ? -60 : peak.0), max(level.1, now.timeIntervalSince(peakAt) > 1.5 ? -60 : peak.1))
            peakAt = now
        }
    }

    // MARK: Fader

    /// Fader: −60…+6 dB (Gain mode: −12…+24 dB), linear in dB.
    private func faderPos(_ v: Double) -> CGFloat {
        gainMode ? CGFloat((max(-12, min(24, v)) + 12) / 36) : CGFloat((max(-60, min(6, v)) + 60) / 66)
    }
    private func faderValue(_ p: CGFloat) -> Double { gainMode ? Double(p) * 36 - 12 : Double(p) * 66 - 60 }
    private var cap: CGFloat { compact ? 14 : 18 }

    private var scaleLabels: some View {
        GeometryReader { g in
            let travel = g.size.height - cap
            ForEach(faderMarks.filter { labelled.contains($0) }, id: \.self) { m in
                Text(verbatim: !gainMode && m <= -60 ? "-∞" : (m > 0 ? "+\(Int(m))" : "\(Int(m))"))
                    .font(.system(size: compact ? 7 : 8, design: .monospaced)).foregroundStyle(DS.text3)
                    .position(x: g.size.width / 2, y: cap / 2 + travel * (1 - faderPos(m)))
            }
        }
        .frame(width: compact ? 16 : 20)
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
        .frame(width: compact ? 26 : 34)
    }

    // MARK: Meter (L/R, same scale and colours as the monitor VU meters)

    private var meter: some View {
        HStack(spacing: 2) {
            bar(level.0, peak.0)
            bar(level.1, peak.1)
        }
        .padding(.vertical, cap / 2)
    }

    private func bar(_ db: Float, _ pk: Float) -> some View {
        GeometryReader { g in
            let h = g.size.height
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.black)
                LinearGradient(stops: [.init(color: .green, location: 0), .init(color: .green, location: MonitorVU.pos(-18)),
                                       .init(color: .yellow, location: MonitorVU.pos(-18)), .init(color: .yellow, location: MonitorVU.pos(-6)),
                                       .init(color: .red, location: MonitorVU.pos(-6)), .init(color: .red, location: 1)],
                               startPoint: .bottom, endPoint: .top)
                    .mask(alignment: .bottom) { Rectangle().frame(height: h * MonitorVU.pos(db)) }
                if pk > -59 {
                    Rectangle().fill(pk > -6 ? Color.red : Color.white).frame(height: 2)
                        .offset(y: -h * MonitorVU.pos(pk) + 1)
                }
            }
        }
        .frame(width: compact ? 4 : 5)
    }
}

#!/usr/bin/env python3
"""Test actual meter ballistics and coalesced publications without audio hardware."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'App/Sources/Core/StudioEngine.swift').read_text()
a = s.index('struct MeterEnvelope {')
b = s.index('/// Values that change many times', a)
model = s[a:b] + s[s.index('@MainActor\nfinal class LiveMeters'):]
support = '''import Foundation
import Combine
struct AudioChannelState { var id = UUID(); var level: Float = -60; var levelR: Float = -60 }
enum ScopeAnalyzer { struct Result {} }
'''
tests = '''
@main struct Tests {
 @MainActor static func main() {
    var e = MeterEnvelope()
    e.update(-6, now: 0)
    precondition(e.level == -6 && e.peak == -6)
    e.update(-60, now: 0.5)
    precondition(e.level == -18 && e.peak == -6)
    e.update(-60, now: 1.5)
    precondition(e.peak == -6)
    e.update(-60, now: 2)
    precondition(e.peak == -12)
    e.update(-60, now: 10)
    precondition(e.level == -60 && e.peak == -60)
    e.update(.nan, now: 11)
    precondition(e.level.isFinite && e.peak.isFinite)
    e.update(6, now: 12)
    precondition(e.level == 0 && e.peak == 0)
    print("PASS: immediate attack, timed release, peak expiry at silence, finite/clamped values")
    let meters = LiveMeters()
    var notifications = 0
    let subscription = meters.objectWillChange.sink { notifications += 1 }
    meters.update(master: (-6, -12), channels: [], input: [:], onAir: [], now: 0)
    precondition(notifications == 1)
    meters.update(master: (-6, -12), channels: [], input: [:], onAir: [], now: 0.05)
    precondition(notifications == 1)
    meters.update(master: (-6, -60), channels: [], input: [:], onAir: [], now: 2)
    precondition(meters.peak(nil).0 == -6 && meters.peak(nil).1 < -12)
    let channel = AudioChannelState(level: -24, levelR: -30)
    meters.update(master: (-60, -60), channels: [channel], input: [channel.id: (-3, -9)], onAir: [channel.id], now: 3)
    precondition(meters.stereo(channel.id).0 == -24)
    precondition(meters.input(channel.id).0 == -3)
    precondition(meters.peak(channel.id, preFader: true).1 == -9)
    meters.update(master: (-60, -60), channels: [], input: [:], onAir: [], now: 10)
    precondition(meters.stereo(channel.id).0 == -60 && meters.peak(channel.id).0 == -60)
    withExtendedLifetime(subscription) {}
    print("PASS: one notification/sample, independent L/R peaks, pre/post fader, removed channel cleanup")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='dtd-meter-tests-') as tmp:
    p = Path(tmp)
    (p / 'tests.swift').write_text(support + model + tests)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(p / 'cache'), str(p / 'tests.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

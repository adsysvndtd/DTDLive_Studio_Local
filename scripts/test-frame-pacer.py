#!/usr/bin/env python3
"""Exercise production pacer timing with burst arrivals and queued stale frames."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'App/Sources/Ingest/IngestSource.swift').read_text()
code = s[s.index('final class FramePacer:'):]
support = '''import Foundation
import Dispatch
typealias CVPixelBuffer = Int
enum DecodedFrameTiming { static func presentationTime(_ pb: Int) -> Double? { nil } }
enum HostClock { static var now: Double { ProcessInfo.processInfo.systemUptime } }
final class FrameStore: @unchecked Sendable {
 private let lock = NSLock()
 private var values: [Int] = []
 func put(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
 func snapshot() -> [Int] { lock.lock(); defer { lock.unlock() }; return values }
}
'''
tests = '''
// Original PTS must retain exactly 60 fps even when transport delivers in bursts.
var timestampClock = FramePlayoutClock()
for i in 0..<7200 {
 let media = 100 + Double(i) / 60
 let arrival = 10 + Double(i / 3) * 0.05
 let t = timestampClock.schedule(media: media, arrived: arrival, delay: 0.1)!
 precondition(abs(t.due - (10.1 + Double(i) / 60)) < 0.000001)
 precondition(t.generation == 1, "PTS playback drifted/re-anchored")
}
var arrivals = FrameArrivalClock()
var clock = FramePlayoutClock()
var end = 0.0
for i in 0..<900 {
 // 30 fps delivered as three frames together every 100 ms.
 let now = 10 + Double(i / 3) * 0.1
 end = arrivals.media(at: now)
 let t = clock.schedule(media: end, arrived: now, delay: 0.1)!
 precondition(t.due <= now + 0.201 && t.due >= now - 0.101)
}
precondition(abs(end - 30) < 0.25, "Burst estimator drift: \\(end)")
var c = FramePlayoutClock()
let a = c.schedule(media: 100, arrived: 10, delay: 0.1)!
let b = c.schedule(media: 0, arrived: 10.01, delay: 0.1)!
precondition(b.generation > a.generation)
let d = c.schedule(media: 0.9, arrived: 10.02, delay: 0.1)!
precondition(d.generation > b.generation && abs(d.due - 10.12) < 0.00001)
precondition(c.schedule(media: .nan, arrived: 10, delay: 0.1) == nil)
for fps in [24, 25, 30, 50, 60] {
 var estimate = FrameArrivalClock()
 var t = 0.0
 var prior = 0.0
 for i in 0..<600 { prior = t; t = estimate.media(at: Double(i) / Double(fps)) }
 precondition(abs((t-prior) - 1/Double(fps)) < 0.0001)
}
let store = FrameStore()
let pacer = FramePacer(store: store)
pacer.delay = 0.05
pacer.push(1, media: 100)
pacer.push(2, media: 0) // old pending callback must not publish after reset
Thread.sleep(forTimeInterval: 0.15)
precondition(store.snapshot() == [2], "Stale frame published: \\(store.snapshot())")
print("PASS: burst cadence, 24–60 fps convergence, bounded delay, reset generation and stale callback suppression")
'''
with tempfile.TemporaryDirectory(prefix='dtd-pacer-') as temp:
    src = Path(temp) / 'main.swift'
    src.write_text(support + code + tests)
    binary = str(Path(temp) / 'check')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(Path(temp)/'cache'), str(src), '-o', binary], check=True)
    subprocess.run([binary], check=True)

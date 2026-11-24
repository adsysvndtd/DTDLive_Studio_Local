#!/usr/bin/env python3
"""Regression checks for deletion/reordering and delayed overlay UI callbacks."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'App/Sources/Core/StudioEngine.swift').read_text()
methods = source[source.index('    func editPictureOverlay('):source.index('    private func pushOverlays()')]
ui = (root / 'App/Sources/UI/ProductionView.swift').read_text()
assert 'ForEach($engine.pictureOverlays)' not in ui, 'Do not bind rows to removable array indices'
assert '@Published private(set) var pictureOverlays:' in source
support = '''import Foundation
import CoreGraphics
struct Image { var extent = CGRect(x: 0, y: 0, width: 800, height: 600) }
struct Layer: Equatable {
    let id = UUID()
    var image: Image? = nil
    var rect = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
    var visible = false
    var opacity: CGFloat = 1
    static func == (a: Layer, b: Layer) -> Bool {
        a.id == b.id && a.rect == b.rect && a.visible == b.visible && a.opacity == b.opacity
    }
}
struct Format { var width = 1920; var height = 1080 }
final class Engine {
    var format = Format()
    var pictureOverlays: [Layer] = []
    var pictureOverlayNames: [UUID: String] = [:]
    var pictureOverlayPreviews: [UUID: String] = [:]
'''
tests = '''
}
let engine = Engine()
let a = Layer(), b = Layer(), c = Layer()
engine.pictureOverlays = [a, b, c]
engine.pictureOverlayNames = [a.id: "A", b.id: "B", c.id: "C"]
// These closures model controls retained by SwiftUI after their row is removed.
let lateToggle = { engine.setPictureOverlayVisible(b.id, true) }
let lateOpacity = { engine.setPictureOverlayOpacity(b.id, 0.2) }
let lateMove = { engine.editPictureOverlay(b.id, x: 0.6, y: 0.7, width: 0.4) }
engine.removePictureOverlay(b.id)
let remaining = engine.pictureOverlays
lateToggle(); lateOpacity(); lateMove(); engine.raisePictureOverlay(b.id)
engine.removePictureOverlay(b.id)
precondition(engine.pictureOverlays == remaining)
precondition(engine.pictureOverlayNames[b.id] == nil)
print("PASS: stale toggle/slider/drag/reorder/delete callbacks are no-ops")
engine.raisePictureOverlay(a.id)
precondition(engine.pictureOverlays.map(\\.id) == [c.id, a.id])
engine.setPictureOverlayVisible(a.id, true)
engine.setPictureOverlayOpacity(a.id, 0.4)
precondition(engine.pictureOverlays.first?.visible == false)
precondition(engine.pictureOverlays.last?.visible == true)
precondition(engine.pictureOverlays.last?.opacity == 0.4)
print("PASS: controls target the correct ID after reordering")
for id in [c.id, a.id] { engine.removePictureOverlay(id) }
lateToggle(); lateOpacity(); lateMove()
precondition(engine.pictureOverlays.isEmpty && engine.pictureOverlayNames.isEmpty)
for _ in 0..<100 {
    let layer = Layer()
    engine.pictureOverlays.append(layer)
    engine.removePictureOverlay(layer.id)
    engine.setPictureOverlayVisible(layer.id, true)
}
precondition(engine.pictureOverlays.isEmpty)
print("PASS: delete last/all layers and repeated add/delete")
'''
with tempfile.TemporaryDirectory(prefix='dtd-picture-tests-') as tmp:
    path = Path(tmp) / 'tests.swift'
    path.write_text(support + methods + tests)
    subprocess.run(['xcrun', 'swift', '-module-cache-path', str(Path(tmp) / 'cache'), str(path)], check=True)

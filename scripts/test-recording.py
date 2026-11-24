#!/usr/bin/env python3
"""Run recording lifecycle regressions with media doubles; no camera/codec service required."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
manager = (root / 'App/Sources/Outputs/OutputManager.swift').read_text()
encoders = (root / 'App/Sources/Encode/Encoders.swift').read_text()
slot = manager[manager.index('actor OutputSlot'):manager.index('/// Encode-once / fan-out hub')]
clock = encoders[encoders.index('struct AudioCaptureClock'):encoders.index('/// PCM -> AAC-LC')]
with tempfile.TemporaryDirectory(prefix='dtd-rec-regression-') as tmp:
    directory = pathlib.Path(tmp)
    production = directory / 'Production.swift'
    production.write_text('import Foundation\n' + slot + clock)
    binary = directory / 'tests'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(directory / 'cache'),
                    '-parse-as-library', str(production),
                    str(root / 'scripts/tests/recording-regression.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

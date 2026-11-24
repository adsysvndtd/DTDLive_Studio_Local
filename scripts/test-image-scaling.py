#!/usr/bin/env python3
"""Exercise the actual Core Image resampler and monitor sizing on macOS."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='dtd-image-scaling-') as temp:
    binary = str(Path(temp) / 'check')
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(Path(temp) / 'cache'),
                    str(root / 'App/Sources/Core/MonitorRendering.swift'),
                    str(root / 'scripts/tests/image-scaling-regression.swift'),
                    '-o', binary], check=True)
    subprocess.run([binary], check=True)

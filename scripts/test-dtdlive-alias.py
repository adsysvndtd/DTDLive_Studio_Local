#!/usr/bin/env python3
"""Exercise the receiver's actual alias decoder without SRT hardware."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'App/Sources/Ingest/DTDLiveLink.swift').read_text()
start = source.index('    static func pretty(')
end = source.index('\n}\n', start)
code = 'import Foundation\nenum Receiver {\n' + source[start:end] + '\n}\n'
code += '''
func encoded(_ alias: String) -> String {
    "n1." + Data(alias.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
precondition(Receiver.pretty("n1.Q0FNMQ") == "CAM1")
for name in ["CAM2", "Camera sân khấu", "Máy Ảnh 📷", "A", "AB", "ABC", "n1.camera"] {
    precondition(Receiver.pretty(encoded(name)) == name)
}
for invalid in ["n1.", "n1.A", "n1.@@@", "n1._w", "n1.IA"] {
    precondition(Receiver.pretty(invalid) == invalid)
}
precondition(Receiver.pretty(" CAM1 ") == "CAM1")
precondition(Receiver.pretty("iPhone-DTDLive-12ABCDEF") == "DTDLive 12AB")
precondition(Receiver.pretty("") == "DTDLive")
print("PASS: CAM1, Unicode, base64url lengths, invalid payloads, legacy/plain names")
'''
with tempfile.TemporaryDirectory(prefix='dtd-alias-tests-') as tmp:
    path = Path(tmp) / 'test.swift'
    path.write_text(code)
    subprocess.run(['xcrun', 'swift', '-module-cache-path', str(Path(tmp) / 'cache'), str(path)], check=True)

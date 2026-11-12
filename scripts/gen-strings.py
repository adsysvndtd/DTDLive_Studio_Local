#!/usr/bin/env python3
"""Localization/Localizable.xcstrings (source of truth, edit in Xcode or by hand)
→ App/Resources/{vi,en}.lproj/Localizable.strings (bundled; works with any Xcode/XcodeGen)."""
import json, os, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cat = json.load(open(os.path.join(root, "Localization", "Localizable.xcstrings"), encoding="utf-8"))
src = cat.get("sourceLanguage", "vi")
def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
langs = {src}
for v in cat["strings"].values(): langs |= set(v.get("localizations", {}))
for lang in sorted(langs):
    lines = []
    for key in sorted(cat["strings"]):
        loc = cat["strings"][key].get("localizations", {}).get(lang, {})
        val = loc.get("stringUnit", {}).get("value") or (key if lang == src else None)
        if val is None: continue
        lines.append(f'"{esc(key)}" = "{esc(val)}";')
    d = os.path.join(root, "App", "Resources", f"{lang}.lproj"); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
    print(f"{lang}: {len(lines)} strings", file=sys.stderr)

#!/bin/bash
# Copies the NDI® SDK for Apple (installed from https://ndi.video/for-developers/ndi-sdk/) into Vendor/NDI
# and writes the module map, so build-local.sh compiles DTD Studio with NDI input + output.
# The SDK is licensed by Vizrt; it is not committed to this repo (Vendor/NDI is git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="${1:-/Library/NDI SDK for Apple}"
LIB=$(find "$ROOT" -name 'libndi_ios.a' -print -quit 2>/dev/null || true)
HDR=$(find "$ROOT" -name 'Processing.NDI.Lib.h' -print -quit 2>/dev/null || true)
if [ -z "$LIB" ] || [ -z "$HDR" ]; then
  echo "Không tìm thấy NDI SDK trong \"$ROOT\"."
  echo "Tải và cài \"NDI SDK for Apple\" từ https://ndi.video/for-developers/ndi-sdk/ rồi chạy lại"
  echo "(hoặc: scripts/ndi-setup.sh \"/đường/dẫn/NDI SDK for Apple\")."
  exit 1
fi
mkdir -p Vendor/NDI
cp "$LIB" Vendor/NDI/
cp "$(dirname "$HDR")"/Processing.NDI.*.h Vendor/NDI/
cat > Vendor/NDI/module.modulemap <<'MAP'
module NDI {
    header "Processing.NDI.Lib.h"
    link "ndi_ios"
    export *
}
MAP
echo "✓ NDI SDK đã chép vào Vendor/NDI — chạy ./scripts/build-local.sh để build kèm NDI."

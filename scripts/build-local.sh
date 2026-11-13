#!/bin/bash
# Build DTD Studio on your own Mac (same steps as the GitHub Actions workflow).
#   ./scripts/build-local.sh          → prepare and open in Xcode (then pick your iPad/iPhone and press ▶)
#   ./scripts/build-local.sh ipa      → also build an unsigned .ipa into build/
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf "\n\033[1;33m▶ %s\033[0m\n" "$*"; }

say "Kiểm tra Xcode"
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Chưa có Xcode đầy đủ. Cài Xcode từ App Store, mở 1 lần để cài thêm thành phần, rồi chạy:"
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi
xcodebuild -version

say "Công cụ: Homebrew, cmake, xcodegen"
command -v brew >/dev/null || { echo "Cài Homebrew: https://brew.sh rồi chạy lại"; exit 1; }
command -v cmake >/dev/null || brew install cmake
command -v xcodegen >/dev/null || brew install xcodegen

if [ ! -d Vendor/srtkit/SRTKit.xcframework ]; then
  say "Build SRTKit (libsrt + mbedTLS) — lần đầu mất khoảng 5–10 phút"
  IOS_MIN=17.0 SRTKIT_LINK_LIBSRT=0 ./Vendor/srtkit/scripts/build-ios.sh
else
  say "SRTKit.xcframework đã có — bỏ qua (xoá thư mục đó để build lại)"
fi

say "Tạo chuỗi song ngữ (vi/en)"
python3 scripts/gen-strings.py

say "Tạo DTDStudio.xcodeproj"
if [ -f Vendor/NDI/libndi_ios.a ] && [ -f Vendor/NDI/module.modulemap ]; then
  echo "  NDI® SDK có trong Vendor/NDI → build kèm NDI"
  xcodegen generate --spec project.ndi.yml
else
  xcodegen generate
fi

if [ "${1:-}" = "ipa" ]; then
  say "Build bản unsigned (iOS device)"
  mkdir -p build
  xcodebuild -project DTDStudio.xcodeproj -scheme DTDStudio -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build/dd \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build 2>&1 | tee build/build.log | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" || true
  APP=$(find build/dd/Build/Products/Release-iphoneos -maxdepth 1 -name "*.app" | head -1)
  if [ -n "$APP" ]; then
    rm -rf build/Payload && mkdir -p build/Payload && cp -R "$APP" build/Payload/
    (cd build && zip -qr DTDStudio-unsigned.ipa Payload)
    echo "→ build/DTDStudio-unsigned.ipa (cần ký lại trước khi cài, xem docs/SIGNING.md)"
  else
    echo "Build lỗi — xem build/build.log (các dòng error:)"; exit 1
  fi
else
  say "Mở Xcode"
  echo "Trong Xcode: chọn target DTDStudio › Signing & Capabilities › Team = Apple ID của bạn,"
  echo "cắm iPad/iPhone, chọn thiết bị ở thanh trên cùng rồi bấm ▶ (Run)."
  open DTDStudio.xcodeproj
fi

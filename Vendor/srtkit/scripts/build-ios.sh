#!/usr/bin/env bash
# Build SRTKit.xcframework (libsrt + mbedTLS + lõi SRTKit + bridge Obj-C++) cho iOS.
# Chạy trên macOS có Xcode và CMake (brew install cmake).
#
#   ./scripts/build-ios.sh            # build vào ./build-ios, xuất ./SRTKit.xcframework
#   IOS_MIN=14.0 ./scripts/build-ios.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/build-ios}"
IOS_MIN="${IOS_MIN:-13.0}"
SRT_TAG="${SRT_TAG:-v1.5.7}"
MBEDTLS_TAG="${MBEDTLS_TAG:-v3.6.7}"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "$WORK/src"
cd "$WORK/src"
[ -d srt ] || git clone --depth 1 -b "$SRT_TAG" https://github.com/Haivision/srt.git srt
[ -d mbedtls ] || git clone --depth 1 --recurse-submodules --shallow-submodules -b "$MBEDTLS_TAG" https://github.com/Mbed-TLS/mbedtls.git mbedtls
# WHIP/WebRTC cần DTLS-SRTP (tắt mặc định trong mbedTLS)
(cd mbedtls && python3 scripts/config.py set MBEDTLS_SSL_DTLS_SRTP)

# slice: <tên> <sdk> <archs>
SLICES=(
  "ios-arm64 iphoneos arm64"
  "ios-sim iphonesimulator arm64;x86_64"
)

common_flags() {  # $1 sdk  $2 archs
  echo -DCMAKE_SYSTEM_NAME=iOS \
       -DCMAKE_OSX_SYSROOT="$1" \
       "-DCMAKE_OSX_ARCHITECTURES=$2" \
       -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
       -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
       -DCMAKE_BUILD_TYPE=Release \
       -DCMAKE_POSITION_INDEPENDENT_CODE=ON
}

XCF_ARGS=()
for s in "${SLICES[@]}"; do
  read -r NAME SDK ARCHS <<<"$s"
  PREFIX="$WORK/$NAME/prefix"
  echo "===================== $NAME ($SDK: $ARCHS) ====================="

  cmake -S "$WORK/src/mbedtls" -B "$WORK/$NAME/mbedtls" $(common_flags "$SDK" "$ARCHS") \
        -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF -DCMAKE_INSTALL_PREFIX="$PREFIX"
  cmake --build "$WORK/$NAME/mbedtls" -j"$JOBS"
  cmake --install "$WORK/$NAME/mbedtls"

  cmake -S "$WORK/src/srt" -B "$WORK/$NAME/srt" $(common_flags "$SDK" "$ARCHS") \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DUSE_ENCLIB=mbedtls -DMBEDTLS_PREFIX="$PREFIX" \
        -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
        -DMBEDTLS_INCLUDE_DIR="$PREFIX/include" -DMBEDTLS_LIB="$PREFIX/lib/libmbedtls.a" \
        -DMBEDCRYPTO_LIB="$PREFIX/lib/libmbedcrypto.a" -DMBEDX509_LIB="$PREFIX/lib/libmbedx509.a" \
        -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_APPS=OFF -DENABLE_UNITTESTS=OFF
  cmake --build "$WORK/$NAME/srt" -j"$JOBS"
  cmake --install "$WORK/$NAME/srt"

  cmake -S "$ROOT" -B "$WORK/$NAME/srtkit" $(common_flags "$SDK" "$ARCHS") \
        -DSRT_PREFIX="$PREFIX" -DSRTKIT_BUILD_TESTS=OFF -DSRTKIT_BUILD_OBJC=ON
  cmake --build "$WORK/$NAME/srtkit" -j"$JOBS"

  # Gộp mọi thư viện tĩnh thành một libSRTKit.a
  OUT="$WORK/$NAME/out"
  rm -rf "$OUT" && mkdir -p "$OUT/include"
  LIBS=("$WORK/$NAME/srtkit/libsrtkit.a" "$PREFIX/lib/libmbedtls.a" \
        "$PREFIX/lib/libmbedx509.a" "$PREFIX/lib/libmbedcrypto.a")
  # DTD Studio links libsrt 1.5.7 from HaishinKit (SRTHaishinKit); merging a second copy here would
  # duplicate every srt_* symbol. SRTKIT_LINK_LIBSRT=0 builds SRTKit against the same libsrt headers
  # and leaves the srt_* symbols to the app's libsrt.
  if [ "${SRTKIT_LINK_LIBSRT:-1}" = "1" ]; then LIBS+=("$PREFIX/lib/libsrt.a"); fi
  for extra in everest p256m; do [ -f "$PREFIX/lib/lib$extra.a" ] && LIBS+=("$PREFIX/lib/lib$extra.a"); done
  libtool -static -o "$OUT/libSRTKit.a" "${LIBS[@]}"

  cp "$ROOT/ios/SRTKit.h" "$OUT/include/"
  cat > "$OUT/include/module.modulemap" <<'EOF'
module SRTKit {
    header "SRTKit.h"
    link "c++"
    link framework "CoreMedia"
    link framework "VideoToolbox"
    link framework "AudioToolbox"
    export *
}
EOF
  XCF_ARGS+=(-library "$OUT/libSRTKit.a" -headers "$OUT/include")
done

rm -rf "$ROOT/SRTKit.xcframework"
xcodebuild -create-xcframework "${XCF_ARGS[@]}" -output "$ROOT/SRTKit.xcframework"
echo
echo "Xong: $ROOT/SRTKit.xcframework"
echo "Kéo vào Xcode (Frameworks, Libraries, and Embedded Content -> Do Not Embed), rồi 'import SRTKit' trong Swift."

#!/bin/bash
# Double-click in Finder: builds DTD Studio with the local Xcode, log in build/local-build.log
cd "$(dirname "$0")"
mkdir -p build
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
./scripts/build-local.sh ipa 2>&1 | tee build/local-build.log
echo "=== DONE (exit ${PIPESTATUS[0]}) ===" | tee -a build/local-build.log

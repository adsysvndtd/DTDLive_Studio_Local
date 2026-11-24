#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/dtdstudio-monitor.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/modules" \
  App/Sources/Core/MonitorRendering.swift App/Sources/Core/FrameStore.swift \
  scripts/tests/monitor-quality.swift -o "$test_dir/check"
"$test_dir/check"

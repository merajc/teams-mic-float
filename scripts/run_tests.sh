#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mkdir -p .build/test-module-cache
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/test-module-cache"
export SWIFT_MODULECACHE_PATH="$ROOT/.build/test-module-cache"
export PYTHONDONTWRITEBYTECODE=1

SOURCES=()
for file in Sources/TeamsMicFloat/*.swift; do
    if [[ "$(basename "$file")" == "main.swift" ]]; then
        continue
    fi
    SOURCES+=("$file")
done
SOURCES+=("Tests/TestHarness.swift")

echo "Building native test harness…"
xcrun swiftc \
    -parse-as-library \
    -O \
    -o .build/teamsmicfloat-tests \
    "${SOURCES[@]}" \
    -framework AppKit \
    -framework QuartzCore

echo "Running tests…"
exec .build/teamsmicfloat-tests

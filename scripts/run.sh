#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/TeamsMicFloat.app"

if [[ ! -x "$APP/Contents/MacOS/TeamsMicFloat" ]]; then
    "$ROOT/scripts/build_app.sh"
fi

open "$APP"

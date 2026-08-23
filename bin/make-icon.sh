#!/usr/bin/env bash
#
# make-icon.sh — regenerate the app icon from Tools/MakeIcon.swift.
#
#   bin/make-icon.sh            # the chosen variant
#   bin/make-icon.sh 3-blue     # try another one
#
# The icon is drawn in code on purpose: every size comes from one source, a change is a diff
# somebody can read, and there is no binary in the repo that nobody can edit.
set -euo pipefail
cd "$(dirname "$0")/.."

VARIANT="${1:-1-slate}"
SET="App/Assets.xcassets/AppIcon.appiconset"

rm -rf "$SET"
mkdir -p "$SET"
swift Tools/MakeIcon.swift "$SET" "$VARIANT"

echo "Now run bin/preflight.sh — the asset catalogue is compiled at build time."

#!/usr/bin/env bash
#
# make-icon.sh — prepare the app icon from Assets/AppIcon-source.png.
#
#   bin/make-icon.sh          # the chosen shadow lift
#   bin/make-icon.sh 0.7      # lift the dark background further, 0 to 1
#
# The artwork is the illustrator's; everything Apple wants doing to it — the squircle, the margin,
# the shadow, the ten sizes — is done here so it is reproducible rather than remembered.
set -euo pipefail
cd "$(dirname "$0")/.."

LIFT="${1:-0.5}"
SET="App/Assets.xcassets/AppIcon.appiconset"

rm -rf "$SET"
mkdir -p "$SET"
swift Tools/MakeIcon.swift "$SET" "$LIFT"

echo "Now run bin/preflight.sh — the asset catalogue is compiled at build time."

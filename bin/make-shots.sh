#!/usr/bin/env bash
#
# make-shots.sh — redraw the pictures of Scout that the website shows.
#
# Every one is taken from the app itself, on invented data (`App/DemoData.swift`): no real mail,
# no real files, nobody's real name. The app is launched through LaunchServices rather than run
# directly, because a directly-executed binary inherits the terminal's permissions and draws the
# app icons wrong.
#
#   bin/make-shots.sh                     # write them into the website's assets folder
#   bin/make-shots.sh /some/other/folder  # write them somewhere else
#
# One canvas for all of them, on purpose: a slideshow whose slides change shape makes the page
# jump every time somebody clicks.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

OUT="${1:-$HOME/Sites/stonemesa/apps/assets/screens/scout}"
APP="$ROOT/build/release/Scout.app"
WIDTH=900
HEIGHT=1020

# The order here is the order of the slideshow.
SCENES=(sections person notes solo filters)

[ -d "$APP" ] || { echo "No app at $APP — run bin/rebuild-and-launch.sh --build first."; exit 1; }
command -v cwebp >/dev/null || { echo "cwebp not found — brew install webp"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

index=0
for scene in "${SCENES[@]}"; do
  index=$((index + 1))
  name="$(printf '%02d-%s' "$index" "$scene")"
  echo "  $name…"
  open -n -a "$APP" --args --shot "$scene" "$TMP/$name.png" "$WIDTH" "$HEIGHT"
  # The app lays the panel out, waits for the sources to answer, photographs it and quits.
  sleep 4
  [ -s "$TMP/$name.png" ] || { echo "nothing came back for $scene: $(cat "$TMP/$name.png.txt" 2>/dev/null)"; exit 1; }
  cwebp -quiet -q 88 "$TMP/$name.png" -o "$OUT/$name.webp"
done

echo
echo "Wrote ${#SCENES[@]} pictures to $OUT at $((WIDTH * 2))x$((HEIGHT * 2))"
ls -la "$OUT"

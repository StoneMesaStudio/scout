#!/usr/bin/env bash
#
# Build the double-clickable "Rebuild Scout" app and put it in ~/Library/Scripts, alongside the
# launchers for the other apps.
#
#   ./bin/make-launcher.sh
#
# Run this once. Re-run it only to change how the launcher itself behaves — what it DOES lives in
# `bin/rebuild-and-launch.sh`, which the launcher calls by path, so ordinary fixes need no rebuild.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/Library/Scripts/Rebuild Scout.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$HOME/Library/Scripts"

# The AppleScript is generated rather than committed as a separate file so the project path is
# baked in literally — an applet has no notion of a working directory.
cat > "$WORK/launcher.applescript" <<APPLESCRIPT
-- Rebuild Scout
--
-- A thin shim. All it does is run bin/rebuild-and-launch.sh and turn a failure into a dialog a
-- human will actually read. Every decision that matters (building to the one path macOS ties the
-- permissions to, quitting a stale menu-bar copy, launching through \`open\`) lives in that script.
--
-- No "tell application" against anything but the shell: sending another app an Apple Event needs
-- macOS automation permission, and this exists to remove chores, not add a dialog.

on run
	set repoPath to "$PROJECT_ROOT"
	set buildScript to quoted form of (repoPath & "/bin/rebuild-and-launch.sh")

	display notification "Building the latest code…" with title "Rebuild Scout"

	try
		-- Combines stderr into stdout so a failure's reason survives to the dialog below.
		set output to do shell script buildScript & " 2>&1"
		-- The script's last line is already a sentence; show that rather than a status code.
		display notification (last paragraph of output) with title "Rebuild Scout"
	on error errMsg
		-- \`do shell script\` puts the script's own output in the error message on a non-zero
		-- exit, which is exactly the readable sentence the build script prints. Shown as-is.
		set cleanMsg to errMsg
		if cleanMsg starts with "Error: " then
			set cleanMsg to text 8 thru -1 of cleanMsg
		end if
		display dialog cleanMsg with title "Rebuild Scout — didn't work" buttons {"Show Log", "OK"} default button "OK" with icon caution
		if button returned of result is "Show Log" then
			do shell script "open -R " & quoted form of (repoPath & "/build/last-build.log") & " 2>/dev/null || true"
		end if
	end try
end run
APPLESCRIPT

rm -rf "$DEST"
osacompile -o "$DEST" "$WORK/launcher.applescript"

# ── Icon ────────────────────────────────────────────────────────────────────────────────────────
# Scout has no app icon yet, so the launcher keeps the generic applet one. When there is an
# AppIcon asset, this block gives the launcher the same face — built from the app's own master so
# the two cannot drift apart.
SRC="$PROJECT_ROOT/App/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
if [[ -f "$SRC" ]]; then
    ICONSET="$WORK/scout.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$DEST/Contents/Resources/applet.icns"
    touch "$DEST"
fi

echo "Built: $DEST"
echo "Double-click it to rebuild Scout and relaunch it."

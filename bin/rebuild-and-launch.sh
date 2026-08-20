#!/bin/bash
#
# Rebuild Scout from source and launch it — no Xcode window required.
#
# This is the engine behind the "Rebuild Scout" app in ~/Library/Scripts (built by
# `bin/make-launcher.sh`). It lives in the repo, not inside that app, so the logic is
# version-controlled and one edit here fixes the launcher too.
#
#   ./bin/rebuild-and-launch.sh          # build, then launch
#   ./bin/rebuild-and-launch.sh --build  # build only, don't launch
#
# Exit 0 = built and launched. Non-zero = something failed, and the reason is the last thing on
# stdout — the launcher shows exactly that text in its dialog, so it has to read as a sentence to
# someone who is not going to open a log.

set -uo pipefail

# ── PATH, explicitly ────────────────────────────────────────────────────────────────────────────
# A GUI-launched app inherits a bare PATH, NOT the one from the shell profile. `xcodegen` lives in
# Homebrew, so without this line the launcher fails with "xcodegen: command not found" while the
# identical command works fine in Terminal.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT" || { echo "Can't find the Scout project folder."; exit 1; }

LAUNCH=1
[[ "${1:-}" == "--build" ]] && LAUNCH=0

# ── Where the app lands, and why it must not move ───────────────────────────────────────────────
# macOS ties Full Disk Access, Contacts and the Documents/Desktop/Downloads grants to a specific
# app — and for a locally-signed build, to the path it was granted at. Building somewhere new
# means every permission has to be granted again, which is the most annoying possible way for a
# rebuild to fail. So this path is fixed and matches what has always been launched.
BUILD_DIR="$PROJECT_ROOT/build/release"
APP="$BUILD_DIR/Scout.app"
LOG="$PROJECT_ROOT/build/last-build.log"
mkdir -p "$PROJECT_ROOT/build"

# ── 1. Regenerate the Xcode project ─────────────────────────────────────────────────────────────
# Scout.xcodeproj is gitignored and generated from project.yml, whose globs pick up App/. Skipping
# this is how a newly added .swift file silently isn't in the build.
if ! xcodegen generate >"$LOG" 2>&1; then
    echo "Couldn't prepare the Xcode project."
    echo
    tail -12 "$LOG"
    exit 1
fi

# ── 2. Build ────────────────────────────────────────────────────────────────────────────────────
# Signed, because the permission grants above follow the signature as well as the path. An
# unsigned or re-signed build looks like a different app to macOS and starts from nothing.
echo "Building…"
if ! xcodebuild \
        -project Scout.xcodeproj \
        -scheme Scout \
        -configuration Release \
        -destination 'platform=macOS' \
        -allowProvisioningUpdates \
        CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
        build >"$LOG" 2>&1; then
    echo "The build failed."
    echo
    # The compiler's own error lines, not the thousands of lines of noise around them.
    grep -E "error:" "$LOG" | head -8 | sed 's/^.*\/\([^/]*\.swift\)/\1/' || tail -12 "$LOG"
    echo
    echo "Full log: $LOG"
    exit 1
fi

[[ -d "$APP" ]] || { echo "The build reported success but produced no app. Full log: $LOG"; exit 1; }

if [[ "$LAUNCH" == "0" ]]; then
    echo "Built. Not launching (--build)."
    exit 0
fi

# ── 3. Quit the copy that is already running ────────────────────────────────────────────────────
# Scout has no Dock icon and no window, so a stale copy is invisible: the only sign is that the
# new code isn't there. Worth being thorough about.
FORCED=0
osascript -e 'tell application id "studio.stonemesa.scout" to quit' >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Scout >/dev/null || break
    sleep 0.3
done
if pgrep -x Scout >/dev/null; then
    pkill -9 -x Scout >/dev/null 2>&1
    FORCED=1
    sleep 0.5
fi

# ── 4. Launch ───────────────────────────────────────────────────────────────────────────────────
# Through `open`, never by running the binary directly: a directly-executed binary is a different
# thing to macOS and does not carry the app's permissions with it.
#
# Worth retrying rather than giving up. The build replaces the bundle at a path LaunchServices
# already knows, and for a second or two afterwards `open` can answer -600 (procNotFound) — it is
# still holding the registration for the copy that was just quit. Waiting it out fixes it; if it
# does not, re-registering the bundle does.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
LAUNCH_ERROR=""

launch_app() {
    LAUNCH_ERROR="$(open "$APP" 2>&1)"
    [[ -z "$LAUNCH_ERROR" ]]
}

if ! launch_app; then
    sleep 1
    if ! launch_app; then
        [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1
        sleep 1
        if ! launch_app; then
            echo "Built successfully, but macOS wouldn't launch it."
            echo
            echo "$LAUNCH_ERROR"
            echo
            echo "Opening it from the Finder usually works: $APP"
            exit 1
        fi
    fi
fi

# `open` returns as soon as the request is accepted, which is not the same as the app running.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Scout >/dev/null && break
    sleep 0.3
done
if ! pgrep -x Scout >/dev/null; then
    echo "macOS accepted the launch but Scout isn't running. The app is at: $APP"
    exit 1
fi

if [[ "$FORCED" == "1" ]]; then
    echo "Scout rebuilt and relaunched. The old copy had to be forced to quit."
else
    echo "Scout rebuilt and relaunched."
fi

# ── 5. Warn about another Scout that would shadow this one ──────────────────────────────────────
# A copy in /Applications answers to Spotlight, the Dock and `open -a Scout` by name — so the one
# that starts at login could quietly be an older build, with its own set of permissions.
INSTALLED="/Applications/Scout.app"
if [[ -d "$INSTALLED" ]]; then
    THIS_BUILT=$(stat -f %m "$APP/Contents/MacOS/Scout" 2>/dev/null || echo 0)
    THAT_BUILT=$(stat -f %m "$INSTALLED/Contents/MacOS/Scout" 2>/dev/null || echo 0)
    if (( THAT_BUILT < THIS_BUILT )); then
        echo
        echo "Heads up: there is an older Scout in your Applications folder. Opening Scout"
        echo "from Spotlight or the Dock gets that one, not this build."
    fi
fi
exit 0

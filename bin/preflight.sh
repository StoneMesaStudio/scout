#!/usr/bin/env bash
#
# preflight.sh — the one command to run before shipping this app.
#
# It rebuilds the Xcode project from project.yml, then builds (and, where the
# app has them, tests) every platform this app ships on, plus any Node backend.
# If anything fails it exits non-zero — which is what stops a TestFlight upload
# when this script is wired into the deploy script.
#
# WHAT gets checked is defined per-app in bin/preflight.conf (next to this file).
# This script itself is byte-for-byte identical in every app, so a fix made here
# can be copied verbatim to the others.
#
# Usage:
#   bin/preflight.sh            # run the full check
#   bin/preflight.sh --dry-run  # print what it WOULD run, without running it
#
# Escape hatch (when wired into a deploy script):
#   SKIP_PREFLIGHT=1 bin/upload-to-testflight.sh
#
# Override the iOS simulator used for tests:
#   PREFLIGHT_IOS_DEST='platform=iOS Simulator,name=iPhone 16' bin/preflight.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

DRYRUN="${PREFLIGHT_DRYRUN:-0}"
for a in "$@"; do
  case "$a" in
    --dry-run|-n) DRYRUN=1 ;;
    -h|--help)    sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "preflight: unknown argument: $a" >&2; exit 2 ;;
  esac
done

CONF="$ROOT/bin/preflight.conf"
[ -f "$CONF" ] || { echo "preflight: missing $CONF" >&2; exit 2; }
APP_NAME=""; CHECKS=(); BACKENDS=()
# shellcheck disable=SC1090
source "$CONF"

PROJ="$(ls -d ./*.xcodeproj 2>/dev/null | head -1 || true)"; PROJ="${PROJ#./}"

# ---- pretty helpers -------------------------------------------------------
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }

FAILED=""
trap '[ -n "$FAILED" ] && { echo; bad "PREFLIGHT FAILED at: $FAILED"; exit 1; }' EXIT

# ---- destination tokens ---------------------------------------------------
ios_sim_dest() {
  if [ -n "${PREFLIGHT_IOS_DEST:-}" ]; then printf '%s' "$PREFLIGHT_IOS_DEST"; return; fi
  local name
  name="$(xcrun simctl list devices available 2>/dev/null \
        | sed -nE 's/^[[:space:]]*(iPhone [0-9][0-9]*)[[:space:]]*\(.*/\1/p' \
        | sort -t' ' -k2 -n | tail -1)"
  [ -n "$name" ] && printf 'platform=iOS Simulator,name=%s' "$name" \
                 || printf 'platform=iOS Simulator,name=iPhone 17'
}
expand_dest() {
  case "$1" in
    macos)         printf 'platform=macOS' ;;
    ios-sim)       ios_sim_dest ;;
    ios-generic)   printf 'generic/platform=iOS Simulator' ;;
    watch-generic) printf 'generic/platform=watchOS Simulator' ;;
    *)             printf '%s' "$1" ;;   # already a full -destination string
  esac
}

bold "Preflight — ${APP_NAME:-$(basename "$ROOT")}  ($PROJ)"
[ "$DRYRUN" = 1 ] && echo "(dry run — nothing will actually build)"

# ---- regenerate the project from project.yml ------------------------------
if [ -f project.yml ]; then
  if command -v xcodegen >/dev/null 2>&1; then
    step "xcodegen generate"
    if [ "$DRYRUN" = 1 ]; then echo "  would run: xcodegen generate"
    else xcodegen generate >/dev/null && ok "project regenerated from project.yml"; fi
  else
    echo "  (xcodegen not installed — using the committed $PROJ as-is)"
  fi
fi

# ---- xcode builds / tests -------------------------------------------------
have_xcbeautify=0; command -v xcbeautify >/dev/null 2>&1 && have_xcbeautify=1

run_xcode() {  # $1 scheme  $2 dest  $3 action(build|test)
  local scheme="$1" dest="$2" action="$3"
  # ⚠️ -derivedDataPath IS LOAD-BEARING. Without it this writes `CODE_SIGNING_ALLOWED=NO` output into
  # the SAME Build/Products/Debug/Lode.app that Xcode signs — so running the gate silently REPLACES the
  # runnable app with an unsigned one. An unsigned app has no entitlements, and on macOS that means
  # NO SANDBOX: it quietly switches to `~/Library/Application Support/default.store` and
  # `~/Library/Preferences/…plist` instead of its container, and the data-protection keychain refuses
  # it (errSecMissingEntitlement), so no backup key can be created.
  #
  # That cost most of 2026-08-09. Every fix was built, gated, launched — and the gate de-signed the very
  # build being tested, so John was testing an unsandboxed app against a different database while I
  # inspected the container and saw a state that had nothing to do with what was on his screen.
  # The gate gets its own DerivedData; it must never touch the app anyone runs.
  local cmd=(xcodebuild -project "$PROJ" -scheme "$scheme" -destination "$dest"
             -configuration Debug CODE_SIGNING_ALLOWED=NO
             -derivedDataPath build/preflight)
  [ "$action" = test ] && cmd+=(-parallel-testing-enabled NO)
  cmd+=("$action")
  if [ "$DRYRUN" = 1 ]; then echo "  would run: ${cmd[*]}"; return 0; fi
  if [ "$have_xcbeautify" = 1 ]; then "${cmd[@]}" | xcbeautify --renderer terminal
  else "${cmd[@]}"; fi
}

if [ "${#CHECKS[@]}" -gt 0 ]; then
  for entry in "${CHECKS[@]}"; do
    [ -z "$entry" ] && continue
    IFS='|' read -r label scheme desttok action <<<"$entry"
    label="$(echo "$label" | xargs)"; scheme="$(echo "$scheme" | xargs)"
    desttok="$(echo "$desttok" | xargs)"; action="$(echo "$action" | xargs)"
    dest="$(expand_dest "$desttok")"
    step "$label — $action  [$scheme]"
    echo "  destination: $dest"
    FAILED="$label ($scheme)"
    run_xcode "$scheme" "$dest" "$action"
    ok "$label passed"
    FAILED=""
  done
fi

# ---- node backends --------------------------------------------------------
if [ "${#BACKENDS[@]}" -gt 0 ]; then
  for b in "${BACKENDS[@]}"; do
    [ -z "$b" ] && continue
    step "backend — $b  (npm ci && npm test)"
    FAILED="backend $b"
    if [ "$DRYRUN" = 1 ]; then echo "  would run: (cd $b && npm ci && npm test)"
    else ( cd "$b" && npm ci --silent && npm test ); fi
    ok "backend $b passed"
    FAILED=""
  done
fi

echo
if [ "$DRYRUN" = 1 ]; then bold "Dry run complete — the commands above are what preflight would run."
else bold "✅ PREFLIGHT PASSED — ${APP_NAME:-app} builds and tests clean."; fi

#!/usr/bin/env bash
#
# release.sh — build, sign, notarise and package Scout for direct download.
#
# Scout does not go through the App Store, so Apple's blessing arrives a different way: the app is
# signed with a Developer ID certificate, sent to Apple's notary service, and the resulting ticket
# is *stapled* into the app and the disk image. Stapling is the part people forget — without it a
# Mac that is offline, or behind a captive portal, refuses to open the app.
#
#   bin/release.sh              # the full thing
#   bin/release.sh --dry-run    # print what it would do
#
# Escape hatch, for when the gate is the thing that is broken:
#   SKIP_PREFLIGHT=1 bin/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run|-n) DRY=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "release: unknown argument: $a" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then echo "  would run: $*"; else "$@"; fi; }

APP_NAME="Scout"
BUNDLE_ID="studio.stonemesa.scout"
TEAM_ID="RD59TDS75G"
DIST="$ROOT/dist"
BUILD="$ROOT/build/release-signed"
APP="$BUILD/$APP_NAME.app"

VERSION="$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?/\1/p' project.yml | head -1)"
[ -n "$VERSION" ] || die "Could not read MARKETING_VERSION out of project.yml."
DMG="$DIST/$APP_NAME-$VERSION.dmg"

bold "Releasing $APP_NAME $VERSION"

# ---- 1. The certificate ---------------------------------------------------
# A "Developer ID Application" certificate is a different thing from the "Apple Distribution"
# certificate used for TestFlight, and only it can be notarised. Nothing below works without one.
step "Developer ID certificate"
IDENTITY="$(security find-identity -v -p codesigning \
    | sed -nE 's/.*"(Developer ID Application: .*)"/\1/p' | head -1)"
if [ -z "$IDENTITY" ]; then
  die "No Developer ID Application certificate on this Mac.

  Xcode ▸ Settings ▸ Accounts ▸ Stone Mesa Studio, LLC ▸ Manage Certificates…
  then the + at the bottom left ▸ Developer ID Application.

  It takes about thirty seconds and only the account holder can do it. The
  \"Apple Distribution\" certificate already installed is for TestFlight and the
  App Store; the notary service will not accept it."
fi
ok "$IDENTITY"

# ---- 2. Notary credentials ------------------------------------------------
# The issuer is team-wide, so the key any of the studio's apps uses works here too.
step "Notary credentials"
CREDS=""
for candidate in "$HOME/.appstoreconnect/scout.env" "$HOME/.appstoreconnect/catchall.env"; do
  [ -f "$candidate" ] && { CREDS="$candidate"; break; }
done
[ -n "$CREDS" ] || die "No App Store Connect credentials found.

  Expected ~/.appstoreconnect/scout.env or ~/.appstoreconnect/catchall.env with:
    APP_STORE_CONNECT_KEY_ID=...
    APP_STORE_CONNECT_ISSUER_ID=...
    APP_STORE_CONNECT_KEY_PATH=\$HOME/.appstoreconnect/private_keys/AuthKey_<ID>.p8"
# shellcheck disable=SC1090
source "$CREDS"
: "${APP_STORE_CONNECT_KEY_ID:?missing in $CREDS}"
: "${APP_STORE_CONNECT_ISSUER_ID:?missing in $CREDS}"
: "${APP_STORE_CONNECT_KEY_PATH:?missing in $CREDS}"
[ -f "$APP_STORE_CONNECT_KEY_PATH" ] || die "Key file not found: $APP_STORE_CONNECT_KEY_PATH"
ok "using $(basename "$CREDS")"

# ---- 3. The gate ----------------------------------------------------------
if [ "${SKIP_PREFLIGHT:-0}" = 1 ]; then
  echo "  (preflight skipped by SKIP_PREFLIGHT=1)"
else
  step "Preflight"
  run bin/preflight.sh
fi

# ---- 4. Build, signed for distribution ------------------------------------
step "Build"
run rm -rf "$BUILD" "$DIST"
run mkdir -p "$BUILD" "$DIST"
run xcodegen generate
run xcodebuild \
  -project Scout.xcodeproj -scheme Scout -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/release-derived \
  CONFIGURATION_BUILD_DIR="$BUILD" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build
[ "$DRY" = 1 ] || [ -d "$APP" ] || die "The build reported success but produced no app at $APP"
ok "built"

# ---- 5. Check the signature before Apple does -----------------------------
# Cheaper to fail here than to wait out a notary round trip and be told the same thing.
step "Verify the signature"
if [ "$DRY" = 0 ]; then
  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

  # Captured, not piped. `codesign -dvv | grep -q` looks like the obvious check and is a trap:
  # grep exits the moment it matches, codesign takes SIGPIPE, and under `pipefail` the pipeline
  # reports failure — so a build that is perfectly correct fails the test for having passed it.
  DESCRIPTION="$(codesign -dvv "$APP" 2>&1 || true)"
  printf '%s\n' "$DESCRIPTION" | grep -E "Authority|Timestamp|flags" | sed 's/^/  /'

  case "$DESCRIPTION" in
    *"flags="*runtime*) ;;
    *) die "The hardened runtime is not on. Notarisation will refuse this build." ;;
  esac
  ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
  [ -n "$ENTITLEMENTS" ] || die "Entitlements are unreadable."

  # The debug entitlement. `xcodebuild build` injects it; `xcodebuild archive` does not, which is
  # why this only ever bites the first time somebody ships without archiving. Apple's notary
  # service rejects it outright, and finding that out costs a full round trip — so it is checked
  # here, where the answer is instant.
  case "$ENTITLEMENTS" in
    *get-task-allow*)
      die "The build carries com.apple.security.get-task-allow — the debug entitlement.
  Notarisation refuses it. CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO is what keeps it out." ;;
  esac
fi
ok "signed with a timestamp and the hardened runtime"

# ---- 6. Notarise the app --------------------------------------------------
# The app is notarised on its own first, then stapled, and only then packaged — so the ticket
# travels with the app even after somebody drags it out of the disk image.
step "Notarise the app"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
run /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
run xcrun notarytool submit "$ZIP" \
  --key "$APP_STORE_CONNECT_KEY_PATH" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait
run xcrun stapler staple "$APP"
run rm -f "$ZIP"
ok "notarised and stapled"

# ---- 7. Disk image --------------------------------------------------------
step "Disk image"
STAGE="$DIST/stage"
run mkdir -p "$STAGE"
run cp -R "$APP" "$STAGE/"
# The Applications symlink is the whole of the install instructions.
run ln -s /Applications "$STAGE/Applications"
run hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
run rm -rf "$STAGE"
run codesign --sign "$IDENTITY" --timestamp "$DMG"
ok "$(basename "$DMG")"

# ---- 8. Notarise the disk image too ---------------------------------------
# Otherwise the first thing a new user sees is Gatekeeper refusing the download itself.
step "Notarise the disk image"
run xcrun notarytool submit "$DMG" \
  --key "$APP_STORE_CONNECT_KEY_PATH" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait
run xcrun stapler staple "$DMG"
ok "notarised and stapled"

# ---- 9. What a stranger's Mac will say ------------------------------------
step "What a stranger's Mac will say"
if [ "$DRY" = 0 ]; then
  spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  /'
  xcrun stapler validate "$DMG" 2>&1 | sed 's/^/  /'
fi

echo
bold "✅ $(basename "$DMG") is ready to publish."
echo "   $DMG"
echo
echo "Next: copy it into the download page's assets and deploy the site."

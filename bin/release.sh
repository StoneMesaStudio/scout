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

# ---- 4b. Re-sign what Sparkle brought with it -----------------------------
# `xcodebuild build` signs the app and the frameworks it links, and leaves the helpers *inside*
# Sparkle.framework ad-hoc signed — the updater, the auto-updater and the two XPC services. Apple's
# notary service refuses ad-hoc signed code inside a Developer ID app, and `codesign --verify
# --deep --strict` says nothing about it, so the first sign of trouble would be a notary rejection
# twenty minutes later.
#
# Signed inside out, deepest first: signing a container seals whatever is inside it, so anything
# re-signed afterwards breaks the seal above it.
step "Re-sign Sparkle's helpers"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ "$DRY" = 0 ] && [ -d "$SPARKLE" ]; then
  KEEP="$(mktemp -d)"
  for nested in \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/Updater.app" \
    "$SPARKLE/Versions/B/Autoupdate" \
    "$SPARKLE"
  do
    [ -e "$nested" ] || continue

    # Every one of these carries its own entitlements. `codesign --force` without them signs them
    # away, and an updater missing an entitlement fails at the moment somebody tries to update —
    # long after any build would have caught it. So they are read off and handed straight back.
    SAVED="$KEEP/$(basename "$nested").plist"
    codesign -d --entitlements - --xml "$nested" >"$SAVED" 2>/dev/null || true

    if [ -s "$SAVED" ]; then
      codesign --force --timestamp --options runtime --entitlements "$SAVED" \
        --sign "$IDENTITY" "$nested" >/dev/null 2>&1 || die "Could not re-sign $(basename "$nested")."
    else
      codesign --force --timestamp --options runtime \
        --sign "$IDENTITY" "$nested" >/dev/null 2>&1 || die "Could not re-sign $(basename "$nested")."
    fi
    printf '  signed %s\n' "${nested#$APP/Contents/Frameworks/}"
  done
  rm -rf "$KEEP"

  # The app itself last, and with its own entitlements: re-signing anything inside it broke the
  # seal above, and a bare --force here is what silently strips the app's entitlements.
  codesign --force --timestamp --options runtime \
    --entitlements "$ROOT/App/Support/Scout.entitlements" \
    --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || die "Could not re-sign the app."
  printf '  signed %s\n' "$APP_NAME.app"

  ok "Sparkle's helpers carry the Developer ID, and their entitlements survived"
elif [ "$DRY" = 1 ]; then
  echo "  would re-sign Sparkle's nested helpers, deepest first, preserving their entitlements"
fi

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

  # Nothing inside may be ad-hoc signed. `--deep --strict` above does not check this, which is
  # exactly how Sparkle's helpers sailed through it and would have been refused by the notary.
  ADHOC=""
  while IFS= read -r nested; do
    case "$(codesign -dvv "$nested" 2>&1 || true)" in
      *adhoc*) ADHOC="$ADHOC
  $(printf '%s' "${nested#$APP/}")" ;;
    esac
  done <<EOF
$(find "$APP/Contents/Frameworks" -maxdepth 6 \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" -o -name "Autoupdate" \) 2>/dev/null)
EOF
  [ -z "$ADHOC" ] || die "These are still ad-hoc signed and the notary will refuse them:$ADHOC"
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

# ---- 10. The line the appcast needs ---------------------------------------
# Signed here, after stapling: `stapler staple` rewrites the disk image, so a signature taken
# before it describes a file that no longer exists. The private key lives in the login Keychain
# and never leaves this Mac; losing it means no existing copy of Scout can be updated again.
step "Sign the update"
SIGN_UPDATE="$(find build/release-derived/SourcePackages/artifacts -name sign_update -type f 2>/dev/null | grep -v old_dsa | head -1)"
if [ "$DRY" = 0 ] && [ -n "$SIGN_UPDATE" ]; then
  BUILD_NUMBER="$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"?([^"]+)"?/\1/p' project.yml | head -1)"
  SIGNATURE="$("$SIGN_UPDATE" "$DMG")"
  ok "signed for Sparkle"
  echo
  bold "Paste this into downloads/scout-appcast.xml, newest item first:"
  cat <<ITEM

    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0.0</sparkle:minimumSystemVersion>
      <pubDate>$(date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <description><![CDATA[<ul><li>Say what changed here.</li></ul>]]></description>
      <enclosure url="https://apps.stonemesastudio.com/downloads/$(basename "$DMG")"
                 $SIGNATURE type="application/octet-stream"/>
    </item>
ITEM
elif [ "$DRY" = 1 ]; then
  echo "  would sign the disk image with the Sparkle key and print its appcast entry"
else
  echo "  sign_update not found — resolve packages first, or the appcast entry cannot be made."
fi

echo
bold "✅ $(basename "$DMG") is ready to publish."
echo "   $DMG"
echo
echo "Next: add the item above to downloads/scout-appcast.xml, copy the disk image into"
echo "downloads/, and deploy the site. Leave the older disk images where they are — a copy of"
echo "Scout still on an old version reads its own item out of that file."

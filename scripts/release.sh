#!/usr/bin/env bash
#
# release.sh — cut a signed, notarized, Sparkle-updatable release.
#
#   build+sign .app  ->  DMG  ->  notarize + staple  ->  update appcast  ->  GitHub release
#
# Prerequisites (all configured in app.yml + your machine — see RELEASE.md):
#   - Developer ID Application certificate in the login keychain
#   - notarytool credential profile (xcrun notarytool store-credentials)
#   - Sparkle Ed25519 key pair (generate_keys); public key in app.yml
#   - gh authenticated (gh auth status)
#
# Usage:
#   scripts/release.sh --version 1.0.0 [--build N] [--notes path/to/notes.md] [--prerelease]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="app.yml"
yaml_get() { sed -n "s/^$1:[[:space:]]*\"\{0,1\}\([^\"#]*[^\"# ]\)\"\{0,1\}.*/\1/p" "$CONFIG" | head -1; }

APP_NAME="$(yaml_get app_name)"
DEV_ID="$(yaml_get developer_id_application)"
TEAM_ID="$(yaml_get apple_team_id)"
PROFILE="${PHOTO_SEARCH_NOTARY_PROFILE:-$(yaml_get notarytool_keychain_profile)}"
ED_KEY="$(yaml_get sparkle_public_ed_key)"
DOWNLOAD_BASE="$(yaml_get download_base_url)"

VERSION=""
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
NOTES=""
PRERELEASE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)    VERSION="$2"; shift 2 ;;
    --build)      BUILD="$2";   shift 2 ;;
    --notes)      NOTES="$2";   shift 2 ;;
    --prerelease) PRERELEASE=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$VERSION" ]] || { echo "error: --version X.Y.Z is required" >&2; exit 2; }

# Fail early if the distribution identity isn't configured yet.
missing=()
[[ "$DEV_ID" == *"YOUR NAME"* || -z "$DEV_ID" ]] && missing+=("developer_id_application")
[[ "$TEAM_ID" == "TEAMID"     || -z "$TEAM_ID" ]] && missing+=("apple_team_id")
[[ "$ED_KEY"  == *"TODO"*     || -z "$ED_KEY"  ]] && missing+=("sparkle_public_ed_key")
if (( ${#missing[@]} )); then
  echo "error: set these in app.yml before releasing (see RELEASE.md): ${missing[*]}" >&2
  exit 1
fi

SPARKLE_BIN="$(find .build/artifacts -path '*Sparkle/bin' -type d | head -1)"
[[ -n "$SPARKLE_BIN" ]] || { swift build >/dev/null; SPARKLE_BIN="$(find .build/artifacts -path '*Sparkle/bin' -type d | head -1)"; }

echo "==> Releasing $APP_NAME $VERSION (build $BUILD)"

# 1. Build + sign the .app.
scripts/build_app.sh --version "$VERSION" --build "$BUILD"
APP="dist/$APP_NAME.app"

# 2. Package a DMG without spaces so GitHub Releases and Sparkle appcast URLs match.
DMG_SLUG="${APP_NAME// /}"
DMG="dist/${DMG_SLUG}-v${VERSION}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# 3. Sign, notarize the DMG, and staple tickets to both DMG and .app.
codesign --force --timestamp --sign "$DEV_ID" "$DMG"
NOTARY_ARGS=(--keychain-profile "$PROFILE")
if [[ -n "${PHOTO_SEARCH_NOTARY_KEY:-}" && -n "${PHOTO_SEARCH_NOTARY_KEY_ID:-}" && -n "${PHOTO_SEARCH_NOTARY_ISSUER:-}" ]]; then
  NOTARY_ARGS=(--key "$PHOTO_SEARCH_NOTARY_KEY" --key-id "$PHOTO_SEARCH_NOTARY_KEY_ID" --issuer "$PHOTO_SEARCH_NOTARY_ISSUER")
fi
echo "==> Notarizing (this waits on Apple)…"
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# 4. Regenerate the appcast (generate_appcast reads the private key from the
#    keychain and signs each archive). Keep past DMGs in dist/updates to retain
#    the full version history in the feed.
UPDATES="dist/updates"
mkdir -p "$UPDATES"
cp "$DMG" "$UPDATES/"
"$SPARKLE_BIN/generate_appcast" "$UPDATES" --download-url-prefix "$DOWNLOAD_BASE/v$VERSION/"
cp "$UPDATES/appcast.xml" ./appcast.xml

# 5. Publish the GitHub release with the DMG attached.
NOTES_ARG=(--generate-notes)
[[ -n "$NOTES" ]] && NOTES_ARG=(--notes-file "$NOTES")
PRERELEASE_ARG=()
[[ "$PRERELEASE" == 1 ]] && PRERELEASE_ARG=(--prerelease)
gh release create "v$VERSION" "$DMG" --target "$(git rev-parse HEAD)" --title "$APP_NAME $VERSION" "${PRERELEASE_ARG[@]}" "${NOTES_ARG[@]}"

echo
echo "==> Done. Commit and push the updated appcast.xml so the feed URL serves it:"
echo "    git add appcast.xml && git commit -m 'Release $VERSION' && git push"

#!/bin/zsh
# Builds build/Thuner.app (universal: Apple silicon + Intel) and signs it.
#   Scripts/build-app.sh                    development build, signed with SIGN_IDENTITY (ad-hoc unless set)
#   TIMESTAMP=1 Scripts/build-app.sh        release build: secure timestamp for notarization, plus the update-check
#                                           stats settings (Scripts/release.sh sets it)
#   SIGN_IDENTITY=- Scripts/build-app.sh    ad-hoc signed (ShazamKit matching won't work)
# Signing identity, bundle ID and the rest come from Scripts/config.local.sh (see Scripts/config.example.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
[[ -f Scripts/config.local.sh ]] && source Scripts/config.local.sh

SIGN_IDENTITY=${SIGN_IDENTITY:--}
APP=build/Thuner.app
ARCHS=(--arch arm64 --arch x86_64)
if [[ ${TIMESTAMP:-0} == 1 ]]; then STAMP=(--timestamp); else STAMP=(--timestamp=none); fi

swift build -c release --product Thuner $ARCHS
BIN_DIR=$(swift build -c release --show-bin-path $ARCHS)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Thuner" "$APP/Contents/MacOS/Thuner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n ${BUNDLE_ID:-} ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
fi
if [[ ${TIMESTAMP:-0} != 1 ]]; then
  # Dev build: mark it, and give it a build number no release will beat so Sparkle never "updates" it to an
  # older public version.
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION-dev" -c "Set :CFBundleVersion 999999999999" "$APP/Contents/Info.plist"
elif [[ -n ${STATS_ENDPOINT:-} && -n ${STATS_WEBSITE_ID:-} ]]; then
  # Releases only: where the anonymous update-check stats go (UsageStats). Development builds and builds from
  # source without these send nothing.
  /usr/libexec/PlistBuddy -c "Add :ThunerStatsEndpoint string $STATS_ENDPOINT" \
    -c "Add :ThunerStatsWebsiteID string $STATS_WEBSITE_ID" "$APP/Contents/Info.plist"
  echo "Embedded the update-check stats settings"
fi
# Build in the Last.fm API key and secret saved on this Mac (Settings → Scrobbling stores them in the Keychain),
# so other Macs only need to approve ThUNER on last.fm. They never go into source control.
if LASTFM_JSON=$(security find-generic-password -s com.idallas.thuner -a lastfm-credentials -w 2>/dev/null); then
  python3 - "$APP/Contents/Info.plist" "$LASTFM_JSON" <<'PY'
import json, plistlib, sys
path, creds = sys.argv[1], json.loads(sys.argv[2])
with open(path, "rb") as f: info = plistlib.load(f)
info["LastFMAPIKey"], info["LastFMSharedSecret"] = creds["apiKey"], creds["secret"]
with open(path, "wb") as f: plistlib.dump(info, f)
PY
  echo "Embedded the Last.fm API key"
else
  echo "warning: no Last.fm API key in the Keychain; the app will ask for one in Settings" >&2
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# ditto keeps the framework's symlinks intact.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# Sign inside-out, as Sparkle's docs prescribe for a Developer ID app (no --deep).
sign() { codesign --force --options runtime $STAMP --sign "$SIGN_IDENTITY" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --entitlements Resources/Thuner.entitlements "$APP"

codesign --verify --deep --strict --verbose=1 "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Thuner"))"

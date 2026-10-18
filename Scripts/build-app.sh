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
swift build -c release --product ThunerWidget $ARCHS
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

# Shortcuts actions: the Shortcuts app finds them through Metadata.appintents, which Xcode generates from the
# compiler's constant values and SwiftPM doesn't. Run that step here (the metadata doesn't depend on the arch).
INTERMEDIATES=.build/out/Intermediates.noindex/Thuner.build/Release/Thuner-p.build/Objects-normal/arm64
if [[ -f $INTERMEDIATES/Thuner.SwiftFileList ]] && ls $INTERMEDIATES/*.swiftconstvalues >/dev/null 2>&1; then
  CONSTS=$(mktemp)
  ls $PWD/$INTERMEDIATES/*.swiftconstvalues > "$CONSTS"
  xcrun appintentsmetadataprocessor --quiet-warnings \
    --output "$APP/Contents/Resources" \
    --toolchain-dir "$(xcrun --find swift | sed 's|/usr/bin/swift$||')" \
    --module-name Thuner \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
    --platform-family macOS --deployment-target 15.0 --target-triple arm64-apple-macos15.0 \
    --source-file-list "$INTERMEDIATES/Thuner.SwiftFileList" \
    --swift-const-vals-list "$CONSTS" >/dev/null
  rm -f "$CONSTS"
  [[ -d "$APP/Contents/Resources/Metadata.appintents" ]] || { echo "No Shortcuts metadata generated" >&2; exit 1; }
else
  echo "warning: no compiler constant values found; Shortcuts actions won't be listed" >&2
fi
# ditto keeps the framework's symlinks intact.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# The widget: a WidgetKit extension, versioned like the app, with its ID under the app's.
WIDGET="$APP/Contents/PlugIns/ThunerWidget.appex"
mkdir -p "$WIDGET/Contents/MacOS"
cp "$BIN_DIR/ThunerWidget" "$WIDGET/Contents/MacOS/ThunerWidget"
python3 - "$APP/Contents/Info.plist" "$WIDGET/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f: app = plistlib.load(f)
widget = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": "ThUNER",
    "CFBundleExecutable": "ThunerWidget",
    "CFBundleIdentifier": app["CFBundleIdentifier"] + ".widget",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "ThunerWidget",
    "CFBundlePackageType": "XPC!",
    "CFBundleShortVersionString": app["CFBundleShortVersionString"],
    "CFBundleVersion": app["CFBundleVersion"],
    "LSMinimumSystemVersion": app.get("LSMinimumSystemVersion", "15.0"),
    "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"},
}
with open(sys.argv[2], "wb") as f: plistlib.dump(widget, f)
PY

# Sign inside-out, as Sparkle's docs prescribe for a Developer ID app (no --deep).
sign() { codesign --force --options runtime $STAMP --sign "$SIGN_IDENTITY" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
# Widget extensions must be sandboxed; it only needs to reach ThUNER's own http://127.0.0.1:47480.
sign --entitlements Resources/ThunerWidget.entitlements "$WIDGET"
sign --entitlements Resources/Thuner.entitlements "$APP"

codesign --verify --deep --strict --verbose=1 "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Thuner"))"

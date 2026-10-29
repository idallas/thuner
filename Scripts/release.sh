#!/bin/zsh
# Builds, notarizes and packages a release, then updates the Sparkle appcast and the download button.
#
#   Scripts/release.sh 1.0.0 "What's new, as one line or simple HTML"
#   Scripts/deploy-website.sh          # then publish
#
# Testing channel: CHANNEL=testing Scripts/release.sh 1.3.3-beta.1 "notes" puts the build in the appcast for Macs
# with Settings → Updates → "Get test builds" on (Sparkle channels), and leaves the website's download button alone.
# Scripts/promote-release.sh 1.3.3-beta.1 later makes that build everyone's (stable).
#
# The website files (appcast, release notes, downloads, the ThUNER page) live in a separate repo; WEBSITE_DIR in
# Scripts/config.local.sh points at its software/ folder. Commit the changes there after a release.
#
# One-time setup on the Mac that makes releases:
#   - The Sparkle EdDSA private key in the login Keychain (account "thuner"), from
#       .build/artifacts/sparkle/Sparkle/bin/generate_keys --account thuner
#     Back it up: generate_keys --account thuner -x thuner-sparkle-key.txt (and keep that file somewhere safe).
#   - Notary credentials in the Keychain:
#       xcrun notarytool store-credentials thuner-notary --apple-id <apple id> --team-id <team id>
#   - Scripts/config.local.sh with the Developer ID to sign with (see Scripts/config.example.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
[[ -f Scripts/config.local.sh ]] && source Scripts/config.local.sh
if [[ ${SIGN_IDENTITY:--} == - ]]; then
  echo "error: releases need a Developer ID; set SIGN_IDENTITY in Scripts/config.local.sh" >&2
  exit 1
fi
: ${WEBSITE_DIR:?set WEBSITE_DIR in Scripts/config.local.sh (see Scripts/config.example.sh)}

VERSION=${1:?usage: Scripts/release.sh <version> [release notes]}
NOTES=${2:-}
# Versions restarted at 0.14.0 after 1.3.5. The 1.x numbers already shipped stay retired, so a later 1.x can't be
# mistaken for (or overwrite the zip of) an old one: 1.0.0, 1.0.1 and the whole of 1.1–1.3.
case $VERSION in
  1.0.0|1.0.0-*|1.0.1|1.0.1-*|1.[123]|1.[123].*|1.[123]-*)
    echo "error: $VERSION is a retired version number (1.0.0, 1.0.1 and 1.1–1.3 shipped before the restart at 0.14.0)" >&2; exit 1 ;;
esac
if [[ -e $WEBSITE_DIR/thuner/updates/ThUNER-$VERSION.zip ]] || grep -q "<sparkle:shortVersionString>$VERSION<" "$WEBSITE_DIR/thuner/appcast.xml"; then
  echo "error: $VERSION has been released already" >&2; exit 1
fi
NOTARY_PROFILE=${NOTARY_PROFILE:-thuner-notary}
BUILD_NUMBER=$(date -u +%Y%m%d%H%M)   # always increasing, which is what Sparkle compares
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
UPDATES=$WEBSITE_DIR/thuner/updates
ZIP_NAME=ThUNER-$VERSION.zip
CHANNEL=${CHANNEL:-}
CHANNEL_ARGS=()
if [[ -n $CHANNEL ]]; then
  [[ $CHANNEL == testing ]] || { echo "error: the only channel is testing (CHANNEL=testing), or none for stable" >&2; exit 1; }
  CHANNEL_ARGS=(--channel "$CHANNEL")
fi
URL_PREFIX=https://idallas.com/software/thuner/updates/

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" Resources/Info.plist

TIMESTAMP=1 Scripts/build-app.sh

echo "Notarizing (this usually takes a few minutes)…"
ditto -c -k --keepParent build/Thuner.app build/notarize.zip
xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple build/Thuner.app
spctl --assess --type execute --verbose=2 build/Thuner.app
rm build/notarize.zip

mkdir -p "$UPDATES"
ditto -c -k --sequesterRsrc --keepParent build/Thuner.app "$UPDATES/$ZIP_NAME"
if [[ -n $NOTES ]]; then
  # generate_appcast picks up release notes from an .html file named like the archive.
  print -r -- "$NOTES" > "$UPDATES/ThUNER-$VERSION.html"
fi

"$SPARKLE_BIN/generate_appcast" --account thuner \
  --download-url-prefix "$URL_PREFIX" \
  --embed-release-notes \
  $CHANNEL_ARGS \
  -o "$WEBSITE_DIR/thuner/appcast.xml" \
  "$UPDATES"

if [[ -z $CHANNEL ]]; then
  Scripts/point-website.py "$VERSION" "$URL_PREFIX$ZIP_NAME" "$WEBSITE_DIR/thuner/index.html" "$WEBSITE_DIR/index.html"
else
  echo "Testing release: only Macs with \"Get test builds\" on will see it; the download button stays as it is."
fi

echo
echo "Released $VERSION (build $BUILD_NUMBER): $UPDATES/$ZIP_NAME"
echo "Publish with: Scripts/deploy-website.sh, then commit the website changes in $WEBSITE_DIR"

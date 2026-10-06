#!/bin/zsh
# Builds, notarizes and packages a release, then updates the Sparkle appcast and the download button.
#
#   Scripts/release.sh 1.0.0 "What's new, as one line or simple HTML"
#   Scripts/deploy-website.sh          # then publish
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
NOTARY_PROFILE=${NOTARY_PROFILE:-thuner-notary}
BUILD_NUMBER=$(date -u +%Y%m%d%H%M)   # always increasing, which is what Sparkle compares
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
UPDATES=$WEBSITE_DIR/thuner/updates
ZIP_NAME=ThUNER-$VERSION.zip
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
  -o "$WEBSITE_DIR/thuner/appcast.xml" \
  "$UPDATES"

# Point the download button at this version.
python3 - "$VERSION" "$URL_PREFIX$ZIP_NAME" "$WEBSITE_DIR/thuner/index.html" <<'EOF'
import re, sys
version, url, path = sys.argv[1], sys.argv[2], sys.argv[3]
html = open(path).read()
# data-umami-event makes Umami count clicks as a "Download ThUNER" event, with the version attached.
button = f'<a class="button" href="{url}" data-umami-event="Download ThUNER" data-umami-event-version="{version}">Download ThUNER {version}</a>'
html = re.sub(r"<!-- download -->.*?<!-- /download -->", f"<!-- download -->{button}<!-- /download -->", html, flags=re.S)
open(path, "w").write(html)
EOF

echo
echo "Released $VERSION (build $BUILD_NUMBER): $UPDATES/$ZIP_NAME"
echo "Publish with: Scripts/deploy-website.sh, then commit the website changes in $WEBSITE_DIR"

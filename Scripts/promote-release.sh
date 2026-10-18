#!/bin/zsh
# Makes a testing release everyone's: drops its Sparkle channel in the appcast, so every copy is offered it, and
# points the website's download button at it. Then Scripts/deploy-website.sh, and commit the website repo.
#
#   Scripts/promote-release.sh 1.3.3-beta.1
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f Scripts/config.local.sh ]] && source Scripts/config.local.sh
: ${WEBSITE_DIR:?set WEBSITE_DIR in Scripts/config.local.sh (see Scripts/config.example.sh)}
VERSION=${1:?usage: Scripts/promote-release.sh <version>}
APPCAST=$WEBSITE_DIR/thuner/appcast.xml

python3 - "$APPCAST" "$VERSION" <<'PY'
import re, sys
path, version = sys.argv[1], sys.argv[2]
xml = open(path).read()
found = False
def promote(match):
    global found
    item = match.group(0)
    if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" not in item:
        return item
    found = True
    return re.sub(r"\s*<sparkle:channel>[^<]*</sparkle:channel>", "", item)
xml = re.sub(r"<item>.*?</item>", promote, xml, flags=re.S)
if not found:
    sys.exit(f"error: no {version} in {path}")
open(path, "w").write(xml)
PY
Scripts/point-website.py "$VERSION" "https://idallas.com/software/thuner/updates/ThUNER-$VERSION.zip" \
  "$WEBSITE_DIR/thuner/index.html" "$WEBSITE_DIR/index.html"
echo "Promoted $VERSION to stable. Publish with Scripts/deploy-website.sh, then commit the website changes."

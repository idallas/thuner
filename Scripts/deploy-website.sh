#!/bin/zsh
# Uploads the website folder (WEBSITE_DIR) to DEPLOY_TARGET, and the release files to DOWNLOADS_BUCKET, all set
# in Scripts/config.local.sh. Adds and updates files; never deletes anything remote.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f Scripts/config.local.sh ]] && source Scripts/config.local.sh
: ${WEBSITE_DIR:?set WEBSITE_DIR in Scripts/config.local.sh (see Scripts/config.example.sh)}
[[ -n ${DEPLOY_TARGET:-} || -n ${DOWNLOADS_BUCKET:-} ]] ||
  { echo "error: set DEPLOY_TARGET and/or DOWNLOADS_BUCKET in Scripts/config.local.sh (see Scripts/config.example.sh)" >&2; exit 1; }
if [[ -n ${DEPLOY_TARGET:-} ]]; then
  rsync -avz --perms --exclude .DS_Store "$WEBSITE_DIR/" "$DEPLOY_TARGET"
  echo "Uploaded to $DEPLOY_TARGET"
fi

# Release files (appcast, release notes, zips and deltas) also go to object storage when DOWNLOADS_BUCKET is set:
# the site redirects /software/thuner/appcast.xml and /software/thuner/updates/… there and counts the downloads.
if [[ -n ${DOWNLOADS_BUCKET:-} ]]; then
  command -v rclone >/dev/null || { echo "error: install rclone (brew install rclone)" >&2; exit 1; }
  : ${DOWNLOADS_KEYS:=$HOME/.config/dreamobjects/idallas-downloads}
  : ${DOWNLOADS_ENDPOINT:=https://s3.us-east-005.dream.io}
  [[ -r $DOWNLOADS_KEYS ]] || { echo "error: no keys file at $DOWNLOADS_KEYS (ACCESS_KEY=… and SECRET_KEY=…)" >&2; exit 1; }
  (
    source "$DOWNLOADS_KEYS"
    export RCLONE_CONFIG_DL_TYPE=s3 RCLONE_CONFIG_DL_PROVIDER=Ceph RCLONE_CONFIG_DL_ENDPOINT=$DOWNLOADS_ENDPOINT \
      RCLONE_CONFIG_DL_ACCESS_KEY_ID=$ACCESS_KEY RCLONE_CONFIG_DL_SECRET_ACCESS_KEY=$SECRET_KEY RCLONE_CONFIG_DL_ACL=public-read
    src=$WEBSITE_DIR/thuner dest=dl:$DOWNLOADS_BUCKET/thuner
    # Zips and deltas never change once made; the appcast and release notes can.
    rclone copy "$src" "$dest" --include "/updates/*.zip" --include "/updates/*.delta" \
      --header-upload "Cache-Control: public, max-age=31536000, immutable" --stats-one-line -q
    rclone copy "$src" "$dest" --include "/updates/*.html" --header-upload "Cache-Control: public, max-age=3600" -q
    rclone copy "$src" "$dest" --include "/appcast.xml" --header-upload "Cache-Control: no-cache" -q
  )
  echo "Uploaded release files to $DOWNLOADS_BUCKET/thuner"
fi

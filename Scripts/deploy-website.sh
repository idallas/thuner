#!/bin/zsh
# Uploads the website folder (WEBSITE_DIR) to DEPLOY_TARGET, both set in Scripts/config.local.sh. Adds and
# updates files; never deletes anything remote.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f Scripts/config.local.sh ]] && source Scripts/config.local.sh
: ${WEBSITE_DIR:?set WEBSITE_DIR in Scripts/config.local.sh (see Scripts/config.example.sh)}
: ${DEPLOY_TARGET:?set DEPLOY_TARGET in Scripts/config.local.sh (see Scripts/config.example.sh)}
rsync -avz --perms --exclude .DS_Store "$WEBSITE_DIR/" "$DEPLOY_TARGET"
echo "Uploaded to $DEPLOY_TARGET"

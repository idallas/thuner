# Per-machine settings for the build, release and website scripts (a variable already set in the environment
# wins, so `SIGN_IDENTITY=- Scripts/build-app.sh` still works). Copy to Scripts/config.local.sh (which git
# ignores) and fill in what you need. Everything is optional for a plain development build.

# Code signing identity. "-" (the default) signs ad-hoc: the app runs on this Mac, but ShazamKit matching
# doesn't work (see README → Building). For Shazam, use a Developer ID from a paid team whose App ID has the
# ShazamKit App Service turned on, e.g. "Developer ID Application: Your Name (TEAMID1234)".
# SIGN_IDENTITY=${SIGN_IDENTITY:-"-"}

# Bundle ID to build with. Needs to match the App ID that has ShazamKit enabled.
# BUNDLE_ID=${BUNDLE_ID:-com.example.thuner}

# notarytool keychain profile used by Scripts/release.sh (xcrun notarytool store-credentials <profile> …).
# NOTARY_PROFILE=${NOTARY_PROFILE:-thuner-notary}

# Umami event API for anonymous update-check stats. Only built into releases made with Scripts/release.sh;
# without these, the app sends no stats at all.
# STATS_ENDPOINT=${STATS_ENDPOINT:-https://umami.example.com/api/send}
# STATS_WEBSITE_ID=${STATS_WEBSITE_ID:-00000000-0000-0000-0000-000000000000}

# The website folder Scripts/release.sh writes the appcast, release notes, downloads and download button into,
# and Scripts/deploy-website.sh uploads.
# WEBSITE_DIR=${WEBSITE_DIR:-$HOME/Projects/my-site/software}

# rsync destination for Scripts/deploy-website.sh.
# DEPLOY_TARGET=${DEPLOY_TARGET:-user@example.com:example.com/software/}

# Object storage bucket for the release files (appcast, release notes, zips, deltas), uploaded with rclone by
# the deploy script. The website redirects its old addresses there. Keys live outside the repo in a file with
# ACCESS_KEY=… and SECRET_KEY=… lines.
# DOWNLOADS_BUCKET=${DOWNLOADS_BUCKET:-my-downloads}
# DOWNLOADS_KEYS=${DOWNLOADS_KEYS:-$HOME/.config/dreamobjects/my-downloads}
# DOWNLOADS_ENDPOINT=${DOWNLOADS_ENDPOINT:-https://s3.us-east-005.dream.io}

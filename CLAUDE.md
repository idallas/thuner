# Thuner

A personal "now playing" toolkit for macOS. The name comes from the owner's old nickname (from the surname Bethune) and puns on "tuner."

## What it's for

ThUNER replaced a Shortcut that ran Shazam every 30 seconds on two Macs and pushed the cover to a Tuneshine (a small cover-art display), with no silence detection, new-track detection or confirmation. It also replaces a separate Spotify/Apple Music scrobbler.

- **Turntable Mac**: identifies the turntable's line-in.
- **Main Mac**: identifies the room through the microphone, or reads Apple Music and Spotify directly.

## Phase 1: the menu bar app

Goal: one SwiftUI menu bar app that runs on both Macs, configured per machine.

### Requirements

- **Input device selection**: line-in on the turntable Mac, the mic on the main Mac.
- **Audio capture**: use `AVAudioEngine`, selecting the input device through Core Audio.
- **Matching**: use plain `SHSession` (ShazamKit) fed with our own buffers. Don't use `SHManagedSession`, because it only listens to the default input.
- **Local silence detection**: an RMS/level threshold that can be adjusted to sit above vinyl surface noise.
- **State machine**:
  1. **Idle**: silence, so no queries.
  2. **Identifying**: audio is present, so query every 10–15 seconds until two consecutive results agree.
  3. **Playing**: the track is confirmed, so push the art to the Tuneshine. After that, run a spot check every 60–90 seconds, or wait until near the predicted end of the track, calculated from the match offset and track duration.
  4. Silence goes back to Idle. A different confirmed match goes back to Playing with the new track.
- **Keep the last cover up during short gaps.** Optionally show a "nothing playing" image after a few minutes of silence.
- **Priority between the two Macs**: the turntable Mac wins. The main Mac only pushes art if the turntable Mac hasn't pushed anything in the last few minutes. Coordinate over the local network.
- **Push the cover art to the Tuneshine API.**

### Tuneshine API (resolved)

- Tested with firmware 2.7.3 in "cloud" mode (the device follows a Last.fm account on its own). Local HTTP API at `<name>.local`, found over Bonjour (`_tuneshine._tcp`); spec at `http://<device>/openapi.json`.
- `POST /image` JSON `{imageUrl, trackName, artistName, albumName, serviceName, itemId, timeoutMs}` shows art and overrides the cloud feed until `DELETE /image`, which reverts to the cloud/idle view (what "Clear Tuneshine" does).
- Preferred push: download a 64x64 WebP from Apple's CDN (rewrite mzstatic `/{w}x{h}bb.{ext}` to `/64x64bb.webp`) and upload it as multipart `image` + `metadata` JSON. Uploads must be WebP (PNG/JPEG get HTTP 400). Artwork lookups prefer iTunes/mzstatic, even for Spotify tracks, so this path is almost always available.
- Fallback for non-Apple artwork: `imageUrl` JSON push. The device fetches it itself and fails roughly 1 in 3 times (`FETCH_DEADLINE_ERROR`, `HTTP_TRUNCATED_ERROR`) while still returning 200, so Thuner checks `localMetadata.lastImageError` in `GET /state` and retries.
- Failed pushes are retried by the app after 20s, up to 3 rounds. `lastDisplayed` (restored at launch) is only saved once the device confirms a push or clear.
- The device can take >10s to answer `/state` while busy; use generous timeouts.
- Resolve `.local` to IPv4 before connecting (device has no IPv6).
- Artwork: rewrite mzstatic `/{w}x{h}bb.` to 300x300 and use http.

## Beyond phase 1

1. **Scrobbling**:
   - Last.fm (built): `ScrobbleTracker` in ThunerCore, `LastFM` actor in the app. Desktop auth flow, API key/secret and session key in the Keychain, offline queue in `~/Library/Application Support/Thuner/scrobble-queue.json`. Off by default per Mac; a secondary Mac doesn't scrobble while the turntable Mac is active. Note a Tuneshine in cloud mode may follow the same Last.fm account.
   - Spotify and Apple Music (built, local only): `PlayerMonitor` listens for the apps' distributed notifications (`com.spotify.client.PlaybackStateChanged`, `com.apple.Music.playerInfo`); no permissions, no Web API. Artwork from Spotify oEmbed / iTunes Search. While a player is playing, Shazam queries are skipped. Limitation: a player already playing at launch is only seen at its next track change or play/pause (AppleScript could fix that, at the cost of an Automation permission prompt).
   - Local Network: right after launch macOS can briefly refuse LAN connections even when allowed; `TuneshineDisplay` retries for ~9s before reporting it as denied.
   - Deduplicate across sources: an API-reported play beats a Shazam match of the same song coming through the speakers.
   - Duplicate scrobbles (built): before scrobbling, skip if `PlayHistory` says ThUNER already scrobbled the same play (survives relaunches), or if `user.getRecentTracks` shows the same song within `PlayHistory.samePlayWindow` of the start time (Silicio, Spotify's own scrobbling, another Mac). Can't stop another scrobbler that sends *after* ThUNER.
   - History (built): `PlayHistory` in `~/Library/Application Support/Thuner/history.json`, one entry per play from any source with its scrobble status. History window exports a text list or CSV with Apple Music / Spotify links. Creating playlists directly in Apple Music or Spotify isn't built yet.
2. **Catalog mode** (for old DJ vinyl): play a record, log matches with confidence scores, review them, then push to a playlist.
   - Playlist destinations: Spotify and Apple Music are easy. YouTube's API has a daily quota, and search is expensive against it.
   - Fallbacks when Shazam fails:
     - A second fingerprinting service: ACRCloud (paid) or AcoustID/MusicBrainz (free).
     - A label photo, read with Apple Vision text recognition, to get the catalog number or matrix number, then a Discogs API lookup.
   - Existing apps to compare against first: GrailVinyl and Record Scanner.
   - Possible sub-name: "Runout."
3. **Pro DJ Link overlay** for OBS (Pioneer CDJs):
   - Build on Beat Link (Java) or prolink-connect (JS).
   - Use the DJM mixer's on-air data to decide what's actually audible, and require a track to stay on air for a while before the overlay changes.
   - Serve the overlay as a local web page loaded as an OBS Browser Source.
   - Watch for player-slot conflicts on four-deck setups.

## Unknowns

- Apple doesn't publish a ShazamKit rate limit. The state machine above keeps query volume low anyway.
- There's no known public API for incrementing Apple Music play counts. Check how Quanta does it before relying on it.

## Development

- Layout: `Sources/ThunerCore` (pure logic: `NowPlayingMachine`, `LevelGate`, `PushArbiter`, `Track`; unit tested), `Sources/Thuner` (menu bar app: Core Audio device selection, `AVAudioEngine` capture, `SHSession` matching, iTunes lookup for track length, UDP-broadcast peer link on port 47474, Tuneshine sink).
- Scripts default `DEVELOPER_DIR` to `/Applications/Xcode.app/Contents/Developer`; do the same for `swift` commands if Xcode isn't the active developer dir.
- Per-machine settings for the scripts (signing identity, bundle ID, notary profile, update-check stats, website folder and deploy target) live in `Scripts/config.local.sh`, which git ignores; `Scripts/config.example.sh` documents them. Without it, builds are ad-hoc signed.
- Test: `swift test`. Build the app: `Scripts/build-app.sh` (output `build/Thuner.app`, universal arm64 + x86_64, Sparkle.framework embedded and signed inside-out). Development builds are versioned `<version>-dev` with build number 999999999999 so Sparkle never replaces them.
- Release: `Scripts/release.sh <version> "<notes>"` bumps the version (build number = UTC timestamp), builds with a secure timestamp, notarizes (`notarytool` profile from `NOTARY_PROFILE`) and staples, zips into `$WEBSITE_DIR/thuner/updates/`, regenerates `appcast.xml` with Sparkle's `generate_appcast` (EdDSA key in the login Keychain, account `thuner`), and points the download button at the new zip. Then `Scripts/deploy-website.sh`, and commit the website repo. Zips and Sparkle deltas aren't in git.
- Updates: Sparkle 2, feed `https://idallas.com/software/thuner/appcast.xml`, public key in Info.plist (`SUPublicEDKey`). Losing the private key means existing installs can't verify new updates, so keep a backup (`generate_keys --account thuner -x <file>`).
- Update-check stats (`UsageStats`, Umami event API): only release builds carry the endpoint and site ID (`ThunerStatsEndpoint`/`ThunerStatsWebsiteID`, added by `build-app.sh` from the config); other builds send nothing and hide the setting.
- Last.fm API key: never in source. `build-app.sh` embeds the one saved in this Mac's Keychain (service `com.idallas.thuner`, account `lastfm-credentials`) as `LastFMAPIKey`/`LastFMSharedSecret`; builds without one ask for a key in Settings → Scrobbling.
- Website: static pages (overview + `thuner/` with the appcast and release notes) in a separate private repo, `idallas/software-site`, checked out at `WEBSITE_DIR` (its `software/` folder). Deployed with rsync by `Scripts/deploy-website.sh` to `DEPLOY_TARGET` (never deletes remote files). Preview with that repo's `website` launch config (python http.server on 8765).
- Bundle ID `com.idallas.thuner` (override with `BUNDLE_ID`). ShazamKit needs a paid developer team with the ShazamKit App Service enabled for the App ID, or matches fail with ShazamCore error 102; free personal teams can't enable App Services.
- Settings live in UserDefaults (`inputDeviceUID`, `firstChannel`, `thresholdDB`, `role`, `idleImageMinutes`), so they can be set over SSH on a headless Mac with `defaults write com.idallas.thuner …`.
- Logs: `/usr/bin/log stream --predicate 'subsystem == "com.idallas.thuner"'`.
- The turntable Mac is typically a headless Mac mini, managed over SSH.

## Controls and the API

- `ControlSurface` defines ThUNER's controls once (id, name, kind level/toggle/button, group, state, what turning/pressing does). Adapters expose them: Twist Commando's App Link (`AppLinkClient`, TCP 127.0.0.1:9034) and ThUNER's HTTP API (`WebDisplayServer`). Add a control in `ControlSurface` and every adapter gets it.
- HTTP server on port 47480 (all interfaces): `/` web display, `/now.json`, `GET /api`, `GET /api/controls`, `GET /api/events` (SSE; `?levels=1` adds the input meter), `POST /api/controls/<id>` with `{"value": 0-1}`, `{"press": true}` or `{"on": bool}`.
- Reading is open; POST needs the token (`Authorization: Bearer` or `?token=`, Settings → Display → Control API), except from loopback *without* an `Origin` header (curl, scripts). Browser pages always need it: responses allow every origin, so otherwise any website could drive the app from the user's browser. Settings → Display → "Reachable from: This Mac only" binds the server to loopback.
- Security review 2026-10-05: request parser rejects bad Content-Length (negative values used to trap), event streams capped at 32, requests must arrive within 10s, token compared in constant time; `PeerLink` only accepts datagrams from addresses resolved over Bonjour (no shared secret yet); ListenBrainz-style services refuse plain `http://` to non-local hosts; CSV export neutralizes formula-leading fields. Known/accepted: Last.fm API key + secret are readable in the shipped Info.plist.


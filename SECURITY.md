# Security

## Reporting a problem

Please report security problems privately, through GitHub's **Report a vulnerability** button on this repository's Security tab, rather than in a public issue. You'll get a reply within a few days.

Supported: the latest release from [idallas.com/software/thuner](https://idallas.com/software/thuner/).

## What ThUNER exposes

So you know what to look at:

- **HTTP server, port 47480.** It only runs when the web display is on (Settings → Display).
  - Settings → Display → "Reachable from" chooses who can connect: any device on the network, or this Mac only.
  - Anyone who can reach it can **read** what's playing and the controls' state.
  - **Changing** anything needs the API token. The one exception is programs on the same Mac that send no `Origin` header, like curl or scripts. Browser pages always need the token.
- **Peer link, UDP port 47474.** ThUNER instances advertise themselves over Bonjour (`_thuner._udp`) and exchange now-playing messages. A datagram is only accepted from an address found over Bonjour. There's no shared secret yet, so treat the local network as trusted.
- **Twist Commando App Link.** A client connection to 127.0.0.1:9034, on the same Mac only.
- **Outgoing connections:**
  - Shazam (anonymous audio fingerprints) and the iTunes Search API
  - Spotify oEmbed and Apple's artwork CDN
  - Last.fm and any ListenBrainz-style servers you add. These refuse plain `http://` beyond the local network.
  - Your Tuneshine
  - the Sparkle appcast
  - for official releases only, if you leave it on: an anonymous update-check stat

## Known and accepted

- Official releases have a Last.fm API key and shared secret built in, and anyone can read them from the app bundle. That's normal for a desktop Last.fm app: the key identifies the app, not a user. Each user's session key stays in their own Keychain.

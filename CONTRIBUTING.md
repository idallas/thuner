# Contributing to ThUNER

Thanks for taking a look. ThUNER started as one person's setup for a turntable and a Tuneshine, so issues and pull requests are welcome, but the scope stays fairly focused: knowing what's playing, showing it, and scrobbling it.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on the approach.
- Read [`CLAUDE.md`](CLAUDE.md). It has the design notes (the state machine, Tuneshine API quirks, scrobbling rules, the control API) and is kept current.

## Building and testing

```bash
swift test
```

```bash
Scripts/build-app.sh
```

See the README for signing. Without a paid Apple Developer team with ShazamKit enabled, Shazam identification won't work in your build, but everything else will.

Logs:

```bash
/usr/bin/log stream --predicate 'subsystem == "com.idallas.thuner"'
```

## Code

- Swift 6 toolchain in Swift 5 language mode, macOS 15 minimum.
- Logic that doesn't need Apple's media frameworks goes in `ThunerCore` with tests; the app target holds the audio, network and UI code.
- New controls go in `ControlSurface`. Twist Commando and the HTTP API both pick them up from there.
- Match the surrounding code: small types, doc comments that explain *why*, and plain wording in anything the user sees.
- ThUNER shouldn't use the microphone or the network unexpectedly. Wake the mic only for music-related signals, and ask for a permission at the moment a feature needs it.
- Keep CPU low. ThUNER runs all day; avoid per-tick redraws and polling.

## Pull requests

- Keep each PR to one change, with a description of what you tested (which Mac, which input or player).
- `swift test` should pass. CI runs it on every push.
- Don't commit keys, tokens or personal settings. Per-machine script settings go in `Scripts/config.local.sh`, which git ignores.

By contributing, you agree your contributions are licensed under the MIT License.

# IronTV

Native IPTV player for [Xtream Codes](https://en.wikipedia.org/wiki/Xtream_Codes) providers. SwiftUI, no third-party dependencies.

| Platform | Status |
|---|---|
| macOS 13+ | ✅ Full support, notarized DMG |
| iOS / iPadOS 16+ | ✅ Builds; UI adapted (settings as sheet) |
| tvOS 16+ | ✅ Builds; UI adapted (focusable controls) |

## Features

- **One-URL setup** — paste the M3U playlist URL from your provider; the app extracts server and credentials, validates them against the panel, and stores them in the Keychain (synced across devices via iCloud Keychain). The M3U file itself is never downloaded.
- **Channel browser** — categories sidebar, *All Channels* and *Favorites* scopes, per-channel icons, instant search.
- **Resilient live playback** (AVPlayer, HLS):
  - configurable forward buffer and live-edge cushion
  - stall watchdog: detects stuck buffering, frozen video (even while audio keeps playing), and dead streams; recovers via seek-to-live first, full reconnect second
  - manual audio/video resync button
  - video-only full screen
- **Tunable playback settings** — buffer sizes, reconnect timeouts, health-check interval, fast start, API timeout; synced via iCloud key-value store (entitlement pending).
- **Credential hygiene** — credentials live only in the Keychain; logged URLs are redacted.

## Building

Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate                                    # produces IronTV.xcodeproj
xcodebuild -scheme IronTV -configuration Debug build # macOS
xcodebuild -scheme IronTV test                       # unit tests
xcodebuild -scheme IronTV-iOS -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme IronTV-tvOS -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build
```

`project.yml` is the source of truth — never edit the `.xcodeproj` directly. Re-run `xcodegen generate` after adding/removing source files.

### Toolchain

| Tool | Local (developed against) | CI (blocking gate) |
|------|---------------------------|--------------------|
| macOS | 26.x | `macos-15` runner image |
| Xcode | 26.6 | image default (Xcode 16.x) |
| Swift | 6.3 (language mode 5) | image default |
| XcodeGen | 2.46 | latest from Homebrew |

CI regenerates the project from `project.yml` on every run and never caches the
generated `.xcodeproj` or build products — a stale generated project is exactly
what it exists to catch. It also runs a build and test pass on `macos-latest` and
a `SWIFT_STRICT_CONCURRENCY=complete` pass, both **informational**: they surface a
new Xcode or the outstanding concurrency-migration warnings (issue #17) without
turning unrelated PRs red.

### Dependencies

VLCKit (via [`vlckit-spm`](https://github.com/tylerjonesio/vlckit-spm)) is the only
third-party dependency, pinned to an **exact** version in `project.yml`. It is a
binary LGPL framework embedded in the shipped app, and the generated
`Package.resolved` is gitignored along with the `.xcodeproj`, so that pin is the
only thing making a clean checkout reproducible.

Updating it is a reviewed change, not a routine bump:

1. Change `exactVersion` in `project.yml` and run `xcodegen generate`.
2. Build and test all three targets.
3. Confirm the framework is still **dynamically** linked — static linking would
   break the LGPL terms (see issue #7).
4. Note the new version and why it changed in the PR description.

Adding any other dependency needs explicit approval first.

### Distribution (macOS)

```bash
scripts/make-dmg.sh
```

Regenerates the Xcode project from `project.yml`, builds a universal
(arm64 + x86_64) Release archive into a fresh temporary derived-data
directory, and packages exactly that build as `dist/IronTV-<version>.dmg` —
the script fails rather than package anything whose version, architectures,
embedded frameworks, entitlements, or signature don't match the requested
configuration.

When a `Developer ID Application` certificate is present, the archive is
exported with Developer ID signing, notarized, stapled, and
Gatekeeper-verified. This needs Xcode signed in to the team's Apple Developer
account (Xcode → Settings → Accounts) and a stored notary profile:

```bash
xcrun notarytool store-credentials irontv-notary --apple-id <apple-id> --team-id 5NP3LPSUMR
```

For a local, un-notarized build (installs with a quarantine workaround
documented inside the DMG):

```bash
IRONTV_NOTARIZE=0 scripts/make-dmg.sh
```

## Architecture

```
Sources/
  Domain/          # Account, Category, LiveStream, IDs, M3UURLParser, PlaybackSettings
  API/             # XtreamClient (async), tolerant DTOs, credential redaction
  Persistence/     # KeychainStore, playback/favorites/last-channel stores, iCloud mirror
  Features/
    Settings/      # account entry + validation, playback tuning, license
    Channels/      # category/channel browser
    Player/        # AVPlayerView wrapper, stall watchdog, reconnect logic
  App/             # app entry, root navigation
Tests/             # unit tests + JSON fixtures (Int/String variants, real panel captures)
```

Xtream panels are PHP-backed and inconsistent — every numeric DTO field decodes from both `Int` and `String` (`@FlexibleInt` / `@FlexibleString`).

## Disclaimer

IronTV is a player. It ships with no content, no playlists, and no services; you supply the subscription URL from your own provider and are solely responsible for what you access with it. See [LICENSE](LICENSE).

© 2026 Joaquin Bejar. Free for personal use; redistribution and modification are not permitted.

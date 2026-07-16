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

### Distribution (macOS)

```bash
scripts/make-dmg.sh
```

Builds a universal (arm64 + x86_64) Release, signs it with Developer ID, packages `dist/IronTV-<version>.dmg`, notarizes it with Apple, and staples the ticket. Requires a `Developer ID Application` certificate and a stored notary profile:

```bash
xcrun notarytool store-credentials irontv-notary --apple-id <apple-id> --team-id <team-id>
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

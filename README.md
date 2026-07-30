# IronTV

Native IPTV player for [Xtream Codes](https://en.wikipedia.org/wiki/Xtream_Codes) providers. SwiftUI throughout; the one third-party dependency is VLCKit, pinned and dynamically linked (see [Dependencies](#dependencies)).

**This README is the authoritative description of the shipped app.** `SPEC.md` is the historical MVP design document.

| Platform | Status |
|---|---|
| macOS 14+ | ✅ Shipping — Mac App Store + notarized DMG |
| iOS / iPadOS 17+ | ✅ Shipping — App Store (settings as sheet, compact-column navigation) |
| tvOS 17+ | ✅ Shipping — App Store (focus-driven navigation) |

On the App Store since 2026-07-17. English and Spanish localizations ship from one String Catalog (`Sources/Localizable.xcstrings`).

## Features

- **One-URL setup** — paste the M3U playlist URL from your provider; the app extracts server and credentials, validates them against the panel, and stores them in the device's data-protection Keychain. The M3U file itself is never downloaded. Preferences — favorites, last channel, playback settings — sync across devices via iCloud key-value store; the credentials themselves stay in the local Keychain (tvOS has no iCloud Keychain UI, so each device pastes the URL once).
- **Sample mode** — "Try Sample Channels" browses and plays free legal public streams with no account, both as a first-run demo and as a recovery path when the stored account can't be read.
- **Channel browser** — categories sidebar, *All Channels* and *Favorites* scopes, bounded per-channel icon loading, debounced diacritic-insensitive search that stays smooth on 50k-channel catalogs.
- **Two playback engines on every platform** — AVPlayer (HLS) leads; the VLC engine (raw MPEG-TS) rescues channels AVPlayer can't decode, plays TS-only panels, and can be forced in Settings. The active engine is visible in the player.
- **Resilient live playback**:
  - configurable forward buffer and live-edge cushion (Apple engine)
  - stall watchdog: detects stuck buffering, frozen video (even while audio keeps playing), and dead streams; recovers via seek-to-live first, full reconnect second
  - fast reconnects followed by an indefinite slower cadence — a live stream never gives up
  - manual audio/video resync button
  - video-only full screen; floating always-on-top mini player on macOS
- **Tunable playback settings** — synced via iCloud key-value store. Each option, its engine scope and trade-off:

  | Setting | Default | Range | Engine | Trade-off |
  |---------|---------|-------|--------|-----------|
  | Forward buffer | 30 s | 5–120 s | Apple | more resilience vs. more memory/latency |
  | Live delay (stall cushion) | 10 s | 0–60 s | Apple | absorbs hiccups vs. seconds behind live (auto-capped to ⅓ of the panel window) |
  | Fast start | on | — | Apple | faster zapping vs. possible stutter on weak links |
  | Reconnect after buffering | 8 s | 2–60 s | Apple health check | patience vs. faster recovery |
  | Reconnect after frozen video | 6 s | 2–60 s | Apple health check | tolerance vs. faster recovery |
  | Health check interval | 2 s | 1–10 s | Apple | detection latency vs. overhead |
  | Fast reconnect attempts | 5 | 1–10 | both | immediate retries before the indefinite slower cadence (never a terminal limit) |
  | API request timeout | 30 s | 5–120 s | both (JSON API) | slow panels vs. snappy failures |
  | Engine | Automatic | auto/Apple/VLC | — | Automatic falls back to VLC per channel; the active engine shows in the player toolbar |

  The VLC engine uses a fixed 3-second network cache (not user-configurable — deriving it from the live delay made VLC pre-buffer for many seconds).
- **Credential hygiene** — credentials live only in the Keychain; logged URLs are redacted.
- **Transport security** — HTTPS is preferred: when an `http://` playlist URL is pasted, the app first probes the same server over TLS and silently saves the HTTPS endpoint if it answers; otherwise sending credentials over plain HTTP requires an explicit confirmation, and the panel-API transport state is shown in Settings (stream playback follows the URLs the panel serves — the media engines expose no redirect enforcement). As a post-hoc guard, the AVPlayer watchdog inspects the item's access log and stops playback with a typed error when media requests move to plain HTTP or another origin; detection, not prevention — and the VLC engine exposes no access log, so this watch covers the Apple engine only. ATS remains open (`NSAllowsArbitraryLoads`) by design — the provider host is entered at runtime, so a per-host exception is impossible (rationale documented in `project.yml`).

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
| Swift | 6.3 toolchain, **Swift 6 language mode** | image default |
| XcodeGen | 2.46 | latest from Homebrew |

CI regenerates the project from `project.yml` on every run and never caches the
generated `.xcodeproj` or build products — a stale generated project is exactly
what it exists to catch. Blocking gates: macOS build + tests, iOS and tvOS
builds, a secret scan, a zero-warning pass over app **and test** sources
(`build-for-testing`; isolation violations are compile errors in the Swift 6
language mode, and this job keeps warnings from accumulating on top), and a
docs-drift check (`scripts/check-docs-drift.sh`) that fails when this README,
`CLAUDE.md`, or `SPEC.md` contradict `project.yml` on platforms, bundle id, or
Swift version. A `macos-latest` pass stays **informational** so a new Xcode
image surfaces as a warning instead of turning unrelated PRs red.

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

### Distribution

All three targets ship through App Store Connect (Xcode archive → upload).
macOS additionally distributes as a notarized DMG:

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
  Domain/          # Account, Category, LiveStream, IDs, M3UURLParser, PlaybackSettings, source planner
  API/             # XtreamClient (async), tolerant DTOs, credential redaction, transport policies
  Persistence/     # KeychainStore, playback/favorites/last-channel stores, iCloud mirror
  Features/
    Settings/      # account entry + validation, playback tuning, license
    Channels/      # platform shells, channel browser, playback coordinator, icon pipeline
    Player/        # player surfaces (AVPlayerView / VLC), stall watchdog, reconnect logic
  App/             # app entry, root navigation, single-window policy
  Localizable.xcstrings  # String Catalog (en source, es shipped)
Tests/             # unit tests + JSON fixtures (Int/String variants, real panel captures)
```

Xtream panels are PHP-backed and inconsistent — every numeric DTO field decodes from both `Int` and `String` (`@FlexibleInt` / `@FlexibleString`).

## Disclaimer

IronTV is a player. It ships with no content, no playlists, and no services; you supply the subscription URL from your own provider and are solely responsible for what you access with it. See [LICENSE](LICENSE).

© 2026 Joaquin Bejar. Free for personal use; redistribution and modification are not permitted.

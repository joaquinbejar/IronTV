# CLAUDE.md

## Project

Native IPTV player (SwiftUI) for Xtream Codes providers, shipping from one
codebase to three targets: macOS 14+ (`IronTV`), iOS/iPadOS 17+
(`IronTV-iOS`), tvOS 17+ (`IronTV-tvOS`). Live on the App Store. Single
window/scene everywhere — every window is a provider connection slot, so
macOS uses a unique `Window` scene and iOS/tvOS set
`UIApplicationSupportsMultipleScenes: false`. Browser: sidebar with
categories/channels, player pane.

## Tech stack

- Swift 6 language mode, SwiftUI; deployment targets macOS 14 / iOS 17 / tvOS 17
- AVKit / AVPlayer for playback (HLS `.m3u8` streams) with a VLCKit fallback
  engine (raw MPEG-TS) on **all three platforms** — codec rescue, TS-only
  panels, or forced via Settings
- URLSession + async/await, Codable for the Xtream JSON API
- XcodeGen for project generation (`project.yml` is the source of truth —
  never edit the `.xcodeproj` directly)
- Data-protection Keychain for credentials; iCloud key-value store for synced
  preferences (favorites, last channel, playback settings)
- Localization via `Sources/Localizable.xcstrings` (en source, es shipped) —
  user-facing strings in plain-`String` contexts use `String(localized:)`

## Build & run

```bash
xcodegen generate                          # regenerate .xcodeproj after project.yml changes
xcodebuild -scheme IronTV -configuration Debug -allowProvisioningUpdates build   # CLI build
xcodebuild -scheme IronTV -destination 'platform=macOS' -allowProvisioningUpdates test
```

Run/UI verification is done manually by the developer in Xcode. Do not attempt to launch the GUI app.

After adding/removing/renaming source files, run `xcodegen generate` before building.

## Conventions

- **Versioning & DMG**: every new build delivered for testing bumps the patch version (`CFBundleShortVersionString`) and increments `CFBundleVersion` in `project.yml` on all three targets, then regenerates the DMG with `scripts/make-dmg.sh` (output in `dist/`). Stacked PRs never bump — the bump happens once at delivery.
- **Docs follow project.yml**: a change to deployment targets, bundle id, or Swift version in `project.yml` updates `README.md` and this file in the same PR — `scripts/check-docs-drift.sh` (the `docs-drift` CI job) fails otherwise. Like every gate here, a red run must not be merged; marking the job as a required status check in branch protection is the owner's repository setting.
- All code, comments, and documentation in English.
- Domain modeling first: domain types (`Account`, `Category`, `LiveStream`) are separate from API DTOs. DTOs live in `Sources/API/DTO/`, domain types in `Sources/Domain/`.
- Xtream panels are PHP-backed and inconsistent: numeric fields may arrive as `Int` or `String` depending on the panel. All DTOs must decode both (use a `FlexibleInt`/`FlexibleString` property wrapper or custom `init(from:)`) and tolerate `null`/absent.
- Errors: typed errors per layer (`XtreamAPIError`, `PlaybackError`), no `fatalError` in production paths.
- Playback settings are engine-scoped — buffer/live-delay/fast-start configure the Apple engine only; VLC uses a fixed 3-second network cache by decision. Keep UI labels honest about scope.
- No third-party dependencies unless strictly necessary. Prefer Foundation/AVKit. (Current exception, user-approved: VLCKit as the fallback engine — LGPL, binary SPM package pinned to an exact version in `project.yml`, keep it dynamically linked.)

## Constraints & gotchas

- Providers serve plain HTTP (no TLS) and the host is entered by the user at runtime, so a per-host ATS exception is impossible. `Info.plist` sets `NSAllowsArbitraryLoads: true`. HTTPS is still preferred: pasted http URLs get a TLS probe (same port, then the panel-advertised `https_port`) and plain HTTP requires explicit user confirmation.
- **Never commit credentials.** Test credentials live in `.env` (gitignored). The app stores real credentials in the Keychain.
- AVPlayer only handles HLS — live URLs use the `.m3u8` form: `http://{host}/live/{user}/{pass}/{stream_id}.m3u8`. TS-only panels are **in scope**: the source planner leads with the VLC engine over the `.ts` URL instead of a doomed AVPlayer attempt.
- **Never override the AVPlayer / `AVURLAsset` User-Agent** — panels 403 anything that isn't AppleCoreMedia. The VLC path must keep `:http-user-agent=AppleCoreMedia/1.0.0`.
- **Never use SwiftUI `VideoPlayer` on macOS** — it aborts during AppKit state restoration. `PlayerSurface` wraps `AVPlayerView`.
- Stream URLs embed credentials — never log full stream URLs. Redact username/password in any logging (`CredentialRedactor`).

## Testing

- Unit tests for DTO decoding (fixtures with both Int and String variants of numeric fields) and for URL building.
- No network calls in unit tests; use recorded JSON fixtures in `Tests/Fixtures/`.

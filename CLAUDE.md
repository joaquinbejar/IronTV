# CLAUDE.md

## Project

Native macOS IPTV player (SwiftUI) for Xtream Codes providers. Single-window app: sidebar with categories/channels, video player pane using AVPlayer (HLS).

## Tech stack

- Swift 5.9+, SwiftUI, macOS 13+ deployment target
- AVKit / AVPlayer for playback (HLS `.m3u8` streams)
- URLSession + async/await, Codable for the Xtream JSON API
- XcodeGen for project generation (`project.yml` is the source of truth — never edit the `.xcodeproj` directly)
- Keychain for credential storage

## Build & run

```bash
xcodegen generate                          # regenerate .xcodeproj after project.yml changes
xcodebuild -scheme IronTV -configuration Debug build   # CLI build, use this to verify compilation
```

Run/UI verification is done manually by the developer in Xcode. Do not attempt to launch the GUI app.

After adding/removing/renaming source files, run `xcodegen generate` before building.

## Conventions

- **Versioning & DMG**: every new build delivered for testing bumps the patch version (`CFBundleShortVersionString`, e.g. 0.1.0 → 0.1.1) and increments `CFBundleVersion` in `project.yml`, then regenerates the DMG with `scripts/make-dmg.sh` (output in `dist/`).

- All code, comments, and documentation in English.
- Domain modeling first: domain types (`Account`, `Category`, `LiveStream`) are separate from API DTOs. DTOs live in `Sources/API/DTO/`, domain types in `Sources/Domain/`.
- Xtream panels are PHP-backed and inconsistent: numeric fields may arrive as `Int` or `String` depending on the panel. All DTOs must decode both (use a `FlexibleInt`/`FlexibleString` property wrapper or custom `init(from:)`).
- Errors: typed errors per layer (`XtreamAPIError`, `PlaybackError`), no `fatalError` in production paths.
- No third-party dependencies unless strictly necessary. Prefer Foundation/AVKit. (Current exception, user-approved: VLCKit on iOS/tvOS as codec-fallback engine — LGPL, keep it dynamically linked.)

## Constraints & gotchas

- Providers serve plain HTTP (no TLS) and the host is entered by the user at runtime, so a per-host ATS exception is impossible. `Info.plist` sets `NSAllowsArbitraryLoads: true`.
- **Never commit credentials.** Test credentials live in `.env` (gitignored). The app stores real credentials in the Keychain.
- AVPlayer only handles HLS. Live stream URLs must use the `.m3u8` form: `http://{host}/live/{user}/{pass}/{stream_id}.m3u8`. If a panel only serves `.ts` (MPEG-TS), that is out of scope for the MVP — surface a clear playback error.
- Stream URLs embed credentials — never log full stream URLs. Redact username/password in any logging.

## Testing

- Unit tests for DTO decoding (fixtures with both Int and String variants of numeric fields) and for URL building.
- No network calls in unit tests; use recorded JSON fixtures in `Tests/Fixtures/`.

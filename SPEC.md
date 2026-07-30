# SPEC — IronTV, macOS IPTV Player (Xtream Codes)

App name: **IronTV** · Bundle ID: `com.quantkernel.irontv` · Xcode scheme: `IronTV`

## Goal

Minimal native macOS app to browse and play live TV channels from an Xtream Codes provider. The user supplies a single M3U playlist URL (pasted into Settings); the app extracts host + username + password from it.

## Background: Xtream Codes API

The provider hands out an M3U URL of the form `http://{host}/get.php?username=...&password=...&type=m3u_plus`. The app treats this URL purely as a **credential container**: it parses out host, username, and password and never downloads or parses the M3U file itself. The same panel exposes a JSON API which is used for all data:

```
http://{host}/player_api.php?username={u}&password={p}[&action=...]
```

| action | returns |
|---|---|
| (none) | account + server info (`user_info`, `server_info`) |
| `get_live_categories` | `[{category_id, category_name, parent_id}]` |
| `get_live_streams` | `[{stream_id, name, stream_icon, category_id, epg_channel_id, ...}]` |
| `get_live_streams&category_id=N` | live streams filtered by category |
| `get_short_epg&stream_id=N` | short EPG for one channel (base64-encoded title/description fields) |

Live playback URL (HLS, required for AVPlayer):

```
http://{host}/live/{username}/{password}/{stream_id}.m3u8
```

Panel quirks to handle defensively:
- Numeric fields arrive as `Int` or `String` depending on panel version.
- Fields may be missing or `null`; all DTO fields optional unless verified.
- Responses are large (thousands of streams); fetch per-category where possible.

## ATS

The provider host is entered by the user at runtime, so a per-host ATS exception is impossible (ATS exceptions are compile-time). `Info.plist` sets `NSAppTransportSecurity > NSAllowsArbitraryLoads: true` to allow plain-HTTP panels and streams.

## Domain model

```
Account       { host: URL, username: String, password: String }   // parsed from the pasted M3U URL; stored in Keychain
AccountStatus { authenticated: Bool, status: String?, expiryDate: Date?, maxConnections: Int? }  // from user_info
Category      { id: CategoryID, name: String }
LiveStream    { id: StreamID, name: String, iconURL: URL?, categoryID: CategoryID, epgChannelID: String? }
```

Newtype-style IDs (wrapper structs) rather than raw Ints. Domain types are built from DTOs in a mapping layer; views never touch DTOs.

## Architecture

```
Sources/
  Domain/          // Account, AccountStatus, Category, LiveStream, IDs, M3UURLParser
  API/
    XtreamClient.swift    // async endpoints, URL building, credential redaction
    DTO/                  // Codable DTOs with flexible Int/String decoding
  Persistence/
    KeychainStore.swift   // save/load Account
  Features/
    Settings/             // paste M3U URL -> parse -> validate via player_api.php -> Keychain
    Channels/             // sidebar: categories -> channel list (LazyVStack, async icons)
    Player/               // AVPlayer wrapper view + error surface
  App/
    IronTVApp.swift       # single playback scene (one provider slot); bg = stop
```

MVVM-lite: one observable view model per feature, `XtreamClient` injected. No external architecture frameworks.

## Milestones

1. **Project scaffold**: XcodeGen `project.yml`, app target, ATS arbitrary-loads exception, `NavigationSplitView` root (app stays adaptive for future iOS/iPadOS targets), empty window builds via `xcodebuild`.
2. **Xtream client + DTOs**: account info, categories, live streams; unit tests with JSON fixtures covering Int/String variance.
3. **Settings / account setup**: Settings scene (Cmd+,) with a single "Playlist URL" field. `M3UURLParser` extracts host/username/password from the pasted M3U URL (tolerates http/https, ports, any query-param order, extra params, whitespace; typed errors per failure mode). "Validate & Save" checks `player_api.php` (no action, `user_info.auth == 1`), shows inline status (validating / success with expiry date / typed error), persists `Account` to Keychain. Shows saved account (host + username, never the password) with "Remove account". On launch without an account, the main window shows an empty state pointing to Settings; the channel browser reacts to account save/remove. Settings form stays multiplatform-friendly (no AppKit) for later iOS presentation.
4. **Channel browser**: categories sidebar (plus "All Channels" and "Favorites" scopes), channel list with icons and search field, favorites toggle via context menu.
5. **Playback**: select channel -> AVPlayer plays `.m3u8` URL; loading/error states; remember last channel.
6. **Polish (post-MVP, optional)**: short EPG display, VOD (`get_vod_streams`), multi-account. (Favorites shipped early, in milestone 4.)

## Playback engines

AVPlayer is the primary engine everywhere (hardware decode, AirPlay). On iOS/tvOS, channels whose codecs AVPlayer rejects (MP2 audio, interlaced video — CoreMedia error 'fmt?') automatically fall back to **VLCKit** (LGPL, via the `VLCKitSPM` binary package). VLC's default User-Agent is 403'd by panels, so the fallback forces an AppleCoreMedia UA. Streams that needed VLC are remembered per session and skip the AVPlayer attempt on the next zap.

## Out of scope (MVP)
- Full XMLTV EPG grid
- Recording, timeshift
- iOS/tvOS targets


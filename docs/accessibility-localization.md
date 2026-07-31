# Accessibility & localization

State of the app after issue #16, and the checklist to keep it that way.

## Localization

- **Catalog**: `Sources/Localizable.xcstrings` — one String Catalog for all
  three targets. Source language is English; Spanish ships from the same file.
- **SwiftUI literals** (`Text`, `Label`, `Button`, section headers, prompts)
  are `LocalizedStringKey`s and resolve through the catalog automatically.
- **Plain `String` contexts** — error `errorDescription`s, view-model
  messages, strings passed through `String` parameters — must use
  `String(localized:)`. Interpolated values are stringified first so every
  placeholder is `%@`; `LocalizationCatalogTests` asserts placeholder parity
  between key and translation.
- **Do-not-translate keys** (brand names like IronTV/VLC/Apple, technical
  labels, URL examples) are marked `shouldTranslate: false` in the catalog.
- **Adding a string**: write the English literal in code, add the key with its
  Spanish translation to the catalog. A key without an `es` entry fails
  `LocalizationCatalogTests`.
- The Spanish translations were machine-drafted and are pending a native
  review pass by the maintainer.

## Accessibility

Conventions in place:

- Icon-only controls carry `.accessibilityLabel` (and `.help` on macOS):
  settings gear, URL reveal toggle, resync, floating mini player, full
  screen, floating-exit. Stable `.accessibilityIdentifier`s
  (`browser.settingsButton`, `settings.revealToggle`, `player.resyncButton`,
  `player.floatingButton`, `player.fullScreenButton`,
  `player.exitFullScreenButton` (iOS), `player.exitFloatingButton`,
  `player.retryButton`, `player.engineChip`, `channel.favoriteToggle`,
  `loadFailure.retryButton`) for future UI automation.
- Channel rows combine into one VoiceOver element whose value announces the
  favorite state; the favorite star is never color-only (filled vs outline),
  and on tvOS the indicator image is hidden from accessibility in favor of
  the row value.
- Purely decorative images (`wifi.exclamationmark`, `play.tv`, the tvOS star
  indicator) are `.accessibilityHidden(true)`.
- The active engine is announced ("Playing with the VLC engine") from both
  the toolbar chip and the chrome-less auto-hiding badge.
- tvOS empty-favorites copy names the real actions (Play/Pause, long-press).

## Manual verification checklist (per release)

Run/UI verification is manual, in Xcode, by the developer:

- [ ] VoiceOver walk of the browser, player, and settings on macOS and iOS;
      focus walk on tvOS.
- [ ] Dynamic Type at the largest accessibility size — no clipped labels.
- [ ] Increase Contrast and Reduce Motion — nothing becomes unreadable or
      relies on motion.
- [ ] Keyboard-only navigation on macOS (tab order, Space/Return activation).
- [ ] tvOS focus engine reaches every control (settings steppers, reveal
      toggle, retry buttons).
- [ ] App run with the system language set to Spanish — no truncation, no
      leftover English, dates formatted per locale.
- [ ] Native-speaker review of the Spanish strings in
      `Sources/Localizable.xcstrings`.

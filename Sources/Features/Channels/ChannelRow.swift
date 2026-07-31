import SwiftUI

/// One channel line: icon, name, favorite star. Shared by the desktop list
/// and the tvOS focus list — the star is a button under a pointer or touch,
/// a plain indicator on tvOS where the whole row is the focusable.
struct ChannelRow: View {
    let stream: LiveStream
    let isFavorite: Bool
    let toggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ChannelIconView(url: stream.iconURL)
                .frame(width: 28, height: 28)

            Text(stream.name)
                .lineLimit(1)
                #if !os(tvOS)
                // The favorite state rides the name element; the star button
                // stays its own accessibility element so VoiceOver can act on
                // it directly.
                .accessibilityValue(isFavorite ? Text("Favorite") : Text("Not a favorite"))
                #endif

            Spacer()

            #if os(tvOS)
            // Rows are single focusables on tvOS — the star is an indicator;
            // toggling happens via long-press menu or the play/pause button.
            // Never color-only: filled vs outline carries the state, and the
            // row's accessibility value carries it for VoiceOver.
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? .yellow : .secondary)
                .accessibilityHidden(true)
            #else
            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            // Text-based so the label resolves through the String Catalog —
            // a plain String ternary would reach VoiceOver untranslated.
            .accessibilityLabel(isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites"))
            .accessibilityIdentifier("channel.favoriteToggle")
            #endif
        }
        #if os(tvOS)
        // The whole row is one focusable with no inner controls, so one
        // combined element carrying the favorite state is the right shape
        // here — unlike the pointer/touch row, whose button stays separate.
        .accessibilityElement(children: .combine)
        .accessibilityValue(isFavorite ? Text("Favorite") : Text("Not a favorite"))
        #endif
        .contextMenu {
            Button(action: toggleFavorite) {
                isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites")
            }
        }
    }
}

#Preview("Channel rows") {
    List {
        ChannelRow(
            stream: LiveStream(id: StreamID(1), name: "Sample Channel FHD", iconURL: nil, categoryID: CategoryID(1), epgChannelID: nil),
            isFavorite: true,
            toggleFavorite: {}
        )
        ChannelRow(
            stream: LiveStream(id: StreamID(2), name: "Another Channel With A Very Long Name That Truncates", iconURL: nil, categoryID: CategoryID(1), epgChannelID: nil),
            isFavorite: false,
            toggleFavorite: {}
        )
    }
}

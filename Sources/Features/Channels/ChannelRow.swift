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

            Spacer()

            #if os(tvOS)
            // Rows are single focusables on tvOS — the star is an indicator;
            // toggling happens via long-press menu or the play/pause button.
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? .yellow : .secondary)
            #else
            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            #endif
        }
        .contextMenu {
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", action: toggleFavorite)
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

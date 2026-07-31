import SwiftUI

/// A channel icon backed by ``ChannelIconLoader`` — the bounded, deduplicating
/// replacement for the per-row `AsyncImage`. The placeholder doubles as the
/// error state: a broken icon URL just keeps showing the generic TV glyph,
/// stable across reloads.
struct ChannelIconView: View {
    let url: URL?
    var loader: ChannelIconLoader = .shared

    @State private var icon: CGImage?

    var body: some View {
        ZStack {
            if let icon {
                Image(decorative: icon, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "tv")
                    .foregroundStyle(.secondary)
            }
        }
        // The icon never carries information the channel name doesn't; the
        // placeholder glyph must not be announced either.
        .accessibilityHidden(true)
        // task(id:) both cancels the await when the row scrolls away and
        // restarts it when a recycled row is handed a different channel; a
        // cache hit resolves before the next frame, so the reset can't
        // flicker an icon that is already decoded.
        .task(id: url) {
            icon = nil
            guard let url else { return }
            icon = await loader.image(for: url)
        }
    }
}

#Preview("Channel icon placeholder") {
    ChannelIconView(url: nil)
        .frame(width: 28, height: 28)
}

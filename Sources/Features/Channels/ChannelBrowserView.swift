import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Three-column browser: categories | channels (searchable) | player.
struct ChannelBrowserView: View {
    @StateObject private var channels: ChannelsViewModel
    @StateObject private var player = PlayerViewModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isFullScreen = false
    #if !os(macOS)
    @State private var showingSettings = false
    #endif

    init(account: Account) {
        _channels = StateObject(wrappedValue: ChannelsViewModel(account: account))
    }

    var body: some View {
        content
            .onChange(of: channels.selectedStreamID) { streamID in
                guard let streamID, let stream = channels.selectedStream() else { return }
                do {
                    player.play(stream, url: try channels.playbackURL(for: streamID))
                } catch {
                    player.fail(error)
                }
            }
            .onDisappear {
                player.stop()
            }
            #if os(macOS)
            // Track macOS full screen regardless of how it was triggered
            // (our button, green button, or Ctrl+Cmd+F).
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
                isFullScreen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
                isFullScreen = false
            }
            #endif
    }

    /// In full screen the split view is replaced by the bare player — video
    /// only, no columns, no toolbar. macOS can't collapse the content column
    /// of a NavigationSplitView, so swapping the hierarchy is the reliable way.
    @ViewBuilder
    private var content: some View {
        if isFullScreen {
            PlayerView(viewModel: player, onWillToggleFullScreen: playerWillToggleFullScreen, hidesChrome: true)
                .windowToolbarHidden(true)
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                categoryColumn
                    .navigationSplitViewColumnWidth(min: 200, ideal: 250)
                #if !os(macOS)
                    .toolbar {
                        ToolbarItem {
                            Button {
                                showingSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
                #endif
            } content: {
                channelColumn
                    .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            } detail: {
                PlayerView(viewModel: player, onWillToggleFullScreen: playerWillToggleFullScreen)
            }
            #if !os(macOS)
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            #endif
        }
    }

    private func playerWillToggleFullScreen() {
        if !isFullScreen {
            isFullScreen = true
        }
    }

    @ViewBuilder
    private var categoryColumn: some View {
        switch channels.categoriesPhase {
        case .loading:
            ProgressView("Loading categories…")
        case .failed(let message):
            LoadFailureView(message: message) {
                Task { await channels.loadCategories() }
            }
        case .loaded:
            List(selection: $channels.selectedCategory) {
                Label("All Channels", systemImage: "square.grid.2x2")
                    .tag(CategorySelection.all)
                Label("Favorites", systemImage: "star")
                    .tag(CategorySelection.favorites)

                Section("Categories") {
                    ForEach(channels.categories) { category in
                        Text(category.name)
                            .tag(CategorySelection.category(category.id))
                    }
                }
            }
            .navigationTitle("Categories")
        }
    }

    @ViewBuilder
    private var channelColumn: some View {
        switch channels.streamsPhase {
        case .loading:
            ProgressView("Loading channels…")
        case .failed(let message):
            LoadFailureView(message: message) {
                Task { await channels.loadStreams(bypassCache: true) }
            }
        case .loaded:
            if channels.selectedCategory == nil {
                Text("Select a category")
                    .foregroundStyle(.secondary)
            } else if channels.selectedCategory == .favorites && channels.streams.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "star")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No favorites yet")
                        .font(.headline)
                    Text("Right-click any channel and choose “Add to Favorites”.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                List(channels.filteredStreams, selection: $channels.selectedStreamID) { stream in
                    ChannelRow(
                        stream: stream,
                        isFavorite: channels.isFavorite(stream.id),
                        toggleFavorite: { channels.toggleFavorite(stream.id) }
                    )
                }
                .navigationTitle("Channels")
                #if os(tvOS)
                .searchable(text: $channels.searchText, prompt: "Search channels")
                #else
                .searchable(text: $channels.searchText, placement: .toolbar, prompt: "Search channels")
                #endif
            }
        }
    }
}

private struct ChannelRow: View {
    let stream: LiveStream
    let isFavorite: Bool
    let toggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            AsyncImage(url: stream.iconURL) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "tv")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)

            Text(stream.name)
                .lineLimit(1)

            Spacer()

            #if os(tvOS)
            // No context menus on tvOS 16 — a focusable star button instead.
            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            #else
            if isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .imageScale(.small)
            }
            #endif
        }
        #if !os(tvOS)
        .contextMenu {
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", action: toggleFavorite)
        }
        #endif
    }
}

private extension View {
    /// Hides the window toolbar in full screen — macOS concept only.
    @ViewBuilder
    func windowToolbarHidden(_ hidden: Bool) -> some View {
        #if os(macOS)
        toolbar(hidden ? .hidden : .automatic, for: .windowToolbar)
        #else
        self
        #endif
    }
}

private struct LoadFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: retry)
        }
        .padding()
    }
}

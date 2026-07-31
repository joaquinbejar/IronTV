#if !os(tvOS)
import SwiftUI

/// Pointer/touch presentation of the browser: three-column split view
/// (categories | channels | player) that swaps to a bare full-screen player.
/// In full screen the split view is replaced entirely — video only, no
/// columns, no toolbar — because macOS can't collapse the content column of
/// a NavigationSplitView, so swapping the hierarchy is the reliable way.
struct DesktopBrowserShell: View {
    @ObservedObject var channels: ChannelsViewModel
    @ObservedObject var player: PlayerViewModel
    @Binding var isFullScreen: Bool
    #if os(macOS)
    @ObservedObject var floatingManager: FloatingPlayerManager
    #endif

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #if !os(macOS)
    @State private var showingSettings = false
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    #endif

    var body: some View {
        content
            .task { applyDemoScreenIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if isFullScreen {
            PlayerView(viewModel: player, onWillToggleFullScreen: playerWillToggleFullScreen, hidesChrome: true)
                .windowToolbarHidden(true)
        } else {
            #if os(iOS)
            NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
                categoryColumn
                    .navigationSplitViewColumnWidth(min: 200, ideal: 250)
                    .toolbar {
                        ToolbarItem {
                            Button {
                                showingSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
            } content: {
                channelColumn
                    .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            } detail: {
                PlayerView(viewModel: player, onWillToggleFullScreen: playerWillToggleFullScreen)
                    .onDisappear {
                        if horizontalSizeClass == .compact {
                            player.stop()
                            channels.selectedStreamID = nil
                        }
                    }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            #else
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
                #if os(macOS)
                PlayerView(
                    viewModel: player,
                    onWillToggleFullScreen: playerWillToggleFullScreen,
                    onToggleFloating: { floatingManager.toggle(with: player) }
                )
                #else
                PlayerView(viewModel: player, onWillToggleFullScreen: playerWillToggleFullScreen)
                #endif
            }
            #endif
        }
    }

    private func playerWillToggleFullScreen() {
        if !isFullScreen {
            isFullScreen = true
        }
    }

    private func applyDemoScreenIfNeeded() {
        DemoRouting.applyDesktopScreenIfNeeded(
            channels: channels,
            player: player,
            showChannelList: {
                #if os(iOS)
                preferredCompactColumn = .content
                #endif
            },
            showPlayer: {
                #if os(iOS)
                preferredCompactColumn = .detail
                #endif
            },
            showSettings: {
                #if !os(macOS)
                showingSettings = true
                #endif
            }
        )
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
                    // The hint must name the interaction each platform
                    // actually has: context menu under a pointer, the row's
                    // star button under touch.
                    #if os(macOS)
                    Text("Right-click any channel and choose “Add to Favorites”.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    #else
                    Text("Tap the star on any channel to add it.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    #endif
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
                .searchable(text: $channels.searchText, placement: .toolbar, prompt: "Search channels")
            }
        }
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
#endif

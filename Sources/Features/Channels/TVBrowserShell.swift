#if os(tvOS)
import SwiftUI

/// Focus-driven presentation of the browser: a full-screen navigation stack —
/// categories, then the channel list, then the player — instead of columns.
struct TVBrowserShell: View {
    @ObservedObject var channels: ChannelsViewModel
    @ObservedObject var player: PlayerViewModel

    @State private var tvPath = NavigationPath()
    @State private var showingSettings = false

    var body: some View {
        NavigationStack(path: $tvPath) {
            Group {
                switch channels.categoriesPhase {
                case .loading:
                    ProgressView("Loading categories…")
                case .failed(let message):
                    LoadFailureView(message: message) {
                        Task { await channels.loadCategories() }
                    }
                case .loaded:
                    List {
                        NavigationLink(value: CategorySelection.all) {
                            Label("All Channels", systemImage: "square.grid.2x2")
                        }
                        NavigationLink(value: CategorySelection.favorites) {
                            Label("Favorites", systemImage: "star")
                        }
                        Section("Categories") {
                            ForEach(channels.categories) { category in
                                NavigationLink(category.name, value: CategorySelection.category(category.id))
                            }
                        }
                    }
                }
            }
            .navigationTitle("IronTV")
            .navigationDestination(for: CategorySelection.self) { selection in
                TVChannelListScreen(channels: channels, player: player, selection: selection, title: title(for: selection))
            }
            .navigationDestination(for: LiveStream.self) { stream in
                TVPlayerScreen(channels: channels, player: player, stream: stream)
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("browser.settingsButton")
                }
            }
        }
        .task { DemoRouting.applyTVScreenIfNeeded(path: &tvPath) }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    private func title(for selection: CategorySelection) -> String {
        switch selection {
        case .all: return String(localized: "All Channels")
        case .favorites: return String(localized: "Favorites")
        case .category(let id): return channels.categories.first { $0.id == id }?.name ?? String(localized: "Channels")
        }
    }
}

/// Full-screen channel list for one category scope, pushed from the
/// categories screen. Selecting a channel pushes the full-screen player.
struct TVChannelListScreen: View {
    @ObservedObject var channels: ChannelsViewModel
    @ObservedObject var player: PlayerViewModel
    let selection: CategorySelection
    let title: String

    var body: some View {
        Group {
            switch channels.streamsPhase {
            case .loading:
                ProgressView("Loading channels…")
            case .failed(let message):
                LoadFailureView(message: message) {
                    Task { await channels.loadStreams(bypassCache: true) }
                }
            case .loaded:
                if selection == .favorites && channels.streams.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "star")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No favorites yet")
                            .font(.headline)
                        // The star on a row is an indicator, not a control —
                        // the copy names the actions that actually exist.
                        Text("Focus a channel and press Play/Pause to add it, or hold for more options.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    List(channels.visibleStreams) { stream in
                        NavigationLink(value: stream) {
                            ChannelRow(
                                stream: stream,
                                isFavorite: channels.isFavorite(stream.id),
                                toggleFavorite: { channels.toggleFavorite(stream.id) }
                            )
                        }
                        // Play/pause on the remote toggles favorite on the
                        // focused row; long-press opens the context menu.
                        .onPlayPauseCommand {
                            channels.toggleFavorite(stream.id)
                        }
                    }
                    .searchable(text: $channels.searchText, prompt: "Search channels")
                }
            }
        }
        .navigationTitle(title)
        .onAppear {
            channels.selectedCategory = selection
        }
    }
}

/// Full-screen playback; the Menu button pops back and stops the stream.
struct TVPlayerScreen: View {
    @ObservedObject var channels: ChannelsViewModel
    @ObservedObject var player: PlayerViewModel
    @Environment(\.scenePhase) private var scenePhase
    let stream: LiveStream

    var body: some View {
        PlayerView(viewModel: player, hidesChrome: true)
            .ignoresSafeArea()
            .onChange(of: scenePhase) { _, phase in
                // Standing on the player screen IS the explicit intent to
                // watch this channel: foregrounding resumes it (backgrounding
                // stopped it and released the provider slot). Leaving the
                // screen stops playback like before — this is per-screen
                // resume, not the global auto-play the policy rejects.
                guard phase == .active, player.currentStream == nil else { return }
                startPlayback()
            }
            .onAppear {
                channels.selectedStreamID = stream.id // remembers last channel
                startPlayback()
            }
            .onDisappear {
                player.stop()
            }
    }

    /// The capabilities-aware playback path — the same coordinator the other
    /// platforms use (TS-only panels lead with VLC, trusted direct sources).
    private func startPlayback() {
        let coordinator = PlaybackCoordinator(channels: channels, player: player)
        Task { await coordinator.startPlayback(of: stream) }
    }
}
#endif

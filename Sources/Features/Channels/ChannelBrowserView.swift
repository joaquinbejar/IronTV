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
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    #endif
    #if os(tvOS)
    @State private var tvPath = NavigationPath()
    #endif
    #if os(macOS)
    @StateObject private var floatingManager = FloatingPlayerManager()
    #endif

    init(account: Account) {
        _channels = StateObject(wrappedValue: ChannelsViewModel(account: account))
    }

    var body: some View {
        content
            #if !os(tvOS)
            .task { applyDemoScreenIfNeeded() }
            #endif
            .onChange(of: channels.selectedStreamID) { _, streamID in
                // tvOS navigates by pushing screens; playback starts there.
                #if !os(tvOS)
                guard let streamID, let stream = channels.selectedStream() else { return }
                do {
                    player.play(
                        stream,
                        url: try channels.playbackURL(for: streamID),
                        tsURL: channels.playbackTSURL(for: streamID)
                    )
                } catch {
                    player.fail(error)
                }
                #endif
            }
            .onDisappear {
                #if os(macOS)
                floatingManager.exitIfNeeded(viewModel: player)
                #endif
                player.stop()
            }
            #if os(macOS)
            // Hand the floating player this window explicitly, so entering
            // mini-player mode hides and restores the browser rather than
            // whichever main-capable window AppKit happens to list first.
            .background(HostWindowReader { floatingManager.recordSourceWindow($0) })
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
    /// tvOS gets a full-screen navigation stack instead of columns.
    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        tvContent
        #else
        desktopContent
        #endif
    }

    #if os(tvOS)
    private func tvTitle(_ selection: CategorySelection) -> String {
        switch selection {
        case .all: return "All Channels"
        case .favorites: return "Favorites"
        case .category(let id): return channels.categories.first { $0.id == id }?.name ?? "Channels"
        }
    }

    private var tvContent: some View {
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
                TVChannelListScreen(channels: channels, player: player, selection: selection, title: tvTitle(selection))
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
                }
            }
        }
        .task { applyTVDemoScreenIfNeeded() }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    /// tvOS screenshot deep-link (separate nav model from iOS/macOS).
    private func applyTVDemoScreenIfNeeded() {
        guard DemoMode.isActive,
              let screen = ProcessInfo.processInfo.environment["IRONTV_DEMO_SCREEN"] else { return }
        switch screen {
        case "channels":
            tvPath.append(CategorySelection.category(CategoryID(2)))
        case "favorites":
            tvPath.append(CategorySelection.favorites)
        case "player":
            tvPath.append(CategorySelection.category(CategoryID(2)))
            if let stream = DemoMode.streams(in: .category(CategoryID(2))).first(where: { $0.name == "Match Day FHD" }) {
                tvPath.append(stream)
            }
        default:
            break
        }
    }
    #endif

    @ViewBuilder
    private var desktopContent: some View {
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

    #if !os(tvOS)
    /// Screenshot deep-link: IRONTV_DEMO_SCREEN drives the app straight to one
    /// screen so App Store captures are deterministic. No-op in normal use.
    private func applyDemoScreenIfNeeded() {
        guard DemoMode.isActive,
              let screen = ProcessInfo.processInfo.environment["IRONTV_DEMO_SCREEN"] else { return }
        switch screen {
        case "channels":
            channels.selectedCategory = .category(CategoryID(2)) // Sports
            #if os(iOS)
            preferredCompactColumn = .content
            #endif
        case "favorites":
            channels.selectedCategory = .favorites
            #if os(iOS)
            preferredCompactColumn = .content
            #endif
        case "player":
            channels.selectedCategory = .category(CategoryID(2))
            #if os(iOS)
            preferredCompactColumn = .detail
            #endif
            // Play the bundled demo clip directly — avoids the async
            // stream-load race that would leave the player idle.
            if let stream = DemoMode.streams(in: .category(CategoryID(2))).first(where: { $0.name == "Match Day FHD" }) {
                player.play(stream, url: DemoMode.screenshotClipURL)
            }
        #if !os(macOS)
        case "settings":
            showingSettings = true
        #endif
        default:
            break
        }
    }
    #endif

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

#if os(tvOS)
/// Full-screen channel list for one category scope, pushed from the
/// categories screen. Selecting a channel pushes the full-screen player.
private struct TVChannelListScreen: View {
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
                        Text("Focus a channel and press the star to add it.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    List(channels.filteredStreams) { stream in
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
private struct TVPlayerScreen: View {
    @ObservedObject var channels: ChannelsViewModel
    @ObservedObject var player: PlayerViewModel
    let stream: LiveStream

    var body: some View {
        PlayerView(viewModel: player, hidesChrome: true)
            .ignoresSafeArea()
            .onAppear {
                channels.selectedStreamID = stream.id // remembers last channel
                do {
                    player.play(
                        stream,
                        url: try channels.playbackURL(for: stream.id),
                        tsURL: channels.playbackTSURL(for: stream.id)
                    )
                } catch {
                    player.fail(error)
                }
            }
            .onDisappear {
                player.stop()
            }
    }
}
#endif

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

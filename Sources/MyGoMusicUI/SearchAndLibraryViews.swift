// SearchAndLibraryViews.swift
// 对应原项目 internal/app/ui_search.go, ui_suggest.go, ui_playlistedit.go 的搜索与音乐库视图

#if canImport(MyGoMusicCore)
import MyGoMusicCore
#endif
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 搜索视图（对应 ui_search.go / ui_suggest.go）

public struct SearchView: View {
    @EnvironmentObject private var app: AppModel
    @State private var navPath = NavigationPath()
    @FocusState private var isSearchFieldFocused: Bool

    public init() {}

    /// 统一收敛焦点与系统/第三方输入法键盘，防止结果页和底部弹窗被遮挡
    private func dismissSearchKeyboard() {
        isSearchFieldFocused = false
        MyGoKeyboard.dismiss()
    }

    /// 执行搜索并立即自动退回键盘
    private func submitSearch() {
        dismissSearchKeyboard()
        Task { await app.performSearch() }
    }

    public var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                // 顶部搜索框与分类切换
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField(I18n.t("Search for something to play."), text: $app.searchQuery)
                            .focused($isSearchFieldFocused)
                            .submitLabel(.search)
                            .onSubmit {
                                submitSearch()
                            }
                            .onChange(of: app.searchQuery) { _, newValue in
                                Task { await app.updateSuggestions(for: newValue) }
                            }
                        if !app.searchQuery.isEmpty {
                            Button {
                                app.searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        if isSearchFieldFocused {
                            Button {
                                dismissSearchKeyboard()
                            } label: {
                                Image(systemName: "keyboard.chevron.compact.down")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(I18n.t("Done"))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    searchKindChips
                        .onChange(of: app.searchKind) { _, _ in
                            dismissSearchKeyboard()
                            if !app.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                                Task { await app.performSearch() }
                            }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if app.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                            recentSearchHistorySection
                        } else if app.isSearching {
                            ProgressView(I18n.t("Loading…"))
                                .frame(maxWidth: .infinity, minHeight: 200)
                        } else {
                            if !app.searchSuggestions.isEmpty && app.searchResult.count == 0 {
                                suggestionsSection
                            }
                            searchResultsSection
                            if app.searchResult.more == true {
                                LoadMoreButton(isLoading: app.isLoadingMoreSearch) {
                                    dismissSearchKeyboard()
                                    Task { await app.loadMoreSearch() }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 10)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .onChange(of: app.activeSourceID) { _, _ in
                dismissSearchKeyboard()
            }
            .onDisappear {
                dismissSearchKeyboard()
            }
            .navigationTitle(I18n.t("Search"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    SourceSwitcherMenu()
                }
            }
            .navigationDestination(for: NavigationTarget.self) { target in
                HomeView.buildDestination(for: target)
            }
            .environment(\.mygoNavigate) { target in
                dismissSearchKeyboard()
                navPath.append(target)
            }
        }
    }

    private var searchKindChips: some View {
        let items: [(SearchKind, String)] = [
            (.tracks, I18n.t("Songs")),
            (.albums, I18n.t("Albums")),
            (.artists, I18n.t("Artists")),
            (.playlists, I18n.t("Playlists")),
            (.shows, I18n.t("Podcasts"))
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.0) { kind, label in
                    let isSelected = app.searchKind == kind
                    Button {
                        dismissSearchKeyboard()
                        app.searchKind = kind
                    } label: {
                        Text(label)
                            .font(.system(size: 13.5, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? AnyShapeStyle(MyGoTheme.accent) : AnyShapeStyle(Color.primary.opacity(0.08)),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func openSearchTarget(_ target: NavigationTarget) {
        dismissSearchKeyboard()
        navPath.append(target)
    }

    private var recentSearchHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !app.settings.searchHistory.isEmpty {
                HStack {
                    Text(I18n.t("Recent Searches"))
                        .font(.system(size: 17, weight: .bold))
                    Spacer()
                    Button(I18n.t("Clear")) {
                        dismissSearchKeyboard()
                        app.settings.searchHistory = []
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MyGoTheme.accent)
                }
                .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(app.settings.searchHistory, id: \.self) { item in
                            Button {
                                app.searchQuery = item
                                submitSearch()
                            } label: {
                                Text(item)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(Color.primary.opacity(0.07), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text(I18n.t("Search for something to play."))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissSearchKeyboard()
                }
            }
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(I18n.t("Suggestions"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            ForEach(app.searchSuggestions, id: \.self) { suggestion in
                Button {
                    app.searchQuery = suggestion
                    submitSearch()
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text(suggestion)
                            .font(.system(size: 14.5))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        switch app.searchKind {
        case .tracks:
            let tracks = app.searchResult.tracks ?? []
            if tracks.isEmpty {
                emptyResultView
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.compositeKey) { idx, tr in
                        TrackRowView(track: tr, index: idx) {
                            dismissSearchKeyboard()
                            app.player.playTrack(tracks, at: idx)
                        }
                        .padding(.horizontal, 8)
                    }
                }
            }
        case .albums:
            let albums = app.searchResult.albums ?? []
            if albums.isEmpty {
                emptyResultView
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(albums) { album in
                        Button {
                            openSearchTarget(.album(id: album.id, name: album.name))
                        } label: {
                            CoverCardView(
                                title: album.name,
                                subtitle: album.artistNames,
                                imageURL: album.imageUrl,
                                systemIcon: "opticaldisc"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        case .artists:
            let artists = app.searchResult.artists ?? []
            if artists.isEmpty {
                emptyResultView
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 20) {
                    ForEach(artists) { artist in
                        Button {
                            openSearchTarget(.artist(id: artist.id, name: artist.name))
                        } label: {
                            CoverCardView(
                                title: artist.name,
                                subtitle: I18n.t("Artist"),
                                imageURL: artist.imageUrl,
                                systemIcon: "person.wave.2",
                                isCircular: true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        case .playlists:
            let playlists = app.searchResult.playlists ?? []
            if playlists.isEmpty {
                emptyResultView
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(playlists) { pl in
                        Button {
                            openSearchTarget(.playlist(id: pl.id, name: pl.name))
                        } label: {
                            CoverCardView(
                                title: pl.name,
                                subtitle: pl.trackCount.map(I18n.songs),
                                imageURL: pl.imageUrl,
                                systemIcon: "music.note.list"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        case .shows:
            let shows = app.searchResult.shows ?? []
            if shows.isEmpty {
                emptyResultView
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(shows) { show in
                        Button {
                            openSearchTarget(.show(id: show.id, name: show.name))
                        } label: {
                            CoverCardView(
                                title: show.name,
                                subtitle: show.publisher,
                                imageURL: show.imageUrl,
                                systemIcon: "mic.fill"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var emptyResultView: some View {
        Text(I18n.t("Nothing found"))
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 180)
            .contentShape(Rectangle())
            .onTapGesture {
                dismissSearchKeyboard()
            }
    }
}

// MARK: - 音乐库与歌单管理视图（对应 sidebar 中的导航与歌单区域）

public struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @State private var navPath = NavigationPath()
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var renamingPlaylist: Playlist? = nil
    @State private var renameText = ""
    @State private var showFileImporter = false

    public init() {}

    public var body: some View {
        let info = app.activeSource.info()
        NavigationStack(path: $navPath) {
            List {
                // 当前音源内置与自定义导航入口（遵循插件 navigation 的自定义标题/图标）
                SwiftUI.Section(info.name) {
                    if app.activeSource.can("liked") {
                        NavigationLink(value: NavigationTarget.likedSongs) {
                            Label(
                                info.customTitle(forBuiltin: "liked") ?? I18n.t("Liked Songs"),
                                systemImage: info.customIcon(forBuiltin: "liked").map { sfSymbol(for: $0) } ?? "heart.fill"
                            )
                            .foregroundStyle(.primary)
                        }
                    }
                    if app.activeSource.can("savedAlbums") {
                        NavigationLink(value: NavigationTarget.savedAlbums) {
                            Label(
                                info.customTitle(forBuiltin: "savedAlbums") ?? I18n.t("Saved Albums"),
                                systemImage: info.customIcon(forBuiltin: "savedAlbums").map { sfSymbol(for: $0) } ?? "square.stack.fill"
                            )
                        }
                    }
                    if app.activeSource.can("stations") {
                        NavigationLink(value: NavigationTarget.stations) {
                            Label(
                                info.customTitle(forBuiltin: "stations") ?? I18n.t("Stations"),
                                systemImage: info.customIcon(forBuiltin: "stations").map { sfSymbol(for: $0) } ?? "dot.radiowaves.left.and.right"
                            )
                        }
                    }
                    if app.activeSource.can("shows") {
                        NavigationLink(value: NavigationTarget.podcasts) {
                            Label(
                                info.customTitle(forBuiltin: "shows") ?? I18n.t("Podcasts"),
                                systemImage: info.customIcon(forBuiltin: "shows").map { sfSymbol(for: $0) } ?? "mic.fill"
                            )
                        }
                    }

                    // 插件自定义导航页（如 Songs, Albums, Artists, Charts 等）
                    if let navItems = info.navigation {
                        ForEach(Array(navItems.enumerated()), id: \.offset) { _, item in
                            if let page = item.page, !page.isEmpty, item.builtin == nil {
                                NavigationLink(value: NavigationTarget.browse(page: page, title: item.title)) {
                                    Label(item.title ?? page, systemImage: sfSymbol(for: item.icon))
                                }
                            }
                        }
                    }

                    if app.activeSourceID == LocalMusicSource.sourceID {
                        Button {
                            showFileImporter = true
                        } label: {
                            Label(I18n.t("Import Audio Files…"), systemImage: "folder.badge.plus")
                                .foregroundStyle(MyGoTheme.accent)
                        }
                    }
                }

                // 自建歌单
                if app.activeSource.can("playlists") {
                    SwiftUI.Section {
                        ForEach(app.myPlaylists) { pl in
                            NavigationLink(value: NavigationTarget.playlist(id: pl.id, name: pl.name)) {
                                HStack(spacing: 12) {
                                    ArtworkView(
                                        urlString: pl.imageUrl,
                                        pixelSize: 120,
                                        size: 40,
                                        cornerRadius: 8,
                                        systemIcon: "music.note.list"
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pl.name)
                                            .font(.system(size: 15, weight: .medium))
                                        if let cnt = pl.trackCount {
                                            Text(I18n.songs(cnt))
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .contextMenu {
                                if pl.fixed != true {
                                    if app.activeSource.can("renamePlaylist") {
                                        Button {
                                            renameText = pl.name
                                            renamingPlaylist = pl
                                        } label: {
                                            Label(I18n.t("Rename…"), systemImage: "pencil")
                                        }
                                    }
                                    if app.activeSource.can("deletePlaylist") {
                                        Button(role: .destructive) {
                                            Task { await app.deletePlaylist(id: pl.id) }
                                        } label: {
                                            Label(I18n.t("Delete Playlist…"), systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(I18n.t("My Playlists"))
                            Spacer()
                            if app.activeSource.can("createPlaylist") {
                                Button {
                                    newPlaylistName = ""
                                    showNewPlaylistAlert = true
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(MyGoTheme.accent)
                                }
                            }
                        }
                    }

                    if !app.savedPlaylists.isEmpty {
                        SwiftUI.Section(I18n.t("Saved Playlists")) {
                            ForEach(app.savedPlaylists) { pl in
                                NavigationLink(value: NavigationTarget.playlist(id: pl.id, name: pl.name)) {
                                    HStack(spacing: 12) {
                                        ArtworkView(
                                            urlString: pl.imageUrl,
                                            pixelSize: 120,
                                            size: 40,
                                            cornerRadius: 8,
                                            systemIcon: "music.note.list"
                                        )
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(pl.name)
                                                .font(.system(size: 15, weight: .medium))
                                            Text([pl.trackCount.map(I18n.songs), pl.owner].compactMap { $0 }.joined(separator: " · "))
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(I18n.t("Library"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    SourceSwitcherMenu()
                }
            }
            .navigationDestination(for: NavigationTarget.self) { target in
                HomeView.buildDestination(for: target)
            }
            .environment(\.mygoNavigate) { target in
                navPath.append(target)
            }
            .alert(I18n.t("New Playlist"), isPresented: $showNewPlaylistAlert) {
                TextField(I18n.t("Playlist Name"), text: $newPlaylistName)
                Button(I18n.t("Cancel"), role: .cancel) {}
                Button(I18n.t("Create")) {
                    let name = newPlaylistName
                    Task { await app.createPlaylist(name: name) }
                }
            }
            .alert(
                I18n.t("Rename Playlist"),
                isPresented: Binding(
                    get: { renamingPlaylist != nil },
                    set: { if !$0 { renamingPlaylist = nil } }
                )
            ) {
                TextField(I18n.t("Playlist Name"), text: $renameText)
                Button(I18n.t("Cancel"), role: .cancel) { renamingPlaylist = nil }
                Button(I18n.t("Save")) {
                    if let target = renamingPlaylist {
                        let newName = renameText
                        renamingPlaylist = nil
                        Task { await app.renamePlaylist(id: target.id, name: newName) }
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio, .folder],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    let importedCount = app.localSource.importAudioFiles(urls)
                    if importedCount > 0 {
                        Task { await app.refreshActiveSource() }
                    } else {
                        app.showToast(I18n.t("No audio files imported"))
                    }
                }
            }
        }
    }

    private func sfSymbol(for iconName: String?) -> String {
        switch iconName {
        case "home": return "house"
        case "note": return "music.note"
        case "album": return "opticaldisc"
        case "artist": return "person.wave.2"
        case "playlist": return "music.note.list"
        case "radio": return "dot.radiowaves.left.and.right"
        case "podcast": return "mic"
        case "chart": return "chart.bar.fill"
        case "calendar": return "calendar"
        case "heart": return "heart"
        case "search": return "magnifyingglass"
        case "star": return "star"
        default: return "music.note.list"
        }
    }
}

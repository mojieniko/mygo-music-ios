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
                    .mygoElevatedSurface(cornerRadius: 12)

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
                    LazyVStack(alignment: .leading, spacing: 20) {
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
                .mygoTrackVerticalScroll()
            }
            .background(MyGoTheme.pageBackground.ignoresSafeArea())
            .onChange(of: app.activeSourceID) { _, _ in
                dismissSearchKeyboard()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mygoFocusSearchField)) { _ in
                isSearchFieldFocused = true
            }
            .onDisappear {
                dismissSearchKeyboard()
            }
            .navigationTitle(I18n.t("Search"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
                            .mygoPillSurface(isHighlighted: isSelected)
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
                                    .mygoPillSurface()
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
                LazyTrackRowsView(tracks: tracks) { list, idx in
                    dismissSearchKeyboard()
                    app.player.playTrack(list, at: idx)
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
                // 当前音源内置与自定义导航入口（统一 Apple Music 绯红左侧图标语义，对齐深/浅色层次）
                SwiftUI.Section(info.name) {
                    if app.activeSource.can("liked") {
                        libraryNavRow(
                            title: info.customTitle(forBuiltin: "liked") ?? I18n.t("Liked Songs"),
                            systemImage: info.customIcon(forBuiltin: "liked").map { MyGoNavIconKind.sfSymbol(for: $0) } ?? "heart.fill",
                            value: .likedSongs
                        )
                    }
                    if app.activeSource.can("savedAlbums") {
                        libraryNavRow(
                            title: info.customTitle(forBuiltin: "savedAlbums") ?? I18n.t("Saved Albums"),
                            systemImage: info.customIcon(forBuiltin: "savedAlbums").map { MyGoNavIconKind.sfSymbol(for: $0) } ?? "square.stack.fill",
                            value: .savedAlbums
                        )
                    }
                    if app.activeSource.can("stations") {
                        libraryNavRow(
                            title: info.customTitle(forBuiltin: "stations") ?? I18n.t("Stations"),
                            systemImage: info.customIcon(forBuiltin: "stations").map { MyGoNavIconKind.sfSymbol(for: $0) } ?? "dot.radiowaves.left.and.right",
                            value: .stations
                        )
                    }
                    if app.activeSource.can("shows") {
                        libraryNavRow(
                            title: info.customTitle(forBuiltin: "shows") ?? I18n.t("Podcasts"),
                            systemImage: info.customIcon(forBuiltin: "shows").map { MyGoNavIconKind.sfSymbol(for: $0) } ?? "mic.fill",
                            value: .podcasts
                        )
                    }

                    // 插件自定义导航页（如 Songs, Albums, Artists, Charts 等）
                    if let navItems = info.navigation {
                        ForEach(Array(navItems.enumerated()), id: \.offset) { _, item in
                            if let page = item.page, !page.isEmpty, item.builtin == nil {
                                libraryNavRow(
                                    title: item.title ?? page,
                                    systemImage: MyGoNavIconKind.sfSymbol(for: item.icon),
                                    value: .browse(page: page, title: item.title)
                                )
                            }
                        }
                    }

                    if app.activeSourceID == LocalMusicSource.sourceID {
                        Button {
                            showFileImporter = true
                        } label: {
                            Label {
                                Text(I18n.t("Import Audio Files…"))
                                    .foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 15.5, weight: .semibold))
                                    .foregroundStyle(MyGoTheme.accent)
                                    .frame(width: 24)
                            }
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
            .mygoTrackVerticalScroll()
            .navigationTitle(I18n.t("Library"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: NavigationTarget.self) { target in
                HomeView.buildDestination(for: target)
            }
            .onReceive(NotificationCenter.default.publisher(for: .mygoOpenLibraryTarget)) { note in
                if let target = note.object as? NavigationTarget {
                    navPath.append(target)
                }
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

    @ViewBuilder
    private func libraryNavRow(title: String, systemImage: String, value: NavigationTarget) -> some View {
        NavigationLink(value: value) {
            Label {
                Text(title)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(MyGoTheme.accent)
                    .frame(width: 24)
            }
        }
    }
}

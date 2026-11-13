// HomeAndBrowseViews.swift
// 对应原项目 internal/app/ui_pages.go, ui_browse.go, ui_album.go, ui_artist.go, ui_podcast.go

#if canImport(MyGoMusicCore)
import MyGoMusicCore
#endif
import SwiftUI

// MARK: - 导航目标与环境跳转扩展

public enum NavigationTarget: Hashable {
    case browse(page: String, title: String?)
    case sectionTracks(title: String, subtitle: String?, tracks: [Track])
    case album(id: String, name: String)
    case artist(id: String, name: String)
    case playlist(id: String, name: String)
    case show(id: String, name: String)
    case likedSongs
    case savedAlbums
    case stations
    case podcasts
}

public extension SourceInfo {
    func customTitle(forBuiltin builtinKey: String) -> String? {
        guard let t = navigation?.first(where: { $0.builtin == builtinKey })?.title?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else {
            return nil
        }
        return t
    }

    func customIcon(forBuiltin builtinKey: String) -> String? {
        navigation?.first(where: { $0.builtin == builtinKey })?.icon
    }
}

private struct MyGoNavigateKey: EnvironmentKey {
    static let defaultValue: (NavigationTarget) -> Void = { _ in }
}

public extension EnvironmentValues {
    var mygoNavigate: (NavigationTarget) -> Void {
        get { self[MyGoNavigateKey.self] }
        set { self[MyGoNavigateKey.self] = newValue }
    }
}

/// 公共分页“加载更多”按钮
public struct LoadMoreButton: View {
    public let isLoading: Bool
    public let action: () -> Void

    public init(isLoading: Bool, action: @escaping () -> Void) {
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(I18n.t(isLoading ? "Loading…" : "Load More"))
                    .font(.system(size: 13.5, weight: .semibold))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }
}

// MARK: - 首页视图（对应 homePage / browseRows）

public struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @State private var navPath = NavigationPath()

    public init() {}

    public var body: some View {
        NavigationStack(path: $navPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    headerGreetingSection

                    if app.isLoadingHome && app.homeBrowse == nil && app.recentTracks.isEmpty {
                        ProgressView(I18n.t("Loading…"))
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else if let browse = app.homeBrowse, let sections = browse.sections, !sections.isEmpty {
                        BrowseSectionsStack(sections: sections, isHome: true) { target in
                            navPath.append(target)
                        }
                    } else if !app.recentTracks.isEmpty || !app.myPlaylists.isEmpty || !app.savedPlaylists.isEmpty {
                        fallbackHomeSections
                    } else {
                        emptyHomeState
                    }
                }
                .padding(.vertical, 16)
            }
            .navigationTitle(app.activeSource.info().customTitle(forBuiltin: "home") ?? I18n.t("Home"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    SourceSwitcherMenu()
                }
            }
            .refreshable {
                await app.refreshActiveSource()
            }
            .navigationDestination(for: NavigationTarget.self) { target in
                destinationView(for: target)
            }
            .environment(\.mygoNavigate) { target in
                navPath.append(target)
            }
        }
    }

    private var headerGreetingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(I18n.today())
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(alignment: .center) {
                // 左侧保持纯粹干练的大标题问候，不再与右侧用户名重复拼接，空间豁然开朗
                Text(I18n.greeting())
                    .font(.system(size: 28, weight: .bold))

                Spacer(minLength: 16)

                // 右侧展示精致账户胶囊（头像 + 姓名 + 箭头引导）
                if let acc = app.currentAccount {
                    Button {
                        if let page = acc.page, !page.isEmpty {
                            navPath.append(NavigationTarget.browse(page: page, title: I18n.t("My Page")))
                        }
                    } label: {
                        HStack(spacing: 7) {
                            if let img = acc.imageUrl, !img.isEmpty {
                                ArtworkView(
                                    urlString: img,
                                    pixelSize: 120,
                                    size: 26,
                                    cornerRadius: 13,
                                    systemIcon: "person.crop.circle.fill"
                                )
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 26, height: 26)
                                    .foregroundStyle(MyGoTheme.accent)
                            }
                            Text(acc.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary.opacity(0.6))
                        }
                        .padding(.leading, 4)
                        .padding(.trailing, 9)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
                        )
                        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var fallbackHomeSections: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !app.recentTracks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(I18n.t("Recently Played"))
                        .font(.system(size: 19, weight: .bold))
                        .padding(.horizontal, 16)
                    let slice = Array(app.recentTracks.prefix(8))
                    ForEach(Array(slice.enumerated()), id: \.element.compositeKey) { idx, tr in
                        TrackRowView(track: tr, index: idx) {
                            app.player.playTrack(slice, at: idx)
                        }
                        .padding(.horizontal, 8)
                    }
                }
            }

            let allPlaylists = app.myPlaylists + app.savedPlaylists
            if !allPlaylists.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(I18n.t("Playlists"))
                        .font(.system(size: 19, weight: .bold))
                        .padding(.horizontal, 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(allPlaylists) { pl in
                                Button {
                                    navPath.append(NavigationTarget.playlist(id: pl.id, name: pl.name))
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
                }
            }
        }
    }

    private var emptyHomeState: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 72, height: 72)
                .overlay(
                    Image(systemName: app.activeSourceID == LocalMusicSource.sourceID ? "folder.badge.plus" : "music.note")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.secondary)
                )

            if app.activeSourceID == LocalMusicSource.sourceID {
                Text(I18n.t("Add a music folder"))
                    .font(.system(size: 20, weight: .bold))
                Text(I18n.t("Choose where your music lives, and it will all be here: MP3, FLAC, Ogg, WAV and M4A files, with their tags, covers and lyrics."))
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else if app.activeSource.can("signIn") && app.currentAccount == nil {
                Text(I18n.tf("Sign in to %s", app.activeSource.info().name))
                    .font(.system(size: 20, weight: .bold))
                if let err = app.homeError, !err.isEmpty {
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Button {
                    Task { await app.signInToActiveSource() }
                } label: {
                    Label(I18n.t("Sign In"), systemImage: "person.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(MyGoTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            } else if let err = app.homeError, !err.isEmpty {
                Text(err)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button {
                    Task { await app.refreshActiveSource() }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(MyGoTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Text(I18n.t("Nothing here yet"))
                    .font(.system(size: 20, weight: .bold))
                Text(I18n.t("Search for something to play."))
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(.top, 24)
    }

    @ViewBuilder
    public static func buildDestination(for target: NavigationTarget) -> some View {
        switch target {
        case .browse(let page, let title):
            BrowsePageView(page: page, fallbackTitle: title)
        case .sectionTracks(let title, let subtitle, let tracks):
            SectionTracksPageView(title: title, subtitle: subtitle, tracks: tracks)
        case .album(let id, let name):
            AlbumDetailView(albumID: id, fallbackName: name)
        case .artist(let id, let name):
            ArtistDetailView(artistID: id, fallbackName: name)
        case .playlist(let id, let name):
            PlaylistDetailView(playlistID: id, fallbackName: name)
        case .show(let id, let name):
            PodcastShowDetailView(showID: id, fallbackName: name)
        case .likedSongs:
            LikedSongsView()
        case .savedAlbums:
            SavedAlbumsPageView()
        case .stations:
            StationsPageView()
        case .podcasts:
            SubscribedPodcastsPageView()
        }
    }

    @ViewBuilder
    private func destinationView(for target: NavigationTarget) -> some View {
        Self.buildDestination(for: target)
    }
}

// MARK: - 音源切换下拉菜单（对应 sourceSwitcher）

public struct SourceSwitcherMenu: View {
    @EnvironmentObject private var app: AppModel

    public init() {}

    public var body: some View {
        Menu {
            SwiftUI.Section(I18n.t("Sources")) {
                ForEach(app.enabledSources.map { $0.info() }) { info in
                    Button {
                        app.switchSource(to: info.id)
                    } label: {
                        HStack {
                            Text(info.name)
                            if info.id == app.activeSourceID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            if app.activeSource.can("signIn") {
                Divider()
                if let acc = app.currentAccount {
                    Text(I18n.tf("Signed in as %s", acc.name))
                    if app.activeSource.can("signOut") {
                        Button(role: .destructive) {
                            Task { await app.signOutOfActiveSource() }
                        } label: {
                            Label(I18n.t("Sign Out"), systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                } else {
                    Button {
                        Task { await app.signInToActiveSource() }
                    } label: {
                        Label(I18n.t("Sign In"), systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(MyGoTheme.accent)
                    .frame(width: 8, height: 8)
                Text(app.activeSource.info().name)
                    .font(.system(size: 13.5, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
    }
}

// MARK: - 通用 Browse 分区渲染器（对应 browseRows）

public struct BrowseSectionsStack: View {
    @EnvironmentObject private var app: AppModel
    public let sections: [MusicSection]
    public let isHome: Bool
    public let onNavigate: (NavigationTarget) -> Void

    public init(sections: [MusicSection], isHome: Bool = false, onNavigate: @escaping (NavigationTarget) -> Void) {
        self.sections = sections
        self.isHome = isHome
        self.onNavigate = onNavigate
    }

    public var body: some View {
        let firstTrackSectionIndex = isHome ? sections.firstIndex(where: { !($0.tracks ?? []).isEmpty }) : nil

        ForEach(Array(sections.enumerated()), id: \.offset) { idx, section in
            VStack(alignment: .leading, spacing: 12) {
                // 首页第一个歌曲分区展示为每日推荐黑胶卡片（对应 ui_daily.go）
                if idx == firstTrackSectionIndex, let tracks = section.tracks, !tracks.isEmpty {
                    let isPlayingFromHere = app.player.isPlaying && tracks.contains(where: { $0.compositeKey == app.player.currentTrack?.compositeKey })
                    DailyFeatureCardView(
                        section: section,
                        isPlayingFromCard: isPlayingFromHere,
                        audioBands: isPlayingFromHere ? app.player.audioBands : [0.2, 0.2, 0.2, 0.2],
                        onPlay: {
                            app.player.playQueue(tracks, start: 0)
                        },
                        onOpen: {
                            let pageTitle = section.pageTitle ?? section.title ?? I18n.t("Songs")
                            onNavigate(.sectionTracks(title: pageTitle, subtitle: section.subtitle, tracks: tracks))
                        }
                    )
                    .padding(.horizontal, 16)
                } else {
                    if let title = section.title, !title.isEmpty {
                        HStack {
                            Text(title)
                                .font(.system(size: 19, weight: .bold))
                            Spacer()
                            if let morePage = section.morePage, !morePage.isEmpty {
                                NavigationLink(value: NavigationTarget.browse(page: morePage, title: title)) {
                                    Text(I18n.t("See All"))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(MyGoTheme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // 歌曲列表
                    if let tracks = section.tracks, !tracks.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(Array(tracks.enumerated()), id: \.element.compositeKey) { tIdx, tr in
                                TrackRowView(track: tr, index: tIdx) {
                                    app.player.playTrack(tracks, at: tIdx)
                                }
                                .padding(.horizontal, 8)
                            }
                        }
                    }

                    // 专辑横向卡片栏
                    if let albums = section.albums, !albums.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(albums) { album in
                                    NavigationLink(value: NavigationTarget.album(id: album.id, name: album.name)) {
                                        CoverCardView(
                                            title: album.name,
                                            subtitle: album.artistNames.isEmpty ? album.released : album.artistNames,
                                            imageURL: album.imageUrl,
                                            systemIcon: "opticaldisc"
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    // 歌手横向圆形卡片栏
                    if let artists = section.artists, !artists.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(artists) { artist in
                                    NavigationLink(value: NavigationTarget.artist(id: artist.id, name: artist.name)) {
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
                    }

                    // 歌单横向卡片栏
                    if let playlists = section.playlists, !playlists.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(playlists) { pl in
                                    NavigationLink(value: NavigationTarget.playlist(id: pl.id, name: pl.name)) {
                                        CoverCardView(
                                            title: pl.name,
                                            subtitle: pl.trackCount.map(I18n.songs) ?? pl.owner,
                                            imageURL: pl.imageUrl,
                                            systemIcon: "music.note.list"
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    // 播客横向卡片栏
                    if let shows = section.shows, !shows.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(shows) { show in
                                    NavigationLink(value: NavigationTarget.show(id: show.id, name: show.name)) {
                                        CoverCardView(
                                            title: show.name,
                                            subtitle: show.publisher ?? show.episodeCount.map(I18n.episodes),
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

                    // 电台卡片栏（支持点击卡片任何位置及播放按钮）
                    if let stations = section.stations, !stations.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(stations) { station in
                                    CoverCardView(
                                        title: station.name,
                                        subtitle: station.description ?? I18n.t("Radio"),
                                        imageURL: station.imageUrl,
                                        systemIcon: "dot.radiowaves.left.and.right",
                                        onPlay: {
                                            Task { await app.startStation(station) }
                                        },
                                        onTap: {
                                            Task { await app.startStation(station) }
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    // 自定义页面链接卡片（Links）
                    if let links = section.links, !links.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(links, id: \.page) { link in
                                NavigationLink(value: NavigationTarget.browse(page: link.page, title: link.title)) {
                                    HStack(spacing: 12) {
                                        ArtworkView(
                                            urlString: link.imageUrl,
                                            pixelSize: 120,
                                            size: 46,
                                            cornerRadius: 10,
                                            systemIcon: "sparkles"
                                        )
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(link.title)
                                                .font(.system(size: 15, weight: .semibold))
                                            if let sub = link.subtitle, !sub.isEmpty {
                                                Text(sub)
                                                    .font(.system(size: 12.5))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(12)
                                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }
}

// MARK: - 自定义 Browse 页面与详情页

public struct BrowsePageView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.mygoNavigate) private var mygoNavigate
    public let page: String
    public let fallbackTitle: String?

    @State private var browseData: Browse? = nil
    @State private var isLoading = true
    @State private var errorMsg: String? = nil

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let sub = browseData?.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
                if let desc = browseData?.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let errorMsg {
                    Text(errorMsg)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let sections = browseData?.sections {
                    BrowseSectionsStack(sections: sections, isHome: false) { target in
                        mygoNavigate(target)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(browseData?.title ?? fallbackTitle ?? I18n.t("Discover"))
        .task {
            isLoading = true
            do {
                let res = try await app.activeSource.browse(page: page)
                self.browseData = res
            } catch {
                self.errorMsg = error.localizedDescription
            }
            isLoading = false
        }
    }
}

public struct SectionTracksPageView: View {
    @EnvironmentObject private var app: AppModel
    public let title: String
    public let subtitle: String?
    public let tracks: [Track]
    public var hasMore: Bool = false
    public var isLoadingMore: Bool = false
    public var onLoadMore: (() async -> Void)? = nil

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Button {
                        app.player.playQueue(tracks, start: 0)
                    } label: {
                        Label(I18n.t("Play"), systemImage: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(MyGoTheme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        app.player.playShuffled(tracks)
                    } label: {
                        Label(I18n.t("Shuffle"), systemImage: "shuffle")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }

                VStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.compositeKey) { idx, tr in
                        TrackRowView(track: tr, index: idx) {
                            app.player.playTrack(tracks, at: idx)
                        }
                        .padding(.horizontal, 8)
                    }
                }

                if hasMore, let onLoadMore {
                    LoadMoreButton(isLoading: isLoadingMore) {
                        Task { await onLoadMore() }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(title)
    }
}

public struct AlbumDetailView: View {
    @EnvironmentObject private var app: AppModel
    public let albumID: String
    public let fallbackName: String

    @State private var albumPage: AlbumPage? = nil
    @State private var isLoading = true
    @State private var isSaved = false

    public var body: some View {
        ScrollView {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if let page = albumPage {
                let tracks = page.tracks ?? []
                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        ArtworkView(
                            urlString: page.album.imageUrl,
                            pixelSize: 600,
                            size: 200,
                            cornerRadius: 16,
                            systemIcon: "opticaldisc"
                        )
                        .shadow(color: .black.opacity(0.24), radius: 16, x: 0, y: 8)

                        Text(page.album.name)
                            .font(.system(size: 22, weight: .bold))
                            .multilineTextAlignment(.center)

                        Text([page.album.artistNames, page.album.released].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button {
                                app.player.playQueue(tracks, start: 0)
                            } label: {
                                Label(I18n.t("Play"), systemImage: "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(MyGoTheme.accent, in: Capsule())
                            }
                            .buttonStyle(.plain)

                            Button {
                                app.player.playShuffled(tracks)
                            } label: {
                                Label(I18n.t("Shuffle"), systemImage: "shuffle")
                                    .font(.system(size: 14, weight: .semibold))
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(Color.primary.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)

                            if app.activeSource.can("saveAlbum") {
                                let srcID = app.activeSourceID
                                Button {
                                    Task {
                                        isSaved = await app.toggleSaveAlbum(sourceID: srcID, albumID: albumID, currentlySaved: isSaved)
                                    }
                                } label: {
                                    Image(systemName: isSaved ? "heart.fill" : "heart")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(isSaved ? MyGoTheme.accent : .primary)
                                        .frame(width: 40, height: 40)
                                        .background(Color.primary.opacity(0.08), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(I18n.t(isSaved ? "Saved" : "Save Album"))
                            }
                        }
                    }
                    .padding(.top, 12)

                    VStack(spacing: 2) {
                        ForEach(Array(tracks.enumerated()), id: \.element.compositeKey) { idx, tr in
                            TrackRowView(track: tr, index: idx) {
                                app.player.playTrack(tracks, at: idx)
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                }
            }
        }
        .navigationTitle(albumPage?.album.name ?? fallbackName)
        .task {
            isLoading = true
            albumPage = try? await app.activeSource.album(id: albumID)
            isSaved = albumPage?.album.saved ?? app.savedAlbums.contains(where: { $0.id == albumID })
            if let tracks = albumPage?.tracks {
                await app.checkLikes(for: tracks)
            }
            isLoading = false
        }
    }
}

public struct ArtistDetailView: View {
    @EnvironmentObject private var app: AppModel
    public let artistID: String
    public let fallbackName: String

    @State private var artistPage: ArtistPage? = nil
    @State private var isLoading = true
    @State private var isFollowing = false

    public var body: some View {
        ScrollView {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if let page = artistPage {
                let tracks = page.tracks ?? []
                let albums = page.albums ?? []
                VStack(alignment: .leading, spacing: 22) {
                    VStack(spacing: 12) {
                        ArtworkView(
                            urlString: page.artist.imageUrl,
                            pixelSize: 600,
                            size: 140,
                            cornerRadius: 70,
                            systemIcon: "person.wave.2"
                        )
                        Text(page.artist.name)
                            .font(.system(size: 24, weight: .bold))

                        HStack(spacing: 10) {
                            if !tracks.isEmpty {
                                Button {
                                    app.player.playQueue(tracks, start: 0)
                                } label: {
                                    Label(I18n.t("Play"), systemImage: "play.fill")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 9)
                                        .background(MyGoTheme.accent, in: Capsule())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    app.player.playShuffled(tracks)
                                } label: {
                                    Label(I18n.t("Shuffle"), systemImage: "shuffle")
                                        .font(.system(size: 14, weight: .semibold))
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 9)
                                        .background(Color.primary.opacity(0.08), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }

                            if app.activeSource.can("followArtist") {
                                let srcID = app.activeSourceID
                                Button {
                                    Task {
                                        isFollowing = await app.toggleFollowArtist(sourceID: srcID, artistID: artistID, currentlyFollowing: isFollowing)
                                    }
                                } label: {
                                    Label(
                                        I18n.t(isFollowing ? "Following" : "Follow"),
                                        systemImage: isFollowing ? "checkmark" : "plus"
                                    )
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(isFollowing ? MyGoTheme.accent : .primary)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 9)
                                    .background(Color.primary.opacity(0.08), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                    if !tracks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(I18n.t("Songs"))
                                .font(.system(size: 19, weight: .bold))
                                .padding(.horizontal, 16)
                            ForEach(Array(tracks.enumerated()), id: \.element.compositeKey) { idx, tr in
                                TrackRowView(track: tr, index: idx) {
                                    app.player.playTrack(tracks, at: idx)
                                }
                                .padding(.horizontal, 8)
                            }
                        }
                    }

                    if !albums.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(I18n.t("Albums"))
                                .font(.system(size: 19, weight: .bold))
                                .padding(.horizontal, 16)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    ForEach(albums) { album in
                                        NavigationLink(value: NavigationTarget.album(id: album.id, name: album.name)) {
                                            CoverCardView(
                                                title: album.name,
                                                subtitle: album.released,
                                                imageURL: album.imageUrl,
                                                systemIcon: "opticaldisc"
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(artistPage?.artist.name ?? fallbackName)
        .task {
            isLoading = true
            artistPage = try? await app.activeSource.artist(id: artistID)
            isFollowing = artistPage?.artist.following ?? false
            if let tracks = artistPage?.tracks {
                await app.checkLikes(for: tracks)
            }
            isLoading = false
        }
    }
}

public struct PlaylistDetailView: View {
    @EnvironmentObject private var app: AppModel
    public let playlistID: String
    public let fallbackName: String

    @State private var playlistData: Playlist? = nil
    @State private var isLoading = true
    @State private var isSaved = false
    @State private var isEditingOrder = false

    public var body: some View {
        ScrollView {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if let pl = playlistData {
                let tracks = pl.tracks ?? []
                let isOwner = pl.mine == true
                let canRemove = isOwner && app.activeSource.can("removeFromPlaylist")
                let canMove = isOwner && app.activeSource.can("movePlaylistTrack")

                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        ArtworkView(
                            urlString: pl.imageUrl,
                            pixelSize: 600,
                            size: 190,
                            cornerRadius: 16,
                            systemIcon: "music.note.list"
                        )
                        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 6)

                        Text(pl.name)
                            .font(.system(size: 22, weight: .bold))
                            .multilineTextAlignment(.center)

                        Text(I18n.songs(tracks.count))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        if let desc = pl.description, !desc.isEmpty {
                            Text(desc)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }

                        HStack(spacing: 10) {
                            if !tracks.isEmpty {
                                Button {
                                    app.player.playQueue(tracks, start: 0)
                                } label: {
                                    Label(I18n.t("Play"), systemImage: "play.fill")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(MyGoTheme.accent, in: Capsule())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    app.player.playShuffled(tracks)
                                } label: {
                                    Label(I18n.t("Shuffle"), systemImage: "shuffle")
                                        .font(.system(size: 14, weight: .semibold))
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(Color.primary.opacity(0.08), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }

                            if !isOwner && app.activeSource.can("savePlaylist") {
                                let srcID = app.activeSourceID
                                Button {
                                    Task {
                                        isSaved = await app.toggleSavePlaylist(sourceID: srcID, playlistID: playlistID, currentlySaved: isSaved)
                                    }
                                } label: {
                                    Image(systemName: isSaved ? "heart.fill" : "heart")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(isSaved ? MyGoTheme.accent : .primary)
                                        .frame(width: 40, height: 40)
                                        .background(Color.primary.opacity(0.08), in: Circle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, 12)

                    VStack(spacing: 2) {
                        ForEach(Array(tracks.enumerated()), id: \.element.compositeKey) { idx, tr in
                            HStack(spacing: 4) {
                                TrackRowView(track: tr, index: idx) {
                                    app.player.playTrack(tracks, at: idx)
                                }

                                if isEditingOrder {
                                    if canMove {
                                        Button {
                                            Task { await moveRow(from: idx, to: max(0, idx - 1)) }
                                        } label: {
                                            Image(systemName: "arrow.up.circle")
                                                .foregroundStyle(idx == 0 ? Color.secondary.opacity(0.35) : .primary)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(idx == 0)

                                        Button {
                                            Task { await moveRow(from: idx, to: min(tracks.count - 1, idx + 1)) }
                                        } label: {
                                            Image(systemName: "arrow.down.circle")
                                                .foregroundStyle(idx == tracks.count - 1 ? Color.secondary.opacity(0.35) : .primary)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(idx == tracks.count - 1)
                                    }

                                    if canRemove {
                                        Button(role: .destructive) {
                                            Task { await removeRow(trackID: tr.id) }
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundStyle(.red)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .contextMenu {
                                if canMove && idx > 0 {
                                    Button(I18n.t("Move Up"), systemImage: "arrow.up") {
                                        Task { await moveRow(from: idx, to: idx - 1) }
                                    }
                                }
                                if canMove && idx < tracks.count - 1 {
                                    Button(I18n.t("Move Down"), systemImage: "arrow.down") {
                                        Task { await moveRow(from: idx, to: idx + 1) }
                                    }
                                }
                                if canRemove {
                                    Button(I18n.t("Remove from Playlist"), systemImage: "trash", role: .destructive) {
                                        Task { await removeRow(trackID: tr.id) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(playlistData?.name ?? fallbackName)
        .toolbar {
            if let pl = playlistData, pl.mine == true,
               (app.activeSource.can("removeFromPlaylist") || app.activeSource.can("movePlaylistTrack")) {
                ToolbarItem(placement: .automatic) {
                    Button(isEditingOrder ? I18n.t("Done") : I18n.t("Edit")) {
                        withAnimation { isEditingOrder.toggle() }
                    }
                }
            }
        }
        .task {
            isLoading = true
            playlistData = try? await app.activeSource.playlist(id: playlistID)
            isSaved = playlistData?.saved ?? app.savedPlaylists.contains(where: { $0.id == playlistID })
            if let tracks = playlistData?.tracks {
                await app.checkLikes(for: tracks)
            }
            isLoading = false
        }
    }

    private func removeRow(trackID: String) async {
        let srcID = app.activeSourceID
        if await app.removeTrack(trackID, fromPlaylist: playlistID, sourceID: srcID) {
            playlistData?.tracks?.removeAll { $0.id == trackID }
        }
    }

    private func moveRow(from: Int, to: Int) async {
        let srcID = app.activeSourceID
        guard var list = playlistData?.tracks,
              from >= 0, from < list.count, to >= 0, to < list.count, from != to else { return }
        if await app.moveTrack(inPlaylist: playlistID, sourceID: srcID, from: from, to: to) {
            let item = list.remove(at: from)
            list.insert(item, at: to)
            playlistData?.tracks = list
        }
    }
}

public struct PodcastShowDetailView: View {
    @EnvironmentObject private var app: AppModel
    public let showID: String
    public let fallbackName: String

    @State private var showPage: ShowPage? = nil
    @State private var isLoading = true
    @State private var isSubscribed = false
    @State private var isLoadingMore = false

    public var body: some View {
        ScrollView {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if let page = showPage {
                let episodes = page.episodes ?? []
                VStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 12) {
                        ArtworkView(
                            urlString: page.show.imageUrl,
                            pixelSize: 600,
                            size: 170,
                            cornerRadius: 16,
                            systemIcon: "mic.fill"
                        )
                        Text(page.show.name)
                            .font(.system(size: 22, weight: .bold))
                        if let pub = page.show.publisher, !pub.isEmpty {
                            Text(pub)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(MyGoTheme.accent)
                        }
                        if let desc = page.show.description, !desc.isEmpty {
                            Text(desc)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        if app.activeSource.can("subscribeShow") {
                            let srcID = app.activeSourceID
                            Button {
                                Task {
                                    isSubscribed = await app.toggleSubscribeShow(sourceID: srcID, showID: showID, currentlySubscribed: isSubscribed)
                                }
                            } label: {
                                Label(
                                    I18n.t(isSubscribed ? "Subscribed" : "Subscribe"),
                                    systemImage: isSubscribed ? "checkmark" : "plus"
                                )
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(isSubscribed ? MyGoTheme.accent : .white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 9)
                                .background(isSubscribed ? Color.primary.opacity(0.08) : MyGoTheme.accent, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(I18n.t("Episodes"))
                            .font(.system(size: 19, weight: .bold))
                            .padding(.horizontal, 16)
                        ForEach(Array(episodes.enumerated()), id: \.element.compositeKey) { idx, ep in
                            TrackRowView(track: ep, index: idx) {
                                app.player.playTrack(episodes, at: idx)
                            }
                            .padding(.horizontal, 8)
                        }

                        if page.more == true {
                            LoadMoreButton(isLoading: isLoadingMore) {
                                Task { await loadMoreEpisodes() }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(showPage?.show.name ?? fallbackName)
        .task {
            isLoading = true
            showPage = try? await app.activeSource.show(id: showID, offset: 0)
            isSubscribed = showPage?.show.subscribed ?? app.subscribedShows.contains(where: { $0.id == showID })
            isLoading = false
        }
    }

    private func loadMoreEpisodes() async {
        guard !isLoadingMore, let current = showPage, current.more == true else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let offset = current.episodes?.count ?? 0
        if let next = try? await app.activeSource.show(id: showID, offset: offset) {
            let incoming = next.episodes ?? []
            var existing = current.episodes ?? []
            let seen = Set(existing.map(\.id))
            for ep in incoming where !seen.contains(ep.id) {
                existing.append(ep)
            }
            showPage?.episodes = existing
            showPage?.more = (next.more == true) && !incoming.isEmpty
        }
    }
}

public struct LikedSongsView: View {
    @EnvironmentObject private var app: AppModel

    public var body: some View {
        SectionTracksPageView(
            title: app.activeSource.info().customTitle(forBuiltin: "liked") ?? I18n.t("Liked Songs"),
            subtitle: I18n.songs(app.likedTracks.count),
            tracks: app.likedTracks,
            hasMore: app.likedHasMore,
            isLoadingMore: app.isLoadingMoreLiked,
            onLoadMore: {
                await app.loadMoreLikedSongs()
            }
        )
    }
}

public struct SavedAlbumsPageView: View {
    @EnvironmentObject private var app: AppModel

    public var body: some View {
        ScrollView {
            if app.savedAlbums.isEmpty {
                Text(I18n.t("Albums you save will show here"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                VStack(spacing: 16) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                        ForEach(app.savedAlbums) { album in
                            NavigationLink(value: NavigationTarget.album(id: album.id, name: album.name)) {
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

                    if app.savedAlbumsHasMore {
                        LoadMoreButton(isLoading: app.isLoadingMoreSavedAlbums) {
                            Task { await app.loadMoreSavedAlbums() }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(app.activeSource.info().customTitle(forBuiltin: "savedAlbums") ?? I18n.t("Saved Albums"))
    }
}

public struct StationsPageView: View {
    @EnvironmentObject private var app: AppModel

    public var body: some View {
        ScrollView {
            if app.stations.isEmpty {
                Text(I18n.t("No stations yet"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(app.stations) { station in
                        CoverCardView(
                            title: station.name,
                            subtitle: station.description ?? I18n.t("Music without end"),
                            imageURL: station.imageUrl,
                            systemIcon: "dot.radiowaves.left.and.right",
                            onPlay: {
                                Task { await app.startStation(station) }
                            },
                            onTap: {
                                Task { await app.startStation(station) }
                            }
                        )
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(app.activeSource.info().customTitle(forBuiltin: "stations") ?? I18n.t("Stations"))
    }
}

public struct SubscribedPodcastsPageView: View {
    @EnvironmentObject private var app: AppModel

    public var body: some View {
        ScrollView {
            if app.subscribedShows.isEmpty {
                Text(I18n.t("Podcasts you subscribe to will show here"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(app.subscribedShows) { show in
                        NavigationLink(value: NavigationTarget.show(id: show.id, name: show.name)) {
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
                .padding(16)
            }
        }
        .navigationTitle(app.activeSource.info().customTitle(forBuiltin: "shows") ?? I18n.t("Podcasts"))
    }
}

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
    case album(id: String, name: String, sourceID: String? = nil)
    case artist(id: String, name: String, sourceID: String? = nil)
    case playlist(id: String, name: String)
    case show(id: String, name: String)
    case likedSongs
    case savedAlbums
    case stations
    case podcasts
    case settings
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
            .mygoPillSurface()
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
    @State private var navPath: [NavigationTarget] = []

    public init() {}

    public var body: some View {
        NavigationStack(path: $navPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
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
            .background(MyGoTheme.pageBackground.ignoresSafeArea())
            .mygoTrackVerticalScroll()
            .navigationTitle(app.activeSource.info().customTitle(forBuiltin: "home") ?? I18n.t("Home"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    SourceSwitcherMenu()
                }
                if let account = app.currentAccount {
                    ToolbarItem(placement: .topBarTrailing) {
                        HomeAccountToolbarPill(account: account) {
                            if let page = account.page, !page.isEmpty {
                                navPath.append(NavigationTarget.browse(page: page, title: I18n.t("My Page")))
                            }
                        }
                    }
                }
                #else
                ToolbarItem(placement: .navigation) {
                    SourceSwitcherMenu()
                }
                if let account = app.currentAccount {
                    ToolbarItem(placement: .primaryAction) {
                        HomeAccountToolbarPill(account: account) {
                            if let page = account.page, !page.isEmpty {
                                navPath.append(NavigationTarget.browse(page: page, title: I18n.t("My Page")))
                            }
                        }
                    }
                }
                #endif
            }
            .refreshable {
                await app.refreshActiveSource()
            }
            .navigationDestination(for: NavigationTarget.self) { target in
                destinationView(for: target)
            }
            .onReceive(NotificationCenter.default.publisher(for: .mygoOpenHomeTarget)) { note in
                if let target = note.object as? NavigationTarget {
                    navPath.append(target)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .mygoOpenHomeDaily)) { _ in
                if let firstSection = app.homeBrowse?.sections?.first(where: { !($0.tracks ?? []).isEmpty }) {
                    if let morePage = firstSection.morePage, !morePage.isEmpty {
                        navPath.append(NavigationTarget.browse(page: morePage, title: firstSection.title))
                    } else if let tracks = firstSection.tracks {
                        navPath.append(NavigationTarget.sectionTracks(
                            title: firstSection.title ?? I18n.t("Daily Mix"),
                            subtitle: firstSection.subtitle,
                            tracks: tracks
                        ))
                    }
                }
            }
            .environment(\.mygoNavigate) { target in
                navPath.append(target)
            }
        }
    }

    private var fallbackHomeSections: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !app.recentTracks.isEmpty {
                let recentSection = MusicSection(
                    title: I18n.t("Recently Played"),
                    tracks: app.recentTracks
                )
                HomeSectionFeatureCard(section: recentSection) { target in
                    navPath.append(target)
                }
                .padding(.horizontal, 16)
            }

            let allPlaylists = app.myPlaylists + app.savedPlaylists
            if !allPlaylists.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(I18n.t("Playlists"))
                        .font(.system(size: 19, weight: .bold))
                        .padding(.horizontal, 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 16) {
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
                .fill(MyGoTheme.elevatedSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(MyGoTheme.surfaceStroke, lineWidth: 0.6)
                )
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
        case .album(let id, let name, let sourceID):
            AlbumDetailView(albumID: id, fallbackName: name, sourceID: sourceID)
        case .artist(let id, let name, let sourceID):
            ArtistDetailView(artistID: id, fallbackName: name, sourceID: sourceID)
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
        case .settings:
            SettingsView(embedInNavigationStack: false)
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
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }
}

/// 首页导航栏右上角账户按钮（紧致贴合头像与用户名，直承 iOS 26 系统工具栏玻璃外框，杜绝双层套娃与多余留白）
private struct HomeAccountToolbarPill: View {
    let account: Account
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let img = account.imageUrl, !img.isEmpty {
                    ArtworkView(
                        urlString: img,
                        pixelSize: 120,
                        size: 24,
                        cornerRadius: 12,
                        systemIcon: "person.crop.circle.fill"
                    )
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .foregroundStyle(MyGoTheme.accent)
                }
                Text(account.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let page = account.page, !page.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.65))
                }
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(account.name)
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
            let isLeadFeature = idx == firstTrackSectionIndex && !(section.tracks ?? []).isEmpty
            VStack(alignment: .leading, spacing: 12) {
                // 首页第一个歌曲分区展示为 3 封面错落黑胶 Hero 卡片（对应 ui_daily.go）
                if isLeadFeature {
                    HomeSectionFeatureCard(section: section, onNavigate: onNavigate)
                        .padding(.horizontal, 16)
                } else if let title = section.title, !title.isEmpty {
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

                // 歌曲列表（首部已提升为 Hero 卡片的分区不再重复平铺单曲行；全面 Lazy 虚拟化渲染）
                if !isLeadFeature, let tracks = section.tracks, !tracks.isEmpty {
                    LazyTrackRowsView(tracks: tracks) { list, tIdx in
                        app.player.playTrack(list, at: tIdx)
                    }
                }

                    // 专辑横向卡片栏
                    if let albums = section.albums, !albums.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 16) {
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
                            LazyHStack(spacing: 16) {
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
                            LazyHStack(spacing: 16) {
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
                            LazyHStack(spacing: 16) {
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
                            LazyHStack(spacing: 16) {
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
                        let navItems = app.activeSource.info().navigation ?? []
                        VStack(spacing: 8) {
                            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                                let navIcon = navItems.first(where: { $0.page == link.page })?.icon
                                NavigationLink(value: NavigationTarget.browse(page: link.page, title: link.title)) {
                                    HStack(spacing: 12) {
                                        BrowseLinkIconView(
                                            urlString: link.imageUrl,
                                            page: link.page,
                                            title: link.title,
                                            navigationIcon: navIcon,
                                            size: 46,
                                            cornerRadius: 10
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
                                    .mygoElevatedSurface(cornerRadius: 14)
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

/// 首页 Hero 卡片共享连接器，统一承载「自定义首页」与「最近播放 Fallback」两种入口
private struct HomeSectionFeatureCard: View {
    @EnvironmentObject private var app: AppModel
    let section: MusicSection
    let onNavigate: (NavigationTarget) -> Void

    var body: some View {
        let tracks = section.tracks ?? []
        let isQueueActive = DailyFeatureCardMath.isQueueActive(
            queue: app.player.queue,
            currentTrack: app.player.currentTrack,
            sectionTracks: tracks
        )
        let isPlayingFromHere = isQueueActive && app.player.isPlaying

        DailyFeatureCardView(
            section: section,
            isPlayingFromCard: isPlayingFromHere,
            isQueueFromCard: isQueueActive,
            audioBands: isPlayingFromHere ? app.player.audioBands : [0.2, 0.2, 0.2, 0.2],
            onPlay: {
                if isQueueActive {
                    app.player.togglePlay()
                } else {
                    let startIdx = tracks.firstIndex(where: { $0.unavailable != true }) ?? 0
                    app.player.playQueue(tracks, start: startIdx)
                }
            },
            onOpen: {
                let pageTitle = section.pageTitle ?? section.title ?? I18n.t("Songs")
                if let morePage = section.morePage, !morePage.isEmpty {
                    onNavigate(.browse(page: morePage, title: pageTitle))
                } else {
                    onNavigate(.sectionTracks(title: pageTitle, subtitle: section.subtitle, tracks: tracks))
                }
            }
        )
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
            LazyVStack(alignment: .leading, spacing: 20) {
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
        .background(MyGoTheme.pageBackground.ignoresSafeArea())
        .mygoTrackVerticalScroll()
        .refreshable {
            if let res = try? await app.activeSource.browse(page: page) {
                self.browseData = res
            }
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

/// 详情页顶部滚动收起后在导航栏右上角浮现的快捷播放胶囊（#7）
private struct CollapsedToolbarPlayButtons: View {
    @EnvironmentObject private var app: AppModel
    let tracks: [Track]

    var body: some View {
        HStack(spacing: 6) {
            Button {
                MyGoHaptics.impact(.light)
                app.player.playQueue(tracks, start: 0)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(MyGoTheme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(I18n.t("Play"))

            Button {
                MyGoHaptics.impact(.light)
                app.player.playShuffled(tracks)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                    .mygoCircleSurface()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(I18n.t("Shuffle"))
        }
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }
}

/// 详情页操作按钮条：全部离线下载与批量多选开关（支持工具栏紧致尺寸与常规尺寸）
private struct DetailDownloadAndSelectButtons: View {
    @EnvironmentObject private var app: AppModel
    let tracks: [Track]
    @Binding var isSelecting: Bool
    var compact: Bool = false
    var onBeforeEnableSelect: (() -> Void)? = nil

    private var playableTracks: [Track] {
        tracks.filter { $0.unavailable != true }
    }

    private var allDownloaded: Bool {
        !playableTracks.isEmpty && playableTracks.allSatisfy { app.isTrackDownloaded($0) }
    }

    var body: some View {
        let size: CGFloat = compact ? 30 : 34
        let iconSize: CGFloat = compact ? 13 : 14
        HStack(spacing: compact ? 6 : 8) {
            Button {
                guard !playableTracks.isEmpty else { return }
                MyGoHaptics.impact(.medium)
                Task { await app.downloadTracksForOffline(playableTracks) }
            } label: {
                Image(systemName: allDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(allDownloaded ? MyGoTheme.accent : .primary)
                    .frame(width: size, height: size)
                    .mygoCircleSurface()
            }
            .buttonStyle(.plain)
            .disabled(playableTracks.isEmpty)
            .accessibilityLabel(I18n.t("Download All"))

            Button {
                MyGoHaptics.impact(.light)
                if !isSelecting {
                    onBeforeEnableSelect?()
                }
                withAnimation(.easeInOut(duration: 0.18)) {
                    isSelecting.toggle()
                }
            } label: {
                Image(systemName: isSelecting ? "checkmark.circle.fill" : "checklist")
                    .font(.system(size: iconSize - 0.5, weight: .semibold))
                    .foregroundStyle(isSelecting ? .white : .primary)
                    .frame(width: size, height: size)
                    .background {
                        if isSelecting {
                            Circle().fill(MyGoTheme.accent)
                        } else {
                            Circle().fill(Color.clear).mygoCircleSurface()
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)
            .accessibilityLabel(I18n.t("Select"))
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

    @State private var isSelecting = false
    @State private var isHeaderCollapsed = false

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 16) {
                    ParallaxDetailHeaderView(
                        title: title,
                        subtitle: subtitle ?? I18n.songs(tracks.count),
                        artworkURL: tracks.first?.album.imageUrl,
                        artworkSize: 210,
                        isCollapsed: $isHeaderCollapsed
                    )
                    .padding(.top, 8)

                    AppleMusicPlayShuffleBar(
                        hasTracks: !tracks.isEmpty,
                        onPlay: { app.player.playQueue(tracks, start: 0) },
                        onShuffle: { app.player.playShuffled(tracks) }
                    )
                }

                LazyTrackRowsView(tracks: tracks, isSelecting: $isSelecting) { list, idx in
                    app.player.playTrack(list, at: idx)
                }

                if hasMore, let onLoadMore {
                    LoadMoreButton(isLoading: isLoadingMore) {
                        Task { await onLoadMore() }
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .coordinateSpace(name: MyGoDetailScrollSpace.name)
        .background(MyGoTheme.pageBackground.ignoresSafeArea())
        .mygoTrackVerticalScroll()
        .navigationTitle(isHeaderCollapsed ? title : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if isHeaderCollapsed && !tracks.isEmpty {
                    CollapsedToolbarPlayButtons(tracks: tracks)
                }
                if !tracks.isEmpty {
                    DetailDownloadAndSelectButtons(tracks: tracks, isSelecting: $isSelecting, compact: true)
                }
            }
        }
    }
}

public struct AlbumDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.mygoNavigate) private var navigate
    public let albumID: String
    public let fallbackName: String
    public let sourceID: String?

    @State private var albumPage: AlbumPage? = nil
    @State private var resolvedSourceID: String? = nil
    @State private var isLoading = true
    @State private var isSaved = false
    @State private var isSelecting = false
    @State private var isHeaderCollapsed = false

    public init(albumID: String, fallbackName: String, sourceID: String? = nil) {
        self.albumID = albumID
        self.fallbackName = fallbackName
        self.sourceID = sourceID
    }

    public var body: some View {
        let targetSourceID = resolvedSourceID ?? sourceID ?? app.activeSourceID
        let targetSource = app.source(forID: targetSourceID) ?? app.activeSource
        let tracks = albumPage?.tracks ?? []
        let albumTitle = albumPage?.album.name ?? fallbackName

        ScrollView {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if let page = albumPage {
                let metaLine: String = {
                    var parts: [String] = []
                    if let rel = page.album.released, !rel.isEmpty {
                        parts.append(rel)
                    }
                    if !tracks.isEmpty {
                        parts.append(I18n.songs(tracks.count))
                    }
                    return parts.joined(separator: " · ")
                }()
                let primaryArtist = page.album.artists?.first(where: { !$0.id.isEmpty })

                LazyVStack(spacing: 18) {
                    VStack(spacing: 16) {
                        ParallaxDetailHeaderView(
                            title: page.album.name,
                            subtitle: metaLine,
                            accentSubtitle: page.album.artistNames,
                            artworkURL: page.album.imageUrl,
                            artworkSize: 236,
                            onAccentSubtitleTap: primaryArtist.map { artist in
                                {
                                    navigate(.artist(id: artist.id, name: artist.name, sourceID: targetSourceID))
                                }
                            },
                            isCollapsed: $isHeaderCollapsed
                        )
                        .padding(.top, 10)

                        AppleMusicPlayShuffleBar(
                            hasTracks: !tracks.isEmpty,
                            onPlay: { app.player.playQueue(tracks, start: 0) },
                            onShuffle: { app.player.playShuffled(tracks) }
                        )
                    }

                    LazyTrackRowsView(tracks: tracks, isSelecting: $isSelecting) { list, idx in
                        app.player.playTrack(list, at: idx)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .coordinateSpace(name: MyGoDetailScrollSpace.name)
        .background(MyGoTheme.pageBackground.ignoresSafeArea())
        .mygoTrackVerticalScroll()
        .refreshable {
            if let loaded = await app.loadAlbumPage(albumID: albumID, sourceID: sourceID) {
                albumPage = loaded.page
                resolvedSourceID = loaded.resolvedSourceID
                isSaved = loaded.page.album.saved ?? app.savedAlbums.contains(where: { $0.id == albumID })
                if let tracks = loaded.page.tracks {
                    await app.checkLikes(for: tracks)
                }
            }
        }
        .navigationTitle(isHeaderCollapsed ? albumTitle : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if isHeaderCollapsed && !tracks.isEmpty {
                    CollapsedToolbarPlayButtons(tracks: tracks)
                }
                if targetSource.can("saveAlbum") && albumPage != nil {
                    Button {
                        MyGoHaptics.impact(isSaved ? .light : .medium)
                        Task {
                            isSaved = await app.toggleSaveAlbum(sourceID: targetSourceID, albumID: albumID, currentlySaved: isSaved)
                        }
                    } label: {
                        Image(systemName: isSaved ? "heart.fill" : "heart")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(isSaved ? MyGoTheme.accent : .primary)
                            .frame(width: 30, height: 30)
                            .mygoCircleSurface()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(I18n.t(isSaved ? "Saved" : "Save Album"))
                }
                if !tracks.isEmpty {
                    DetailDownloadAndSelectButtons(tracks: tracks, isSelecting: $isSelecting, compact: true)
                }
            }
        }
        .task {
            isLoading = true
            if let loaded = await app.loadAlbumPage(albumID: albumID, sourceID: sourceID) {
                albumPage = loaded.page
                resolvedSourceID = loaded.resolvedSourceID
                isSaved = loaded.page.album.saved ?? app.savedAlbums.contains(where: { $0.id == albumID })
                if let tracks = loaded.page.tracks {
                    await app.checkLikes(for: tracks)
                }
            }
            isLoading = false
        }
    }
}

public struct ArtistDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.mygoBottomOverlayInset) private var bottomOverlayInset
    public let artistID: String
    public let fallbackName: String
    public let sourceID: String?

    @State private var artistPage: ArtistPage? = nil
    @State private var resolvedSourceID: String? = nil
    @State private var isLoading = true
    @State private var isFollowing = false
    @State private var searchOffset = 0
    @State private var hasMoreSearchTracks = false
    @State private var isLoadingMoreTracks = false
    @State private var isSelecting = false
    @State private var showAllTracks = false
    @State private var isHeaderCollapsed = false

    public init(artistID: String, fallbackName: String, sourceID: String? = nil) {
        self.artistID = artistID
        self.fallbackName = fallbackName
        self.sourceID = sourceID
    }

    private func loadArtistDetails() async {
        isLoading = true
        if let outcome = await app.loadArtistPage(artistID: artistID, fallbackName: fallbackName, sourceID: sourceID) {
            artistPage = outcome.page
            resolvedSourceID = outcome.resolvedSourceID
            isFollowing = outcome.page.artist.following ?? false
            searchOffset = outcome.searchMoreOffset
            hasMoreSearchTracks = outcome.hasMoreSearchTracks
            if let tracks = outcome.page.tracks {
                await app.checkLikes(for: tracks)
            }
        } else {
            artistPage = nil
        }
        isLoading = false
    }

    private func loadMoreSongs() async {
        guard !isLoadingMoreTracks,
              hasMoreSearchTracks,
              let current = artistPage else { return }
        let sid = resolvedSourceID ?? sourceID ?? app.activeSourceID
        let targetName = current.artist.name.isEmpty ? fallbackName : current.artist.name
        isLoadingMoreTracks = true
        let more = await app.loadMoreArtistTracks(artistName: targetName, sourceID: sid, offset: searchOffset)
        var existing = current.tracks ?? []
        var seenKeys = Set(existing.map(\.compositeKey))
        let appended = more.tracks.filter { seenKeys.insert($0.compositeKey).inserted }
        if !appended.isEmpty {
            existing.append(contentsOf: appended)
            artistPage?.tracks = existing
            await app.checkLikes(for: appended)
        }
        searchOffset = more.nextOffset
        hasMoreSearchTracks = more.hasMore
        isLoadingMoreTracks = false
    }

    public var body: some View {
        let targetSourceID = resolvedSourceID ?? sourceID ?? app.activeSourceID
        let targetSource = app.source(forID: targetSourceID) ?? app.activeSource
        ScrollView {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 280)
            } else if let page = artistPage {
                let tracks = page.tracks ?? []
                let albums = page.albums ?? []
                let fallbackHeroURL = albums.first?.imageUrl ?? tracks.first?.album.imageUrl
                let visibleTracks: [Track] = showAllTracks ? tracks : Array(tracks.prefix(5))

                LazyVStack(alignment: .leading, spacing: 24) {
                    AppleMusicArtistHeroHeader(
                        artistName: page.artist.name,
                        subtitle: tracks.isEmpty ? "" : "\(tracks.count)\(hasMoreSearchTracks ? "+" : "") \(I18n.t("Songs"))",
                        imageURL: page.artist.imageUrl,
                        fallbackArtworkURL: fallbackHeroURL,
                        hasTracks: !tracks.isEmpty,
                        isCollapsed: $isHeaderCollapsed,
                        onPlay: { app.player.playQueue(tracks, start: 0) },
                        onShuffle: { app.player.playShuffled(tracks) }
                    )

                    // 1. 「最新发行 / 主打专辑」高光卡片（Apple Music Spotlight Card）
                    if let latestAlbum = albums.first {
                        artistLatestReleaseSection(album: latestAlbum, targetSourceID: targetSourceID)
                    }

                    // 2. 热门歌曲 Top 5 与一键展开全部
                    if !tracks.isEmpty {
                        artistTopSongsSection(tracks: tracks, visibleTracks: visibleTracks)
                    }

                    // 3. 大尺寸专辑与唱片集横向画廊
                    if !albums.isEmpty {
                        artistAlbumsGallerySection(albums: albums, targetSourceID: targetSourceID)
                    }
                }
                .padding(.bottom, max(28, bottomOverlayInset))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text(I18n.t("Nothing found"))
                        .font(.system(size: 16, weight: .semibold))
                    Button {
                        Task { await loadArtistDetails() }
                    } label: {
                        Label(I18n.t("Retry"), systemImage: "arrow.clockwise")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(MyGoTheme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
                .padding(.bottom, max(28, bottomOverlayInset))
            }
        }
        .coordinateSpace(name: MyGoDetailScrollSpace.name)
        .background(MyGoTheme.pageBackground.ignoresSafeArea())
        #if os(iOS)
        .ignoresSafeArea(edges: .top)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .mygoTrackVerticalScroll()
        .refreshable {
            await loadArtistDetails()
        }
        .navigationTitle(isHeaderCollapsed ? (artistPage?.artist.name ?? fallbackName) : "")
        .toolbar {
            let tracks = artistPage?.tracks ?? []
            let effectiveArtistID = (artistPage?.artist.id.isEmpty == false ? artistPage?.artist.id : nil) ?? artistID
            ToolbarItemGroup(placement: .automatic) {
                if isHeaderCollapsed && !tracks.isEmpty {
                    CollapsedToolbarPlayButtons(tracks: tracks)
                }
                if targetSource.can("followArtist") && !effectiveArtistID.isEmpty && artistPage != nil {
                    Button {
                        MyGoHaptics.impact(isFollowing ? .light : .medium)
                        Task {
                            isFollowing = await app.toggleFollowArtist(sourceID: targetSourceID, artistID: effectiveArtistID, currentlyFollowing: isFollowing)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isFollowing ? "checkmark" : "plus")
                                .font(.system(size: 11.5, weight: .bold))
                            Text(I18n.t(isFollowing ? "Following" : "Follow"))
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(isFollowing ? MyGoTheme.accent : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .mygoPillSurface()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task {
            await loadArtistDetails()
        }
    }

    @ViewBuilder
    private func artistLatestReleaseSection(album: Album, targetSourceID: String) -> some View {
        NavigationLink(value: NavigationTarget.album(id: album.id, name: album.name, sourceID: targetSourceID)) {
            HStack(spacing: 14) {
                ArtworkView(
                    urlString: album.imageUrl,
                    pixelSize: 320,
                    size: 88,
                    cornerRadius: 12,
                    systemIcon: "opticaldisc"
                )
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 5) {
                    Text(I18n.t("Latest Release"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(MyGoTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MyGoTheme.accent.opacity(0.14), in: Capsule())

                    Text(album.name)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let released = album.released, !released.isEmpty {
                        Text(released)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(MyGoTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(MyGoTheme.surfaceStroke, lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func artistTopSongsSection(tracks: [Track], visibleTracks: [Track]) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(I18n.t("Top Songs"))
                        .font(.system(size: 21, weight: .bold))
                    Text("\(tracks.count)\(hasMoreSearchTracks ? "+" : "")")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if showAllTracks || tracks.count <= 5 {
                    DetailDownloadAndSelectButtons(tracks: tracks, isSelecting: $isSelecting, compact: true)
                }

                if tracks.count > 5 {
                    Button {
                        MyGoHaptics.selection()
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                            showAllTracks.toggle()
                            if !showAllTracks {
                                isSelecting = false
                            }
                        }
                    } label: {
                        Text(showAllTracks ? I18n.t("Show Less") : I18n.t("See All"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MyGoTheme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(MyGoTheme.accent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            LazyTrackRowsView(tracks: visibleTracks, isSelecting: $isSelecting) { _, idx in
                app.player.playTrack(tracks, at: idx)
            }

            if showAllTracks && hasMoreSearchTracks {
                LoadMoreButton(isLoading: isLoadingMoreTracks) {
                    Task { await loadMoreSongs() }
                }
            }
        }
    }

    @ViewBuilder
    private func artistAlbumsGallerySection(albums: [Album], targetSourceID: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(I18n.t("Albums"))
                .font(.system(size: 21, weight: .bold))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(value: NavigationTarget.album(id: album.id, name: album.name, sourceID: targetSourceID)) {
                            CoverCardView(
                                title: album.name,
                                subtitle: album.released,
                                imageURL: album.imageUrl,
                                systemIcon: "opticaldisc",
                                cardSize: 164
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

public struct PlaylistDetailView: View {
    @EnvironmentObject private var app: AppModel
    public let playlistID: String
    public let fallbackName: String

    @State private var playlistData: Playlist? = nil
    @State private var isLoading = true
    @State private var isSaved = false
    @State private var isEditingOrder = false
    @State private var isSelecting = false
    @State private var isHeaderCollapsed = false

    public var body: some View {
        let tracks = playlistData?.tracks ?? []
        ScrollView {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if let pl = playlistData {
                let isOwner = pl.mine == true
                let canRemove = isOwner && app.activeSource.can("removeFromPlaylist")
                let canMove = isOwner && app.activeSource.can("movePlaylistTrack")

                LazyVStack(spacing: 18) {
                    VStack(spacing: 16) {
                        let descPart = (pl.description?.isEmpty == false) ? " · \(pl.description!)" : ""
                        ParallaxDetailHeaderView(
                            title: pl.name,
                            subtitle: I18n.songs(tracks.count) + descPart,
                            artworkURL: pl.imageUrl,
                            artworkSize: 226,
                            isCollapsed: $isHeaderCollapsed
                        )
                        .padding(.top, 10)

                        if !tracks.isEmpty {
                            AppleMusicPlayShuffleBar(
                                hasTracks: !tracks.isEmpty,
                                onPlay: { app.player.playQueue(tracks, start: 0) },
                                onShuffle: { app.player.playShuffled(tracks) }
                            )
                        }
                    }

                    if isEditingOrder {
                        LazyVStack(spacing: 2) {
                            let entries = LazyTrackRowsView.buildRowEntries(for: tracks)
                            ForEach(entries) { entry in
                                let idx = entry.index
                                let tr = entry.track
                                HStack(spacing: 4) {
                                    TrackRowView(track: tr, index: idx) {
                                        app.player.playTrack(tracks, at: idx)
                                    }

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
                    } else {
                        LazyTrackRowsView(tracks: tracks, isSelecting: $isSelecting) { list, idx in
                            app.player.playTrack(list, at: idx)
                        }
                    }
                }
            }
        }
        .coordinateSpace(name: MyGoDetailScrollSpace.name)
        .background(MyGoTheme.pageBackground.ignoresSafeArea())
        .mygoTrackVerticalScroll()
        .refreshable {
            if let loaded = try? await app.activeSource.playlist(id: playlistID) {
                playlistData = loaded
                isSaved = loaded.saved ?? app.savedPlaylists.contains(where: { $0.id == playlistID })
                if let tracks = loaded.tracks {
                    await app.checkLikes(for: tracks)
                }
            }
        }
        .navigationTitle(isHeaderCollapsed ? (playlistData?.name ?? fallbackName) : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if isHeaderCollapsed && !tracks.isEmpty {
                    CollapsedToolbarPlayButtons(tracks: tracks)
                }
                if let pl = playlistData, pl.mine != true, app.activeSource.can("savePlaylist") {
                    let srcID = app.activeSourceID
                    Button {
                        MyGoHaptics.impact(isSaved ? .light : .medium)
                        Task {
                            isSaved = await app.toggleSavePlaylist(sourceID: srcID, playlistID: playlistID, currentlySaved: isSaved)
                        }
                    } label: {
                        Image(systemName: isSaved ? "heart.fill" : "heart")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(isSaved ? MyGoTheme.accent : .primary)
                            .frame(width: 30, height: 30)
                            .mygoCircleSurface()
                    }
                    .buttonStyle(.plain)
                }
                if !tracks.isEmpty {
                    DetailDownloadAndSelectButtons(
                        tracks: tracks,
                        isSelecting: $isSelecting,
                        compact: true,
                        onBeforeEnableSelect: { isEditingOrder = false }
                    )
                }
                if let pl = playlistData, pl.mine == true,
                   (app.activeSource.can("removeFromPlaylist") || app.activeSource.can("movePlaylistTrack")) {
                    Button(isEditingOrder ? I18n.t("Done") : I18n.t("Edit")) {
                        withAnimation {
                            isEditingOrder.toggle()
                            if isEditingOrder {
                                isSelecting = false
                            }
                        }
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
                LazyVStack(alignment: .leading, spacing: 20) {
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
                                .mygoPillSurface(isHighlighted: !isSubscribed)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                    LazyVStack(alignment: .leading, spacing: 8) {
                        Text(I18n.t("Episodes"))
                            .font(.system(size: 19, weight: .bold))
                            .padding(.horizontal, 16)
                        LazyTrackRowsView(tracks: episodes) { list, idx in
                            app.player.playTrack(list, at: idx)
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
        .background(MyGoTheme.pageBackground.ignoresSafeArea())
        .mygoTrackVerticalScroll()
        .refreshable {
            if let loaded = try? await app.activeSource.show(id: showID, offset: 0) {
                showPage = loaded
                isSubscribed = loaded.show.subscribed ?? app.subscribedShows.contains(where: { $0.id == showID })
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
        .background(MyGoTheme.pageBackground.ignoresSafeArea())
        .mygoTrackVerticalScroll()
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
        .background(MyGoTheme.pageBackground.ignoresSafeArea())
        .mygoTrackVerticalScroll()
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
        .background(MyGoTheme.pageBackground.ignoresSafeArea())
        .mygoTrackVerticalScroll()
        .navigationTitle(app.activeSource.info().customTitle(forBuiltin: "shows") ?? I18n.t("Podcasts"))
    }
}

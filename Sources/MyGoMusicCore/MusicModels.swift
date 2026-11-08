// MusicModels.swift
// 对应原项目 internal/music/music.go 的核心数据结构与音乐源协议

import Foundation

// MARK: - 基础音乐实体

/// 歌手模型（对应 music.Artist）
public struct Artist: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var imageUrl: String?
    /// 是否已关注该歌手（支持 followArtist 的音乐源使用）
    public var following: Bool?

    public init(id: String, name: String, imageUrl: String? = nil, following: Bool? = nil) {
        self.id = id
        self.name = name
        self.imageUrl = imageUrl
        self.following = following
    }
}

/// 专辑模型（对应 music.Album）
public struct Album: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var imageUrl: String?
    public var artists: [Artist]?
    /// 发行日期，例如 "2024-03-01"
    public var released: String?
    /// 是否已收藏该专辑（支持 saveAlbum 的音乐源使用）
    public var saved: Bool?

    public init(
        id: String = "",
        name: String = "",
        imageUrl: String? = nil,
        artists: [Artist]? = nil,
        released: String? = nil,
        saved: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.imageUrl = imageUrl
        self.artists = artists
        self.released = released
        self.saved = saved
    }

    /// 拼接专辑歌手名称
    public var artistNames: String {
        (artists ?? []).map(\.name).joined(separator: ", ")
    }
}

/// 单曲或播客单集模型（对应 music.Track）
public struct Track: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// 歌曲所属的音乐源 ID（由宿主自动填充）
    public var source: String?
    public var name: String
    public var artists: [Artist]?
    public var album: Album
    /// 时长（毫秒）
    public var duration: Int64
    /// 分享链接
    public var url: String?
    /// 是否不可播放
    public var unavailable: Bool?

    // 播客单集专属字段
    public var showId: String?
    public var description: String?
    public var published: String?

    public init(
        id: String,
        source: String? = nil,
        name: String,
        artists: [Artist]? = nil,
        album: Album = Album(),
        duration: Int64 = 0,
        url: String? = nil,
        unavailable: Bool? = nil,
        showId: String? = nil,
        description: String? = nil,
        published: String? = nil
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.artists = artists
        self.album = album
        self.duration = duration
        self.url = url
        self.unavailable = unavailable
        self.showId = showId
        self.description = description
        self.published = published
    }

    /// 拼接歌手名称（对应 Track.ArtistNames）
    public var artistNames: String {
        (artists ?? []).map(\.name).joined(separator: ", ")
    }

    /// 转换为秒数时长
    public var durationSeconds: TimeInterval {
        TimeInterval(duration) / 1000.0
    }

    /// 是否为播客单集
    public var isEpisode: Bool {
        guard let showId else { return false }
        return !showId.isEmpty
    }

    /// 全局唯一复合键（包含 source 与 id）
    public var compositeKey: String {
        "\(source ?? "local"):\(id)"
    }
}

/// 歌单模型（对应 music.Playlist）
public struct Playlist: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var imageUrl: String?
    public var description: String?
    public var owner: String?
    public var trackCount: Int?
    /// 是否为用户自建歌单
    public var mine: Bool?
    /// 是否为收藏的他人的歌单
    public var saved: Bool?
    /// 是否为固定系统歌单（如“我喜欢的音乐”，不可重命名或删除）
    public var fixed: Bool?
    public var tracks: [Track]?

    public init(
        id: String,
        name: String,
        imageUrl: String? = nil,
        description: String? = nil,
        owner: String? = nil,
        trackCount: Int? = nil,
        mine: Bool? = nil,
        saved: Bool? = nil,
        fixed: Bool? = nil,
        tracks: [Track]? = nil
    ) {
        self.id = id
        self.name = name
        self.imageUrl = imageUrl
        self.description = description
        self.owner = owner
        self.trackCount = trackCount
        self.mine = mine
        self.saved = saved
        self.fixed = fixed
        self.tracks = tracks
    }
}

/// 歌手详情页模型（对应 music.ArtistPage）
public struct ArtistPage: Codable, Hashable, Sendable {
    public var artist: Artist
    public var tracks: [Track]?
    public var albums: [Album]?

    public init(artist: Artist, tracks: [Track]? = nil, albums: [Album]? = nil) {
        self.artist = artist
        self.tracks = tracks
        self.albums = albums
    }
}

/// 专辑详情页模型（对应 music.AlbumPage）
public struct AlbumPage: Codable, Hashable, Sendable {
    public var album: Album
    public var tracks: [Track]?

    public init(album: Album, tracks: [Track]? = nil) {
        self.album = album
        self.tracks = tracks
    }
}

/// 账号信息模型（对应 music.Account）
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var imageUrl: String?
    /// 个人主页对应的 Browse 页面标识
    public var page: String?

    public init(id: String, name: String, imageUrl: String? = nil, page: String? = nil) {
        self.id = id
        self.name = name
        self.imageUrl = imageUrl
        self.page = page
    }
}

// MARK: - 搜索与分页

/// 搜索类别（对应 music.SearchKind）
public enum SearchKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case tracks = "tracks"
    case albums = "albums"
    case artists = "artists"
    case playlists = "playlists"
    case shows = "shows"

    public var id: String { rawValue }
}

/// 搜索结果页（对应 music.SearchResult）
public struct SearchResult: Codable, Hashable, Sendable {
    public var tracks: [Track]?
    public var albums: [Album]?
    public var artists: [Artist]?
    public var playlists: [Playlist]?
    public var shows: [Show]?
    public var more: Bool?

    public init(
        tracks: [Track]? = nil,
        albums: [Album]? = nil,
        artists: [Artist]? = nil,
        playlists: [Playlist]? = nil,
        shows: [Show]? = nil,
        more: Bool? = nil
    ) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
        self.shows = shows
        self.more = more
    }

    public var count: Int {
        let trackCount = tracks?.count ?? 0
        let albumCount = albums?.count ?? 0
        let artistCount = artists?.count ?? 0
        let playlistCount = playlists?.count ?? 0
        let showCount = shows?.count ?? 0
        return trackCount + albumCount + artistCount + playlistCount + showCount
    }
}

/// 歌曲分页（对应 music.Page）
public struct TrackPage: Codable, Hashable, Sendable {
    public var tracks: [Track]?
    public var more: Bool?

    public init(tracks: [Track]? = nil, more: Bool? = nil) {
        self.tracks = tracks
        self.more = more
    }
}

/// 专辑分页（对应 music.AlbumList）
public struct AlbumList: Codable, Hashable, Sendable {
    public var albums: [Album]?
    public var more: Bool?

    public init(albums: [Album]? = nil, more: Bool? = nil) {
        self.albums = albums
        self.more = more
    }
}

// MARK: - 播客、电台与评论

/// 播客节目模型（对应 music.Show）
public struct Show: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var imageUrl: String?
    public var description: String?
    public var publisher: String?
    public var publisherPage: String?
    public var episodeCount: Int?
    public var subscribed: Bool?

    public init(
        id: String,
        name: String,
        imageUrl: String? = nil,
        description: String? = nil,
        publisher: String? = nil,
        publisherPage: String? = nil,
        episodeCount: Int? = nil,
        subscribed: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.imageUrl = imageUrl
        self.description = description
        self.publisher = publisher
        self.publisherPage = publisherPage
        self.episodeCount = episodeCount
        self.subscribed = subscribed
    }
}

/// 播客详情页模型（对应 music.ShowPage）
public struct ShowPage: Codable, Hashable, Sendable {
    public var show: Show
    public var episodes: [Track]?
    public var more: Bool?

    public init(show: Show, episodes: [Track]? = nil, more: Bool? = nil) {
        self.show = show
        self.episodes = episodes
        self.more = more
    }
}

/// 无限电台模型（对应 music.Station）
public struct Station: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var imageUrl: String?

    public init(id: String, name: String, description: String? = nil, imageUrl: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.imageUrl = imageUrl
    }
}

/// 歌曲评论模型（对应 music.Comment）
public struct Comment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var author: String
    public var avatarUrl: String?
    public var text: String
    /// 评论时间戳（毫秒）
    public var time: Int64?
    public var likes: Int?
    public var liked: Bool?

    public init(
        id: String,
        author: String,
        avatarUrl: String? = nil,
        text: String,
        time: Int64? = nil,
        likes: Int? = nil,
        liked: Bool? = nil
    ) {
        self.id = id
        self.author = author
        self.avatarUrl = avatarUrl
        self.text = text
        self.time = time
        self.likes = likes
        self.liked = liked
    }
}

/// 评论分页模型（对应 music.CommentPage）
public struct CommentPage: Codable, Hashable, Sendable {
    public var comments: [Comment]?
    public var total: Int?
    public var more: Bool?

    public init(comments: [Comment]? = nil, total: Int? = nil, more: Bool? = nil) {
        self.comments = comments
        self.total = total
        self.more = more
    }
}

// MARK: - 自定义浏览页与导航

/// 浏览页面（对应 music.Browse）
public struct Browse: Codable, Hashable, Sendable {
    public var title: String?
    public var subtitle: String?
    public var imageUrl: String?
    public var description: String?
    public var sections: [Section]?

    public init(
        title: String? = nil,
        subtitle: String? = nil,
        imageUrl: String? = nil,
        description: String? = nil,
        sections: [Section]? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.imageUrl = imageUrl
        self.description = description
        self.sections = sections
    }
}

/// 浏览页分区（对应 music.Section）
public typealias MusicSection = Section
public struct Section: Codable, Hashable, Sendable {
    public var title: String?
    public var tracks: [Track]?
    public var albums: [Album]?
    public var artists: [Artist]?
    public var playlists: [Playlist]?
    public var shows: [Show]?
    public var stations: [Station]?
    public var links: [BrowseLink]?
    public var morePage: String?
    public var empty: String?
    public var pageTitle: String?
    public var subtitle: String?

    public init(
        title: String? = nil,
        tracks: [Track]? = nil,
        albums: [Album]? = nil,
        artists: [Artist]? = nil,
        playlists: [Playlist]? = nil,
        shows: [Show]? = nil,
        stations: [Station]? = nil,
        links: [BrowseLink]? = nil,
        morePage: String? = nil,
        empty: String? = nil,
        pageTitle: String? = nil,
        subtitle: String? = nil
    ) {
        self.title = title
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
        self.shows = shows
        self.stations = stations
        self.links = links
        self.morePage = morePage
        self.empty = empty
        self.pageTitle = pageTitle
        self.subtitle = subtitle
    }
}

/// 跳转其他 Browse 页的链接卡片（对应 music.Link）
public struct BrowseLink: Codable, Hashable, Sendable {
    public var title: String
    public var subtitle: String?
    public var imageUrl: String?
    public var page: String

    public init(title: String, subtitle: String? = nil, imageUrl: String? = nil, page: String) {
        self.title = title
        self.subtitle = subtitle
        self.imageUrl = imageUrl
        self.page = page
    }
}

/// 导航栏条目（对应 music.NavItem）
public struct NavItem: Codable, Hashable, Sendable {
    public var title: String?
    public var page: String?
    /// 内置页面：home, liked, savedAlbums, stations, shows
    public var builtin: String?
    /// 图标名：home, note, album, artist, playlist, radio, podcast, chart, calendar, heart, search, star
    public var icon: String?

    public init(title: String? = nil, page: String? = nil, builtin: String? = nil, icon: String? = nil) {
        self.title = title
        self.page = page
        self.builtin = builtin
        self.icon = icon
    }
}

// MARK: - 音频流、歌词与远程播放

/// 音频流描述（对应 music.Stream）
public struct StreamInfo: Codable, Hashable, Sendable {
    public var url: String
    /// mp3, flac, ogg, wav, m4a, aac
    public var type: String?
    public var quality: String?
    public var bitRate: Int?
    public var size: Int64?
    public var peak: Double?
    public var gain: Double?
    public var headers: [String: String]?

    public init(
        url: String,
        type: String? = nil,
        quality: String? = nil,
        bitRate: Int? = nil,
        size: Int64? = nil,
        peak: Double? = nil,
        gain: Double? = nil,
        headers: [String: String]? = nil
    ) {
        self.url = url
        self.type = type
        self.quality = quality
        self.bitRate = bitRate
        self.size = size
        self.peak = peak
        self.gain = gain
        self.headers = headers
    }
}

/// 原始歌词响应（对应 music.Lyrics）
public struct RawLyrics: Codable, Hashable, Sendable {
    public var lrc: String?
    public var translation: String?
    public var lines: [RawLyricLine]?

    public init(lrc: String? = nil, translation: String? = nil, lines: [RawLyricLine]? = nil) {
        self.lrc = lrc
        self.translation = translation
        self.lines = lines
    }
}

/// 原始逐行歌词（对应 music.LyricLine）
public struct RawLyricLine: Codable, Hashable, Sendable {
    public var start: Int64
    public var end: Int64?
    public var text: String?
    public var translation: String?
    public var words: [RawLyricWord]?

    public init(
        start: Int64,
        end: Int64? = nil,
        text: String? = nil,
        translation: String? = nil,
        words: [RawLyricWord]? = nil
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.translation = translation
        self.words = words
    }
}

/// 原始逐字歌词（对应 music.LyricWord）
public struct RawLyricWord: Codable, Hashable, Sendable {
    public var start: Int64
    public var end: Int64
    public var text: String

    public init(start: Int64, end: Int64, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// 远程播放设备（对应 music.Device）
public struct RemoteDevice: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var active: Bool?

    public init(id: String, name: String, active: Bool? = nil) {
        self.id = id
        self.name = name
        self.active = active
    }
}

/// 远程播放状态（对应 music.RemoteState）
public struct RemoteState: Codable, Hashable, Sendable {
    public var playing: Bool
    public var trackId: String?
    public var position: Int64
    public var duration: Int64
    public var volume: Int
    public var device: String?

    public init(
        playing: Bool,
        trackId: String? = nil,
        position: Int64 = 0,
        duration: Int64 = 0,
        volume: Int = 100,
        device: String? = nil
    ) {
        self.playing = playing
        self.trackId = trackId
        self.position = position
        self.duration = duration
        self.volume = volume
        self.device = device
    }
}

/// 播放模式（对应 music.Playback）
public enum PlaybackMode: String, Codable, Hashable, Sendable {
    case stream = "stream"
    case remote = "remote"
}

/// 插件配置项（对应 music.Setting）
public struct PluginSettingSpec: Codable, Identifiable, Hashable, Sendable {
    public var key: String
    public var label: String
    public var help: String?
    public var link: String?

    public var id: String { key }

    public init(key: String, label: String, help: String? = nil, link: String? = nil) {
        self.key = key
        self.label = label
        self.help = help
        self.link = link
    }
}

/// 音乐源元信息（对应 music.Info）
public struct SourceInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var version: String?
    public var playback: PlaybackMode?
    public var settings: [PluginSettingSpec]?
    public var navigation: [NavItem]?

    public init(
        id: String,
        name: String,
        version: String? = nil,
        playback: PlaybackMode? = .stream,
        settings: [PluginSettingSpec]? = nil,
        navigation: [NavItem]? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.playback = playback
        self.settings = settings
        self.navigation = navigation
    }
}

/// 登录引导提示（对应 music.SignInPrompt）
public struct SignInPrompt: Codable, Hashable, Sendable {
    public var qr: String?
    public var text: String?

    public init(qr: String? = nil, text: String? = nil) {
        self.qr = qr
        self.text = text
    }
}

// MARK: - 错误类型与音乐源协议

/// 音乐源错误类型（对应 music.ErrSignIn / ErrSetup / ErrUnavailable / ErrUnsupported）
public enum SourceError: Error, LocalizedError, Equatable, Sendable {
    case signIn(String)
    case setup(String)
    case unavailable(String)
    case unsupported(String)
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .signIn(let reason):
            return reason.isEmpty ? I18n.t("Sign in to play this song") : reason
        case .setup(let reason):
            return reason.isEmpty ? I18n.t("The plugin needs setting up") : reason
        case .unavailable(let reason):
            return reason.isEmpty ? I18n.t("This song isn't available") : reason
        case .unsupported(let reason):
            return reason.isEmpty ? "not supported by this source" : reason
        case .message(let msg):
            return msg
        }
    }
}

/// 处理封面 URL 中的 {size} 或 %7Bsize%7D 占位符（对应原项目 sized 函数）
public func sizedImageURL(_ url: String?, px: Int) -> String? {
    guard let url, !url.isEmpty else { return nil }
    return url
        .replacingOccurrences(of: "{size}", with: "\(px)")
        .replacingOccurrences(of: "%7Bsize%7D", with: "\(px)", options: .caseInsensitive)
}

/// 统一音乐源协议（对应 music.Source）
public protocol MusicSource: AnyObject {
    func info() -> SourceInfo
    func can(_ capability: String) -> Bool

    func setting(_ key: String) -> String
    func setSetting(_ key: String, value: String) throws

    func signIn() async throws -> Account?
    func signOut() async throws
    func account() async throws -> Account?

    func search(query: String, kind: SearchKind, offset: Int) async throws -> SearchResult
    func suggest(query: String) async throws -> [String]
    func playlists() async throws -> [Playlist]
    func playlist(id: String) async throws -> Playlist
    func album(id: String) async throws -> AlbumPage
    func artist(id: String) async throws -> ArtistPage
    func liked(offset: Int) async throws -> TrackPage
    func recent() async throws -> [Track]

    func home() async throws -> Browse
    func browse(page: String) async throws -> Browse

    func isLiked(ids: [String]) async throws -> [String: Bool]
    func like(id: String, on: Bool) async throws
    func likeEpisode(id: String, on: Bool) async throws

    func createPlaylist(name: String) async throws -> Playlist
    func renamePlaylist(id: String, name: String) async throws
    func deletePlaylist(id: String) async throws
    func addToPlaylist(id: String, trackIds: [String]) async throws
    func removeFromPlaylist(id: String, trackIds: [String]) async throws
    func movePlaylistTrack(id: String, from: Int, to: Int) async throws
    func savePlaylist(id: String, on: Bool) async throws

    func followArtist(id: String, on: Bool) async throws
    func saveAlbum(id: String, on: Bool) async throws
    func savedAlbums(offset: Int) async throws -> AlbumList

    func shows() async throws -> [Show]
    func show(id: String, offset: Int) async throws -> ShowPage
    func subscribeShow(id: String, on: Bool) async throws

    func stations() async throws -> [Station]
    func stationNext(id: String) async throws -> [Track]

    func comments(trackId: String, offset: Int) async throws -> CommentPage
    func likeComment(trackId: String, commentId: String, on: Bool) async throws
    func postComment(trackId: String, text: String) async throws -> Comment

    func lyrics(id: String) async throws -> RawLyrics
    func stream(id: String, quality: String) async throws -> StreamInfo

    func played(track: Track) async

    // Remote 远程播放接口
    func remotePlay(ids: [String], start: Int, position: Int64) async throws
    func remotePause() async throws
    func remoteResume() async throws
    func remoteSeek(position: Int64) async throws
    func remoteVolume(percent: Int) async throws
    func remoteState() async throws -> RemoteState?
    func remoteDevices() async throws -> [RemoteDevice]
    func remoteUse(deviceId: String) async throws
}

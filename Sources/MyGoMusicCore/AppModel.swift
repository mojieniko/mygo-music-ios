// AppModel.swift
// 对应原项目 internal/app/app.go, sources.go, settings.go 的全局应用状态与数据源管理

import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 外观模式（对应 settings.Appearance）
public enum AppAppearance: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var id: String { rawValue }

    public var labelKey: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// 音质等级（对应 qualityLevels）
public enum AudioQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard = "standard"
    case high = "high"
    case lossless = "lossless"

    public var id: String { rawValue }

    public var labelKey: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        case .lossless: return "Lossless"
        }
    }
}

/// 全局设置模型（1:1 对应 internal/app/settings.go）
public struct AppSettings: Codable, Equatable, Sendable {
    public var language: AppLanguage = .system
    public var source: String = "kugou-lite"
    public var captions: Bool = false
    public var disabledPlugins: [String] = []
    public var quality: AudioQuality = .high
    public var appearance: AppAppearance = .system
    public var growFromCover: Bool = true
    public var smoke: Bool = true
    public var lyricsStage: Bool = false
    public var stageStyle: StageStyle = .flow
    public var stageSparks: Bool = true
    public var volume: Double = 0.8
    public var normalize: Bool = true
    public var hotComments: Bool = true
    public var fog: Bool = true
    public var cacheMB: Int = 2048
    public var searchHistory: [String] = []

    private enum CodingKeys: String, CodingKey {
        case language, source, captions, disabledPlugins, quality, appearance
        case growFromCover, smoke, lyricsStage, stageStyle, stageSparks, volume
        case normalize, hotComments, fog, cacheMB, searchHistory
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? "kugou-lite"
        captions = try values.decodeIfPresent(Bool.self, forKey: .captions) ?? false
        disabledPlugins = try values.decodeIfPresent([String].self, forKey: .disabledPlugins) ?? []
        quality = try values.decodeIfPresent(AudioQuality.self, forKey: .quality) ?? .high
        appearance = try values.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        growFromCover = try values.decodeIfPresent(Bool.self, forKey: .growFromCover) ?? true
        smoke = try values.decodeIfPresent(Bool.self, forKey: .smoke) ?? true
        lyricsStage = try values.decodeIfPresent(Bool.self, forKey: .lyricsStage) ?? false
        stageStyle = try values.decodeIfPresent(StageStyle.self, forKey: .stageStyle) ?? .flow
        stageSparks = try values.decodeIfPresent(Bool.self, forKey: .stageSparks) ?? true
        volume = try values.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8
        normalize = try values.decodeIfPresent(Bool.self, forKey: .normalize) ?? true
        hotComments = try values.decodeIfPresent(Bool.self, forKey: .hotComments) ?? true
        fog = try values.decodeIfPresent(Bool.self, forKey: .fog) ?? true
        cacheMB = try values.decodeIfPresent(Int.self, forKey: .cacheMB) ?? 2048
        searchHistory = try values.decodeIfPresent([String].self, forKey: .searchHistory) ?? []
    }
}

/// 正在播放全屏页的子面板（对应 paneLyrics, paneStage, paneQueue, paneWall, paneComments, paneShow）
public enum NowPlayingPane: Int, CaseIterable, Identifiable, Sendable {
    case lyrics = 0
    case stage = 1
    case queue = 2
    case wall = 3
    case comments = 4
    case show = 5

    public var id: Int { rawValue }

    public var labelKey: String {
        switch self {
        case .lyrics: return "Lyrics"
        case .stage: return "Stage"
        case .queue: return "Up Next"
        case .wall: return "Wall"
        case .comments: return "Comments"
        case .show: return "About"
        }
    }
}

/// 全局应用视图模型（对应 internal/app/app.go）
@MainActor
public final class AppModel: ObservableObject {
    public let baseDataDir: URL
    public let pluginsDir: URL
    public let pluginDataDir: URL
    public let localSource: LocalMusicSource
    public let player: PlayerEngine

    @Published public var settings: AppSettings {
        didSet {
            I18n.setLanguage(settings.language)
            player.volume = settings.volume
            player.diskCache.limitMB = settings.cacheMB
            saveSettings()
        }
    }

    @Published public private(set) var pluginSources: [JSPluginSource] = []
    @Published public var activeSourceID: String = "kugou-lite"

    // 当前活动音乐源的数据缓存
    @Published public private(set) var isLoadingHome: Bool = false
    @Published public private(set) var homeError: String? = nil
    @Published public private(set) var homeBrowse: Browse? = nil
    @Published public private(set) var recentTracks: [Track] = []
    @Published public private(set) var myPlaylists: [Playlist] = []
    @Published public private(set) var savedPlaylists: [Playlist] = []
    @Published public private(set) var likedTracks: [Track] = []
    @Published public private(set) var savedAlbums: [Album] = []
    @Published public private(set) var stations: [Station] = []
    @Published public private(set) var subscribedShows: [Show] = []
    @Published public private(set) var currentAccount: Account? = nil
    @Published public private(set) var accountsBySource: [String: Account] = [:]
    @Published public private(set) var likedMap: [String: Bool] = [:]

    // 正在播放与评论状态
    @Published public var isNowPlayingPresented: Bool = false
    @Published public var activeNowPlayingPane: NowPlayingPane = .lyrics
    @Published public private(set) var currentTrackComments: [Comment] = []
    @Published public private(set) var currentTrackCommentTotal: Int = 0
    @Published public private(set) var isLoadingComments: Bool = false

    // 搜索状态
    @Published public var searchQuery: String = ""
    @Published public var searchKind: SearchKind = .tracks
    @Published public private(set) var searchResult: SearchResult = SearchResult()
    @Published public private(set) var searchSuggestions: [String] = []
    @Published public private(set) var isSearching: Bool = false

    // 插件安装、二维码/提示登录与 WebView 登录状态
    @Published public var toastMessage: String? = nil
    @Published public var isSignInSheetPresented: Bool = false
    @Published public var signInTargetSourceID: String? = nil
    @Published public var isSigningIn: Bool = false
    @Published public var signInError: String? = nil
    @Published public var activeSignInPrompt: SignInPrompt? = nil
    @Published public var activeWebSignInRequest: WebSignInRequest? = nil
    @Published public var isInstallingPlugin: Bool = false
    @Published public var installErrorMessage: String? = nil

    private var webSignInContinuation: CheckedContinuation<String, Error>? = nil
    private var playerCancellable: AnyCancellable?
    private var trackChangeCancellable: AnyCancellable?
    private var searchGeneration = 0
    private var suggestionGeneration = 0
    private var sourceRefreshGeneration = 0
    private var artworkGeneration = 0

    public init(baseDataDir: URL? = nil) {
        let rootDir = baseDataDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyGoMusic", isDirectory: true)
        self.baseDataDir = rootDir
        self.pluginsDir = rootDir.appendingPathComponent("plugins", isDirectory: true)
        self.pluginDataDir = rootDir.appendingPathComponent("plugin-data", isDirectory: true)

        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)

        // 加载设置
        let settingsFile = rootDir.appendingPathComponent("settings.json")
        var initialSettings: AppSettings
        if let data = try? Data(contentsOf: settingsFile),
           let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            initialSettings = loaded
        } else {
            initialSettings = AppSettings()
        }
        self.settings = initialSettings
        I18n.setLanguage(initialSettings.language)

        // 初始化本地音乐源（并将示例音频放入本地目录以便开箱体验）
        let localDir = rootDir.appendingPathComponent("local", isDirectory: true)
        let createdLocalSource = LocalMusicSource(dataDir: localDir)
        self.localSource = createdLocalSource

        // 初始化播放器
        let createdPlayer = PlayerEngine(cacheDir: rootDir.appendingPathComponent("audio-cache", isDirectory: true))
        self.player = createdPlayer

        // 彻底清理演示插件（demo-plugin）与演示铃声，不再展示演示音源
        Self.purgeDemoPluginAndFiles(pluginsDir: self.pluginsDir, localDir: localDir)
        if initialSettings.source == "demo" {
            initialSettings.source = "kugou-lite"
        }

        self.player.volume = initialSettings.volume
        self.player.diskCache.limitMB = initialSettings.cacheMB
        self.activeNowPlayingPane = .lyrics

        // 发现并加载所有插件
        reloadPlugins()

        // 绑定播放器回调
        self.player.sourceResolver = { [weak self] id in
            self?.source(forID: id)
        }
        self.player.qualityProvider = { [weak self] in
            self?.settings.quality.rawValue ?? "high"
        }
        self.player.normalizeProvider = { [weak self] in
            self?.settings.normalize ?? true
        }
        self.player.onSourceFailure = { [weak self] sourceID, err in
            Task { @MainActor in
                guard let self else { return }
                self.showToast(err.localizedDescription)
                if case .signIn = err {
                    await self.signIn(toSourceID: sourceID)
                }
            }
        }
        self.player.onSessionChanged = { [weak self] in
            Task { @MainActor in
                self?.savePlaybackSession()
            }
        }

        // 监听当前播放曲目变化以加载评论和喜欢状态
        self.trackChangeCancellable = self.player.$currentTrack
            .removeDuplicates()
            .sink { [weak self] newTrack in
                Task { @MainActor in
                    guard let self else { return }
                    if let tr = newTrack {
                        #if canImport(UIKit)
                        await self.updateNowPlayingArtwork(for: tr)
                        #endif
                        await self.checkLikes(for: [tr])
                        await self.loadComments(for: tr)
                    } else {
                        #if canImport(UIKit)
                        self.artworkGeneration &+= 1
                        self.player.setNowPlayingArtwork(data: nil)
                        #endif
                        self.currentTrackComments = []
                        self.currentTrackCommentTotal = 0
                    }
                }
            }

        // 仅在播放器核心宏观状态（切歌、播放/暂停、加载状态、队列、歌词就绪等）变化时通知 AppModel
        // 彻底解耦高频的 position（20fps）与 audioBands，避免全 App 顶层视图树被高频重绘拖垮
        self.playerCancellable = Publishers.MergeMany([
            self.player.$currentTrack.map { _ in () }.eraseToAnyPublisher(),
            self.player.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            self.player.$isLoading.map { _ in () }.eraseToAnyPublisher(),
            self.player.$currentOrderIndex.map { _ in () }.eraseToAnyPublisher(),
            self.player.$order.map { _ in () }.eraseToAnyPublisher(),
            self.player.$queue.map { _ in () }.eraseToAnyPublisher(),
            self.player.$lyrics.map { _ in () }.eraseToAnyPublisher(),
            self.player.$lyricsLoaded.map { _ in () }.eraseToAnyPublisher(),
            self.player.$errorMessage.map { _ in () }.eraseToAnyPublisher(),
            self.player.$repeatMode.map { _ in () }.eraseToAnyPublisher(),
            self.player.$shuffle.map { _ in () }.eraseToAnyPublisher()
        ])
        .sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        // 恢复上次使用的音源与播放会话
        let preferredID = self.settings.source
        if enabledSources.contains(where: { $0.info().id == preferredID }) {
            self.activeSourceID = preferredID
        } else if let first = enabledSources.first {
            self.activeSourceID = first.info().id
        }

        restorePlaybackSessionIfNeeded()
        Task {
            await refreshActiveSource()
        }
    }

    private static func purgeDemoPluginAndFiles(pluginsDir: URL, localDir: URL) {
        let fm = FileManager.default
        let demoDir = pluginsDir.appendingPathComponent("demo", isDirectory: true)
        if fm.fileExists(atPath: demoDir.path) {
            try? fm.removeItem(at: demoDir)
        }
        let musicFiles = localDir.appendingPathComponent("MusicFiles", isDirectory: true)
        let sampleMP3 = musicFiles.appendingPathComponent("MyGo - Welcome Tone.mp3")
        let sampleLRC = musicFiles.appendingPathComponent("MyGo - Welcome Tone.lrc")
        try? fm.removeItem(at: sampleMP3)
        try? fm.removeItem(at: sampleLRC)
    }

    // MARK: - 音源管理（对应 makeSources / enabledChanged / switchSource）

    public func reloadPlugins() {
        let discovered = PluginInstaller.discover(pluginsDir: pluginsDir, dataRootDir: pluginDataDir)
            .filter { $0.manifest.id != "demo" }
        for p in discovered {
            wirePluginCallbacks(p)
        }
        self.pluginSources = discovered
        Task {
            for p in discovered where p.can("account") {
                if let acc = try? await p.account() {
                    self.accountsBySource[p.manifest.id] = acc
                } else {
                    self.accountsBySource.removeValue(forKey: p.manifest.id)
                }
            }
        }
    }

    private func wirePluginCallbacks(_ p: JSPluginSource) {
        let pid = p.manifest.id
        p.onSignInPrompt = { [weak self] prompt in
            Task { @MainActor in
                guard let self else { return }
                self.signInTargetSourceID = pid
                self.activeSignInPrompt = prompt
                self.isSignInSheetPresented = true
            }
        }
        p.onOpenURL = { url in
            Task { @MainActor in
                #if canImport(UIKit)
                UIApplication.shared.open(url)
                #elseif canImport(AppKit)
                NSWorkspace.shared.open(url)
                #endif
            }
        }
        p.onWebSignIn = { [weak self] req in
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(throwing: SourceError.message("AppModel deallocated"))
                        return
                    }
                    if let prev = self.webSignInContinuation {
                        self.webSignInContinuation = nil
                        prev.resume(throwing: SourceError.message("Cancelled"))
                    }
                    self.webSignInContinuation = continuation
                    self.activeWebSignInRequest = req
                }
            }
        }
    }

    /// 获取封面图片请求所需的自定义防盗链 Header（对应 internal/app/sources.go 中的 imageHeaders）
    public func imageHeaders(for url: URL) -> [String: String] {
        var merged: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) mygo-music/0.1"
        ]
        for p in pluginSources where isSourceEnabled(p.manifest.id) {
            if let rules = p.headersFor(url: url, kind: PluginRequestHeaders.kindImage) {
                for (k, v) in rules where merged[k] == nil {
                    merged[k] = v
                }
            }
        }
        return merged
    }

    #if canImport(UIKit)
    private func updateNowPlayingArtwork(for track: Track) async {
        artworkGeneration &+= 1
        let generation = artworkGeneration
        player.setNowPlayingArtwork(data: nil)

        guard let rawURL = sizedImageURL(track.album.imageUrl, px: 600), !rawURL.isEmpty else { return }
        var data: Data?

        if rawURL.hasPrefix("data:image/"), let comma = rawURL.firstIndex(of: ",") {
            data = Data(base64Encoded: String(rawURL[rawURL.index(after: comma)...]), options: .ignoreUnknownCharacters)
        } else {
            let url: URL?
            if rawURL.hasPrefix("file://") {
                url = URL(string: rawURL)
            } else if rawURL.hasPrefix("/") {
                url = URL(fileURLWithPath: rawURL)
            } else {
                url = URL(string: rawURL)
            }

            if let url, url.isFileURL {
                data = try? Data(contentsOf: url)
            } else if let url {
                var request = URLRequest(url: url)
                for (key, value) in imageHeaders(for: url) {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                if let (responseData, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 {
                    data = responseData
                }
            }
        }

        guard artworkGeneration == generation,
              player.currentTrack?.compositeKey == track.compositeKey else { return }
        player.setNowPlayingArtwork(data: data)
    }
    #endif

    public var allSources: [MusicSource] {
        [localSource] + pluginSources.map { $0 as MusicSource }
    }

    public var enabledSources: [MusicSource] {
        let disabled = Set(settings.disabledPlugins)
        let active = allSources.filter { !disabled.contains($0.info().id) }
        return active.isEmpty ? [localSource] : active
    }

    public var activeSource: MusicSource {
        source(forID: activeSourceID) ?? enabledSources.first ?? localSource
    }

    public func source(forID id: String) -> MusicSource? {
        if id == LocalMusicSource.sourceID {
            return localSource
        }
        return pluginSources.first { $0.manifest.id == id }
    }

    public func isSourceEnabled(_ id: String) -> Bool {
        !settings.disabledPlugins.contains(id)
    }

    public func setSourceEnabled(_ id: String, enabled: Bool) {
        var disabled = settings.disabledPlugins.filter { $0 != id }
        if !enabled {
            if enabledSources.count <= 1 && enabledSources.first?.info().id == id {
                return
            }
            disabled.append(id)
        }
        settings.disabledPlugins = disabled
        if !enabled && activeSourceID == id, let first = enabledSources.first {
            switchSource(to: first.info().id)
        }
    }

    public func switchSource(to sourceID: String) {
        guard source(forID: sourceID) != nil else { return }
        searchGeneration &+= 1
        suggestionGeneration &+= 1
        isSearching = false
        searchSuggestions = []
        activeSourceID = sourceID
        settings.source = sourceID
        searchQuery = ""
        searchResult = SearchResult()
        Task {
            await refreshActiveSource()
        }
    }

    /// 刷新当前音源的首页、歌单、喜欢、电台、播客与账号数据
    public func refreshActiveSource() async {
        sourceRefreshGeneration &+= 1
        let generation = sourceRefreshGeneration
        let src = activeSource
        let srcID = src.info().id
        isLoadingHome = true
        homeError = nil

        if src.can("account") {
            let acc = try? await src.account()
            guard sourceRefreshGeneration == generation, activeSourceID == srcID else { return }
            currentAccount = acc
            if let acc {
                accountsBySource[srcID] = acc
            } else {
                accountsBySource.removeValue(forKey: srcID)
            }
        } else {
            currentAccount = nil
            accountsBySource.removeValue(forKey: srcID)
        }

        if src.can("home") {
            do {
                let b = try await src.home()
                guard sourceRefreshGeneration == generation, activeSourceID == srcID else { return }
                self.homeBrowse = b
                if let sections = b.sections {
                    let allTracks = sections.flatMap { $0.tracks ?? [] }
                    await checkLikes(for: allTracks)
                }
            } catch {
                guard sourceRefreshGeneration == generation, activeSourceID == srcID else { return }
                self.homeError = error.localizedDescription
            }
        } else {
            self.homeBrowse = nil
        }

        if src.can("recent") {
            let rec = try? await src.recent()
            guard sourceRefreshGeneration == generation, activeSourceID == srcID else { return }
            if let rec {
                self.recentTracks = rec
                await checkLikes(for: rec)
            }
        } else {
            self.recentTracks = []
        }

        if src.can("playlists") {
            let pls = try? await src.playlists()
            guard sourceRefreshGeneration == generation, activeSourceID == srcID else { return }
            if let pls {
                self.myPlaylists = pls.filter { $0.mine == true }
                self.savedPlaylists = pls.filter { $0.mine != true }
            }
        } else {
            self.myPlaylists = []
            self.savedPlaylists = []
        }

        if src.can("liked") {
            let page = try? await src.liked(offset: 0)
            guard sourceRefreshGeneration == generation, activeSourceID == srcID else { return }
            if let page {
                self.likedTracks = page.tracks ?? []
                await checkLikes(for: self.likedTracks)
            }
        } else {
            self.likedTracks = []
        }

        if src.can("savedAlbums") {
            let list = try? await src.savedAlbums(offset: 0)
            guard sourceRefreshGeneration == generation, activeSourceID == srcID else { return }
            if let list {
                self.savedAlbums = list.albums ?? []
            }
        } else {
            self.savedAlbums = []
        }

        if src.can("stations") {
            let st = try? await src.stations()
            guard sourceRefreshGeneration == generation, activeSourceID == srcID else { return }
            if let st {
                self.stations = st
            }
        } else {
            self.stations = []
        }

        if src.can("shows") {
            let sh = try? await src.shows()
            guard sourceRefreshGeneration == generation, activeSourceID == srcID else { return }
            if let sh {
                self.subscribedShows = sh
            }
        } else {
            self.subscribedShows = []
        }

        guard sourceRefreshGeneration == generation, activeSourceID == srcID else { return }
        isLoadingHome = false
    }

    // MARK: - 喜欢、歌单与评论操作

    public func isTrackLiked(_ track: Track) -> Bool {
        likedMap[track.compositeKey] ?? false
    }

    public func checkLikes(for tracks: [Track]) async {
        guard !tracks.isEmpty else { return }
        var bySource: [String: [String]] = [:]
        for t in tracks {
            let sid = t.source ?? activeSourceID
            bySource[sid, default: []].append(t.id)
        }
        for (sid, ids) in bySource {
            guard let src = source(forID: sid), src.can("isLiked") else { continue }
            if let map = try? await src.isLiked(ids: ids) {
                for (id, liked) in map {
                    likedMap["\(sid):\(id)"] = liked
                }
            }
        }
    }

    public func toggleLike(_ track: Track) async {
        let sid = track.source ?? activeSourceID
        guard let src = source(forID: sid) else { return }
        let key = track.compositeKey
        let newState = !(likedMap[key] ?? false)
        likedMap[key] = newState
        do {
            if track.isEpisode && src.can("likeEpisode") {
                try await src.likeEpisode(id: track.id, on: newState)
            } else {
                try await src.like(id: track.id, on: newState)
            }
            showToast(newState ? I18n.t("Added to Liked Songs") : I18n.t("Removed from Liked Songs"))
            if sid == activeSourceID, src.can("liked"), let page = try? await src.liked(offset: 0) {
                self.likedTracks = page.tracks ?? []
            }
        } catch {
            likedMap[key] = !newState
            showToast(I18n.t("That didn't work. Try again later."))
        }
    }

    public func createPlaylist(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, activeSource.can("createPlaylist") else { return }
        do {
            _ = try await activeSource.createPlaylist(name: trimmed)
            await refreshActiveSource()
        } catch {
            showToast(I18n.t("Couldn't create the playlist. Try again later."))
        }
    }

    public func renamePlaylist(id: String, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, activeSource.can("renamePlaylist") else { return }
        do {
            try await activeSource.renamePlaylist(id: id, name: trimmed)
            await refreshActiveSource()
        } catch {
            showToast(I18n.t("Couldn't rename the playlist. Try again later."))
        }
    }

    public func deletePlaylist(id: String) async {
        guard activeSource.can("deletePlaylist") else { return }
        do {
            try await activeSource.deletePlaylist(id: id)
            showToast(I18n.t("Playlist deleted"))
            await refreshActiveSource()
        } catch {
            showToast(I18n.t("Couldn't delete the playlist. Try again later."))
        }
    }

    public func addTrack(_ track: Track, toPlaylist playlistID: String) async {
        let sid = track.source ?? activeSourceID
        guard let src = source(forID: sid), src.can("addToPlaylist") else { return }
        do {
            try await src.addToPlaylist(id: playlistID, trackIds: [track.id])
            showToast(I18n.t("Added to the playlist"))
            await refreshActiveSource()
        } catch {
            showToast(I18n.t("Couldn't add it to the playlist. Try again later."))
        }
    }

    public func startStation(_ station: Station) async {
        let src = activeSource
        guard src.can("stationNext") else { return }
        showToast(I18n.t("Tuning in…"))
        do {
            let initial = try await src.stationNext(id: station.id)
            guard !initial.isEmpty else {
                showToast(I18n.t("The station has nothing more right now"))
                return
            }
            let stationID = station.id
            player.playRadio(name: station.name, initialTracks: initial) {
                (try? await src.stationNext(id: stationID)) ?? []
            }
        } catch {
            showToast(I18n.t("This station can't play right now. Try again later."))
        }
    }

    public func loadComments(for track: Track) async {
        let sid = track.source ?? activeSourceID
        guard let src = source(forID: sid), src.can("comments") else {
            currentTrackComments = []
            currentTrackCommentTotal = 0
            return
        }
        isLoadingComments = true
        defer { isLoadingComments = false }
        if let page = try? await src.comments(trackId: track.id, offset: 0) {
            currentTrackComments = page.comments ?? []
            currentTrackCommentTotal = page.total ?? currentTrackComments.count
        }
    }

    public func postComment(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tr = player.currentTrack else { return }
        let sid = tr.source ?? activeSourceID
        guard let src = source(forID: sid), src.can("postComment") else { return }
        do {
            let newComment = try await src.postComment(trackId: tr.id, text: trimmed)
            currentTrackComments.insert(newComment, at: 0)
            currentTrackCommentTotal += 1
        } catch {
            showToast(I18n.t("Couldn't post your comment. Try again later."))
        }
    }

    // MARK: - 搜索与账号操作

    public func performSearch() async {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration &+= 1
        let generation = searchGeneration
        let source = activeSource
        guard !q.isEmpty, source.can("search") else {
            isSearching = false
            searchResult = SearchResult()
            return
        }
        let kind = searchKind

        // 记录搜索历史
        var hist = settings.searchHistory.filter { $0.lowercased() != q.lowercased() }
        hist.insert(q, at: 0)
        if hist.count > 12 { hist = Array(hist.prefix(12)) }
        settings.searchHistory = hist

        isSearching = true
        defer {
            if searchGeneration == generation { isSearching = false }
        }
        do {
            let res = try await source.search(query: q, kind: kind, offset: 0)
            guard searchGeneration == generation, activeSourceID == source.info().id else { return }
            self.searchResult = res
            if let tracks = res.tracks {
                await checkLikes(for: tracks)
            }
        } catch {
            if searchGeneration == generation { showToast(I18n.t("The search failed")) }
        }
    }

    public func updateSuggestions(for query: String) async {
        suggestionGeneration &+= 1
        let generation = suggestionGeneration
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = activeSource
        guard !q.isEmpty, source.can("suggest") else {
            searchSuggestions = []
            return
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard suggestionGeneration == generation,
              searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == q,
              activeSourceID == source.info().id else { return }
        if let list = try? await source.suggest(query: q),
           suggestionGeneration == generation,
           searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == q,
           activeSourceID == source.info().id {
            searchSuggestions = list
        }
    }

    public func signInToActiveSource() async {
        await signIn(toSourceID: activeSourceID)
    }

    public func signIn(toSourceID sourceID: String) async {
        guard let src = source(forID: sourceID), src.can("signIn") else { return }
        signInTargetSourceID = sourceID
        signInError = nil
        activeSignInPrompt = nil
        isSigningIn = true
        // 先等待插件选择登录方式：Web 插件会直接打开自己的登录页，扫码插件则由 signInPrompt 再打开提示页。
        isSignInSheetPresented = false

        do {
            let acc = try await src.signIn()
            isSigningIn = false
            activeSignInPrompt = nil
            if let acc {
                accountsBySource[sourceID] = acc
                if sourceID == activeSourceID {
                    currentAccount = acc
                }
                isSignInSheetPresented = false
                showToast(I18n.tf("Signed in as %s", acc.name))
            } else if let fetched = try? await src.account() {
                accountsBySource[sourceID] = fetched
                if sourceID == activeSourceID {
                    currentAccount = fetched
                }
                isSignInSheetPresented = false
                showToast(I18n.tf("Signed in as %s", fetched.name))
            } else {
                isSignInSheetPresented = false
            }
            if sourceID == activeSourceID {
                await refreshActiveSource()
            }
        } catch {
            isSigningIn = false
            if error.localizedDescription == I18n.t("Sign-in cancelled") { return }
            signInError = error.localizedDescription
            isSignInSheetPresented = true
            showToast(error.localizedDescription)
        }
    }

    public func dismissSignInSheet() {
        isSignInSheetPresented = false
        isSigningIn = false
        activeSignInPrompt = nil
        signInError = nil
        cancelWebSignIn()
    }

    public func completeWebSignIn(cookieHeader: String) {
        activeWebSignInRequest = nil
        if let cont = webSignInContinuation {
            webSignInContinuation = nil
            cont.resume(returning: cookieHeader)
        }
    }

    public func cancelWebSignIn() {
        activeWebSignInRequest = nil
        if let cont = webSignInContinuation {
            webSignInContinuation = nil
            cont.resume(throwing: SourceError.message(I18n.t("Sign-in cancelled")))
        }
    }

    public func signOutOfActiveSource() async {
        await signOut(ofSourceID: activeSourceID)
    }

    public func signOut(ofSourceID sourceID: String) async {
        guard let src = source(forID: sourceID), src.can("signOut") else { return }
        do {
            try await src.signOut()
            accountsBySource.removeValue(forKey: sourceID)
            if sourceID == activeSourceID {
                self.currentAccount = nil
                await refreshActiveSource()
            }
        } catch {
            showToast(I18n.t("Couldn't sign out"))
        }
    }

    // MARK: - 插件安装与 Deep Link（mygo-music://install-plugin?repo=owner/repo）

    public func installPluginFromGitHub(repoInput: String) async {
        isInstallingPlugin = true
        installErrorMessage = nil
        defer { isInstallingPlugin = false }
        do {
            let pending = try await PluginInstaller.fetchFromGitHub(repoInput: repoInput)
            let installed = try PluginInstaller.install(pending, into: pluginsDir, dataRootDir: pluginDataDir)
            reloadPlugins()
            switchSource(to: installed.manifest.id)
            showToast("Installed \(installed.info().name)")
        } catch {
            installErrorMessage = error.localizedDescription
        }
    }

    public func removePlugin(id: String) {
        guard let target = pluginSources.first(where: { $0.manifest.id == id }) else { return }
        try? FileManager.default.removeItem(at: target.pluginDir)
        reloadPlugins()
        if activeSourceID == id {
            switchSource(to: enabledSources.first?.info().id ?? LocalMusicSource.sourceID)
        }
    }

    public func handleDeepLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              (scheme == "mygo-music" || scheme == "mygo-music-dev") else { return }
        let host = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard host == "install-plugin",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let repo = components.queryItems?.first(where: { $0.name == "repo" })?.value,
              !repo.isEmpty else {
            return
        }
        Task {
            await installPluginFromGitHub(repoInput: repo)
        }
    }

    public func showToast(_ text: String) {
        toastMessage = text
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.toastMessage == text {
                self.toastMessage = nil
            }
        }
    }

    // MARK: - 设置与会话持久化

    private func saveSettings() {
        let file = baseDataDir.appendingPathComponent("settings.json")
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private func savePlaybackSession() {
        let file = baseDataDir.appendingPathComponent("session.json")
        if let session = player.exportSession(),
           let data = try? JSONEncoder().encode(session) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private func restorePlaybackSessionIfNeeded() {
        let file = baseDataDir.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: file),
              let session = try? JSONDecoder().decode(SavedPlaybackSession.self, from: data) else {
            return
        }
        player.restoreSession(session)
    }
}

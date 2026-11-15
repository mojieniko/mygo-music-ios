// AppModel.swift
// 对应原项目 internal/app/app.go, sources.go, settings.go 的全局应用状态与数据源管理

import Combine
import Foundation
#if canImport(Speech)
import Speech
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 单个插件的在线检查状态
public enum PluginUpdateCheckState: Hashable, Sendable {
    case checking
    case upToDate
    case updateAvailable(String)
    case failed(String)
}

/// 插件升级请求新增敏感权限时，等待用户二次确认的挂起任务
public struct PendingPluginUpdateApproval: Identifiable, Sendable {
    public let requestID: UUID
    public var id: String { pending.manifest.id }
    public var pluginName: String
    public var targetVersion: String
    public var addedPermissions: PluginPermissions
    public var pending: PendingPlugin

    public init(
        requestID: UUID = UUID(),
        pluginName: String,
        targetVersion: String,
        addedPermissions: PluginPermissions,
        pending: PendingPlugin
    ) {
        self.requestID = requestID
        self.pluginName = pluginName
        self.targetVersion = targetVersion
        self.addedPermissions = addedPermissions
        self.pending = pending
    }
}

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
    public var fade: Bool = true
    public var hotComments: Bool = true
    public var fog: Bool = true
    public var lockScreenLyrics: Bool = true
    public var cacheMB: Int = 2048
    public var searchHistory: [String] = []
    public var githubToken: String = ""
    public var pluginUpdates: [String: String] = [:]
    public var pluginsCheckedAt: TimeInterval = 0

    private enum CodingKeys: String, CodingKey {
        case language, source, captions, disabledPlugins, quality, appearance
        case growFromCover, smoke, lyricsStage, stageStyle, stageSparks, volume
        case normalize, fade, hotComments, fog, lockScreenLyrics, cacheMB, searchHistory
        case githubToken, pluginUpdates, pluginsCheckedAt
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
        fade = try values.decodeIfPresent(Bool.self, forKey: .fade) ?? true
        hotComments = try values.decodeIfPresent(Bool.self, forKey: .hotComments) ?? true
        fog = try values.decodeIfPresent(Bool.self, forKey: .fog) ?? true
        lockScreenLyrics = try values.decodeIfPresent(Bool.self, forKey: .lockScreenLyrics) ?? true
        cacheMB = try values.decodeIfPresent(Int.self, forKey: .cacheMB) ?? 2048
        searchHistory = try values.decodeIfPresent([String].self, forKey: .searchHistory) ?? []
        githubToken = try values.decodeIfPresent(String.self, forKey: .githubToken) ?? ""
        pluginUpdates = try values.decodeIfPresent([String: String].self, forKey: .pluginUpdates) ?? [:]
        pluginsCheckedAt = try values.decodeIfPresent(TimeInterval.self, forKey: .pluginsCheckedAt) ?? 0
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
            if oldValue.captions != settings.captions {
                if settings.captions {
                    Task { @MainActor [weak self] in
                        await self?.requestSpeechPermissionAndRefreshCaptions()
                    }
                } else {
                    captionTask?.cancel()
                    timedCaptions = []
                    liveCaptionsStatus = ""
                }
            }
            if oldValue.lockScreenLyrics != settings.lockScreenLyrics {
                player.refreshNowPlayingInfo()
            }
        }
    }

    @Published public private(set) var pluginSources: [JSPluginSource] = []
    @Published public private(set) var pluginLoadFailures: [PluginLoadFailure] = []
    @Published public private(set) var pluginOrigins: [String: PluginOrigin] = [:]
    @Published public private(set) var isCheckingUpdates: Bool = false
    @Published public private(set) var pluginCheckStates: [String: PluginUpdateCheckState] = [:]
    @Published public private(set) var updatingPluginIDs: Set<String> = []
    @Published public private(set) var isUpdatingAllPlugins: Bool = false
    @Published public var pendingPluginUpdateApproval: PendingPluginUpdateApproval? = nil
    @Published public private(set) var communityPlugins: [CommunityPluginEntry] = []
    @Published public private(set) var isLoadingCommunityPlugins: Bool = false
    @Published public private(set) var communityPluginsError: String? = nil
    private var cachedPluginReleases: [String: PluginReleaseInfo] = [:]
    private var pendingPluginUpdateQueue: [PendingPluginUpdateApproval] = []
    private var confirmedPluginUpdateRequestIDs: Set<UUID> = []
    private var deferredPluginUpdateCleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var nextQueuedApprovalTask: Task<Void, Never>? = nil

    /// 当前有可用更新的已安装插件数量（仅计仍存在于本地列表中的插件）
    public var availablePluginUpdateCount: Int {
        pluginSources.filter { settings.pluginUpdates[$0.manifest.id] != nil }.count
    }
    @Published public private(set) var isStartupReady: Bool = true
    @Published public var activeSourceID: String = "kugou-lite"
    public private(set) var syncInitDurationMs: Double = 0
    public private(set) var deferredStartupDurationMs: Double? = nil

    // 当前活动音乐源的数据缓存
    @Published public private(set) var isLoadingHome: Bool = false
    @Published public private(set) var homeError: String? = nil
    @Published public private(set) var homeBrowse: Browse? = nil
    @Published public private(set) var recentTracks: [Track] = []
    @Published public private(set) var myPlaylists: [Playlist] = []
    @Published public private(set) var savedPlaylists: [Playlist] = []
    @Published public private(set) var likedTracks: [Track] = []
    @Published public private(set) var likedHasMore: Bool = false
    @Published public private(set) var isLoadingMoreLiked: Bool = false
    @Published public private(set) var savedAlbums: [Album] = []
    @Published public private(set) var savedAlbumsHasMore: Bool = false
    @Published public private(set) var isLoadingMoreSavedAlbums: Bool = false
    @Published public private(set) var stations: [Station] = []
    @Published public private(set) var subscribedShows: [Show] = []
    @Published public private(set) var currentAccount: Account? = nil
    @Published public private(set) var accountsBySource: [String: Account] = [:]
    @Published public private(set) var likedMap: [String: Bool] = [:]

    // 正在播放、实时字幕与评论状态
    @Published public var isNowPlayingPresented: Bool = false
    @Published public var activeNowPlayingPane: NowPlayingPane = .lyrics
    @Published public private(set) var currentTrackComments: [Comment] = []
    @Published public private(set) var currentTrackCommentTotal: Int = 0
    @Published public private(set) var commentsHasMore: Bool = false
    @Published public private(set) var isLoadingComments: Bool = false
    @Published public private(set) var isLoadingMoreComments: Bool = false
    @Published public private(set) var timedCaptions: [LyricLine] = []
    @Published public private(set) var liveCaptionsStatus: String = ""

    // 搜索状态
    @Published public var searchQuery: String = ""
    @Published public var searchKind: SearchKind = .tracks
    @Published public private(set) var searchResult: SearchResult = SearchResult()
    @Published public private(set) var searchSuggestions: [String] = []
    @Published public private(set) var isSearching: Bool = false
    @Published public private(set) var isLoadingMoreSearch: Bool = false

    // 插件安装、二维码/提示登录、加入歌单与 WebView 登录状态
    @Published public var toastMessage: String? = nil
    @Published public var pendingAddToPlaylistTrack: Track? = nil
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
    private var captionTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>? = nil
    private var hasExplicitPluginReload = false
    private var commentLikePendingIDs: Set<String> = []
    private var searchGeneration = 0
    private var suggestionGeneration = 0
    private var sourceRefreshGeneration = 0
    private var artworkGeneration = 0

    public init(baseDataDir: URL? = nil, deferHeavyStartup: Bool = false) {
        let initStartNs = DispatchTime.now().uptimeNanoseconds
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
        if initialSettings.source == "demo" {
            initialSettings.source = "kugou-lite"
        }
        self.settings = initialSettings
        I18n.setLanguage(initialSettings.language)

        // 初始化本地音乐源（App 冷启动时延后扫描以免阻塞首帧渲染）
        let localDir = rootDir.appendingPathComponent("local", isDirectory: true)
        let createdLocalSource = LocalMusicSource(dataDir: localDir, eagerSyncScan: !deferHeavyStartup)
        self.localSource = createdLocalSource

        // 初始化播放器（冷启动不提前同步激活系统音频会话）
        let createdPlayer = PlayerEngine(
            cacheDir: rootDir.appendingPathComponent("audio-cache", isDirectory: true),
            activateAudioSessionOnInit: !deferHeavyStartup
        )
        self.player = createdPlayer

        self.player.volume = initialSettings.volume
        self.player.diskCache.limitMB = initialSettings.cacheMB
        self.activeNowPlayingPane = initialSettings.lyricsStage ? .stage : .lyrics
        if deferHeavyStartup {
            self.isStartupReady = false
            self.isLoadingHome = true
            self.activeSourceID = initialSettings.source
        }

        createdLocalSource.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isStartupReady, self.activeSourceID == LocalMusicSource.sourceID else { return }
                await self.refreshActiveSource()
            }
        }

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
        self.player.fadeEnabledProvider = { [weak self] in
            self?.settings.fade ?? true
        }
        self.player.lockScreenLyricsProvider = { [weak self] in
            self?.settings.lockScreenLyrics ?? true
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

        // 监听当前播放曲目变化以加载评论、喜欢状态和播客实时字幕
        self.trackChangeCancellable = self.player.$currentTrack
            .removeDuplicates()
            .sink { [weak self] newTrack in
                Task { @MainActor in
                    guard let self else { return }
                    self.timedCaptions = []
                    self.liveCaptionsStatus = ""
                    self.captionTask?.cancel()
                    if let tr = newTrack {
                        #if canImport(UIKit)
                        await self.updateNowPlayingArtwork(for: tr)
                        #endif
                        await self.checkLikes(for: [tr])
                        await self.loadComments(for: tr)
                        await self.refreshCaptionsForCurrentTrack()
                    } else {
                        #if canImport(UIKit)
                        self.artworkGeneration &+= 1
                        self.player.setNowPlayingArtwork(data: nil)
                        #endif
                        self.currentTrackComments = []
                        self.currentTrackCommentTotal = 0
                        self.commentsHasMore = false
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

        if deferHeavyStartup {
            self.syncInitDurationMs = Double(DispatchTime.now().uptimeNanoseconds - initStartNs) / 1_000_000.0
            #if DEBUG
            print(String(format: "[MyGoStartup] syncInit=%.2fms (deferHeavyStartup=true)", self.syncInitDurationMs))
            #endif
            self.startupTask = Task { [weak self] in
                await self?.bootstrapDeferredStartup(localDir: localDir, startupBeganNs: initStartNs)
            }
        } else {
            // 同步路径（供单元测试与非延迟场景直接完成初始化）
            Self.purgeDemoPluginAndFiles(pluginsDir: self.pluginsDir, localDir: localDir)
            reloadPlugins()
            resolveInitialActiveSource()
            restorePlaybackSessionIfNeeded()
            self.syncInitDurationMs = Double(DispatchTime.now().uptimeNanoseconds - initStartNs) / 1_000_000.0
            Task {
                await refreshActiveSource()
            }
        }
    }

    /// 等待延迟启动装配完成（同步初始化模式立即返回）
    public func waitUntilStartupReady() async {
        await startupTask?.value
    }

    private func resolveInitialActiveSource() {
        let preferredID = self.settings.source
        if enabledSources.contains(where: { $0.info().id == preferredID }) {
            self.activeSourceID = preferredID
        } else if let first = enabledSources.first {
            self.activeSourceID = first.info().id
        }
    }

    private func bootstrapDeferredStartup(localDir: URL, startupBeganNs: UInt64) async {
        let rootDir = self.baseDataDir
        let pluginsRoot = self.pluginsDir
        let pluginDataRoot = self.pluginDataDir

        let payload: (snapshot: PluginDiscoverySnapshot, session: SavedPlaybackSession?) =
            await Task.detached(priority: .userInitiated) {
                Self.purgeDemoPluginAndFiles(pluginsDir: pluginsRoot, localDir: localDir)
                let snapshot = Self.loadPluginSnapshot(pluginsDir: pluginsRoot, pluginDataDir: pluginDataRoot)
                let sessionURL = rootDir.appendingPathComponent("session.json")
                let restoredSession = (try? Data(contentsOf: sessionURL))
                    .flatMap { try? JSONDecoder().decode(SavedPlaybackSession.self, from: $0) }
                return (snapshot, restoredSession)
            }.value

        let effectiveSnapshot: PluginDiscoverySnapshot
        if hasExplicitPluginReload {
            effectiveSnapshot = Self.loadPluginSnapshot(pluginsDir: pluginsRoot, pluginDataDir: pluginDataRoot)
        } else {
            effectiveSnapshot = payload.snapshot
        }
        applyPluginSnapshot(effectiveSnapshot)
        resolveInitialActiveSource()

        if let session = payload.session, player.currentTrack == nil {
            player.restoreSession(session)
        }
        self.isStartupReady = true
        self.deferredStartupDurationMs = Double(DispatchTime.now().uptimeNanoseconds - startupBeganNs) / 1_000_000.0
        #if DEBUG
        print(String(format: "[MyGoStartup] deferredReady=%.2fms plugins=%d", self.deferredStartupDurationMs ?? 0, payload.snapshot.plugins.count))
        #endif

        await refreshActiveSource()

        // 启动完成后后台按 24 小时冷却自动检测一次插件更新，不阻塞首屏就绪
        Task { [weak self] in
            await self?.checkForPluginUpdates(manual: false)
        }
    }

    nonisolated private static func purgeDemoPluginAndFiles(pluginsDir: URL, localDir: URL) {
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

    private struct PluginDiscoverySnapshot: Sendable {
        let plugins: [JSPluginSource]
        let failures: [PluginLoadFailure]
        let origins: [String: PluginOrigin]
    }

    nonisolated private static func loadPluginSnapshot(
        pluginsDir: URL,
        pluginDataDir: URL
    ) -> PluginDiscoverySnapshot {
        let result = PluginInstaller.discoverDetailed(pluginsDir: pluginsDir, dataRootDir: pluginDataDir)
        let discovered = result.plugins.filter { $0.manifest.id != "demo" }
        var origins: [String: PluginOrigin] = [:]
        for p in discovered {
            if let origin = PluginInstaller.effectiveOrigin(for: p.pluginDir, manifest: p.manifest) {
                origins[p.manifest.id] = origin
            }
        }
        let failures = result.failures.filter { $0.folderName != "demo" }
        return PluginDiscoverySnapshot(plugins: discovered, failures: failures, origins: origins)
    }

    public func reloadPlugins() {
        hasExplicitPluginReload = true
        let snapshot = Self.loadPluginSnapshot(pluginsDir: pluginsDir, pluginDataDir: pluginDataDir)
        applyPluginSnapshot(snapshot)
    }

    private func applyPluginSnapshot(_ snapshot: PluginDiscoverySnapshot) {
        var updates = settings.pluginUpdates
        let activeIDs = Set(snapshot.plugins.map(\.manifest.id))
        for p in snapshot.plugins {
            wirePluginCallbacks(p)
            let pid = p.manifest.id
            let originVer = snapshot.origins[pid]?.version ?? ""
            let installedVer = originVer.isEmpty ? (p.manifest.version ?? "") : originVer
            if let pendingVer = updates[pid],
               !installedVer.isEmpty,
               !PluginInstaller.hasNewerUpdate(candidate: pendingVer, current: installedVer) {
                updates.removeValue(forKey: pid)
            }
        }
        for staleID in updates.keys where !activeIDs.contains(staleID) {
            updates.removeValue(forKey: staleID)
        }
        for staleID in pluginCheckStates.keys where !activeIDs.contains(staleID) {
            pluginCheckStates.removeValue(forKey: staleID)
        }
        for staleID in cachedPluginReleases.keys where !activeIDs.contains(staleID) {
            cachedPluginReleases.removeValue(forKey: staleID)
        }
        if updates != settings.pluginUpdates {
            settings.pluginUpdates = updates
        }
        self.pluginOrigins = snapshot.origins
        self.pluginLoadFailures = snapshot.failures
        self.pluginSources = snapshot.plugins
        Task {
            for p in snapshot.plugins where p.can("account") {
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
        guard !pluginSources.isEmpty else { return merged }
        let disabled = Set(settings.disabledPlugins)
        for p in pluginSources {
            guard !disabled.contains(p.manifest.id),
                  !(p.manifest.requestHeaders?.isEmpty ?? true) else {
                continue
            }
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

    /// 刷新当前音源的首页、歌单、喜欢、电台、播客与账号数据（采用分级并发策略大幅缩短首屏阻塞）
    public func refreshActiveSource() async {
        sourceRefreshGeneration &+= 1
        let generation = sourceRefreshGeneration
        let src = activeSource
        let srcID = src.info().id
        isLoadingHome = true
        homeError = nil

        // 第一阶段：并发拉取账号状态与首页区块，拿到首页即刻释放加载遮罩供用户交互
        async let fetchedAccount: Account? = {
            guard src.can("account") else { return nil }
            return try? await src.account()
        }()
        async let fetchedHome: Result<Browse?, Error> = {
            guard src.can("home") else { return .success(nil) }
            do {
                return .success(try await src.home())
            } catch {
                return .failure(error)
            }
        }()

        let (acc, homeOutcome) = await (fetchedAccount, fetchedHome)
        guard sourceRefreshGeneration == generation, activeSourceID == srcID else { return }

        if src.can("account") {
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

        var likeCheckPool: [Track] = []
        switch homeOutcome {
        case .success(let b):
            self.homeBrowse = b
            if let sections = b?.sections {
                for sec in sections {
                    if let tracks = sec.tracks {
                        likeCheckPool.append(contentsOf: tracks)
                    }
                }
            }
        case .failure(let error):
            self.homeError = error.localizedDescription
        }

        if src.can("home") {
            isLoadingHome = false
        }

        // 第二阶段：并发拉取其余资料库数据并合并更新，避免多次串行 RTT 与连续全屏重绘
        async let fetchedRecent: [Track]? = {
            guard src.can("recent") else { return nil }
            return try? await src.recent()
        }()
        async let fetchedPlaylists: [Playlist]? = {
            guard src.can("playlists") else { return nil }
            return try? await src.playlists()
        }()
        async let fetchedLiked: TrackPage? = {
            guard src.can("liked") else { return nil }
            return try? await src.liked(offset: 0)
        }()
        async let fetchedAlbums: AlbumList? = {
            guard src.can("savedAlbums") else { return nil }
            return try? await src.savedAlbums(offset: 0)
        }()
        async let fetchedStations: [Station]? = {
            guard src.can("stations") else { return nil }
            return try? await src.stations()
        }()
        async let fetchedShows: [Show]? = {
            guard src.can("shows") else { return nil }
            return try? await src.shows()
        }()

        let (rec, pls, likedPage, albumsList, st, sh) = await (
            fetchedRecent,
            fetchedPlaylists,
            fetchedLiked,
            fetchedAlbums,
            fetchedStations,
            fetchedShows
        )
        guard sourceRefreshGeneration == generation, activeSourceID == srcID else { return }

        if src.can("recent") {
            if let rec {
                self.recentTracks = rec
                likeCheckPool.append(contentsOf: rec)
            }
        } else {
            self.recentTracks = []
        }

        if src.can("playlists") {
            if let pls {
                self.myPlaylists = pls.filter { $0.mine == true }
                self.savedPlaylists = pls.filter { $0.mine != true }
            }
        } else {
            self.myPlaylists = []
            self.savedPlaylists = []
        }

        if src.can("liked") {
            if let likedPage {
                let tracks = likedPage.tracks ?? []
                self.likedTracks = tracks
                self.likedHasMore = likedPage.more == true
                likeCheckPool.append(contentsOf: tracks)
            } else {
                self.likedHasMore = false
            }
        } else {
            self.likedTracks = []
            self.likedHasMore = false
        }

        if src.can("savedAlbums") {
            if let albumsList {
                self.savedAlbums = albumsList.albums ?? []
                self.savedAlbumsHasMore = albumsList.more == true
            } else {
                self.savedAlbumsHasMore = false
            }
        } else {
            self.savedAlbums = []
            self.savedAlbumsHasMore = false
        }

        if src.can("stations") {
            if let st {
                self.stations = st
            }
        } else {
            self.stations = []
        }

        if src.can("shows") {
            if let sh {
                self.subscribedShows = sh
            }
        } else {
            self.subscribedShows = []
        }

        isLoadingHome = false

        if !likeCheckPool.isEmpty {
            await checkLikes(for: likeCheckPool)
        }
    }

    // MARK: - 喜欢、歌单与评论操作

    public func isTrackLiked(_ track: Track) -> Bool {
        likedMap[track.compositeKey] ?? false
    }

    /// 按音源分组并保序去重曲目 ID，避免大曲库下对同一首歌重复查询喜欢状态
    public static func uniqueTrackIDsBySource(tracks: [Track], fallbackSourceID: String) -> [String: [String]] {
        var bySource: [String: [String]] = [:]
        var seenKeys = Set<String>()
        for t in tracks {
            let sid = t.source ?? fallbackSourceID
            let composite = "\(sid):\(t.id)"
            if seenKeys.insert(composite).inserted {
                bySource[sid, default: []].append(t.id)
            }
        }
        return bySource
    }

    /// 仅计算与现有 `likedMap` 有差异的条目，消除无变化的冗余视图刷新
    public static func diffLikedUpdates(
        existing: [String: Bool],
        incoming: [String: Bool],
        sourceID: String
    ) -> [String: Bool] {
        var delta: [String: Bool] = [:]
        for (id, liked) in incoming {
            let key = "\(sourceID):\(id)"
            if existing[key] != liked {
                delta[key] = liked
            }
        }
        return delta
    }

    public func checkLikes(for tracks: [Track]) async {
        guard !tracks.isEmpty else { return }
        let bySource = Self.uniqueTrackIDsBySource(tracks: tracks, fallbackSourceID: activeSourceID)
        var pendingUpdates: [String: Bool] = [:]
        for (sid, ids) in bySource {
            guard !ids.isEmpty, let src = source(forID: sid), src.can("isLiked") else { continue }
            if let map = try? await src.isLiked(ids: ids) {
                let delta = Self.diffLikedUpdates(existing: likedMap, incoming: map, sourceID: sid)
                for (key, value) in delta {
                    pendingUpdates[key] = value
                }
            }
        }
        guard !pendingUpdates.isEmpty else { return }
        var nextMap = likedMap
        for (key, value) in pendingUpdates {
            nextMap[key] = value
        }
        likedMap = nextMap
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

    public func removeTrack(_ trackID: String, fromPlaylist playlistID: String, sourceID: String) async -> Bool {
        guard let src = source(forID: sourceID), src.can("removeFromPlaylist") else { return false }
        do {
            try await src.removeFromPlaylist(id: playlistID, trackIds: [trackID])
            if sourceID == activeSourceID { await refreshActiveSource() }
            return true
        } catch {
            showToast(I18n.t("That didn't work. Try again later."))
            return false
        }
    }

    public func moveTrack(inPlaylist playlistID: String, sourceID: String, from: Int, to: Int) async -> Bool {
        guard from != to, let src = source(forID: sourceID), src.can("movePlaylistTrack") else { return false }
        do {
            try await src.movePlaylistTrack(id: playlistID, from: from, to: to)
            if sourceID == activeSourceID { await refreshActiveSource() }
            return true
        } catch {
            showToast(I18n.t("That didn't work. Try again later."))
            return false
        }
    }

    public func toggleSaveAlbum(sourceID: String, albumID: String, currentlySaved: Bool) async -> Bool {
        guard let src = source(forID: sourceID), src.can("saveAlbum") else { return currentlySaved }
        let target = !currentlySaved
        do {
            try await src.saveAlbum(id: albumID, on: target)
            if sourceID == activeSourceID, src.can("savedAlbums"), let list = try? await src.savedAlbums(offset: 0) {
                self.savedAlbums = list.albums ?? []
                self.savedAlbumsHasMore = list.more == true
            }
            return target
        } catch {
            showToast(I18n.t("That didn't work. Try again later."))
            return currentlySaved
        }
    }

    public func toggleFollowArtist(sourceID: String, artistID: String, currentlyFollowing: Bool) async -> Bool {
        guard let src = source(forID: sourceID), src.can("followArtist") else { return currentlyFollowing }
        let target = !currentlyFollowing
        do {
            try await src.followArtist(id: artistID, on: target)
            return target
        } catch {
            showToast(I18n.t("That didn't work. Try again later."))
            return currentlyFollowing
        }
    }

    /// 跨源/本源加载歌手详情页的结果包
    public struct ArtistLoadOutcome: Sendable {
        public var page: ArtistPage
        public var resolvedSourceID: String
        public var searchMoreOffset: Int
        public var hasMoreSearchTracks: Bool
    }

    /// 按优先级候选音源拉取歌手完整主页与所有歌曲（带按名搜歌手 ID、搜歌曲及播放队列四级兜底）
    public func loadArtistPage(artistID: String, fallbackName: String, sourceID: String? = nil) async -> ArtistLoadOutcome? {
        let trimmedID = artistID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)

        var candidates: [any MusicSource] = []
        if let sid = sourceID?.trimmingCharacters(in: .whitespacesAndNewlines), !sid.isEmpty,
           let preferred = source(forID: sid) {
            candidates.append(preferred)
        }
        if !candidates.contains(where: { $0.info().id == activeSource.info().id }) {
            candidates.append(activeSource)
        }
        for src in enabledSources where !candidates.contains(where: { $0.info().id == src.info().id }) {
            candidates.append(src)
        }

        // 1) 直接查明确传入的 artistID；非原曲所属源试查 ID 时必须校验歌手名称，防止不同平台数字 ID 撞车
        for src in candidates where !trimmedID.isEmpty && src.can("artist") {
            if let page = try? await src.artist(id: trimmedID) {
                let sid = src.info().id
                let isSameSource = sourceID?.trimmingCharacters(in: .whitespacesAndNewlines) == sid
                if isSameSource || trimmedName.isEmpty || Self.artistNameMatches(page.artist.name, target: trimmedName) {
                    return await enrichArtistOutcome(page: page, source: src, fallbackName: trimmedName)
                }
            }
        }

        // 2) ID 为空或插件未认出该 ID：按歌手名搜索最匹配歌手再拉取完整歌手页
        if !trimmedName.isEmpty {
            for src in candidates where src.can("artist") && src.can("search") {
                if let res = try? await src.search(query: trimmedName, kind: .artists, offset: 0),
                   let matched = Self.pickBestMatchingArtist(from: res.artists ?? [], name: trimmedName),
                   !matched.id.isEmpty,
                   let page = try? await src.artist(id: matched.id) {
                    return await enrichArtistOutcome(page: page, source: src, fallbackName: trimmedName)
                }
            }

            // 3) 若目标源不支持 artist() 接口，兜底用搜索歌曲聚合展示该歌手曲目（严格校验歌手名避免无关推荐混入）
            for src in candidates where src.can("search") {
                if let res = try? await src.search(query: trimmedName, kind: .tracks, offset: 0),
                   let raw = res.tracks, !raw.isEmpty {
                    let sid = src.info().id
                    let filtered = Self.filterAndStampArtistTracks(raw, artistName: trimmedName, sourceID: sid, requireMatch: true)
                    guard !filtered.isEmpty else { continue }
                    let artistObj = Artist(
                        id: trimmedID,
                        name: trimmedName,
                        imageUrl: filtered.first?.album.imageUrl
                    )
                    return ArtistLoadOutcome(
                        page: ArtistPage(artist: artistObj, tracks: filtered, albums: nil),
                        resolvedSourceID: sid,
                        searchMoreOffset: raw.count,
                        hasMoreSearchTracks: res.more == true
                    )
                }
            }

            // 4) 终极兜底：从当前待播队列与本地源曲目筛选同歌手歌曲（保障演示曲/内存曲目也能跳转浏览）
            let queueMatched = player.queue.filter { tr in
                Self.trackMatchesArtist(tr, name: trimmedName, artistID: trimmedID)
            }
            if !queueMatched.isEmpty {
                let sid = queueMatched.first?.source ?? activeSourceID
                let artistObj = Artist(
                    id: trimmedID,
                    name: trimmedName,
                    imageUrl: queueMatched.first?.album.imageUrl
                )
                return ArtistLoadOutcome(
                    page: ArtistPage(artist: artistObj, tracks: queueMatched, albums: nil),
                    resolvedSourceID: sid,
                    searchMoreOffset: 0,
                    hasMoreSearchTracks: false
                )
            }
        }
        return nil
    }

    /// 歌手页加载更多该歌手歌曲（通过对应源分页搜索并过滤去重）
    public func loadMoreArtistTracks(
        artistName: String,
        sourceID: String,
        offset: Int
    ) async -> (tracks: [Track], nextOffset: Int, hasMore: Bool) {
        let trimmed = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let src = source(forID: sourceID),
              src.can("search"),
              let res = try? await src.search(query: trimmed, kind: .tracks, offset: offset) else {
            return ([], offset, false)
        }
        let raw = res.tracks ?? []
        let filtered = Self.filterAndStampArtistTracks(raw, artistName: trimmed, sourceID: sourceID)
        return (filtered, offset + raw.count, res.more == true && !raw.isEmpty)
    }

    /// 跨源加载专辑详情页（保证从播放器跳转歌手后再进专辑也能精准命中所属音源）
    public func loadAlbumPage(albumID: String, sourceID: String? = nil) async -> (page: AlbumPage, resolvedSourceID: String)? {
        let src = sourceID.flatMap { source(forID: $0) } ?? activeSource
        guard var page = try? await src.album(id: albumID) else { return nil }
        let sid = src.info().id
        if let tracks = page.tracks {
            page.tracks = tracks.map { Self.stampTrack($0, sourceID: sid) }
        }
        return (page, sid)
    }

    private func enrichArtistOutcome(page: ArtistPage, source src: any MusicSource, fallbackName: String) async -> ArtistLoadOutcome {
        let sid = src.info().id
        let artistName = page.artist.name.isEmpty ? fallbackName : page.artist.name
        var updatedPage = page
        updatedPage.artist.name = artistName
        var tracks = (page.tracks ?? []).map { Self.stampTrack($0, sourceID: sid) }
        var searchOffset = 0
        var hasMoreSearch = false

        if src.can("search") && !artistName.isEmpty {
            if tracks.isEmpty, let res = try? await src.search(query: artistName, kind: .tracks, offset: 0) {
                let raw = res.tracks ?? []
                tracks = Self.filterAndStampArtistTracks(raw, artistName: artistName, sourceID: sid)
                searchOffset = raw.count
                hasMoreSearch = res.more == true && !raw.isEmpty
            } else if !tracks.isEmpty && tracks.count >= 15 {
                // 在线插件通常默认返回前 20~50 首热门曲，允许在列表底部按需补全搜索其它歌曲
                hasMoreSearch = true
                searchOffset = 0
            }
        }
        updatedPage.tracks = tracks
        return ArtistLoadOutcome(
            page: updatedPage,
            resolvedSourceID: sid,
            searchMoreOffset: searchOffset,
            hasMoreSearchTracks: hasMoreSearch
        )
    }

    private static func artistNameMatches(_ candidate: String, target: String) -> Bool {
        let a = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.localizedCaseInsensitiveCompare(b) == .orderedSame
            || a.localizedCaseInsensitiveContains(b)
            || b.localizedCaseInsensitiveContains(a)
    }

    private static func pickBestMatchingArtist(from artists: [Artist], name: String) -> Artist? {
        if let exact = artists.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        return artists.first(where: { artistNameMatches($0.name, target: name) })
    }

    private static func trackMatchesArtist(_ track: Track, name: String, artistID: String = "") -> Bool {
        if !artistID.isEmpty, (track.artists ?? []).contains(where: { $0.id == artistID }) {
            return true
        }
        return (track.artists ?? []).contains {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(name) == .orderedSame
        } || track.artistNames.localizedCaseInsensitiveContains(name)
    }

    private static func filterAndStampArtistTracks(
        _ tracks: [Track],
        artistName: String,
        sourceID: String,
        requireMatch: Bool = false
    ) -> [Track] {
        let matched = tracks.filter { trackMatchesArtist($0, name: artistName) }
        if matched.isEmpty && requireMatch {
            return []
        }
        let chosen = matched.isEmpty ? tracks : matched
        return chosen.map { stampTrack($0, sourceID: sourceID) }
    }

    private static func stampTrack(_ track: Track, sourceID: String) -> Track {
        guard track.source == nil || track.source?.isEmpty == true else { return track }
        var copy = track
        copy.source = sourceID
        return copy
    }

    public func toggleSavePlaylist(sourceID: String, playlistID: String, currentlySaved: Bool) async -> Bool {
        guard let src = source(forID: sourceID), src.can("savePlaylist") else { return currentlySaved }
        let target = !currentlySaved
        do {
            try await src.savePlaylist(id: playlistID, on: target)
            if sourceID == activeSourceID, src.can("playlists"), let pls = try? await src.playlists() {
                self.myPlaylists = pls.filter { $0.mine == true }
                self.savedPlaylists = pls.filter { $0.mine != true }
            }
            return target
        } catch {
            showToast(I18n.t("That didn't work. Try again later."))
            return currentlySaved
        }
    }

    public func toggleSubscribeShow(sourceID: String, showID: String, currentlySubscribed: Bool) async -> Bool {
        guard let src = source(forID: sourceID), src.can("subscribeShow") else { return currentlySubscribed }
        let target = !currentlySubscribed
        do {
            try await src.subscribeShow(id: showID, on: target)
            if sourceID == activeSourceID, src.can("shows"), let sh = try? await src.shows() {
                self.subscribedShows = sh
            }
            return target
        } catch {
            showToast(I18n.t("That didn't work. Try again later."))
            return currentlySubscribed
        }
    }

    public func loadMoreLikedSongs() async {
        let src = activeSource
        let srcID = src.info().id
        guard likedHasMore, !isLoadingMoreLiked, src.can("liked") else { return }
        isLoadingMoreLiked = true
        defer { isLoadingMoreLiked = false }
        let offset = likedTracks.count
        if let page = try? await src.liked(offset: offset), activeSourceID == srcID {
            let incoming = page.tracks ?? []
            self.likedTracks = Self.appendUnique(self.likedTracks, items: incoming)
            self.likedHasMore = page.more == true && !incoming.isEmpty
            await checkLikes(for: incoming)
        }
    }

    public func loadMoreSavedAlbums() async {
        let src = activeSource
        let srcID = src.info().id
        guard savedAlbumsHasMore, !isLoadingMoreSavedAlbums, src.can("savedAlbums") else { return }
        isLoadingMoreSavedAlbums = true
        defer { isLoadingMoreSavedAlbums = false }
        let offset = savedAlbums.count
        if let list = try? await src.savedAlbums(offset: offset), activeSourceID == srcID {
            let incoming = list.albums ?? []
            self.savedAlbums = Self.appendUnique(self.savedAlbums, items: incoming)
            self.savedAlbumsHasMore = list.more == true && !incoming.isEmpty
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
            commentsHasMore = false
            return
        }
        isLoadingComments = true
        defer { isLoadingComments = false }
        if let page = try? await src.comments(trackId: track.id, offset: 0) {
            currentTrackComments = page.comments ?? []
            currentTrackCommentTotal = page.total ?? currentTrackComments.count
            commentsHasMore = page.more == true
        } else {
            commentsHasMore = false
        }
    }

    public func loadMoreComments() async {
        guard commentsHasMore, !isLoadingMoreComments, let tr = player.currentTrack else { return }
        let sid = tr.source ?? activeSourceID
        guard let src = source(forID: sid), src.can("comments") else { return }
        isLoadingMoreComments = true
        defer { isLoadingMoreComments = false }
        let offset = currentTrackComments.count
        if let page = try? await src.comments(trackId: tr.id, offset: offset),
           player.currentTrack?.compositeKey == tr.compositeKey {
            let incoming = page.comments ?? []
            currentTrackComments = Self.appendUnique(currentTrackComments, items: incoming)
            if let total = page.total { currentTrackCommentTotal = total }
            commentsHasMore = page.more == true && !incoming.isEmpty
        }
    }

    public func toggleLikeComment(_ comment: Comment) async {
        guard !commentLikePendingIDs.contains(comment.id), let tr = player.currentTrack else { return }
        let sid = tr.source ?? activeSourceID
        guard let src = source(forID: sid), src.can("likeComment") else { return }
        guard let idx = currentTrackComments.firstIndex(where: { $0.id == comment.id }) else { return }

        commentLikePendingIDs.insert(comment.id)
        defer { commentLikePendingIDs.remove(comment.id) }

        let oldLiked = currentTrackComments[idx].liked == true
        let newLiked = !oldLiked
        let oldCount = currentTrackComments[idx].likes ?? 0
        let newCount = max(0, oldCount + (newLiked ? 1 : -1))
        currentTrackComments[idx].liked = newLiked
        currentTrackComments[idx].likes = newCount

        do {
            try await src.likeComment(trackId: tr.id, commentId: comment.id, on: newLiked)
        } catch {
            if let revertIdx = currentTrackComments.firstIndex(where: { $0.id == comment.id }) {
                currentTrackComments[revertIdx].liked = oldLiked
                currentTrackComments[revertIdx].likes = oldCount
            }
            showToast(I18n.t("That didn't work. Try again later."))
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

    private static func appendUnique<T: Identifiable>(_ existing: [T], items: [T]) -> [T] where T.ID: Hashable {
        var seen = Set(existing.map(\.id))
        var combined = existing
        for item in items where !seen.contains(item.id) {
            seen.insert(item.id)
            combined.append(item)
        }
        return combined
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

    public func loadMoreSearch() async {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = activeSource
        let kind = searchKind
        guard !q.isEmpty, searchResult.more == true, !isLoadingMoreSearch, source.can("search") else { return }

        let offset: Int
        switch kind {
        case .tracks: offset = searchResult.tracks?.count ?? 0
        case .albums: offset = searchResult.albums?.count ?? 0
        case .artists: offset = searchResult.artists?.count ?? 0
        case .playlists: offset = searchResult.playlists?.count ?? 0
        case .shows: offset = searchResult.shows?.count ?? 0
        }

        let generation = searchGeneration
        isLoadingMoreSearch = true
        defer { isLoadingMoreSearch = false }

        do {
            let next = try await source.search(query: q, kind: kind, offset: offset)
            guard searchGeneration == generation, activeSourceID == source.info().id else { return }

            var merged = searchResult
            let incomingTracks = next.tracks ?? []
            if !incomingTracks.isEmpty {
                merged.tracks = Self.appendUnique(merged.tracks ?? [], items: incomingTracks)
                await checkLikes(for: incomingTracks)
            }
            if let albums = next.albums, !albums.isEmpty {
                merged.albums = Self.appendUnique(merged.albums ?? [], items: albums)
            }
            if let artists = next.artists, !artists.isEmpty {
                merged.artists = Self.appendUnique(merged.artists ?? [], items: artists)
            }
            if let pls = next.playlists, !pls.isEmpty {
                merged.playlists = Self.appendUnique(merged.playlists ?? [], items: pls)
            }
            if let shows = next.shows, !shows.isEmpty {
                merged.shows = Self.appendUnique(merged.shows ?? [], items: shows)
            }
            let gainedAny = !(next.tracks?.isEmpty ?? true)
                || !(next.albums?.isEmpty ?? true)
                || !(next.artists?.isEmpty ?? true)
                || !(next.playlists?.isEmpty ?? true)
                || !(next.shows?.isEmpty ?? true)
            merged.more = (next.more == true) && gainedAny
            self.searchResult = merged
        } catch {
            showToast(I18n.t("The search failed"))
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

    // MARK: - 插件安装、更新与 Deep Link（mygo-music://install-plugin?repo=owner/repo）

    private func cleanupTemporaryPendingSource(_ sourcePath: URL) {
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory.standardizedFileURL.path
        let stdPath = sourcePath.standardizedFileURL.path
        guard stdPath.hasPrefix(tmpRoot) else { return }
        var cursor: URL? = sourcePath
        while let current = cursor {
            let stdCurrent = current.standardizedFileURL.path
            guard stdCurrent.count > tmpRoot.count else { break }
            let name = current.lastPathComponent
            // 仅清理 PluginInstaller 自行解包的临时目录，绝不误删用户传入的本地文件夹或其父目录
            if name.hasPrefix("mygo-plugin-") || name.hasPrefix("mygo-local-zip-") {
                try? fm.removeItem(at: current)
                return
            }
            cursor = current.deletingLastPathComponent()
        }
    }

    private func finalizeInstalledPending(_ pending: PendingPlugin, switchActive: Bool) async throws -> JSPluginSource {
        defer { cleanupTemporaryPendingSource(pending.sourcePath) }
        let installed = try PluginInstaller.install(pending, into: pluginsDir, dataRootDir: pluginDataDir)
        let pid = installed.manifest.id
        settings.pluginUpdates.removeValue(forKey: pid)
        cachedPluginReleases.removeValue(forKey: pid)
        pluginCheckStates[pid] = .upToDate
        reloadPlugins()
        if switchActive {
            switchSource(to: pid)
        } else if activeSourceID == pid {
            await refreshActiveSource()
        }
        return installed
    }

    private func applyCheckResult(
        pluginID: String,
        info: PluginUpdateInfo,
        updates: inout [String: String]
    ) {
        if info.hasUpdate {
            updates[pluginID] = info.latestVersion
            if let release = info.release {
                cachedPluginReleases[pluginID] = release
            }
            pluginCheckStates[pluginID] = .updateAvailable(info.latestVersion)
        } else {
            updates.removeValue(forKey: pluginID)
            cachedPluginReleases.removeValue(forKey: pluginID)
            pluginCheckStates[pluginID] = .upToDate
        }
    }

    public func installPluginFromGitHub(repoInput: String, transport: PluginHTTPTransport? = nil) async {
        isInstallingPlugin = true
        installErrorMessage = nil
        defer { isInstallingPlugin = false }
        do {
            let pending = try await PluginInstaller.fetchFromGitHub(
                repoInput: repoInput,
                token: settings.githubToken,
                transport: transport
            )
            let installed = try await finalizeInstalledPending(pending, switchActive: true)
            showToast(I18n.tf("Installed %@", installed.info().name))
        } catch {
            installErrorMessage = error.localizedDescription
        }
    }

    public func importLocalPlugin(from url: URL) async {
        isInstallingPlugin = true
        installErrorMessage = nil
        defer { isInstallingPlugin = false }
        do {
            let pending = try PluginInstaller.openFromLocal(url)
            let installed = try await finalizeInstalledPending(pending, switchActive: true)
            showToast(I18n.tf("Installed %@", installed.info().name))
        } catch {
            installErrorMessage = error.localizedDescription
            showToast(error.localizedDescription)
        }
    }

    public func checkForPluginUpdates(manual: Bool = true, transport: PluginHTTPTransport? = nil) async {
        guard !isCheckingUpdates else { return }
        if !manual {
            let now = Date().timeIntervalSince1970
            if now - settings.pluginsCheckedAt < 86400 { return }
        }

        let checkable = pluginSources.compactMap { plugin -> (id: String, dir: URL)? in
            guard PluginInstaller.effectiveOrigin(for: plugin.pluginDir, manifest: plugin.manifest) != nil else {
                return nil
            }
            return (plugin.manifest.id, plugin.pluginDir)
        }
        guard !checkable.isEmpty else {
            if manual {
                let msg = pluginSources.isEmpty
                    ? I18n.t("No updates available")
                    : I18n.t("No plugins have a GitHub update source yet")
                showToast(msg)
            }
            return
        }

        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        for item in checkable {
            pluginCheckStates[item.id] = .checking
        }

        let token = settings.githubToken
        let results: [(String, Result<PluginUpdateInfo, Error>)] = await withTaskGroup(
            of: (String, Result<PluginUpdateInfo, Error>).self
        ) { group in
            for item in checkable {
                group.addTask {
                    do {
                        let info = try await PluginInstaller.checkUpdate(for: item.dir, token: token, transport: transport)
                        return (item.id, .success(info))
                    } catch {
                        return (item.id, .failure(error))
                    }
                }
            }
            var collected: [(String, Result<PluginUpdateInfo, Error>)] = []
            for await res in group {
                collected.append(res)
            }
            return collected
        }

        var newUpdates = settings.pluginUpdates
        var foundCount = 0
        var firstFoundVersion: String?
        var succeededCount = 0
        var failedCount = 0
        var lastError: String?

        for (pid, result) in results {
            switch result {
            case .success(let info):
                succeededCount += 1
                applyCheckResult(pluginID: pid, info: info, updates: &newUpdates)
                if info.hasUpdate {
                    foundCount += 1
                    if firstFoundVersion == nil {
                        firstFoundVersion = PluginInstaller.displayVersion(info.latestVersion)
                    }
                }
            case .failure(let err):
                failedCount += 1
                lastError = err.localizedDescription
                pluginCheckStates[pid] = .failed(err.localizedDescription)
            }
        }

        settings.pluginUpdates = newUpdates
        // 自动后台检查若全部因离线/限流失败，不锁定 24 小时冷却，以便恢复联网后能自动重试
        if manual || succeededCount > 0 {
            settings.pluginsCheckedAt = Date().timeIntervalSince1970
        }

        if manual {
            if foundCount == 1, let ver = firstFoundVersion {
                showToast(I18n.tf("Update to %s available", ver))
            } else if foundCount > 1 {
                showToast(I18n.tf("Checked updates · %d available", foundCount))
            } else if failedCount > 0 && succeededCount == 0 {
                showToast(lastError ?? I18n.t("Couldn't check for updates"))
            } else {
                showToast(I18n.t("No updates available"))
            }
        }
    }

    public func checkPluginUpdate(id: String, transport: PluginHTTPTransport? = nil) async {
        guard let target = pluginSources.first(where: { $0.manifest.id == id }) else { return }
        guard PluginInstaller.effectiveOrigin(for: target.pluginDir, manifest: target.manifest) != nil else {
            pluginCheckStates[id] = .failed(I18n.t("Not installed via GitHub"))
            showToast(I18n.t("Not installed via GitHub"))
            return
        }

        pluginCheckStates[id] = .checking
        do {
            let info = try await PluginInstaller.checkUpdate(
                for: target.pluginDir,
                token: settings.githubToken,
                transport: transport
            )
            var newUpdates = settings.pluginUpdates
            applyCheckResult(pluginID: id, info: info, updates: &newUpdates)
            settings.pluginUpdates = newUpdates
            if info.hasUpdate {
                let ver = PluginInstaller.displayVersion(info.latestVersion)
                showToast(I18n.tf("Update to %s available", ver))
            } else {
                showToast(I18n.t("Up to date"))
            }
        } catch {
            pluginCheckStates[id] = .failed(error.localizedDescription)
            showToast(error.localizedDescription)
        }
    }

    @discardableResult
    public func updatePlugin(
        id: String,
        forceReinstall: Bool = false,
        skipPermissionPrompt: Bool = false,
        transport: PluginHTTPTransport? = nil
    ) async -> Bool {
        guard !updatingPluginIDs.contains(id) else { return false }
        guard let target = pluginSources.first(where: { $0.manifest.id == id }) else { return false }
        guard let origin = PluginInstaller.effectiveOrigin(for: target.pluginDir, manifest: target.manifest) else {
            showToast(I18n.t("Not installed via GitHub"))
            return false
        }

        updatingPluginIDs.insert(id)
        isInstallingPlugin = true
        installErrorMessage = nil
        defer {
            updatingPluginIDs.remove(id)
            isInstallingPlugin = !updatingPluginIDs.isEmpty
        }

        do {
            var pending: PendingPlugin
            if !forceReinstall,
               let cached = cachedPluginReleases[id],
               cached.repo == origin.repo {
                pending = try await PluginInstaller.fetchFromRelease(
                    cached,
                    token: settings.githubToken,
                    transport: transport
                )
            } else {
                pending = try await PluginInstaller.fetchFromGitHub(
                    repoInput: origin.repo,
                    token: settings.githubToken,
                    transport: transport
                )
            }
            if pending.repo == nil {
                pending.repo = origin.repo
            }

            if !skipPermissionPrompt,
               let added = PluginInstaller.expandedPermissions(
                   from: target.manifest.permissions,
                   to: pending.manifest.permissions
               ) {
                let displayVer = PluginInstaller.displayVersion(pending.version ?? (pending.manifest.version ?? ""))
                enqueuePluginUpdateApproval(
                    PendingPluginUpdateApproval(
                        pluginName: pending.manifest.name ?? target.info().name,
                        targetVersion: displayVer,
                        addedPermissions: added,
                        pending: pending
                    )
                )
                return false
            }

            let installed = try await finalizeInstalledPending(pending, switchActive: false)
            let ver = PluginInstaller.displayVersion(pending.version ?? (installed.manifest.version ?? ""))
            showToast(I18n.tf("Updated %@ %@", installed.info().name, ver))
            return true
        } catch {
            installErrorMessage = error.localizedDescription
            pluginCheckStates[id] = .failed(error.localizedDescription)
            showToast(error.localizedDescription)
            return false
        }
    }

    public func updateAllPlugins(transport: PluginHTTPTransport? = nil) async {
        guard !isUpdatingAllPlugins else { return }
        let targetIDs = pluginSources
            .map(\.manifest.id)
            .filter { settings.pluginUpdates[$0] != nil }
        guard !targetIDs.isEmpty else { return }

        isUpdatingAllPlugins = true
        defer { isUpdatingAllPlugins = false }
        for pid in targetIDs {
            _ = await updatePlugin(id: pid, transport: transport)
        }
    }

    private func enqueuePluginUpdateApproval(_ approval: PendingPluginUpdateApproval) {
        if let active = pendingPluginUpdateApproval {
            if active.id == approval.id {
                deferredPluginUpdateCleanupTasks.removeValue(forKey: active.requestID)?.cancel()
                cleanupTemporaryPendingSource(active.pending.sourcePath)
                pendingPluginUpdateApproval = approval
                return
            }
            if let idx = pendingPluginUpdateQueue.firstIndex(where: { $0.id == approval.id }) {
                cleanupTemporaryPendingSource(pendingPluginUpdateQueue[idx].pending.sourcePath)
                pendingPluginUpdateQueue[idx] = approval
            } else {
                pendingPluginUpdateQueue.append(approval)
            }
            return
        }
        nextQueuedApprovalTask?.cancel()
        nextQueuedApprovalTask = nil
        pendingPluginUpdateApproval = approval
    }

    private func scheduleNextQueuedPluginUpdateIfNeeded() {
        guard pendingPluginUpdateApproval == nil, !pendingPluginUpdateQueue.isEmpty else { return }
        nextQueuedApprovalTask?.cancel()
        nextQueuedApprovalTask = Task { @MainActor [weak self] in
            // 等待上一个 UIAlertController 完成退场动画，避免 SwiftUI 吞掉连续弹窗
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.nextQueuedApprovalTask = nil
            guard self.pendingPluginUpdateApproval == nil, !self.pendingPluginUpdateQueue.isEmpty else { return }
            self.pendingPluginUpdateApproval = self.pendingPluginUpdateQueue.removeFirst()
        }
    }

    /// 供 UI 按钮同步确认权限变更并启动安装，规避 `.alert` 关闭时 `isPresented` 置 `false` 与 `Task` 调度之间的竞态
    @discardableResult
    public func approvePendingPluginUpdate(_ approval: PendingPluginUpdateApproval) -> Task<Void, Never> {
        let reqID = approval.requestID
        guard !confirmedPluginUpdateRequestIDs.contains(reqID) else {
            return Task {}
        }
        confirmedPluginUpdateRequestIDs.insert(reqID)
        deferredPluginUpdateCleanupTasks.removeValue(forKey: reqID)?.cancel()
        if pendingPluginUpdateApproval?.requestID == reqID {
            pendingPluginUpdateApproval = nil
        }
        pendingPluginUpdateQueue.removeAll { $0.requestID == reqID }

        let pid = approval.pending.manifest.id
        updatingPluginIDs.insert(pid)
        isInstallingPlugin = true
        installErrorMessage = nil

        return Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performApprovedPluginUpdate(approval)
        }
    }

    public func confirmPendingPluginUpdate() async {
        guard let approval = pendingPluginUpdateApproval else { return }
        let task = approvePendingPluginUpdate(approval)
        await task.value
    }

    private func performApprovedPluginUpdate(_ approval: PendingPluginUpdateApproval) async {
        let pid = approval.pending.manifest.id
        let reqID = approval.requestID
        updatingPluginIDs.insert(pid)
        isInstallingPlugin = true
        defer {
            confirmedPluginUpdateRequestIDs.remove(reqID)
            updatingPluginIDs.remove(pid)
            isInstallingPlugin = !updatingPluginIDs.isEmpty
            scheduleNextQueuedPluginUpdateIfNeeded()
        }
        do {
            let installed = try await finalizeInstalledPending(approval.pending, switchActive: false)
            let ver = PluginInstaller.displayVersion(approval.pending.version ?? (installed.manifest.version ?? ""))
            showToast(I18n.tf("Updated %@ %@", installed.info().name, ver))
        } catch {
            installErrorMessage = error.localizedDescription
            pluginCheckStates[pid] = .failed(error.localizedDescription)
            showToast(error.localizedDescription)
        }
    }

    /// 仅由 SwiftUI `.alert` 的 `isPresented` 置 `false` 回调使用：延迟回收未确认临时包，避免抢在确认按钮前删除文件
    public func handlePendingPluginUpdateAlertDismissed() {
        guard let approval = pendingPluginUpdateApproval else { return }
        pendingPluginUpdateApproval = nil
        let reqID = approval.requestID
        guard !confirmedPluginUpdateRequestIDs.contains(reqID) else { return }
        deferredPluginUpdateCleanupTasks[reqID]?.cancel()
        deferredPluginUpdateCleanupTasks[reqID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.deferredPluginUpdateCleanupTasks.removeValue(forKey: reqID)
            guard !self.confirmedPluginUpdateRequestIDs.contains(reqID) else { return }
            self.cleanupTemporaryPendingSource(approval.pending.sourcePath)
            self.scheduleNextQueuedPluginUpdateIfNeeded()
        }
    }

    public func cancelPendingPluginUpdate(_ approval: PendingPluginUpdateApproval? = nil) {
        guard let target = approval ?? pendingPluginUpdateApproval else { return }
        let reqID = target.requestID
        guard !confirmedPluginUpdateRequestIDs.contains(reqID) else { return }
        deferredPluginUpdateCleanupTasks.removeValue(forKey: reqID)?.cancel()
        if pendingPluginUpdateApproval?.requestID == reqID {
            pendingPluginUpdateApproval = nil
        }
        pendingPluginUpdateQueue.removeAll { $0.requestID == reqID }
        cleanupTemporaryPendingSource(target.pending.sourcePath)
        scheduleNextQueuedPluginUpdateIfNeeded()
    }

    @discardableResult
    public func linkPluginRepository(
        id: String,
        repoInput: String,
        checkNow: Bool = true,
        transport: PluginHTTPTransport? = nil
    ) async -> Bool {
        guard let target = pluginSources.first(where: { $0.manifest.id == id }) else { return false }
        do {
            let normalizedRepo = try PluginInstaller.parseRepo(repoInput)
            let existing = PluginInstaller.readOrigin(in: target.pluginDir)
            let initialVer: String
            if existing?.repo == normalizedRepo, let ver = existing?.version, !ver.isEmpty {
                initialVer = ver
            } else {
                initialVer = PluginInstaller.normalizeVersionTag(target.manifest.version ?? "")
            }
            try PluginInstaller.saveOrigin(PluginOrigin(repo: normalizedRepo, version: initialVer), in: target.pluginDir)
            settings.pluginUpdates.removeValue(forKey: id)
            cachedPluginReleases.removeValue(forKey: id)
            pluginCheckStates.removeValue(forKey: id)
            reloadPlugins()
            if checkNow {
                await checkPluginUpdate(id: id, transport: transport)
            } else {
                showToast(I18n.t("Linked GitHub update source"))
            }
            return true
        } catch {
            showToast(error.localizedDescription)
            return false
        }
    }

    public func loadCommunityPlugins(force: Bool = false, transport: PluginHTTPTransport? = nil) async {
        guard !isLoadingCommunityPlugins else { return }
        if !force && !communityPlugins.isEmpty { return }
        isLoadingCommunityPlugins = true
        communityPluginsError = nil
        defer { isLoadingCommunityPlugins = false }
        do {
            communityPlugins = try await PluginInstaller.fetchCommunityPlugins(
                token: settings.githubToken,
                transport: transport
            )
        } catch {
            communityPluginsError = error.localizedDescription
        }
    }

    public func grantProcessPermission(for pluginID: String) {
        guard let target = pluginSources.first(where: { $0.manifest.id == pluginID }) else { return }
        do {
            try target.setProcessGranted(true)
            objectWillChange.send()
            showToast(I18n.t("Process permission granted"))
        } catch {
            showToast(error.localizedDescription)
        }
    }

    public func removePlugin(id: String) {
        guard let target = pluginSources.first(where: { $0.manifest.id == id }) else { return }
        try? FileManager.default.removeItem(at: target.pluginDir)
        settings.pluginUpdates.removeValue(forKey: id)
        pluginCheckStates.removeValue(forKey: id)
        cachedPluginReleases.removeValue(forKey: id)
        updatingPluginIDs.remove(id)
        if pendingPluginUpdateApproval?.id == id, let active = pendingPluginUpdateApproval {
            cancelPendingPluginUpdate(active)
        }
        let queuedForRemoved = pendingPluginUpdateQueue.filter { $0.id == id }
        if !queuedForRemoved.isEmpty {
            pendingPluginUpdateQueue.removeAll { $0.id == id }
            for item in queuedForRemoved {
                cleanupTemporaryPendingSource(item.pending.sourcePath)
            }
        }
        reloadPlugins()
        if activeSourceID == id {
            switchSource(to: enabledSources.first?.info().id ?? LocalMusicSource.sourceID)
        }
    }

    // MARK: - 播客实时语音识别字幕（对应 internal/app/ui_captions.go）

    public func requestSpeechPermissionAndRefreshCaptions() async {
        #if canImport(Speech)
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            await refreshCaptionsForCurrentTrack()
            return
        }
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            let granted: Bool = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authStatus in
                    continuation.resume(returning: authStatus == .authorized)
                }
            }
            if !granted {
                liveCaptionsStatus = I18n.t("Speech recognition not authorized")
                return
            }
        } else if status != .authorized {
            liveCaptionsStatus = I18n.t("Speech recognition not authorized")
            return
        }
        await refreshCaptionsForCurrentTrack()
        #endif
    }

    public func refreshCaptionsForCurrentTrack() async {
        captionTask?.cancel()
        guard settings.captions, let track = player.currentTrack, track.isEpisode else {
            timedCaptions = []
            liveCaptionsStatus = ""
            return
        }

        #if canImport(Speech)
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            liveCaptionsStatus = I18n.t("Speech recognition not authorized")
            return
        }
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            liveCaptionsStatus = status == .notDetermined ? "" : I18n.t("Speech recognition not authorized")
            return
        }

        // 定位可识别的本地或已缓存音轨文件
        let localAudioURL: URL?
        if let streamURLStr = player.currentStream?.url {
            if streamURLStr.hasPrefix("file://"), let u = URL(string: streamURLStr) {
                localAudioURL = u
            } else if streamURLStr.hasPrefix("/") {
                localAudioURL = URL(fileURLWithPath: streamURLStr)
            } else {
                let sourceID = track.source ?? LocalMusicSource.sourceID
                let key = AudioDiskCache.cacheKey(
                    sourceID: sourceID,
                    trackID: track.id,
                    quality: settings.quality.rawValue
                )
                localAudioURL = player.diskCache.cachedFileURL(forKey: key)?.fileURL
            }
        } else {
            localAudioURL = nil
        }

        guard let audioFileURL = localAudioURL else {
            liveCaptionsStatus = I18n.t("Recognizing captions…")
            return
        }

        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            liveCaptionsStatus = I18n.t("Speech recognition not authorized")
            return
        }

        liveCaptionsStatus = I18n.t("Recognizing captions…")
        let trackKey = track.compositeKey
        captionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let request = SFSpeechURLRecognitionRequest(url: audioFileURL)
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            let streamLines = AsyncStream<[LyricLine]> { continuation in
                let recTask = recognizer.recognitionTask(with: request) { result, error in
                    if let result {
                        let built = Self.buildCaptionLines(from: result.bestTranscription.segments)
                        continuation.yield(built)
                        if result.isFinal {
                            continuation.finish()
                        }
                    } else if error != nil {
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in
                    recTask.cancel()
                }
            }
            for await lines in streamLines {
                guard !Task.isCancelled, self.player.currentTrack?.compositeKey == trackKey else { break }
                if !lines.isEmpty {
                    self.timedCaptions = lines
                }
            }
            if !Task.isCancelled, self.player.currentTrack?.compositeKey == trackKey {
                self.liveCaptionsStatus = ""
            }
        }
        #endif
    }

    #if canImport(Speech)
    private static func buildCaptionLines(from segments: [SFTranscriptionSegment]) -> [LyricLine] {
        guard !segments.isEmpty else { return [] }
        var lines: [LyricLine] = []
        var bufferText = ""
        var bufferStart: TimeInterval = segments[0].timestamp
        var bufferEnd: TimeInterval = segments[0].timestamp + segments[0].duration

        for seg in segments {
            let word = seg.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            if bufferText.isEmpty {
                bufferStart = seg.timestamp
            }
            if !bufferText.isEmpty {
                bufferText += " "
            }
            bufferText += word
            bufferEnd = seg.timestamp + max(seg.duration, 0.2)

            if bufferText.count >= 42 || (bufferEnd - bufferStart) >= 4.0 {
                lines.append(LyricLine(at: bufferStart, end: bufferEnd, text: bufferText))
                bufferText = ""
            }
        }
        if !bufferText.isEmpty {
            lines.append(LyricLine(at: bufferStart, end: bufferEnd, text: bufferText))
        }
        return lines
    }
    #endif

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
            await waitUntilStartupReady()
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

// LocalSource.swift
// 对应原项目 internal/local/local.go, catalog.go, scan.go 的本地文件音乐源

import AVFoundation
import Foundation

/// 本地持久化存储结构（对应 local.library）
private struct LocalLibraryPersistence: Codable {
    var folders: [String] = []
    var likes: [String] = []
    var recent: [String] = []
    var playlists: [StoredPlaylist] = []
}

private struct StoredPlaylist: Codable {
    var id: String
    var name: String
    var tracks: [String] = []
}

/// 本地文件音乐源（1:1 移植自 internal/local）
public final class LocalMusicSource: MusicSource, @unchecked Sendable {
    public static let sourceID = "local"
    private static let pageSize = 200
    private static let keepRecent = 200
    private static let showRecent = 100
    private static let homeRows = 12

    private static let supportedCapabilities: Set<String> = [
        "search", "playlists", "playlist", "album", "artist",
        "liked", "recent", "isLiked", "like",
        "createPlaylist", "renamePlaylist", "deletePlaylist",
        "addToPlaylist", "removeFromPlaylist", "movePlaylistTrack",
        "lyrics", "stream", "home", "browse"
    ]

    private static let supportedExtensions: Set<String> = [
        "mp3", "flac", "ogg", "wav", "m4a", "aac"
    ]

    public let dataDir: URL
    public let defaultMusicFolder: URL

    private let lock = NSLock()
    private var lib: LocalLibraryPersistence
    private var tracksByID: [String: Track] = [:]
    private var orderedTracks: [Track] = []
    private var albumsByID: [String: AlbumPage] = [:]
    private var orderedAlbums: [Album] = []
    private var artistsByID: [String: ArtistPage] = [:]
    private var orderedArtists: [Artist] = []
    private var isScanningFlag = false

    public var onChange: (@Sendable () -> Void)?

    public init(dataDir: URL) {
        self.dataDir = dataDir
        self.defaultMusicFolder = dataDir.appendingPathComponent("MusicFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: defaultMusicFolder, withIntermediateDirectories: true)

        let libFile = dataDir.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: libFile),
           let decoded = try? JSONDecoder().decode(LocalLibraryPersistence.self, from: data) {
            self.lib = decoded
        } else {
            self.lib = LocalLibraryPersistence(folders: [defaultMusicFolder.path])
        }

        if !self.lib.folders.contains(defaultMusicFolder.path) {
            self.lib.folders.insert(defaultMusicFolder.path, at: 0)
        }
        rebuildCatalogSynchronously()
    }

    // MARK: - 线程安全锁辅助方法

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - 文件夹与扫描管理

    public func folders() -> [String] {
        withLock { lib.folders }
    }

    public func isScanning() -> Bool {
        withLock { isScanningFlag }
    }

    public func trackCount() -> Int {
        withLock { orderedTracks.count }
    }

    public func addFolders(_ paths: [String]) {
        lock.lock()
        for raw in paths where !raw.isEmpty {
            let clean = (raw as NSString).standardizingPath
            if !lib.folders.contains(clean) {
                lib.folders.append(clean)
            }
        }
        saveLibraryLocked()
        lock.unlock()
        rescan()
    }

    public func removeFolder(_ path: String) {
        let clean = (path as NSString).standardizingPath
        lock.lock()
        lib.folders.removeAll { $0 == clean }
        saveLibraryLocked()
        lock.unlock()
        rescan()
    }

    /// 导入外部音频文件或目录到沙盒本地音乐目录
    @discardableResult
    public func importAudioFiles(_ urls: [URL]) -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: defaultMusicFolder, withIntermediateDirectories: true)
        var importedCount = 0
        for url in urls {
            let secured = url.startAccessingSecurityScopedResource()
            defer {
                if secured { url.stopAccessingSecurityScopedResource() }
            }
            var candidates: [URL] = []
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let fileURL as URL in enumerator where Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                        candidates.append(fileURL)
                    }
                }
            } else if Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
                candidates.append(url)
            }

            for source in candidates {
                let destination = uniqueImportURL(for: source.lastPathComponent)
                let staging = defaultMusicFolder.appendingPathComponent(".import-\(UUID().uuidString)")
                do {
                    try fm.copyItem(at: source, to: staging)
                    try fm.moveItem(at: staging, to: destination)
                    importedCount += 1
                } catch {
                    try? fm.removeItem(at: staging)
                    continue
                }

                let lrcSource = source.deletingPathExtension().appendingPathExtension("lrc")
                if fm.fileExists(atPath: lrcSource.path) {
                    let lrcDestination = destination.deletingPathExtension().appendingPathExtension("lrc")
                    let lrcStaging = defaultMusicFolder.appendingPathComponent(".import-\(UUID().uuidString)")
                    do {
                        try fm.copyItem(at: lrcSource, to: lrcStaging)
                        try fm.moveItem(at: lrcStaging, to: lrcDestination)
                    } catch {
                        try? fm.removeItem(at: lrcStaging)
                    }
                }
            }
        }
        if importedCount > 0 { rescan() }
        return importedCount
    }

    private func uniqueImportURL(for filename: String) -> URL {
        let fileManager = FileManager.default
        let initial = defaultMusicFolder.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: initial.path) else { return initial }
        let base = initial.deletingPathExtension().lastPathComponent
        let ext = initial.pathExtension
        var suffix = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
            let candidate = defaultMusicFolder.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }

    public func rescan() {
        rebuildCatalogSynchronously()
        onChange?()
    }

    /// 同步扫描所有已添加文件夹并构建专辑、歌手与歌曲索引
    public func rebuildCatalogSynchronously() {
        lock.lock()
        isScanningFlag = true
        let scanFolders = lib.folders
        lock.unlock()

        var discoveredTracks: [Track] = []
        var seenPaths = Set<String>()
        let fm = FileManager.default

        for folderPath in scanFolders {
            let folderURL = URL(fileURLWithPath: folderPath)
            guard let enumerator = fm.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard Self.supportedExtensions.contains(ext) else { continue }
                let cleanPath = fileURL.standardizedFileURL.path
                guard !seenPaths.contains(cleanPath) else { continue }
                seenPaths.insert(cleanPath)

                let track = Self.readTrackMetadata(at: fileURL, coversDir: dataDir.appendingPathComponent("covers", isDirectory: true))
                discoveredTracks.append(track)
            }
        }

        // 按歌名排序
        discoveredTracks.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var byID: [String: Track] = [:]
        var albumGroups: [String: (album: Album, tracks: [Track])] = [:]
        var artistGroups: [String: (artist: Artist, tracks: [Track], albumIDs: Set<String>)] = [:]

        for track in discoveredTracks {
            byID[track.id] = track

            let albumID = track.album.id
            if var existingAlbum = albumGroups[albumID] {
                existingAlbum.tracks.append(track)
                albumGroups[albumID] = existingAlbum
            } else {
                albumGroups[albumID] = (track.album, [track])
            }

            for art in (track.artists ?? []) {
                if var existingArtist = artistGroups[art.id] {
                    existingArtist.tracks.append(track)
                    existingArtist.albumIDs.insert(albumID)
                    artistGroups[art.id] = existingArtist
                } else {
                    artistGroups[art.id] = (art, [track], [albumID])
                }
            }
        }

        let sortedAlbums = albumGroups.values
            .map(\.album)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var albumPages: [String: AlbumPage] = [:]
        for (id, group) in albumGroups {
            albumPages[id] = AlbumPage(album: group.album, tracks: group.tracks)
        }

        let sortedArtists = artistGroups.values
            .map(\.artist)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var artistPages: [String: ArtistPage] = [:]
        for (id, group) in artistGroups {
            let artistAlbums = group.albumIDs.compactMap { albumGroups[$0]?.album }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            artistPages[id] = ArtistPage(artist: group.artist, tracks: group.tracks, albums: artistAlbums)
        }

        lock.lock()
        self.tracksByID = byID
        self.orderedTracks = discoveredTracks
        self.albumsByID = albumPages
        self.orderedAlbums = sortedAlbums
        self.artistsByID = artistPages
        self.orderedArtists = sortedArtists
        self.isScanningFlag = false
        lock.unlock()
    }

    private static func readTrackMetadata(at fileURL: URL, coversDir: URL) -> Track {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        var title = baseName
        var artistName = "Unknown Artist"
        var albumName = "Unknown Album"
        var durationMs: Int64 = 0
        var imageURL: String? = nil

        // 支持 "Artist - Title" 文件名自动拆分作为回退
        if let dashRange = baseName.range(of: " - ") {
            let left = String(baseName[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(baseName[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !left.isEmpty && !right.isEmpty {
                artistName = left
                title = right
            }
        }

        let asset = AVURLAsset(url: fileURL)
        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite && seconds > 0 {
            durationMs = Int64((seconds * 1000.0).rounded())
        }

        for item in asset.commonMetadata {
            guard let commonKey = item.commonKey else { continue }
            switch commonKey {
            case .commonKeyTitle:
                if let val = item.stringValue, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    title = val.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case .commonKeyArtist:
                if let val = item.stringValue, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    artistName = val.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case .commonKeyAlbumName:
                if let val = item.stringValue, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    albumName = val.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case .commonKeyArtwork:
                if let data = item.dataValue, !data.isEmpty {
                    try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
                    let hash = PluginCrypto.md5Hex(fileURL.standardizedFileURL.path)
                    let coverFile = coversDir.appendingPathComponent("\(hash).jpg")
                    if !FileManager.default.fileExists(atPath: coverFile.path) {
                        try? data.write(to: coverFile)
                    }
                    imageURL = coverFile.absoluteString
                }
            default:
                break
            }
        }

        let artistID = "artist:" + artistName.lowercased()
        let albumID = "album:" + albumName.lowercased() + ":" + artistName.lowercased()
        let artist = Artist(id: artistID, name: artistName)
        let album = Album(id: albumID, name: albumName, imageUrl: imageURL, artists: [artist])

        return Track(
            id: fileURL.standardizedFileURL.path,
            source: Self.sourceID,
            name: title,
            artists: [artist],
            album: album,
            duration: durationMs
        )
    }

    private func saveLibraryLocked() {
        if let data = try? JSONEncoder().encode(lib) {
            try? data.write(to: dataDir.appendingPathComponent("library.json"), options: .atomic)
        }
    }

    private func resolveTracksLocked(_ ids: [String]) -> [Track] {
        ids.compactMap { tracksByID[$0] }
    }

    private func makePublicPlaylistLocked(_ stored: StoredPlaylist) -> Playlist {
        var count = 0
        var firstCover: String? = nil
        for tid in stored.tracks {
            if let tr = tracksByID[tid] {
                count += 1
                if firstCover == nil, let cov = tr.album.imageUrl, !cov.isEmpty {
                    firstCover = cov
                }
            }
        }
        return Playlist(
            id: stored.id,
            name: stored.name,
            imageUrl: firstCover,
            trackCount: count,
            mine: true
        )
    }

    private static func pageSlice<T>(_ items: [T], offset: Int) -> ([T], Bool) {
        let clamped = min(max(offset, 0), items.count)
        let end = min(clamped + pageSize, items.count)
        return (Array(items[clamped..<end]), end < items.count)
    }

    private static func matches(_ text: String, queryTokens: [String]) -> Bool {
        let lower = text.lowercased()
        for token in queryTokens {
            if !lower.contains(token) {
                return false
            }
        }
        return true
    }

    // MARK: - MusicSource 协议实现

    public func info() -> SourceInfo {
        SourceInfo(
            id: Self.sourceID,
            name: I18n.t("Local Files"),
            playback: .stream,
            navigation: [
                NavItem(builtin: "home"),
                NavItem(title: I18n.t("Songs"), page: "songs", icon: "note"),
                NavItem(title: I18n.t("Albums"), page: "albums", icon: "album"),
                NavItem(title: I18n.t("Artists"), page: "artists", icon: "artist"),
                NavItem(builtin: "liked")
            ]
        )
    }

    public func can(_ capability: String) -> Bool {
        Self.supportedCapabilities.contains(capability)
    }

    public func setting(_ key: String) -> String { "" }
    public func setSetting(_ key: String, value: String) throws {}

    public func signIn() async throws -> Account? { throw SourceError.unsupported("signIn") }
    public func signOut() async throws { throw SourceError.unsupported("signOut") }
    public func account() async throws -> Account? { nil }

    public func search(query: String, kind: SearchKind, offset: Int) async throws -> SearchResult {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return withLock {
            switch kind {
            case .tracks:
                let matched = orderedTracks.filter { tr in
                    let hay = "\(tr.name) \(tr.artistNames) \(tr.album.name)"
                    return Self.matches(hay, queryTokens: tokens)
                }
                let (page, more) = Self.pageSlice(matched, offset: offset)
                return SearchResult(tracks: page, more: more)
            case .albums:
                let matched = orderedAlbums.filter { Self.matches($0.name, queryTokens: tokens) }
                let (page, more) = Self.pageSlice(matched, offset: offset)
                return SearchResult(albums: page, more: more)
            case .artists:
                let matched = orderedArtists.filter { Self.matches($0.name, queryTokens: tokens) }
                let (page, more) = Self.pageSlice(matched, offset: offset)
                return SearchResult(artists: page, more: more)
            case .playlists:
                let all = lib.playlists.map(makePublicPlaylistLocked)
                let matched = all.filter { Self.matches($0.name, queryTokens: tokens) }
                let (page, more) = Self.pageSlice(matched, offset: offset)
                return SearchResult(playlists: page, more: more)
            case .shows:
                return SearchResult(shows: [], more: false)
            }
        }
    }

    public func suggest(query: String) async throws -> [String] {
        throw SourceError.unsupported("suggest")
    }

    public func playlists() async throws -> [Playlist] {
        withLock {
            lib.playlists.map(makePublicPlaylistLocked)
        }
    }

    public func playlist(id: String) async throws -> Playlist {
        try withLock {
            guard let stored = lib.playlists.first(where: { $0.id == id }) else {
                throw SourceError.unavailable("no playlist \(id)")
            }
            var out = makePublicPlaylistLocked(stored)
            out.tracks = resolveTracksLocked(stored.tracks)
            return out
        }
    }

    public func album(id: String) async throws -> AlbumPage {
        try withLock {
            guard let page = albumsByID[id] else {
                throw SourceError.unavailable("no album \(id)")
            }
            return page
        }
    }

    public func artist(id: String) async throws -> ArtistPage {
        try withLock {
            guard let page = artistsByID[id] else {
                throw SourceError.unavailable("no artist \(id)")
            }
            return page
        }
    }

    public func liked(offset: Int) async throws -> TrackPage {
        let resolved = withLock { resolveTracksLocked(lib.likes) }
        let (page, more) = Self.pageSlice(resolved, offset: offset)
        return TrackPage(tracks: page, more: more)
    }

    public func recent() async throws -> [Track] {
        let resolved = withLock { resolveTracksLocked(lib.recent) }
        return Array(resolved.prefix(Self.showRecent))
    }

    public func home() async throws -> Browse {
        let (tracks, albums, pls, recentTracks) = withLock {
            (
                orderedTracks,
                orderedAlbums,
                lib.playlists.map(makePublicPlaylistLocked),
                Array(resolveTracksLocked(lib.recent).prefix(Self.homeRows))
            )
        }

        if tracks.isEmpty && pls.isEmpty {
            return Browse(sections: [])
        }

        var sections: [MusicSection] = []
        if !recentTracks.isEmpty {
            sections.append(MusicSection(title: I18n.t("Recently Played"), tracks: recentTracks))
        }
        if !albums.isEmpty {
            sections.append(MusicSection(
                title: I18n.t("Albums"),
                albums: Array(albums.prefix(Self.homeRows)),
                morePage: "albums"
            ))
        }
        if !pls.isEmpty {
            sections.append(MusicSection(title: I18n.t("Playlists"), playlists: pls))
        }
        if recentTracks.isEmpty && !tracks.isEmpty {
            sections.append(MusicSection(
                title: I18n.t("Songs"),
                tracks: Array(tracks.prefix(Self.homeRows)),
                morePage: "songs"
            ))
        }
        return Browse(sections: sections)
    }

    public func browse(page: String) async throws -> Browse {
        let (tracks, albums, artists) = withLock {
            (orderedTracks, orderedAlbums, orderedArtists)
        }

        switch page {
        case "songs":
            return Browse(
                title: I18n.t("Songs"),
                subtitle: I18n.songs(tracks.count),
                sections: [MusicSection(tracks: tracks)]
            )
        case "albums":
            return Browse(
                title: I18n.t("Albums"),
                sections: [MusicSection(albums: albums)]
            )
        case "artists":
            return Browse(
                title: I18n.t("Artists"),
                sections: [MusicSection(artists: artists)]
            )
        default:
            throw SourceError.unavailable("no page \(page)")
        }
    }

    public func isLiked(ids: [String]) async throws -> [String: Bool] {
        let likedSet = withLock { Set(lib.likes) }
        var out: [String: Bool] = [:]
        for id in ids {
            out[id] = likedSet.contains(id)
        }
        return out
    }

    public func like(id: String, on: Bool) async throws {
        withLock {
            if on {
                if !lib.likes.contains(id) {
                    lib.likes.insert(id, at: 0)
                }
            } else {
                lib.likes.removeAll { $0 == id }
            }
            saveLibraryLocked()
        }
        onChange?()
    }

    public func likeEpisode(id: String, on: Bool) async throws {
        throw SourceError.unsupported("likeEpisode")
    }

    public func createPlaylist(name: String) async throws -> Playlist {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        withLock {
            lib.playlists.append(StoredPlaylist(id: String(id), name: name, tracks: []))
            saveLibraryLocked()
        }
        onChange?()
        return Playlist(id: String(id), name: name, trackCount: 0, mine: true)
    }

    public func renamePlaylist(id: String, name: String) async throws {
        try withLock {
            guard let idx = lib.playlists.firstIndex(where: { $0.id == id }) else {
                throw SourceError.unavailable("no playlist \(id)")
            }
            lib.playlists[idx].name = name
            saveLibraryLocked()
        }
        onChange?()
    }

    public func deletePlaylist(id: String) async throws {
        try withLock {
            guard let idx = lib.playlists.firstIndex(where: { $0.id == id }) else {
                throw SourceError.unavailable("no playlist \(id)")
            }
            lib.playlists.remove(at: idx)
            saveLibraryLocked()
        }
        onChange?()
    }

    public func addToPlaylist(id: String, trackIds: [String]) async throws {
        try withLock {
            guard let idx = lib.playlists.firstIndex(where: { $0.id == id }) else {
                throw SourceError.unavailable("no playlist \(id)")
            }
            for tid in trackIds where !lib.playlists[idx].tracks.contains(tid) {
                lib.playlists[idx].tracks.append(tid)
            }
            saveLibraryLocked()
        }
        onChange?()
    }

    public func removeFromPlaylist(id: String, trackIds: [String]) async throws {
        try withLock {
            guard let idx = lib.playlists.firstIndex(where: { $0.id == id }) else {
                throw SourceError.unavailable("no playlist \(id)")
            }
            let removeSet = Set(trackIds)
            lib.playlists[idx].tracks.removeAll { removeSet.contains($0) }
            saveLibraryLocked()
        }
        onChange?()
    }

    public func movePlaylistTrack(id: String, from: Int, to: Int) async throws {
        try withLock {
            guard let idx = lib.playlists.firstIndex(where: { $0.id == id }) else {
                throw SourceError.unavailable("no playlist \(id)")
            }
            var listedIndices: [Int] = []
            for (i, tid) in lib.playlists[idx].tracks.enumerated() where tracksByID[tid] != nil {
                listedIndices.append(i)
            }
            guard from >= 0, from < listedIndices.count, to >= 0, to < listedIndices.count else {
                throw SourceError.message("invalid track index")
            }
            let realFrom = listedIndices[from]
            let realTo = listedIndices[to]
            let item = lib.playlists[idx].tracks.remove(at: realFrom)
            lib.playlists[idx].tracks.insert(item, at: realTo)
            saveLibraryLocked()
        }
        onChange?()
    }

    public func savePlaylist(id: String, on: Bool) async throws { throw SourceError.unsupported("savePlaylist") }
    public func followArtist(id: String, on: Bool) async throws { throw SourceError.unsupported("followArtist") }
    public func saveAlbum(id: String, on: Bool) async throws { throw SourceError.unsupported("saveAlbum") }
    public func savedAlbums(offset: Int) async throws -> AlbumList { throw SourceError.unsupported("savedAlbums") }
    public func shows() async throws -> [Show] { throw SourceError.unsupported("shows") }
    public func show(id: String, offset: Int) async throws -> ShowPage { throw SourceError.unsupported("show") }
    public func subscribeShow(id: String, on: Bool) async throws { throw SourceError.unsupported("subscribeShow") }
    public func stations() async throws -> [Station] { throw SourceError.unsupported("stations") }
    public func stationNext(id: String) async throws -> [Track] { throw SourceError.unsupported("stationNext") }
    public func comments(trackId: String, offset: Int) async throws -> CommentPage { throw SourceError.unsupported("comments") }
    public func likeComment(trackId: String, commentId: String, on: Bool) async throws { throw SourceError.unsupported("likeComment") }
    public func postComment(trackId: String, text: String) async throws -> Comment { throw SourceError.unsupported("postComment") }

    public func lyrics(id: String) async throws -> RawLyrics {
        let exists = withLock { tracksByID[id] != nil }
        guard exists else { throw SourceError.unavailable("no track \(id)") }

        let audioURL = URL(fileURLWithPath: id)
        let lrcURL = audioURL.deletingPathExtension().appendingPathExtension("lrc")
        if let lrcText = try? String(contentsOf: lrcURL, encoding: .utf8) {
            return RawLyrics(lrc: lrcText)
        }
        return RawLyrics()
    }

    public func stream(id: String, quality: String) async throws -> StreamInfo {
        let exists = withLock { tracksByID[id] != nil }
        guard exists, FileManager.default.fileExists(atPath: id) else {
            throw SourceError.unavailable("no track \(id)")
        }
        let fileURL = URL(fileURLWithPath: id)
        let ext = fileURL.pathExtension.lowercased()
        let q = (ext == "flac" || ext == "wav") ? "lossless" : ""
        return StreamInfo(url: fileURL.absoluteString, type: ext, quality: q)
    }

    public func played(track: Track) async {
        guard !track.id.isEmpty else { return }
        withLock {
            lib.recent.removeAll { $0 == track.id }
            lib.recent.insert(track.id, at: 0)
            if lib.recent.count > Self.keepRecent {
                lib.recent = Array(lib.recent.prefix(Self.keepRecent))
            }
            saveLibraryLocked()
        }
        onChange?()
    }

    public func remotePlay(ids: [String], start: Int, position: Int64) async throws { throw SourceError.unsupported("remotePlay") }
    public func remotePause() async throws { throw SourceError.unsupported("remotePause") }
    public func remoteResume() async throws { throw SourceError.unsupported("remoteResume") }
    public func remoteSeek(position: Int64) async throws { throw SourceError.unsupported("remoteSeek") }
    public func remoteVolume(percent: Int) async throws { throw SourceError.unsupported("remoteVolume") }
    public func remoteState() async throws -> RemoteState? { throw SourceError.unsupported("remoteState") }
    public func remoteDevices() async throws -> [RemoteDevice] { throw SourceError.unsupported("remoteDevices") }
    public func remoteUse(deviceId: String) async throws { throw SourceError.unsupported("remoteUse") }
}

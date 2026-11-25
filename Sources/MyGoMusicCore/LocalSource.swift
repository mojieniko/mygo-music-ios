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
        "mp3", "flac", "wav", "m4a", "aac"
    ]

    public let dataDir: URL
    public let defaultMusicFolder: URL
    public let sharedDocumentsFolder: URL?

    private let lock = NSLock()
    private var lib: LocalLibraryPersistence
    private var tracksByID: [String: Track] = [:]
    private var orderedTracks: [Track] = []
    private var albumsByID: [String: AlbumPage] = [:]
    private var orderedAlbums: [Album] = []
    private var artistsByID: [String: ArtistPage] = [:]
    private var orderedArtists: [Artist] = []
    private var offlineDownloadsMap: [String: String] = [:]
    private var isScanningFlag = false
    private var scanGeneration: Int = 0
    private var activeScanTask: Task<Void, Never>?

    public var onChange: (@Sendable () -> Void)?

    public init(dataDir: URL, sharedDocumentsFolder: URL? = nil, eagerSyncScan: Bool = true) {
        self.dataDir = dataDir
        self.defaultMusicFolder = dataDir.appendingPathComponent("MusicFiles", isDirectory: true)
        self.sharedDocumentsFolder = sharedDocumentsFolder
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: defaultMusicFolder, withIntermediateDirectories: true)
        if let sharedDocumentsFolder {
            try? FileManager.default.createDirectory(at: sharedDocumentsFolder, withIntermediateDirectories: true)
        }

        let libFile = dataDir.appendingPathComponent("library.json")
        var didMigrate = false
        if let data = try? Data(contentsOf: libFile),
           let decoded = try? JSONDecoder().decode(LocalLibraryPersistence.self, from: data) {
            let (normalized, changed) = Self.normalizePersistence(
                decoded,
                defaultMusicFolder: defaultMusicFolder,
                sharedDocumentsFolder: sharedDocumentsFolder,
                dataDir: dataDir
            )
            self.lib = normalized
            didMigrate = changed
        } else {
            self.lib = LocalLibraryPersistence(folders: [defaultMusicFolder.path])
        }

        if !self.lib.folders.contains(defaultMusicFolder.path) {
            self.lib.folders.insert(defaultMusicFolder.path, at: 0)
            didMigrate = true
        }
        if let sharedPath = sharedDocumentsFolder?.path, !self.lib.folders.contains(sharedPath) {
            self.lib.folders.append(sharedPath)
            didMigrate = true
        }
        if didMigrate {
            lock.lock()
            saveLibraryLocked()
            lock.unlock()
        }
        loadOfflineDownloadsMap()
        if eagerSyncScan {
            rebuildCatalogSynchronously()
        } else {
            lock.lock()
            self.isScanningFlag = true
            lock.unlock()
        }
        let task = Task.detached(priority: eagerSyncScan ? .utility : .userInitiated) { [weak self] in
            guard let self else { return }
            await self.rescanAsync()
        }
        lock.lock()
        self.activeScanTask = task
        lock.unlock()
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

    public func track(forFileURL url: URL) -> Track? {
        let path = url.standardizedFileURL.path
        return withLock {
            tracksByID[path] ?? (FileManager.default.fileExists(atPath: path) ? Self.skeletonTrack(at: url) : nil)
        }
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
        importAudioFilesReturningURLs(urls).count
    }

    /// 导入外部音频文件或目录到沙盒本地音乐目录，并返回已落盘的目标音频文件 URL 列表
    @discardableResult
    public func importAudioFilesReturningURLs(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        try? fm.createDirectory(at: defaultMusicFolder, withIntermediateDirectories: true)
        var importedURLs: [URL] = []
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
                    importedURLs.append(destination)
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
        if !importedURLs.isEmpty { rescan() }
        return importedURLs
    }

    // MARK: - 主动离线下载持久化与本地曲库联动

    private func loadOfflineDownloadsMap() {
        let mapURL = dataDir.appendingPathComponent("offline_downloads.json")
        guard let data = try? Data(contentsOf: mapURL),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        let fm = FileManager.default
        var cleaned: [String: String] = [:]
        var changed = false
        for (key, rawPath) in raw {
            let relocated = Self.relocateSandboxPath(rawPath, to: dataDir)
            if fm.fileExists(atPath: relocated) {
                cleaned[key] = relocated
                if relocated != rawPath { changed = true }
            } else {
                changed = true
            }
        }
        withLock {
            self.offlineDownloadsMap = cleaned
            if changed {
                saveOfflineDownloadsLocked()
            }
        }
    }

    private func saveOfflineDownloadsLocked() {
        let mapURL = dataDir.appendingPathComponent("offline_downloads.json")
        if let data = try? JSONEncoder().encode(offlineDownloadsMap) {
            try? data.write(to: mapURL, options: .atomic)
        }
    }

    /// 返回当前所有已永久离线保存的原曲目 compositeKey 集合
    public func downloadedCompositeKeys() -> Set<String> {
        withLock {
            let fm = FileManager.default
            var keys = Set<String>()
            for (key, path) in offlineDownloadsMap where fm.fileExists(atPath: path) {
                keys.insert(key)
            }
            return keys
        }
    }

    /// 查询指定曲目（支持在线源 compositeKey 或本地曲目）是否已离线下载落盘
    public func isTrackDownloaded(compositeKey: String) -> Bool {
        localFileURLForDownloadedTrack(compositeKey: compositeKey) != nil
    }

    /// 获取已离线下载曲目的本地音频文件 URL
    public func localFileURLForDownloadedTrack(compositeKey: String) -> URL? {
        withLock {
            guard let path = offlineDownloadsMap[compositeKey],
                  FileManager.default.fileExists(atPath: path) else {
                return nil
            }
            return URL(fileURLWithPath: path)
        }
    }

    /// 将下载好的在线音轨、LRC 歌词与高清封面永久存入本地曲库目录，并预写入精确元数据索引
    @discardableResult
    public func storeDownloadedTrack(
        track: Track,
        tempAudioURL: URL,
        fileExtension: String,
        lrcText: String?,
        coverData: Data?
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: defaultMusicFolder, withIntermediateDirectories: true)

        let rawExt = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        let cleanExt = Self.supportedExtensions.contains(rawExt) ? rawExt : "mp3"
        let baseTitle = Self.sanitizedDownloadFileName(
            artist: track.artistNames,
            title: track.name
        )
        let destURL = uniqueImportURL(for: "\(baseTitle).\(cleanExt)")
        let stagingURL = defaultMusicFolder.appendingPathComponent(".dl-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: tempAudioURL, to: stagingURL)
            try fm.moveItem(at: stagingURL, to: destURL)
        } catch {
            try? fm.removeItem(at: stagingURL)
            throw error
        }

        if let lrcText, !lrcText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lrcURL = destURL.deletingPathExtension().appendingPathExtension("lrc")
            try? Data(lrcText.utf8).write(to: lrcURL, options: .atomic)
        }

        let canonicalPath = destURL.standardizedFileURL.path
        var savedCoverURL: String? = nil
        if let coverData, !coverData.isEmpty {
            let coversDir = dataDir.appendingPathComponent("covers", isDirectory: true)
            try? fm.createDirectory(at: coversDir, withIntermediateDirectories: true)
            let hash = PluginCrypto.md5Hex(canonicalPath)
            let coverFile = coversDir.appendingPathComponent("\(hash).jpg")
            try? coverData.write(to: coverFile, options: .atomic)
            savedCoverURL = coverFile.absoluteString
        }

        let vals = try? destURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = vals?.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        let fsize = Int64(vals?.fileSize ?? 0)

        let localArtists = track.artists?.isEmpty == false ? track.artists : nil
        let localAlbum = Album(
            id: "album:" + (track.album.name.isEmpty ? "offline" : track.album.name.lowercased()),
            name: track.album.name.isEmpty ? I18n.t("Offline Downloads") : track.album.name,
            imageUrl: savedCoverURL ?? track.album.imageUrl,
            artists: localArtists
        )
        let storedTrack = Track(
            id: canonicalPath,
            source: Self.sourceID,
            name: track.name,
            artists: localArtists,
            album: localAlbum,
            duration: track.duration
        )

        withLock {
            // 若此前存在同 key 的旧离线文件，先替换登记
            offlineDownloadsMap[track.compositeKey] = canonicalPath
            saveOfflineDownloadsLocked()

            var cache = loadMetadataCache()
            cache[canonicalPath] = CachedMetadataEntry(
                modTime: mtime,
                fileSize: fsize,
                track: storedTrack
            )
            saveMetadataCache(cache)
        }

        rescan()
        return destURL
    }

    /// 移除指定曲目的离线下载本地文件及元数据记录
    public func removeDownloadedTrack(compositeKey: String) {
        let removedPath: String? = withLock {
            guard let path = offlineDownloadsMap.removeValue(forKey: compositeKey) else {
                return nil
            }
            saveOfflineDownloadsLocked()
            return path
        }
        guard let removedPath else { return }

        let fm = FileManager.default
        let audioURL = URL(fileURLWithPath: removedPath)
        let lrcURL = audioURL.deletingPathExtension().appendingPathExtension("lrc")
        try? fm.removeItem(at: audioURL)
        try? fm.removeItem(at: lrcURL)

        withLock {
            var cache = loadMetadataCache()
            cache.removeValue(forKey: removedPath)
            saveMetadataCache(cache)
        }
        rescan()
    }

    private static func sanitizedDownloadFileName(artist: String, title: String) -> String {
        let raw = artist.isEmpty ? title : "\(artist) - \(title)"
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\r\n\t")
        let parts = raw.components(separatedBy: invalid)
        let cleaned = parts.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "Track" }
        return String(cleaned.prefix(96))
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

    private struct CachedMetadataEntry: Codable {
        var modTime: TimeInterval
        var fileSize: Int64
        var track: Track
    }

    /// 触发非阻塞扫描：先快速建立文件名/磁盘元数据缓存索引，再在后台异步解析 AVAsset 精确标签
    public func rescan() {
        rebuildCatalogSynchronously()
        onChange?()
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.rescanAsync()
        }
        lock.lock()
        activeScanTask?.cancel()
        activeScanTask = task
        lock.unlock()
    }

    /// 异步完整扫描所有目录并使用现代 `AVAsset.load` API 提取时长、标签与内嵌封面
    public func rescanAsync() async {
        let (gen, scanFolders, coversDir) = withLock { () -> (Int, [String], URL) in
            scanGeneration += 1
            isScanningFlag = true
            return (scanGeneration, lib.folders, dataDir.appendingPathComponent("covers", isDirectory: true))
        }

        let fileURLs = Self.enumerateAudioFiles(in: scanFolders)
        var diskCache = loadMetadataCache()
        var resolvedTracks: [Track] = []
        var pendingURLs: [(URL, TimeInterval, Int64)] = []

        for fileURL in fileURLs {
            let path = fileURL.standardizedFileURL.path
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let fsize = Int64(values?.fileSize ?? 0)
            if let cached = diskCache[path],
               abs(cached.modTime - mtime) < 0.01,
               cached.fileSize == fsize {
                resolvedTracks.append(cached.track)
            } else {
                pendingURLs.append((fileURL, mtime, fsize))
            }
        }

        if !pendingURLs.isEmpty {
            let maxConcurrent = 4
            await withTaskGroup(of: (String, TimeInterval, Int64, Track).self) { group in
                var iterator = pendingURLs.makeIterator()
                for _ in 0..<maxConcurrent {
                    if let next = iterator.next() {
                        group.addTask {
                            let track = await Self.readTrackMetadataAsync(at: next.0, coversDir: coversDir)
                            return (next.0.standardizedFileURL.path, next.1, next.2, track)
                        }
                    }
                }
                while let result = await group.next() {
                    if Task.isCancelled { break }
                    diskCache[result.0] = CachedMetadataEntry(
                        modTime: result.1,
                        fileSize: result.2,
                        track: result.3
                    )
                    resolvedTracks.append(result.3)
                    if let next = iterator.next() {
                        group.addTask {
                            let track = await Self.readTrackMetadataAsync(at: next.0, coversDir: coversDir)
                            return (next.0.standardizedFileURL.path, next.1, next.2, track)
                        }
                    }
                }
            }
        }

        // 清理已从磁盘删除的文件缓存条目
        let currentPathSet = Set(fileURLs.map { $0.standardizedFileURL.path })
        diskCache = diskCache.filter { currentPathSet.contains($0.key) }
        saveMetadataCache(diskCache)

        let stillCurrent = withLock { gen == scanGeneration }
        guard stillCurrent else { return }

        applyDiscoveredTracks(resolvedTracks)
        onChange?()
    }

    /// 同步快速构建索引（复用元数据缓存 + 文件名回退，无阻塞 AVAsset 同步 API 调用）
    public func rebuildCatalogSynchronously() {
        lock.lock()
        isScanningFlag = true
        let scanFolders = lib.folders
        lock.unlock()

        let fileURLs = Self.enumerateAudioFiles(in: scanFolders)
        let diskCache = loadMetadataCache()
        var discoveredTracks: [Track] = []
        discoveredTracks.reserveCapacity(fileURLs.count)

        for fileURL in fileURLs {
            let cleanPath = fileURL.standardizedFileURL.path
            if let cached = diskCache[cleanPath] {
                discoveredTracks.append(cached.track)
            } else {
                discoveredTracks.append(Self.skeletonTrack(at: fileURL))
            }
        }

        applyDiscoveredTracks(discoveredTracks)
    }

    private func applyDiscoveredTracks(_ tracks: [Track]) {
        let discoveredTracks = tracks.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

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

    private func loadMetadataCache() -> [String: CachedMetadataEntry] {
        let cacheURL = dataDir.appendingPathComponent("metadata_cache.json")
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: CachedMetadataEntry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveMetadataCache(_ cache: [String: CachedMetadataEntry]) {
        let cacheURL = dataDir.appendingPathComponent("metadata_cache.json")
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    private static func enumerateAudioFiles(in folders: [String]) -> [URL] {
        var result: [URL] = []
        var seenPaths = Set<String>()
        let fm = FileManager.default
        for folderPath in folders {
            let folderURL = URL(fileURLWithPath: folderPath)
            guard let enumerator = fm.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent == "Inbox",
                   fileURL.deletingLastPathComponent().lastPathComponent == "Documents" {
                    enumerator.skipDescendants()
                    continue
                }
                let ext = fileURL.pathExtension.lowercased()
                guard supportedExtensions.contains(ext) else { continue }
                let cleanPath = fileURL.standardizedFileURL.path
                guard !seenPaths.contains(cleanPath) else { continue }
                seenPaths.insert(cleanPath)
                result.append(fileURL)
            }
        }
        return result
    }

    private static func inferNamesFromFilename(_ fileURL: URL) -> (title: String, artist: String) {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        if let dashRange = baseName.range(of: " - ") {
            let left = String(baseName[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(baseName[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !left.isEmpty && !right.isEmpty {
                return (right, left)
            }
        }
        return (baseName, "Unknown Artist")
    }

    private static func skeletonTrack(at fileURL: URL) -> Track {
        let inferred = inferNamesFromFilename(fileURL)
        let albumName = fileURL.deletingLastPathComponent().lastPathComponent
        let cleanAlbum = albumName.isEmpty || albumName == "MusicFiles" || albumName == "Documents" ? "Unknown Album" : albumName
        let artistID = "artist:" + inferred.artist.lowercased()
        let albumID = "album:" + cleanAlbum.lowercased() + ":" + inferred.artist.lowercased()
        let artist = Artist(id: artistID, name: inferred.artist)
        let album = Album(id: albumID, name: cleanAlbum, imageUrl: nil, artists: [artist])
        return Track(
            id: fileURL.standardizedFileURL.path,
            source: Self.sourceID,
            name: inferred.title,
            artists: [artist],
            album: album,
            duration: 0
        )
    }

    private static func readTrackMetadataAsync(at fileURL: URL, coversDir: URL) async -> Track {
        let inferred = inferNamesFromFilename(fileURL)
        var title = inferred.title
        var artistName = inferred.artist
        var albumName = "Unknown Album"
        var durationMs: Int64 = 0
        var imageURL: String? = nil

        let asset = AVURLAsset(url: fileURL)
        if let loadedDuration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(loadedDuration)
            if seconds.isFinite && seconds > 0 {
                durationMs = Int64((seconds * 1000.0).rounded())
            }
        }

        let commonItems = (try? await asset.load(.commonMetadata)) ?? []
        for item in commonItems {
            guard let commonKey = item.commonKey else { continue }
            switch commonKey {
            case .commonKeyTitle:
                if let val = try? await item.load(.stringValue),
                   !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    title = val.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case .commonKeyArtist:
                if let val = try? await item.load(.stringValue),
                   !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    artistName = val.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case .commonKeyAlbumName:
                if let val = try? await item.load(.stringValue),
                   !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    albumName = val.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case .commonKeyArtwork:
                if let data = try? await item.load(.dataValue), !data.isEmpty {
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
            let relocated = Self.relocateSandboxPath(id, to: dataDir)
            out[id] = likedSet.contains(id) || likedSet.contains(relocated)
        }
        return out
    }

    public func like(id: String, on: Bool) async throws {
        let canonical = Self.relocateSandboxPath(id, to: dataDir)
        withLock {
            if on {
                if !lib.likes.contains(canonical) {
                    lib.likes.insert(canonical, at: 0)
                }
            } else {
                lib.likes.removeAll { $0 == canonical || $0 == id }
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

    /// 兼容中文 Windows 常见编码的 LRC 文本解码器（UTF-8 / BOM UTF-16 / GB18030 / GBK / ISO-8859-1）
    public static func decodeTextWithFallback(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        // 处理 UTF-16 BOM
        if data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE]) {
            if let s = String(data: data, encoding: .utf16), !s.isEmpty { return s }
        }
        // 处理 UTF-8 BOM 并优先尝试严谨 UTF-8 解码
        let utf8Slice = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        if let s = String(data: utf8Slice, encoding: .utf8) {
            return s
        }
        // 简体中文常见 GB18030 / GBK 回退
        let gb18030Raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let gb18030Enc = String.Encoding(rawValue: gb18030Raw)
        if let s = String(data: data, encoding: gb18030Enc), !s.isEmpty {
            return s
        }
        let gbkRaw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosChineseSimplif.rawValue))
        let gbkEnc = String.Encoding(rawValue: gbkRaw)
        if let s = String(data: data, encoding: gbkEnc), !s.isEmpty {
            return s
        }
        // Big5 & Shift-JIS & UTF-16 & Latin1 兜底
        let big5Raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: big5Raw)), !s.isEmpty {
            return s
        }
        if let s = String(data: data, encoding: .shiftJIS), !s.isEmpty {
            return s
        }
        if let s = String(data: data, encoding: .utf16LittleEndian), !s.isEmpty {
            return s
        }
        return String(data: data, encoding: .isoLatin1)
    }

    public func lyrics(id: String) async throws -> RawLyrics {
        guard let resolvedID = withLock({ resolveTrackIDLocked(id) }) else {
            throw SourceError.unavailable("no track \(id)")
        }

        let audioURL = URL(fileURLWithPath: resolvedID)
        // 1. 优先同名 .lrc（支持 GBK/GB18030/UTF-8/UTF-16 自动编码识别）
        let lrcURL = audioURL.deletingPathExtension().appendingPathExtension("lrc")
        if let lrcData = try? Data(contentsOf: lrcURL),
           let lrcText = Self.decodeTextWithFallback(lrcData),
           !lrcText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return RawLyrics(lrc: lrcText)
        }

        // 2. 回退读取音频内嵌歌词（ID3 USLT / iTunes ©lyr / FLAC LYRICS）
        let asset = AVURLAsset(url: audioURL)
        let items = (try? await asset.load(.metadata)) ?? []
        for item in items {
            let keyStr = (item.key as? String ?? "").lowercased()
            let idStr = (item.identifier?.rawValue ?? "").lowercased()
            let isLyricTag = keyStr == "uslt"
                || keyStr == "©lyr"
                || keyStr == "lyr"
                || keyStr.contains("lyric")
                || idStr.contains("lyric")
                || idStr.contains("uslt")
            guard isLyricTag else { continue }
            if let embedded = try? await item.load(.stringValue),
               !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let normalized = embedded.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                if normalized.range(of: #"\[\d{1,2}:\d{2}"#, options: .regularExpression) != nil {
                    return RawLyrics(lrc: normalized)
                }
                let lines = normalized
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map { RawLyricLine(start: -1, text: $0) }
                if !lines.isEmpty {
                    return RawLyrics(lines: lines)
                }
            }
        }
        return RawLyrics()
    }

    public func stream(id: String, quality: String) async throws -> StreamInfo {
        guard let resolvedID = withLock({ resolveTrackIDLocked(id) }) else {
            throw SourceError.unavailable("no track \(id)")
        }
        let fileURL = URL(fileURLWithPath: resolvedID)
        let ext = fileURL.pathExtension.lowercased()
        let q = (ext == "flac" || ext == "wav") ? "lossless" : ""
        return StreamInfo(url: fileURL.absoluteString, type: ext, quality: q)
    }

    public func played(track: Track) async {
        guard !track.id.isEmpty else { return }
        withLock {
            let canonicalID = resolveTrackIDLocked(track.id) ?? Self.relocateSandboxPath(track.id, to: dataDir)
            lib.recent.removeAll { $0 == canonicalID || $0 == track.id }
            lib.recent.insert(canonicalID, at: 0)
            if lib.recent.count > Self.keepRecent {
                lib.recent = Array(lib.recent.prefix(Self.keepRecent))
            }
            saveLibraryLocked()
        }
        onChange?()
    }

    // MARK: - iOS 沙盒容器重装/更新路径迁移适配

    private static let sandboxLocalMarker = "/Library/Application Support/MyGoMusic/local/"
    private static let sandboxMusicFilesMarker = "/local/MusicFiles/"
    private static let sandboxDocumentsMarker = "/Documents/"

    /// 将历史 iOS 容器 UUID 下的本地音频/目录路径自动重写到当前有效沙盒目录
    private static func relocateSandboxPath(
        _ rawPath: String,
        to currentDataDir: URL,
        sharedDocumentsFolder: URL? = nil
    ) -> String {
        if let range = rawPath.range(of: sandboxLocalMarker) {
            let tail = String(rawPath[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return tail.isEmpty ? currentDataDir.path : currentDataDir.appendingPathComponent(tail).path
        }
        if !FileManager.default.fileExists(atPath: rawPath),
           let range = rawPath.range(of: sandboxMusicFilesMarker) {
            let tail = String(rawPath[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let base = currentDataDir.appendingPathComponent("MusicFiles", isDirectory: true)
            return tail.isEmpty ? base.path : base.appendingPathComponent(tail).path
        }
        if let sharedDocumentsFolder,
           rawPath.contains("/var/mobile/Containers/Data/Application/") || rawPath.contains("/CoreSimulator/Devices/"),
           let range = rawPath.range(of: sandboxDocumentsMarker) {
            let tail = String(rawPath[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return tail.isEmpty ? sharedDocumentsFolder.path : sharedDocumentsFolder.appendingPathComponent(tail).path
        }
        return rawPath
    }

    private static func deduplicatedPreservingOrder(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        out.reserveCapacity(items.count)
        for item in items where !item.isEmpty && seen.insert(item).inserted {
            out.append(item)
        }
        return out
    }

    private static func normalizePersistence(
        _ raw: LocalLibraryPersistence,
        defaultMusicFolder: URL,
        sharedDocumentsFolder: URL? = nil,
        dataDir: URL
    ) -> (LocalLibraryPersistence, Bool) {
        let fm = FileManager.default
        let migratedFolders = raw.folders.compactMap { folder -> String? in
            let relocated = relocateSandboxPath(folder, to: dataDir, sharedDocumentsFolder: sharedDocumentsFolder)
            // 清理因老版本重装累加且已失效的历史沙盒 MusicFiles 路径，保留用户自选外置目录
            if relocated != defaultMusicFolder.path,
               relocated.contains("/MusicFiles"),
               !fm.fileExists(atPath: relocated) {
                return nil
            }
            return relocated
        }
        let folders = deduplicatedPreservingOrder(migratedFolders)
        let likes = deduplicatedPreservingOrder(raw.likes.map { relocateSandboxPath($0, to: dataDir, sharedDocumentsFolder: sharedDocumentsFolder) })
        let recent = deduplicatedPreservingOrder(raw.recent.map { relocateSandboxPath($0, to: dataDir, sharedDocumentsFolder: sharedDocumentsFolder) })
        let playlists = raw.playlists.map { pl in
            StoredPlaylist(
                id: pl.id,
                name: pl.name,
                tracks: deduplicatedPreservingOrder(pl.tracks.map { relocateSandboxPath($0, to: dataDir, sharedDocumentsFolder: sharedDocumentsFolder) })
            )
        }
        let changed = folders != raw.folders
            || likes != raw.likes
            || recent != raw.recent
            || playlists.map(\.tracks) != raw.playlists.map(\.tracks)
        return (
            LocalLibraryPersistence(folders: folders, likes: likes, recent: recent, playlists: playlists),
            changed
        )
    }

    private func resolveTrackIDLocked(_ rawID: String) -> String? {
        let fm = FileManager.default
        if tracksByID[rawID] != nil && fm.fileExists(atPath: rawID) {
            return rawID
        }
        let relocated = Self.relocateSandboxPath(rawID, to: dataDir, sharedDocumentsFolder: sharedDocumentsFolder)
        if tracksByID[relocated] != nil && fm.fileExists(atPath: relocated) {
            return relocated
        }
        if fm.fileExists(atPath: relocated) {
            let ext = URL(fileURLWithPath: relocated).pathExtension.lowercased()
            if Self.supportedExtensions.contains(ext) {
                return relocated
            }
        }
        return nil
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

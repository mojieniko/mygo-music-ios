// PluginInstaller.swift
// 对应原项目 internal/plugin/install.go 的插件发现、GitHub 仓库解析与安装管理

import Compression
import Foundation

/// 插件来源记录（对应 plugin.Origin / .origin.json）
public struct PluginOrigin: Codable, Hashable, Sendable {
    public var repo: String
    public var version: String

    public init(repo: String, version: String) {
        self.repo = repo
        self.version = version
    }
}

/// 待确认安装的插件包（对应 plugin.Pending）
public struct PendingPlugin: Identifiable, Sendable {
    public var id: String { manifest.id }
    public var repo: String?
    public var version: String?
    public var sourcePath: URL
    public var manifest: PluginManifest

    public init(repo: String? = nil, version: String? = nil, sourcePath: URL, manifest: PluginManifest) {
        self.repo = repo
        self.version = version
        self.sourcePath = sourcePath
        self.manifest = manifest
    }
}

/// 插件更新检测结果
public struct PluginUpdateInfo: Sendable {
    public var pluginID: String
    public var repo: String
    public var currentVersion: String
    public var latestVersion: String
    public var hasUpdate: Bool
    public var pending: PendingPlugin?

    public init(
        pluginID: String,
        repo: String,
        currentVersion: String,
        latestVersion: String,
        hasUpdate: Bool,
        pending: PendingPlugin? = nil
    ) {
        self.pluginID = pluginID
        self.repo = repo
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.hasUpdate = hasUpdate
        self.pending = pending
    }
}

/// 已安装但加载失败的插件诊断信息
public struct PluginLoadFailure: Identifiable, Sendable {
    public var id: String { folderName }
    public var folderName: String
    public var path: URL
    public var reason: String
}

/// 插件安装与发现管理器（1:1 移植自 internal/plugin/install.go）
public enum PluginInstaller {
    private static let repoRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#)
    private static let pluginIdRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#)

    public static func isValidPluginID(_ id: String) -> Bool {
        let range = NSRange(id.startIndex..., in: id)
        return !id.isEmpty && pluginIdRegex.firstMatch(in: id, range: range)?.range == range
    }

    /// 解析 GitHub 仓库地址，支持 owner/repo、https://github.com/owner/repo/tree/main、git@github.com:owner/repo.git（对应 plugin.ParseRepo）
    public static func parseRepo(_ input: String) throws -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rest = cutPrefixCaseInsensitive(s, prefix: "git@github.com:") {
            s = rest
        } else {
            if let rest = cutPrefixCaseInsensitive(s, prefix: "https://") {
                s = rest
            } else if let rest = cutPrefixCaseInsensitive(s, prefix: "http://") {
                s = rest
            }
            if let rest = cutPrefixCaseInsensitive(s, prefix: "www.") {
                s = rest
            }
            if var rest = cutPrefixCaseInsensitive(s, prefix: "github.com/") {
                if let hashIdx = rest.firstIndex(of: "#") {
                    rest = String(rest[..<hashIdx])
                }
                if let queryIdx = rest.firstIndex(of: "?") {
                    rest = String(rest[..<queryIdx])
                }
                let parts = rest.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count >= 2 {
                    rest = "\(parts[0])/\(parts[1])"
                }
                s = rest
            }
        }
        while s.hasSuffix("/") {
            s.removeLast()
        }
        if s.hasSuffix(".git") {
            s = String(s.dropLast(4))
        }
        let ns = s as NSString
        let matches = repoRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty || s.contains("..") {
            throw SourceError.message("not a GitHub repository: \(input.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return s
    }

    private static func cutPrefixCaseInsensitive(_ s: String, prefix: String) -> String? {
        guard s.count >= prefix.count else { return nil }
        let idx = s.index(s.startIndex, offsetBy: prefix.count)
        if s[..<idx].lowercased() == prefix.lowercased() {
            return String(s[idx...])
        }
        return nil
    }

    /// 根据平台选择 GitHub Release 资产（对应 pickAsset）
    public static func pickAsset(names: [String], goos: String = "darwin", goarch: String = "arm64") -> Int {
        let platforms = ["darwin", "linux", "windows"]
        var general = -1
        for (i, name) in names.enumerated() {
            let n = name.lowercased()
            guard n.hasSuffix(".zip") else { continue }
            if n.contains(goos) && n.contains(goarch) {
                return i
            }
            let isOtherPlatform = platforms.contains { n.contains($0) }
            if !isOtherPlatform && general < 0 {
                general = i
            }
        }
        return general
    }

    /// 比较两个语义化版本号，判断 candidate 是否比 current 更新（对应 plugin.IsNewer）
    public static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        guard let a = parseVersionNumbers(candidate),
              let b = parseVersionNumbers(current) else {
            return candidate != current && !candidate.isEmpty
        }
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv {
                return av > bv
            }
        }
        return false
    }

    public static func parseVersionNumbers(_ version: String) -> [Int]? {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") {
            v.removeFirst()
        }
        if let dashIdx = v.firstIndex(of: "-") {
            v = String(v[..<dashIdx])
        }
        let parts = v.split(separator: ".")
        guard (2...4).contains(parts.count) else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard let n = Int(p), n >= 0 else { return nil }
            nums.append(n)
        }
        return nums
    }

    /// 扫描插件目录并加载所有有效插件（对应 plugin.Discover）
    public static func discover(pluginsDir: URL, dataRootDir: URL) -> [JSPluginSource] {
        discoverDetailed(pluginsDir: pluginsDir, dataRootDir: dataRootDir).plugins
    }

    /// 扫描插件目录并返回成功列表与失败诊断，便于在设置中提示最低版本不兼容等错误
    public static func discoverDetailed(
        pluginsDir: URL,
        dataRootDir: URL
    ) -> (plugins: [JSPluginSource], failures: [PluginLoadFailure]) {
        try? FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dataRootDir, withIntermediateDirectories: true)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }

        var loaded: [JSPluginSource] = []
        var failures: [PluginLoadFailure] = []
        let sortedEntries = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for entry in sortedEntries {
            let manifestFile = entry.appendingPathComponent("plugin.json")
            guard FileManager.default.fileExists(atPath: manifestFile.path) else { continue }
            do {
                let plugin = try JSPluginSource(pluginDir: entry, dataRootDir: dataRootDir)
                if !loaded.contains(where: { $0.manifest.id == plugin.manifest.id }) {
                    loaded.append(plugin)
                }
            } catch {
                failures.append(PluginLoadFailure(
                    folderName: entry.lastPathComponent,
                    path: entry,
                    reason: error.localizedDescription
                ))
            }
        }
        return (loaded, failures)
    }

    /// 读取插件的 GitHub 来源记录（.origin.json）
    public static func readOrigin(in pluginDir: URL) -> PluginOrigin? {
        let originURL = pluginDir.appendingPathComponent(".origin.json")
        guard let data = try? Data(contentsOf: originURL) else { return nil }
        return try? JSONDecoder().decode(PluginOrigin.self, from: data)
    }

    /// 从本地文件夹或 `.zip` 压缩包读取待安装插件
    public static func openFromLocal(_ url: URL) throws -> PendingPlugin {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw SourceError.message("Plugin path does not exist")
        }

        if !isDir.boolValue && url.pathExtension.lowercased() == "zip" {
            let data = try Data(contentsOf: url)
            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("mygo-local-zip-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            do {
                try extractZipData(data, into: tmpDir)
                return try openFromFolder(tmpDir)
            } catch {
                try? FileManager.default.removeItem(at: tmpDir)
                throw error
            }
        }

        guard isDir.boolValue else {
            throw SourceError.message("Select a plugin folder or .zip archive")
        }
        return try openFromFolder(url)
    }

    /// 从本地文件夹读取待安装插件（对应 plugin.Open）
    public static func openFromFolder(_ folderURL: URL) throws -> PendingPlugin {
        let root = try locatePluginRoot(in: folderURL)
        let manifestData = try Data(contentsOf: root.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        // 试编译校验（含 minAppVersion 与多文件模块解析）
        let tmpData = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpData) }
        _ = try JSPluginSource(pluginDir: root, dataRootDir: tmpData)
        return PendingPlugin(sourcePath: root, manifest: manifest)
    }

    /// 检查已安装插件是否有 GitHub 更新
    public static func checkUpdate(for pluginDir: URL, token: String? = nil) async throws -> PluginUpdateInfo {
        guard let origin = readOrigin(in: pluginDir) else {
            throw SourceError.message(I18n.t("Not installed via GitHub"))
        }
        let manifestData = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        let manifestVer = manifest.version ?? ""
        let currentVersion = manifestVer.isEmpty ? origin.version : manifestVer

        let pending = try await fetchFromGitHub(repoInput: origin.repo, token: token)
        let latestManifestVer = pending.manifest.version ?? ""
        let latestVersion = latestManifestVer.isEmpty ? (pending.version ?? "") : latestManifestVer
        let hasUpdate: Bool
        if !latestVersion.isEmpty && !currentVersion.isEmpty {
            hasUpdate = isNewerVersion(latestVersion, than: currentVersion)
                || (parseVersionNumbers(latestVersion) == nil && parseVersionNumbers(currentVersion) == nil && (pending.version ?? latestVersion) != origin.version)
        } else {
            hasUpdate = false
        }

        if !hasUpdate {
            try? FileManager.default.removeItem(at: pending.sourcePath)
            return PluginUpdateInfo(
                pluginID: manifest.id,
                repo: origin.repo,
                currentVersion: currentVersion,
                latestVersion: latestVersion.isEmpty ? currentVersion : latestVersion,
                hasUpdate: false,
                pending: nil
            )
        }
        return PluginUpdateInfo(
            pluginID: manifest.id,
            repo: origin.repo,
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            hasUpdate: true,
            pending: pending
        )
    }

    private static func makeGitHubRequest(url: URL, token: String?, accept: String? = "application/vnd.github+json") -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("mygo-music", forHTTPHeaderField: "User-Agent")
        if let accept {
            req.setValue(accept, forHTTPHeaderField: "Accept")
        }
        if let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            req.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private static func checkGitHubHTTPStatus(_ http: HTTPURLResponse) throws {
        if http.statusCode == 404 {
            throw SourceError.message(I18n.t("There's no such public repository on GitHub"))
        }
        if (http.statusCode == 403 || http.statusCode == 429),
           http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            throw SourceError.message("GitHub API rate limit exceeded; configure a GitHub Token in Settings")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SourceError.message("GitHub answered \(http.statusCode)")
        }
    }

    /// 从 GitHub 下载插件（优先下载最新 Release .zip 资产或 zipball，回退到有限深度递归 Contents API，支持可选 GitHub Token）
    public static func fetchFromGitHub(repoInput: String, token: String? = nil) async throws -> PendingPlugin {
        let repo = try parseRepo(repoInput)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("mygo-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        struct GHAsset: Decodable {
            let name: String
            let browser_download_url: String
        }
        struct GHRelease: Decodable {
            let tag_name: String?
            let zipball_url: String?
            let assets: [GHAsset]?
        }

        // 1. 优先尝试获取最新 GitHub Release（与原项目 internal/plugin/install.go 一致）
        if let releaseURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") {
            let relReq = makeGitHubRequest(url: releaseURL, token: token)
            if let (relData, relResp) = try? await URLSession.shared.data(for: relReq),
               let http = relResp as? HTTPURLResponse {
                if (http.statusCode == 403 || http.statusCode == 429),
                   http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                    try checkGitHubHTTPStatus(http)
                }
                if http.statusCode == 200,
                   let release = try? JSONDecoder().decode(GHRelease.self, from: relData) {
                    let assets = release.assets ?? []
                    let idx = pickAsset(names: assets.map(\.name))
                    let zipURLStr: String? = (idx >= 0 && idx < assets.count) ? assets[idx].browser_download_url : release.zipball_url
                    if let zipURLStr, let zipURL = URL(string: zipURLStr) {
                        // 对非 github API 域名仅在同域/api.github.com 上附带 Authorization，避免泄露 token 给外部重定向 CDN
                        let zipToken = (zipURL.host == "api.github.com") ? token : nil
                        let zipReq = makeGitHubRequest(url: zipURL, token: zipToken, accept: nil)
                        let (zipData, zipResp) = try await URLSession.shared.data(for: zipReq)
                        if let zHttp = zipResp as? HTTPURLResponse, (200...299).contains(zHttp.statusCode) {
                            do {
                                try extractZipData(zipData, into: tmpDir)
                                var pending = try openFromFolder(tmpDir)
                                pending.repo = repo
                                pending.version = (release.tag_name ?? "latest").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                                return pending
                            } catch let err as SourceError {
                                // 版本兼容性等明确业务校验错误直接向上抛出，避免退回拉源码掩盖错误
                                let msg = err.localizedDescription
                                if msg.contains("MyGo Music") || msg.contains("version") {
                                    try? FileManager.default.removeItem(at: tmpDir)
                                    throw err
                                }
                                // 其余结构不完整（如源码未构建发布资产仅在 tag 等）清空临时目录后走回退逻辑
                                try? FileManager.default.removeItem(at: tmpDir)
                                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                            } catch {
                                try? FileManager.default.removeItem(at: tmpDir)
                                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                            }
                        }
                    }
                }
            }
        }

        // 2. 回退：通过 GitHub Contents API 有限深度递归拉取仓库文件（兼容无 Release、含多模块目录的插件仓库）
        struct GHContentItem: Decodable {
            let name: String
            let path: String
            let type: String
            let download_url: String?
            let sha: String?
        }

        let skipDirectories: Set<String> = [".git", ".github", ".vscode", ".idea", "node_modules", "__MACOSX"]
        var latestSHA: String?
        var fetchedFileCount = 0
        let maxFiles = 96

        func downloadDirectory(apiURL: URL, localDir: URL, depth: Int) async throws {
            guard depth <= 4, fetchedFileCount < maxFiles else { return }
            let req = makeGitHubRequest(url: apiURL, token: token)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw SourceError.message("GitHub network error")
            }
            try checkGitHubHTTPStatus(http)

            let items = try JSONDecoder().decode([GHContentItem].self, from: data)
            try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

            for item in items {
                guard fetchedFileCount < maxFiles else { break }
                if latestSHA == nil, let sha = item.sha, !sha.isEmpty {
                    latestSHA = String(sha.prefix(8))
                }
                if item.name.hasPrefix(".") && item.name != ".origin.json" {
                    continue
                }
                if item.type == "file", let dl = item.download_url, let dlURL = URL(string: dl) {
                    fetchedFileCount += 1
                    let fileReq = makeGitHubRequest(url: dlURL, token: (dlURL.host == "api.github.com" ? token : nil), accept: nil)
                    let (fileData, fileResp) = try await URLSession.shared.data(for: fileReq)
                    if let fHttp = fileResp as? HTTPURLResponse, !(200...299).contains(fHttp.statusCode) {
                        throw SourceError.message("Failed to download \(item.path): HTTP \(fHttp.statusCode)")
                    }
                    try fileData.write(to: localDir.appendingPathComponent(item.name), options: .atomic)
                } else if item.type == "dir", !skipDirectories.contains(item.name) {
                    let encodedPath = item.path
                        .split(separator: "/")
                        .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                        .joined(separator: "/")
                    if let subURL = URL(string: "https://api.github.com/repos/\(repo)/contents/\(encodedPath)") {
                        try await downloadDirectory(
                            apiURL: subURL,
                            localDir: localDir.appendingPathComponent(item.name, isDirectory: true),
                            depth: depth + 1
                        )
                    }
                }
            }
        }

        do {
            let rootURL = URL(string: "https://api.github.com/repos/\(repo)/contents")!
            try await downloadDirectory(apiURL: rootURL, localDir: tmpDir, depth: 0)
            var pending = try openFromFolder(tmpDir)
            pending.repo = repo
            pending.version = latestSHA ?? "latest"
            return pending
        } catch {
            try? FileManager.default.removeItem(at: tmpDir)
            throw error
        }
    }

    /// 使用 Compression 流式解压原始 Deflate 流（避免输出缓冲恰满时返回 0 导致静默失败）
    private static func decompressRawDeflate(
        bytes: [UInt8],
        startOffset: Int,
        compressedSize: Int,
        expectedUncompressedSize: Int
    ) throws -> Data {
        if compressedSize == 0 || expectedUncompressedSize == 0 {
            return Data()
        }
        return try bytes.withUnsafeBufferPointer { srcBuffer -> Data in
            guard let base = srcBuffer.baseAddress else {
                throw SourceError.message("Invalid zip buffer")
            }

            let dummyPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
            defer { dummyPtr.deallocate() }
            var stream = compression_stream(
                dst_ptr: dummyPtr,
                dst_size: 0,
                src_ptr: UnsafePointer(dummyPtr),
                src_size: 0,
                state: nil
            )
            let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            guard initStatus != COMPRESSION_STATUS_ERROR else {
                throw SourceError.message("Failed to initialize deflate stream")
            }
            defer { compression_stream_destroy(&stream) }

            stream.src_ptr = base.advanced(by: startOffset)
            stream.src_size = compressedSize

            let chunkSize = max(16384, min(expectedUncompressedSize + 1024, 131072))
            var outChunk = [UInt8](repeating: 0, count: chunkSize)
            var result = Data(capacity: max(expectedUncompressedSize, 0))

            while true {
                let status: compression_status = outChunk.withUnsafeMutableBufferPointer { dstBuffer in
                    stream.dst_ptr = dstBuffer.baseAddress!
                    stream.dst_size = dstBuffer.count
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = chunkSize - stream.dst_size
                if produced > 0 {
                    result.append(contentsOf: outChunk.prefix(produced))
                }
                if status == COMPRESSION_STATUS_END {
                    return result
                }
                if status == COMPRESSION_STATUS_ERROR {
                    throw SourceError.message("Corrupted deflate stream in zip archive")
                }
                if produced == 0 && stream.src_size == 0 {
                    // 部分旧 zip 流尾处理边界：已完成全部输入
                    return result
                }
            }
        }
    }

    /// 纯 Swift + Compression 框架解压 ZIP 数据（兼容 iOS 与 macOS，支持 Stored 与流式 Deflate）
    public static func extractZipData(_ data: Data, into destination: URL) throws {
        let bytes = [UInt8](data)
        let count = bytes.count
        guard count >= 22 else {
            throw SourceError.message("Invalid zip archive")
        }

        func readUInt16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        func readUInt32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }

        // 查找 End of Central Directory Record (0x06054b50)
        var eocdOffset = -1
        let minSearch = max(0, count - 65557)
        for i in stride(from: count - 22, through: minSearch, by: -1) {
            if bytes[i] == 0x50 && bytes[i + 1] == 0x4b && bytes[i + 2] == 0x05 && bytes[i + 3] == 0x06 {
                eocdOffset = i
                break
            }
        }
        guard eocdOffset >= 0 else {
            throw SourceError.message("EOCD not found in zip archive")
        }

        let totalEntries = Int(readUInt16(eocdOffset + 10))
        var cdOffset = Int(readUInt32(eocdOffset + 16))
        guard cdOffset >= 0 && cdOffset <= count else {
            throw SourceError.message("Invalid central directory offset in zip archive")
        }

        for _ in 0..<totalEntries {
            guard cdOffset + 46 <= count, readUInt32(cdOffset) == 0x02014b50 else {
                throw SourceError.message("Malformed central directory entry in zip archive")
            }
            let flags = readUInt16(cdOffset + 8)
            let method = readUInt16(cdOffset + 10)
            let compSize = Int(readUInt32(cdOffset + 20))
            let uncompSize = Int(readUInt32(cdOffset + 24))
            let nameLen = Int(readUInt16(cdOffset + 28))
            let extraLen = Int(readUInt16(cdOffset + 30))
            let commentLen = Int(readUInt16(cdOffset + 32))
            let localHeaderOffset = Int(readUInt32(cdOffset + 42))

            guard cdOffset + 46 + nameLen <= count else {
                throw SourceError.message("Truncated entry name in zip archive")
            }
            let nameBytes = bytes[(cdOffset + 46)..<(cdOffset + 46 + nameLen)]
            let entryName = String(decoding: nameBytes, as: UTF8.self)
            cdOffset += 46 + nameLen + extraLen + commentLen

            // 忽略 macOS 打包附加元数据并防止路径穿越
            if entryName.hasPrefix("__MACOSX/") || entryName == "__MACOSX" {
                continue
            }
            let cleanRel = (entryName as NSString).standardizingPath
            if cleanRel.isEmpty || cleanRel == "." || cleanRel.hasPrefix("/") || cleanRel.contains("..") {
                continue
            }

            let outURL = destination.appendingPathComponent(cleanRel)
            if entryName.hasSuffix("/") {
                try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
                continue
            }

            if (flags & 0x0001) != 0 {
                throw SourceError.message("Encrypted zip archives are not supported")
            }

            guard localHeaderOffset + 30 <= count, readUInt32(localHeaderOffset) == 0x04034b50 else {
                throw SourceError.message("Invalid local header for \(entryName)")
            }
            let localNameLen = Int(readUInt16(localHeaderOffset + 26))
            let localExtraLen = Int(readUInt16(localHeaderOffset + 28))
            let dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen
            guard dataStart >= 0, compSize >= 0, dataStart + compSize <= count else {
                throw SourceError.message("Truncated zip entry data for \(entryName)")
            }

            try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            if method == 0 {
                // Stored (无压缩)
                let slice = Data(bytes[dataStart..<(dataStart + compSize)])
                try slice.write(to: outURL, options: .atomic)
            } else if method == 8 {
                // Deflate (流式解压，避免边界 0 字节静默丢失)
                let outData = try decompressRawDeflate(
                    bytes: bytes,
                    startOffset: dataStart,
                    compressedSize: compSize,
                    expectedUncompressedSize: uncompSize
                )
                try outData.write(to: outURL, options: .atomic)
            } else {
                throw SourceError.message("Unsupported zip compression method \(method) for \(entryName)")
            }
        }
    }

    /// 确认安装插件到 pluginsDir（对应 Pending.Install）
    public static func install(_ pending: PendingPlugin, into pluginsDir: URL, dataRootDir: URL) throws -> JSPluginSource {
        guard isValidPluginID(pending.manifest.id) else {
            throw SourceError.message("Invalid plugin id")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        let dest = pluginsDir.appendingPathComponent(pending.manifest.id, isDirectory: true)
        let staging = pluginsDir.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let backup = pluginsDir.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        try fm.copyItem(at: pending.sourcePath, to: staging)
        if let repo = pending.repo {
            let origin = PluginOrigin(repo: repo, version: pending.version ?? "")
            if let originData = try? JSONEncoder().encode(origin) {
                try? originData.write(to: staging.appendingPathComponent(".origin.json"), options: .atomic)
            }
        }
        let stagedPlugin = try JSPluginSource(pluginDir: staging, dataRootDir: dataRootDir)
        guard stagedPlugin.manifest.id == pending.manifest.id else {
            throw SourceError.message("Plugin id does not match its manifest")
        }

        let hadPrevious = fm.fileExists(atPath: dest.path)
        if hadPrevious { try fm.moveItem(at: dest, to: backup) }
        do {
            try fm.moveItem(at: staging, to: dest)
        } catch {
            if hadPrevious { try? fm.moveItem(at: backup, to: dest) }
            throw error
        }
        if hadPrevious { try? fm.removeItem(at: backup) }
        return try JSPluginSource(pluginDir: dest, dataRootDir: dataRootDir)
    }

    /// 查找包含 plugin.json 的根目录（忽略 __MACOSX，最多向下探查 2 层目录）
    private static func locatePluginRoot(in dir: URL, depth: Int = 0) throws -> URL {
        let direct = dir.appendingPathComponent("plugin.json")
        if FileManager.default.fileExists(atPath: direct.path) {
            return dir
        }
        if depth < 2, let children = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let validDirs = children.filter { url in
                guard url.lastPathComponent != "__MACOSX" else { return false }
                return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            let matching = validDirs.filter {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("plugin.json").path)
            }
            if matching.count == 1 {
                return matching[0]
            }
            if validDirs.count == 1 {
                if let nested = try? locatePluginRoot(in: validDirs[0], depth: depth + 1) {
                    return nested
                }
            }
        }
        throw SourceError.message("plugin.json not found in \(dir.lastPathComponent)")
    }
}

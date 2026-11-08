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
        try? FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dataRootDir, withIntermediateDirectories: true)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var loaded: [JSPluginSource] = []
        let sortedEntries = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for entry in sortedEntries {
            let manifestFile = entry.appendingPathComponent("plugin.json")
            guard FileManager.default.fileExists(atPath: manifestFile.path) else { continue }
            if let plugin = try? JSPluginSource(pluginDir: entry, dataRootDir: dataRootDir) {
                if !loaded.contains(where: { $0.manifest.id == plugin.manifest.id }) {
                    loaded.append(plugin)
                }
            }
        }
        return loaded
    }

    /// 从本地文件夹读取待安装插件（对应 plugin.Open）
    public static func openFromFolder(_ folderURL: URL) throws -> PendingPlugin {
        let root = try locatePluginRoot(in: folderURL)
        let manifestData = try Data(contentsOf: root.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        // 试编译校验
        let tmpData = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpData) }
        _ = try JSPluginSource(pluginDir: root, dataRootDir: tmpData)
        return PendingPlugin(sourcePath: root, manifest: manifest)
    }

    /// 从 GitHub 下载插件（优先下载最新 Release .zip 资产或 zipball，回退到 Contents API，跨平台纯 Swift 解压）
    public static func fetchFromGitHub(repoInput: String) async throws -> PendingPlugin {
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
            var relReq = URLRequest(url: releaseURL)
            relReq.setValue("mygo-music", forHTTPHeaderField: "User-Agent")
            relReq.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if let (relData, relResp) = try? await URLSession.shared.data(for: relReq),
               let http = relResp as? HTTPURLResponse, http.statusCode == 200,
               let release = try? JSONDecoder().decode(GHRelease.self, from: relData) {
                let assets = release.assets ?? []
                let idx = pickAsset(names: assets.map(\.name))
                let zipURLStr: String? = (idx >= 0 && idx < assets.count) ? assets[idx].browser_download_url : release.zipball_url
                if let zipURLStr, let zipURL = URL(string: zipURLStr) {
                    var zipReq = URLRequest(url: zipURL)
                    zipReq.setValue("mygo-music", forHTTPHeaderField: "User-Agent")
                    if let (zipData, zipResp) = try? await URLSession.shared.data(for: zipReq),
                       let zHttp = zipResp as? HTTPURLResponse, (200...299).contains(zHttp.statusCode),
                       (try? extractZipData(zipData, into: tmpDir)) != nil,
                       var pending = try? openFromFolder(tmpDir) {
                        pending.repo = repo
                        pending.version = (release.tag_name ?? "latest").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                        return pending
                    }
                }
            }
        }

        // 2. 回退：通过 GitHub Contents API 拉取仓库顶层与 locales 目录中的插件文件
        let contentsURL = URL(string: "https://api.github.com/repos/\(repo)/contents")!
        var req = URLRequest(url: contentsURL)
        req.setValue("mygo-music", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw SourceError.message("GitHub network error")
        }
        if http.statusCode == 404 {
            throw SourceError.message(I18n.t("There's no such public repository on GitHub"))
        }
        guard http.statusCode == 200 else {
            throw SourceError.message("GitHub answered \(http.statusCode)")
        }

        struct GHContentItem: Decodable {
            let name: String
            let path: String
            let type: String
            let download_url: String?
            let sha: String?
        }

        let items = try JSONDecoder().decode([GHContentItem].self, from: data)
        var version = "latest"
        for item in items {
            if let sha = item.sha, version == "latest" {
                version = String(sha.prefix(8))
            }
            if item.type == "file", let dl = item.download_url, let dlURL = URL(string: dl) {
                let (fileData, _) = try await URLSession.shared.data(from: dlURL)
                try fileData.write(to: tmpDir.appendingPathComponent(item.name))
            } else if item.type == "dir" && (item.name == "locales" || item.name == "dist" || item.name == "src") {
                let subURL = URL(string: "https://api.github.com/repos/\(repo)/contents/\(item.name)")!
                var subReq = URLRequest(url: subURL)
                subReq.setValue("mygo-music", forHTTPHeaderField: "User-Agent")
                if let (subData, _) = try? await URLSession.shared.data(for: subReq),
                   let subItems = try? JSONDecoder().decode([GHContentItem].self, from: subData) {
                    let subDir = tmpDir.appendingPathComponent(item.name, isDirectory: true)
                    try? FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
                    for sub in subItems where sub.type == "file" {
                        if let dl = sub.download_url, let dlURL = URL(string: dl),
                           let (fData, _) = try? await URLSession.shared.data(from: dlURL) {
                            try? fData.write(to: subDir.appendingPathComponent(sub.name))
                        }
                    }
                }
            }
        }

        var pending = try openFromFolder(tmpDir)
        pending.repo = repo
        pending.version = version
        return pending
    }

    /// 纯 Swift + Compression 框架解压 ZIP 数据（兼容 iOS 与 macOS，支持 Stored 与 Deflate）
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

        for _ in 0..<totalEntries {
            guard cdOffset + 46 <= count, readUInt32(cdOffset) == 0x02014b50 else { break }
            let method = readUInt16(cdOffset + 10)
            let compSize = Int(readUInt32(cdOffset + 20))
            let uncompSize = Int(readUInt32(cdOffset + 24))
            let nameLen = Int(readUInt16(cdOffset + 28))
            let extraLen = Int(readUInt16(cdOffset + 30))
            let commentLen = Int(readUInt16(cdOffset + 32))
            let localHeaderOffset = Int(readUInt32(cdOffset + 42))

            guard cdOffset + 46 + nameLen <= count else { break }
            let nameBytes = bytes[(cdOffset + 46)..<(cdOffset + 46 + nameLen)]
            let entryName = String(decoding: nameBytes, as: UTF8.self)
            cdOffset += 46 + nameLen + extraLen + commentLen

            // 防止路径穿越
            let cleanRel = (entryName as NSString).standardizingPath
            if cleanRel.isEmpty || cleanRel == "." || cleanRel.hasPrefix("/") || cleanRel.contains("..") {
                continue
            }

            let outURL = destination.appendingPathComponent(cleanRel)
            if entryName.hasSuffix("/") {
                try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
                continue
            }

            guard localHeaderOffset + 30 <= count, readUInt32(localHeaderOffset) == 0x04034b50 else { continue }
            let localNameLen = Int(readUInt16(localHeaderOffset + 26))
            let localExtraLen = Int(readUInt16(localHeaderOffset + 28))
            let dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen
            guard dataStart + compSize <= count else { continue }

            try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            if method == 0 {
                // Stored (无压缩)
                let slice = Data(bytes[dataStart..<(dataStart + compSize)])
                try slice.write(to: outURL, options: .atomic)
            } else if method == 8 {
                // Deflate
                if uncompSize == 0 {
                    try Data().write(to: outURL, options: .atomic)
                } else {
                    var outBuffer = [UInt8](repeating: 0, count: max(uncompSize, 1))
                    let decodedSize = bytes.withUnsafeBufferPointer { srcPtr -> Int in
                        guard let base = srcPtr.baseAddress else { return 0 }
                        return compression_decode_buffer(
                            &outBuffer,
                            outBuffer.count,
                            base.advanced(by: dataStart),
                            compSize,
                            nil,
                            COMPRESSION_ZLIB
                        )
                    }
                    if decodedSize > 0 {
                        let outData = Data(outBuffer.prefix(decodedSize))
                        try outData.write(to: outURL, options: .atomic)
                    }
                }
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

    /// 查找包含 plugin.json 的根目录
    private static func locatePluginRoot(in dir: URL) throws -> URL {
        let direct = dir.appendingPathComponent("plugin.json")
        if FileManager.default.fileExists(atPath: direct.path) {
            return dir
        }
        if let children = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ), children.count == 1 {
            let sub = children[0]
            if FileManager.default.fileExists(atPath: sub.appendingPathComponent("plugin.json").path) {
                return sub
            }
        }
        throw SourceError.message("plugin.json not found in \(dir.lastPathComponent)")
    }
}

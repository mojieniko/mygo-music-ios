// PluginEngine.swift
// 对应原项目 internal/plugin/plugin.go, host.go, headers.go, source.go 及 moejs WebAPI 运行时
// 使用 Apple 原生 JavaScriptCore 执行 MyGo Music 的 JS/TS 插件

import CommonCrypto
import CryptoKit
@preconcurrency import Dispatch
import Foundation
@preconcurrency import JavaScriptCore
import os

// MARK: - 插件权限与清单结构

/// 插件权限配置（对应 plugin.Permissions）
public struct PluginPermissions: Codable, Hashable, Sendable {
    public var network: [String]?
    public var process: [String]?

    public init(network: [String]? = nil, process: [String]? = nil) {
        self.network = network
        self.process = process
    }

    enum CodingKeys: String, CodingKey {
        case network
        case process
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.network = try container.decodeIfPresent([String].self, forKey: .network)
        if let allBool = try? container.decodeIfPresent(Bool.self, forKey: .process) {
            self.process = allBool ? ["*"] : nil
        } else {
            self.process = try? container.decodeIfPresent([String].self, forKey: .process)
        }
    }

    /// 检查网络权限是否允许访问指定域名（对应 Permissions.reaches）
    public func reaches(host: String) -> Bool {
        let lowerHost = host.lowercased()
        for pattern in (network ?? []) {
            let p = pattern.lowercased()
            if p == "*" || p == lowerHost {
                return true
            }
            if p.hasPrefix("*.") {
                let suffix = String(p.dropFirst(1)) // ".example.com"
                if lowerHost.hasSuffix(suffix) {
                    return true
                }
            }
        }
        return false
    }

    /// 检查网络权限是否覆盖指定模式（对应 Permissions.coversPattern）
    public func coversPattern(_ pattern: String) -> Bool {
        let lowerPattern = pattern.lowercased()
        for h in (network ?? []) {
            let lowerH = h.lowercased()
            if lowerH == "*" || lowerH == lowerPattern {
                return true
            }
            if lowerH.hasPrefix("*.") {
                let stripped = lowerPattern.hasPrefix("*") ? String(lowerPattern.dropFirst()) : lowerPattern
                let suffix = String(lowerH.dropFirst(1))
                if stripped.hasSuffix(suffix) {
                    return true
                }
            }
        }
        return false
    }
}

/// 插件图片/音频请求头规则（对应 plugin.RequestHeaders）
public struct PluginRequestHeaders: Codable, Hashable, Sendable {
    public static let kindImage = "image"
    public static let kindAudio = "audio"

    public var hosts: [String]
    public var kinds: [String]?
    public var headers: [String: String]

    public init(hosts: [String], kinds: [String]? = nil, headers: [String: String]) {
        self.hosts = hosts
        self.kinds = kinds
        self.headers = headers
    }
}

/// 插件清单（对应 plugin.Manifest / plugin.json）
public struct PluginManifest: Codable, Hashable, Sendable {
    public var id: String
    public var name: String?
    public var version: String?
    public var minAppVersion: String?
    public var main: String?
    public var playback: PlaybackMode?
    public var permissions: PluginPermissions?
    public var requestHeaders: [PluginRequestHeaders]?
    public var settings: [PluginSettingSpec]?
    public var navigation: [NavItem]?
    public var repository: String?
    public var homepage: String?

    public init(
        id: String,
        name: String? = nil,
        version: String? = nil,
        minAppVersion: String? = nil,
        main: String? = "index.js",
        playback: PlaybackMode? = .stream,
        permissions: PluginPermissions? = nil,
        requestHeaders: [PluginRequestHeaders]? = nil,
        settings: [PluginSettingSpec]? = nil,
        navigation: [NavItem]? = nil,
        repository: String? = nil,
        homepage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.minAppVersion = minAppVersion
        self.main = main
        self.playback = playback
        self.permissions = permissions
        self.requestHeaders = requestHeaders
        self.settings = settings
        self.navigation = navigation
        self.repository = repository
        self.homepage = homepage
    }
}

/// Web 登录请求参数（对应 plugin.WebSignIn）
public struct WebSignInRequest: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(pluginId ?? "plugin"):\(url)" }
    public var pluginId: String?
    public var pluginName: String?
    public var url: String
    public var cookiesOf: String
    public var until: [String]
    public var userAgent: String?

    public init(
        pluginId: String? = nil,
        pluginName: String? = nil,
        url: String,
        cookiesOf: String,
        until: [String],
        userAgent: String? = nil
    ) {
        self.pluginId = pluginId
        self.pluginName = pluginName
        self.url = url
        self.cookiesOf = cookiesOf
        self.until = until
        self.userAgent = userAgent
    }
}

// MARK: - 加密与哈希辅助函数（对应 host.crypto）

public enum PluginCrypto {
    /// 计算字符串的 MD5 十六进制摘要（对应 host.crypto.md5）
    public static func md5Hex(_ text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-1 十六进制摘要
    public static func sha1Hex(_ text: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 十六进制摘要
    public static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// HMAC-SHA256 十六进制摘要
    public static func hmacSha256Hex(key: String, text: String) -> String {
        let symKey = SymmetricKey(data: Data(key.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: symKey)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// AES-ECB + PKCS#7 填充加密并返回十六进制字符串（对应 host.crypto.aesEcbEncrypt）
    public static func aesEcbEncryptHex(key: String, text: String) throws -> String {
        let keyBytes = Array(key.utf8)
        guard keyBytes.count == kCCKeySizeAES128 || keyBytes.count == kCCKeySizeAES192 || keyBytes.count == kCCKeySizeAES256 else {
            throw SourceError.message("crypto/aes: invalid key size \(keyBytes.count)")
        }
        let inputBytes = Array(text.utf8)
        let outCapacity = inputBytes.count + kCCBlockSizeAES128
        var outBytes = Array<UInt8>(repeating: 0, count: outCapacity)
        var numBytesEncrypted: size_t = 0

        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
            keyBytes,
            keyBytes.count,
            nil,
            inputBytes,
            inputBytes.count,
            &outBytes,
            outCapacity,
            &numBytesEncrypted
        )
        guard status == kCCSuccess else {
            throw SourceError.message("CCCrypt failed with status \(status)")
        }
        return outBytes.prefix(numBytesEncrypted).map { String(format: "%02x", $0) }.joined()
    }

    /// AES-CBC + PKCS#7 填充加密并返回十六进制字符串
    public static func aesCbcEncryptHex(key: String, iv: String, text: String) throws -> String {
        let keyBytes = Array(key.utf8)
        let ivBytes = Array(iv.utf8)
        guard keyBytes.count == kCCKeySizeAES128 || keyBytes.count == kCCKeySizeAES192 || keyBytes.count == kCCKeySizeAES256 else {
            throw SourceError.message("crypto/aes: invalid key size \(keyBytes.count)")
        }
        guard ivBytes.count == kCCBlockSizeAES128 else {
            throw SourceError.message("crypto/aes: invalid iv size \(ivBytes.count)")
        }
        let inputBytes = Array(text.utf8)
        let outCapacity = inputBytes.count + kCCBlockSizeAES128
        var outBytes = Array<UInt8>(repeating: 0, count: outCapacity)
        var numBytesEncrypted: size_t = 0

        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            keyBytes,
            keyBytes.count,
            ivBytes,
            inputBytes,
            inputBytes.count,
            &outBytes,
            outCapacity,
            &numBytesEncrypted
        )
        guard status == kCCSuccess else {
            throw SourceError.message("CCCrypt failed with status \(status)")
        }
        return outBytes.prefix(numBytesEncrypted).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - HTTP Set-Cookie 头部与隔离网络客户端

public enum PluginHTTPUtilities {
    /// 合法 HTTP Cookie 名称字符集（RFC 6265 token）
    private static let cookieNameChars = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~"
    )

    /// 准确拆分被 HTTPURLResponse 合并成逗号分隔的多个 Set-Cookie 头部（保留 Expires 中的日期逗号）
    public static func splitSetCookieHeader(_ combined: String) -> [String] {
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var cookies: [String] = []
        let chars = Array(trimmed)
        var start = 0
        var inQuotes = false
        var escaped = false
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if escaped {
                escaped = false
                i += 1
                continue
            }
            if ch == "\\" && inQuotes {
                escaped = true
                i += 1
                continue
            }
            if ch == "\"" {
                inQuotes.toggle()
                i += 1
                continue
            }
            if !inQuotes && ch == "," {
                if looksLikeCookieStart(chars, from: i + 1) {
                    let piece = String(chars[start..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !piece.isEmpty {
                        cookies.append(piece)
                    }
                    start = i + 1
                }
            }
            i += 1
        }
        let tail = String(chars[start..<chars.count]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            cookies.append(tail)
        }
        return cookies
    }

    /// 判断逗号右侧在到达分号前是否符合 `cookie-name=` 形态（排除 `Wed, 12-Nov-2026 ...` 中的星期逗号）
    private static func looksLikeCookieStart(_ chars: [Character], from index: Int) -> Bool {
        var j = index
        while j < chars.count && (chars[j] == " " || chars[j] == "\t") {
            j += 1
        }
        let nameStart = j
        while j < chars.count {
            let c = chars[j]
            if c == "=" {
                guard j > nameStart else { return false }
                for k in nameStart..<j {
                    guard let scalar = chars[k].unicodeScalars.first,
                          chars[k].unicodeScalars.count == 1,
                          cookieNameChars.contains(scalar) else {
                        return false
                    }
                }
                return true
            }
            if c == ";" || c == "," || c == " " || c == "\t" {
                return false
            }
            j += 1
        }
        return false
    }

    /// 判断 HTTP 响应是否属于纯文本或 JSON 载荷，供 `fetch` 桥接跳过高开销的全量 Base64 冗余编码
    public static func isLikelyTextPayload(contentType: String?, data: Data) -> Bool {
        guard let ct = contentType?.lowercased(), !ct.isEmpty else {
            return false
        }
        let mime = ct.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let textMatch = mime.hasPrefix("text/")
            || mime.contains("json")
            || mime.contains("javascript")
            || mime.contains("ecmascript")
            || mime.contains("xml")
            || mime == "application/x-www-form-urlencoded"
        guard textMatch else { return false }
        // 确保无空字节并可无损转为 UTF-8，以保证 Response.arrayBuffer() 通过 TextEncoder 还原字节一致
        return !data.contains(0) && String(data: data, encoding: .utf8) != nil
    }

    /// 在网络回调线程预处理 HTTP 响应字典，避免占用串行 JS 执行队列
    static func buildFetchResponsePayload(
        urlString: String,
        data: Data?,
        httpResp: HTTPURLResponse?
    ) -> [String: Any] {
        let status = httpResp?.statusCode ?? 200
        let statusText = HTTPURLResponse.localizedString(forStatusCode: status)
        let rawData = data ?? Data()

        var contentType: String?
        var headerEntries: [[String]] = []
        var setCookies: [String] = []
        if let fields = httpResp?.allHeaderFields {
            for (k, v) in fields {
                let name = "\(k)"
                let value = "\(v)"
                let lower = name.lowercased()
                if lower == "content-type" {
                    contentType = value
                }
                if lower == "set-cookie" {
                    let parts = splitSetCookieHeader(value)
                    setCookies.append(contentsOf: parts)
                    for p in parts {
                        headerEntries.append(["set-cookie", p])
                    }
                } else {
                    headerEntries.append([name, value])
                }
            }
        }

        let isText = isLikelyTextPayload(contentType: contentType, data: rawData)
        let text = String(data: rawData, encoding: .utf8)
            ?? String(data: rawData, encoding: .isoLatin1)
            ?? ""

        var payload: [String: Any] = [
            "status": status,
            "statusText": statusText,
            "ok": (200...299).contains(status),
            "url": httpResp?.url?.absoluteString ?? urlString,
            "redirected": (httpResp?.url?.absoluteString ?? urlString) != urlString,
            "text": text,
            "headerEntries": headerEntries,
            "setCookies": setCookies
        ]
        if !isText {
            payload["base64"] = rawData.base64EncodedString()
        }
        return payload
    }
}

/// 隔离 Cookie、可控重定向、支持 AbortController 中止的插件网络传输器
private final class PluginHTTPClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    struct RequestConfig {
        let redirectMode: String // follow | manual | error
        let originalOrigin: String
        let permissions: PluginPermissions
        var rejectedByRedirectMode: Bool = false
        var permissionError: String?
    }

    private let lock = NSLock()
    private var configs: [Int: RequestConfig] = [:]
    private var activeTasks: [String: URLSessionDataTask] = [:]
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    func invalidate() {
        lock.lock()
        let tasks = Array(activeTasks.values)
        activeTasks.removeAll()
        configs.removeAll()
        lock.unlock()
        for t in tasks { t.cancel() }
        session.invalidateAndCancel()
    }

    func abort(requestID: String) {
        lock.lock()
        let task = activeTasks.removeValue(forKey: requestID)
        lock.unlock()
        task?.cancel()
    }

    func perform(
        requestID: String,
        request: URLRequest,
        redirectMode: String,
        permissions: PluginPermissions,
        completion: @escaping @Sendable (Data?, HTTPURLResponse?, Error?) -> Void
    ) {
        let origin = Self.originKey(for: request.url)
        var req = request
        req.httpShouldHandleCookies = false
        req.timeoutInterval = 15

        let taskIDBox = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let task = session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let taskID = taskIDBox.withLock { $0 }
            self.lock.lock()
            let cfg = taskID.flatMap { self.configs.removeValue(forKey: $0) }
            self.activeTasks.removeValue(forKey: requestID)
            self.lock.unlock()

            if let permErr = cfg?.permissionError {
                completion(nil, nil, SourceError.message(permErr))
                return
            }
            if cfg?.rejectedByRedirectMode == true {
                completion(nil, nil, SourceError.message("fetch failed: redirect mode is \"error\""))
                return
            }
            completion(data, response as? HTTPURLResponse, error)
        }

        taskIDBox.withLock { $0 = task.taskIdentifier }
        lock.lock()
        configs[task.taskIdentifier] = RequestConfig(
            redirectMode: redirectMode,
            originalOrigin: origin,
            permissions: permissions
        )
        activeTasks[requestID] = task
        lock.unlock()

        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        guard var cfg = configs[task.taskIdentifier] else {
            lock.unlock()
            completionHandler(request)
            return
        }

        switch cfg.redirectMode {
        case "manual":
            lock.unlock()
            completionHandler(nil)
            return
        case "error":
            cfg.rejectedByRedirectMode = true
            configs[task.taskIdentifier] = cfg
            lock.unlock()
            completionHandler(nil)
            return
        default:
            // follow 模式：每次重定向必须重新核验网络权限；跨域跳转剥离 Cookie 与 Authorization
            if let targetHost = request.url?.host?.lowercased(), !cfg.permissions.reaches(host: targetHost) {
                cfg.permissionError = "fetch redirect to \(targetHost) is not allowed by plugin network permissions"
                configs[task.taskIdentifier] = cfg
                lock.unlock()
                completionHandler(nil)
                return
            }
            let newOrigin = Self.originKey(for: request.url)
            lock.unlock()

            var nextRequest = request
            nextRequest.httpShouldHandleCookies = false
            if newOrigin != cfg.originalOrigin {
                nextRequest.setValue(nil, forHTTPHeaderField: "Authorization")
                nextRequest.setValue(nil, forHTTPHeaderField: "Cookie")
            }
            completionHandler(nextRequest)
        }
    }

    private static func originKey(for url: URL?) -> String {
        guard let url else { return "" }
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}

// MARK: - ES Module 与 TypeScript 词法转译及本地模块打包器

/// 将插件中的 TypeScript 与 ES Module 语法安全转换为 JavaScriptCore 可执行的脚本，支持本地相对模块打包
public enum PluginModuleTranspiler {
    public struct TranspiledModule: Codable, Sendable {
        public let code: String
        public let exports: Set<String>
    }

    private static let transpilerCacheVersion = 3

    private struct FileStamp: Codable, Equatable {
        let relativePath: String
        let mtimeMillis: Int64
        let size: Int64
    }

    private struct CachedTranspiledBundle: Codable {
        let version: Int
        let entryPath: String
        let files: [FileStamp]
        let module: TranspiledModule
    }

    /// 扫描单文件并转换为可运行 JS（兼容无本地 import 场景与直接代码转译测试）
    public static func transpile(_ source: String, isTypeScript: Bool = false) -> TranspiledModule {
        let stripped = preprocessTypeScriptIfNeeded(source, force: isTypeScript)
        let rewritten = rewriteESM(stripped, isRoot: true, moduleResolver: nil)
        var footer = "\nglobalThis.__exports = globalThis.__exports || {};\n"
        for name in rewritten.exports.sorted() {
            footer += "if (typeof \(name) !== 'undefined') { globalThis.__exports[\"\(name)\"] = \(name); }\n"
        }
        for assign in rewritten.aliasAssignments {
            footer += assign + "\n"
        }
        let finalCode = "(function() {\n" + rewritten.code + "\n" + footer + "})();"
        return TranspiledModule(code: finalCode, exports: rewritten.exports)
    }

    /// 从插件入口文件打包主模块及其引用的本地相对模块（防路径穿越并处理循环引用）
    public static func bundleEntry(entryURL: URL, pluginDir: URL) throws -> TranspiledModule {
        let canonicalRoot = pluginDir.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalEntry = entryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard isInsideDirectory(canonicalEntry, root: canonicalRoot) else {
            throw SourceError.message("main must reside inside plugin directory")
        }

        var moduleIDMap: [URL: String] = [:]
        var moduleFactories: [String] = []
        var nextID = 0

        func compileFile(_ fileURL: URL, isRoot: Bool) throws -> (id: String, exports: Set<String>) {
            let resolved = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            guard isInsideDirectory(resolved, root: canonicalRoot) else {
                throw SourceError.message("import escapes plugin directory: \(fileURL.lastPathComponent)")
            }
            if let existingID = moduleIDMap[resolved], !isRoot {
                return (existingID, [])
            }

            let modID = isRoot ? "__entry" : "__mod_\(nextID)"
            if !isRoot {
                nextID += 1
                moduleIDMap[resolved] = modID
            }

            if resolved.pathExtension.lowercased() == "json" {
                let rawJSON = try String(contentsOf: resolved, encoding: .utf8)
                moduleFactories.append("""
                __factories["\(modID)"] = function(__modExports) {
                    __modExports.default = \(rawJSON);
                    if (__modExports.default && typeof __modExports.default === 'object' && !Array.isArray(__modExports.default)) {
                        Object.assign(__modExports, __modExports.default);
                    }
                };
                """)
                return (modID, ["default"])
            }

            let rawSource = try String(contentsOf: resolved, encoding: .utf8)
            let isTS = ["ts", "mts", "tsx"].contains(resolved.pathExtension.lowercased())
            let stripped = preprocessTypeScriptIfNeeded(rawSource, force: isTS)

            var resolverError: Error?
            let currentDir = resolved.deletingLastPathComponent()
            let rewritten = rewriteESM(stripped, isRoot: isRoot) { spec -> String? in
                do {
                    guard let targetURL = try resolveLocalModule(spec, from: currentDir, root: canonicalRoot) else {
                        return nil
                    }
                    let dep = try compileFile(targetURL, isRoot: false)
                    return dep.id
                } catch {
                    resolverError = error
                    return nil
                }
            }
            if let resolverError {
                throw resolverError
            }

            var exportFooter = ""
            let targetObj = isRoot ? "globalThis.__exports" : "__modExports"
            for name in rewritten.exports.sorted() {
                exportFooter += "if (typeof \(name) !== 'undefined') { \(targetObj)[\"\(name)\"] = \(name); }\n"
            }
            for assign in rewritten.aliasAssignments {
                exportFooter += assign.replacingOccurrences(of: "globalThis.__exports", with: targetObj) + "\n"
            }

            guard !isRoot else {
                return (modID, rewritten.exports)
            }
            moduleFactories.append("""
            __factories["\(modID)"] = function(__modExports) {
            \(rewritten.code)
            \(exportFooter)
            };
            """)
            return (modID, rewritten.exports)
        }

        // 先编译依赖模块收集所有 factories，再组装完整入口脚本
        let resolvedEntry = canonicalEntry
        let rawEntry = try String(contentsOf: resolvedEntry, encoding: .utf8)
        let entryIsTS = ["ts", "mts", "tsx"].contains(resolvedEntry.pathExtension.lowercased())
        let strippedEntry = preprocessTypeScriptIfNeeded(rawEntry, force: entryIsTS)

        var entryResolveError: Error?
        let entryDir = resolvedEntry.deletingLastPathComponent()
        let entryRewritten = rewriteESM(strippedEntry, isRoot: true) { spec -> String? in
            do {
                guard let targetURL = try resolveLocalModule(spec, from: entryDir, root: canonicalRoot) else {
                    return nil
                }
                let dep = try compileFile(targetURL, isRoot: false)
                return dep.id
            } catch {
                entryResolveError = error
                return nil
            }
        }
        if let entryResolveError {
            throw entryResolveError
        }

        var footer = "\nglobalThis.__exports = globalThis.__exports || {};\n"
        for name in entryRewritten.exports.sorted() {
            footer += "if (typeof \(name) !== 'undefined') { globalThis.__exports[\"\(name)\"] = \(name); }\n"
        }
        for assign in entryRewritten.aliasAssignments {
            footer += assign + "\n"
        }

        let prelude: String
        if moduleFactories.isEmpty {
            prelude = ""
        } else {
            prelude = """
            var __factories = {};
            var __cache = {};
            function __requireLocal(id) {
                if (__cache[id]) return __cache[id];
                var exp = {};
                __cache[id] = exp;
                if (__factories[id]) __factories[id](exp);
                return exp;
            }
            \(moduleFactories.joined(separator: "\n"))
            """
        }

        let finalCode = "(function() {\n" + prelude + "\n" + entryRewritten.code + "\n" + footer + "})();"
        return TranspiledModule(code: finalCode, exports: entryRewritten.exports)
    }

    /// 带磁盘指纹缓存的插件打包入口：插件脚本/JSON 未变动时直接复用已转译 JS，避免冷启动重复扫描
    public static func bundleEntryCached(
        entryURL: URL,
        pluginDir: URL,
        cacheFileURL: URL
    ) throws -> TranspiledModule {
        let canonicalRoot = pluginDir.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalEntry = entryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard isInsideDirectory(canonicalEntry, root: canonicalRoot) else {
            throw SourceError.message("main must reside inside plugin directory")
        }

        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        let entryRelPath: String
        if canonicalEntry.path.hasPrefix(rootPrefix) {
            entryRelPath = String(canonicalEntry.path.dropFirst(rootPrefix.count))
        } else {
            entryRelPath = canonicalEntry.lastPathComponent
        }

        let currentStamps = collectPluginFileStamps(in: canonicalRoot, rootPrefix: rootPrefix)
        if !currentStamps.isEmpty,
           let cacheData = try? Data(contentsOf: cacheFileURL),
           let cached = try? JSONDecoder().decode(CachedTranspiledBundle.self, from: cacheData),
           cached.version == transpilerCacheVersion,
           cached.entryPath == entryRelPath,
           cached.files == currentStamps {
            return cached.module
        }

        let compiled = try bundleEntry(entryURL: entryURL, pluginDir: pluginDir)
        if !currentStamps.isEmpty {
            let bundle = CachedTranspiledBundle(
                version: transpilerCacheVersion,
                entryPath: entryRelPath,
                files: currentStamps,
                module: compiled
            )
            if let encoded = try? JSONEncoder().encode(bundle) {
                try? FileManager.default.createDirectory(
                    at: cacheFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? encoded.write(to: cacheFileURL, options: .atomic)
            }
        }
        return compiled
    }

    private static func collectPluginFileStamps(in canonicalRoot: URL, rootPrefix: String) -> [FileStamp] {
        let fm = FileManager.default
        let watchedExts: Set<String> = ["js", "mjs", "cjs", "ts", "mts", "tsx", "json"]
        guard let enumerator = fm.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var stamps: [FileStamp] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard watchedExts.contains(ext) else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            let resolvedPath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
            let relPath = resolvedPath.hasPrefix(rootPrefix)
                ? String(resolvedPath.dropFirst(rootPrefix.count))
                : fileURL.lastPathComponent
            let mtimeMillis = Int64(((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000).rounded())
            let size = Int64(values.fileSize ?? 0)
            stamps.append(FileStamp(relativePath: relPath, mtimeMillis: mtimeMillis, size: size))
        }
        stamps.sort { $0.relativePath < $1.relativePath }
        return stamps
    }

    private static func isInsideDirectory(_ url: URL, root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(rootPath)
    }

    private static func resolveLocalModule(_ spec: String, from dir: URL, root: URL) throws -> URL? {
        guard spec.hasPrefix("./") || spec.hasPrefix("../") || spec.hasPrefix("/") else {
            return nil
        }
        let fm = FileManager.default
        let base = spec.hasPrefix("/") ? root.appendingPathComponent(String(spec.dropFirst())) : dir.appendingPathComponent(spec)
        let ext = base.pathExtension.lowercased()

        var candidates: [URL] = [base]
        // 处理 TS 源码中常见 `import ... from "./api.js"` 实际对应 `./api.ts` 的情况
        if ext == "js" || ext == "mjs" {
            let noExt = base.deletingPathExtension()
            candidates.append(noExt.appendingPathExtension("ts"))
            candidates.append(noExt.appendingPathExtension("mts"))
            candidates.append(noExt.appendingPathExtension("js"))
            candidates.append(noExt.appendingPathExtension("mjs"))
        } else if ext.isEmpty {
            for suffix in ["ts", "js", "mjs", "json"] {
                candidates.append(base.appendingPathExtension(suffix))
            }
            for idx in ["index.ts", "index.js", "index.mjs"] {
                candidates.append(base.appendingPathComponent(idx))
            }
        }

        for cand in candidates {
            let resolved = cand.standardizedFileURL.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue {
                guard isInsideDirectory(resolved, root: root) else {
                    throw SourceError.message("import escapes plugin directory: \(spec)")
                }
                return resolved
            }
        }
        throw SourceError.message("Cannot find module '\(spec)'")
    }

    // MARK: - 词法掩码与 ESM/TS 安全转换

    private struct LexicalMask {
        /// 源码字符数组与每个字符是否位于可执行代码区（非字符串/模板纯字面量/注释/正则）
        let chars: [Character]
        let isCode: [Bool]
        /// 一次遍历建立 UTF-16 偏移到字符索引的 O(1) 查表，避免正则循环内反复执行 O(N) distance 计算
        private let utf16ToChar: [Int]

        init(_ source: String) {
            var arr: [Character] = []
            arr.reserveCapacity(source.utf16.count)
            var u16Map: [Int] = []
            u16Map.reserveCapacity(source.utf16.count + 1)
            var charIdx = 0
            for ch in source {
                arr.append(ch)
                let unitCount = ch.utf16.count
                for _ in 0..<unitCount {
                    u16Map.append(charIdx)
                }
                charIdx += 1
            }
            u16Map.append(charIdx)

            let n = arr.count
            var codeFlags = [Bool](repeating: true, count: n)

            enum State {
                case code
                case singleQuote
                case doubleQuote
                case lineComment
                case blockComment
                case regex
                case templateLiteral(braceStack: [Int])
            }

            var state: State = .code
            var templateBraceDepths: [Int] = [] // 记录每个 `${...}` 打开前的花括号嵌套计数
            var currentBraceDepth = 0
            var canStartRegex = true
            var regexInClass = false

            var i = 0
            while i < n {
                let c = arr[i]
                let next: Character? = (i + 1 < n) ? arr[i + 1] : nil

                switch state {
                case .code:
                    if c == "/" && next == "/" {
                        codeFlags[i] = false
                        codeFlags[i + 1] = false
                        state = .lineComment
                        i += 2
                        continue
                    }
                    if c == "/" && next == "*" {
                        codeFlags[i] = false
                        codeFlags[i + 1] = false
                        state = .blockComment
                        i += 2
                        continue
                    }
                    if c == "'" {
                        codeFlags[i] = false
                        state = .singleQuote
                        canStartRegex = false
                        i += 1
                        continue
                    }
                    if c == "\"" {
                        codeFlags[i] = false
                        state = .doubleQuote
                        canStartRegex = false
                        i += 1
                        continue
                    }
                    if c == "`" {
                        codeFlags[i] = false
                        state = .templateLiteral(braceStack: [])
                        canStartRegex = false
                        i += 1
                        continue
                    }
                    if c == "/" && canStartRegex {
                        codeFlags[i] = false
                        regexInClass = false
                        state = .regex
                        canStartRegex = false
                        i += 1
                        continue
                    }

                    // 跟踪 `${ ... }` 表达式内花括号回归模板态
                    if !templateBraceDepths.isEmpty {
                        if c == "{" {
                            currentBraceDepth += 1
                        } else if c == "}" {
                            if currentBraceDepth == templateBraceDepths.last {
                                templateBraceDepths.removeLast()
                                currentBraceDepth -= 1
                                codeFlags[i] = false
                                state = .templateLiteral(braceStack: templateBraceDepths)
                                canStartRegex = false
                                i += 1
                                continue
                            } else {
                                currentBraceDepth = max(0, currentBraceDepth - 1)
                            }
                        }
                    }

                    if !c.isWhitespace {
                        if let u = c.unicodeScalars.first, c.unicodeScalars.count == 1,
                           CharacterSet.alphanumerics.contains(u) || c == "_" || c == "$" || c == ")" || c == "]" {
                            // 若前置关键词为 return / throw / case / typeof / await / yield / delete / void / in / of / new 等，仍可跟正则
                            let wordBefore = Self.precedingIdentifier(arr, endingAt: i)
                            let regexKeywords: Set<String> = ["return", "throw", "case", "typeof", "await", "yield", "delete", "void", "in", "of", "new", "else", "do"]
                            canStartRegex = (c != ")" && c != "]") ? regexKeywords.contains(wordBefore) : false
                        } else if c == "+" && i > 0 && arr[i - 1] == "+" {
                            canStartRegex = false
                        } else if c == "-" && i > 0 && arr[i - 1] == "-" {
                            canStartRegex = false
                        } else {
                            canStartRegex = true
                        }
                    }
                    i += 1

                case .lineComment:
                    codeFlags[i] = false
                    if c == "\n" {
                        state = .code
                    }
                    i += 1

                case .blockComment:
                    codeFlags[i] = false
                    if c == "*" && next == "/" {
                        codeFlags[i + 1] = false
                        state = .code
                        i += 2
                        continue
                    }
                    i += 1

                case .singleQuote:
                    codeFlags[i] = false
                    if c == "\\" && i + 1 < n {
                        codeFlags[i + 1] = false
                        i += 2
                        continue
                    }
                    if c == "'" || c == "\n" {
                        state = .code
                    }
                    i += 1

                case .doubleQuote:
                    codeFlags[i] = false
                    if c == "\\" && i + 1 < n {
                        codeFlags[i + 1] = false
                        i += 2
                        continue
                    }
                    if c == "\"" || c == "\n" {
                        state = .code
                    }
                    i += 1

                case .regex:
                    codeFlags[i] = false
                    if c == "\\" && i + 1 < n {
                        codeFlags[i + 1] = false
                        i += 2
                        continue
                    }
                    if c == "[" {
                        regexInClass = true
                    } else if c == "]" {
                        regexInClass = false
                    } else if c == "/" && !regexInClass {
                        state = .code
                    } else if c == "\n" {
                        state = .code
                    }
                    i += 1

                case .templateLiteral:
                    codeFlags[i] = false
                    if c == "\\" && i + 1 < n {
                        codeFlags[i + 1] = false
                        i += 2
                        continue
                    }
                    if c == "$" && next == "{" {
                        codeFlags[i + 1] = false
                        currentBraceDepth += 1
                        templateBraceDepths.append(currentBraceDepth)
                        state = .code
                        canStartRegex = true
                        i += 2
                        continue
                    }
                    if c == "`" {
                        state = .code
                    }
                    i += 1
                }
            }

            self.chars = arr
            self.isCode = codeFlags
            self.utf16ToChar = u16Map
        }

        func charOffset(forUTF16Offset u16Offset: Int) -> Int {
            guard !utf16ToChar.isEmpty else { return 0 }
            let clamped = min(max(u16Offset, 0), utf16ToChar.count - 1)
            return utf16ToChar[clamped]
        }

        private static func precedingIdentifier(_ chars: [Character], endingAt idx: Int) -> String {
            let end = idx
            var start = idx
            while start >= 0 {
                let c = chars[start]
                if c.isLetter || c.isNumber || c == "_" || c == "$" {
                    start -= 1
                } else {
                    break
                }
            }
            if start < end {
                return String(chars[(start + 1)...end])
            }
            return ""
        }
    }

    private struct ESMRewriteResult {
        let code: String
        let exports: Set<String>
        let aliasAssignments: [String]
    }

    private static func rewriteESM(
        _ source: String,
        isRoot: Bool,
        moduleResolver: ((String) -> String?)?
    ) -> ESMRewriteResult {
        var working = source
        var exports = Set<String>()
        var aliasAssignments: [String] = []
        let targetExportsObj = isRoot ? "globalThis.__exports" : "__modExports"

        // 先构造词法掩码保证只改写真正代码位置，避免误伤字符串和注释中的 export/import
        func applySafeCodeRegex(_ pattern: String, transform: ([Substring], String) -> String?) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let mask = LexicalMask(working)
            let ns = working as NSString
            let matches = regex.matches(in: working, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return }

            // 从后往前替换保持偏移有效
            var result = working
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result) else { continue }
                let charOffset = mask.charOffset(forUTF16Offset: match.range.location)
                // 检查匹配起始第一个非空白字符是否在代码区
                var probe = charOffset
                while probe < mask.chars.count && mask.chars[probe].isWhitespace {
                    probe += 1
                }
                guard probe < mask.isCode.count && mask.isCode[probe] else { continue }

                var groups: [Substring] = []
                for idx in 0..<match.numberOfRanges {
                    let r = match.range(at: idx)
                    if r.location != NSNotFound, let sr = Range(r, in: result) {
                        groups.append(result[sr])
                    } else {
                        groups.append(result[fullRange.lowerBound..<fullRange.lowerBound])
                    }
                }
                if let replacement = transform(groups, String(result[fullRange])) {
                    result.replaceSubrange(fullRange, with: replacement)
                }
            }
            working = result
        }

        // 1. 处理本地 import 语句（若存在打包解析器）
        if let moduleResolver {
            // 1a. import { a, b as c } from './x.js';
            applySafeCodeRegex(#"(?ms)^[ \t]*import[ \t]+\{([^}]*)\}[ \t]+from[ \t]+['"]([^'"]+)['"][ \t]*;?"#) { groups, original in
                let spec = String(groups[2])
                guard let modID = moduleResolver(spec) else { return nil }
                let pairs = parseNamedSpecifiers(String(groups[1]))
                let props = pairs.map { $0.local == $0.exported ? $0.local : "\($0.exported): \($0.local)" }.joined(separator: ", ")
                return props.isEmpty ? "__requireLocal(\"\(modID)\");" : "const { \(props) } = __requireLocal(\"\(modID)\");"
            }

            // 1b. import * as ns from './x.js';
            applySafeCodeRegex(#"(?m)^[ \t]*import[ \t]+\*[ \t]+as[ \t]+([A-Za-z0-9_$]+)[ \t]+from[ \t]+['"]([^'"]+)['"][ \t]*;?"#) { groups, _ in
                let ns = String(groups[1])
                let spec = String(groups[2])
                guard let modID = moduleResolver(spec) else { return nil }
                return "const \(ns) = __requireLocal(\"\(modID)\");"
            }

            // 1c. import def from './x.js';
            applySafeCodeRegex(#"(?m)^[ \t]*import[ \t]+([A-Za-z0-9_$]+)[ \t]+from[ \t]+['"]([^'"]+)['"][ \t]*;?"#) { groups, _ in
                let name = String(groups[1])
                let spec = String(groups[2])
                guard let modID = moduleResolver(spec) else { return nil }
                return "const \(name) = __requireLocal(\"\(modID)\").default ?? __requireLocal(\"\(modID)\");"
            }

            // 1d. import './x.js'; (纯副作用)
            applySafeCodeRegex(#"(?m)^[ \t]*import[ \t]+['"]([^'"]+)['"][ \t]*;?"#) { groups, _ in
                let spec = String(groups[1])
                guard let modID = moduleResolver(spec) else { return nil }
                return "__requireLocal(\"\(modID)\");"
            }

            // 1e. export { a, b as c } from './x.js';
            applySafeCodeRegex(#"(?ms)^[ \t]*export[ \t]+\{([^}]*)\}[ \t]+from[ \t]+['"]([^'"]+)['"][ \t]*;?"#) { groups, _ in
                let spec = String(groups[2])
                guard let modID = moduleResolver(spec) else { return nil }
                let pairs = parseNamedSpecifiers(String(groups[1]))
                var stmts: [String] = []
                for p in pairs {
                    exports.insert(p.exported)
                    stmts.append("\(targetExportsObj)[\"\(p.exported)\"] = __requireLocal(\"\(modID)\")[\"\(p.local)\"];")
                }
                return stmts.joined(separator: " ")
            }

            // 1f. export * from './x.js';
            applySafeCodeRegex(#"(?m)^[ \t]*export[ \t]+\*[ \t]+from[ \t]+['"]([^'"]+)['"][ \t]*;?"#) { groups, _ in
                let spec = String(groups[1])
                guard let modID = moduleResolver(spec) else { return nil }
                return "Object.assign(\(targetExportsObj), __requireLocal(\"\(modID)\"));"
            }
        }

        // 2. export async function name / export function* name / export function name
        applySafeCodeRegex(#"(?m)^[ \t]*export[ \t]+(async[ \t]+)?function(\*[ \t]*|[ \t]+)([A-Za-z0-9_$]+)"#) { groups, _ in
            let asyncKw = groups[1].isEmpty ? "" : "async "
            let starOrSpace = String(groups[2]).contains("*") ? "* " : " "
            let name = String(groups[3])
            exports.insert(name)
            return "\(asyncKw)function\(starOrSpace)\(name)"
        }

        // 3. export class Name
        applySafeCodeRegex(#"(?m)^[ \t]*export[ \t]+class[ \t]+([A-Za-z0-9_$]+)"#) { groups, _ in
            let name = String(groups[1])
            exports.insert(name)
            return "class \(name)"
        }

        // 4. export const/let/var name = ... 或 export const { a, b } = ...
        applySafeCodeRegex(#"(?m)^[ \t]*export[ \t]+(const|let|var)[ \t]+([A-Za-z0-9_$]+)"#) { groups, _ in
            let decl = String(groups[1])
            let name = String(groups[2])
            exports.insert(name)
            return "\(decl) \(name)"
        }
        applySafeCodeRegex(#"(?m)^[ \t]*export[ \t]+(const|let|var)[ \t]+\{([^}]+)\}"#) { groups, _ in
            let decl = String(groups[1])
            let inner = String(groups[2])
            for spec in parseNamedSpecifiers(inner) {
                exports.insert(spec.exported)
            }
            return "\(decl) {\(inner)}"
        }

        // 5. export default ...
        applySafeCodeRegex(#"(?m)^[ \t]*export[ \t]+default[ \t]+(?:(async[ \t]+)?function(\*[ \t]*|[ \t]*)([A-Za-z0-9_$]*))"#) { groups, original in
            let asyncKw = groups[1].isEmpty ? "" : "async "
            let star = String(groups[2]).contains("*") ? "* " : " "
            let name = String(groups[3])
            exports.insert("default")
            if !name.isEmpty {
                aliasAssignments.append("\(targetExportsObj)[\"default\"] = \(name);")
                return "\(asyncKw)function\(star)\(name)"
            }
            return "\(targetExportsObj)[\"default\"] = \(asyncKw)function\(star)"
        }
        applySafeCodeRegex(#"(?m)^[ \t]*export[ \t]+default[ \t]+"#) { _, _ in
            exports.insert("default")
            return "\(targetExportsObj)[\"default\"] = "
        }

        // 6. export { a, b as c } (支持多行与尾逗号，放在 from 处理之后避免误吞 export ... from)
        applySafeCodeRegex(#"(?ms)^[ \t]*export[ \t]*\{([^}]*)\}[ \t]*;?"#) { groups, _ in
            let pairs = parseNamedSpecifiers(String(groups[1]))
            for pair in pairs {
                exports.insert(pair.exported)
                aliasAssignments.append("\(targetExportsObj)[\"\(pair.exported)\"] = \(pair.local);")
            }
            return ""
        }

        return ESMRewriteResult(code: working, exports: exports, aliasAssignments: aliasAssignments)
    }

    private static func parseNamedSpecifiers(_ body: String) -> [(local: String, exported: String)] {
        let cleaned = body
            .replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        var out: [(String, String)] = []
        for rawItem in cleaned.split(separator: ",") {
            let item = rawItem.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.isEmpty { continue }
            if item.hasPrefix("type ") { continue } // TS inline type specifier
            // 支持 destructuring 重命名 `a: b` 和 ESM 别名 `a as b`
            if let asRange = item.range(of: #"\s+as\s+"#, options: .regularExpression) {
                let local = String(item[..<asRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let exported = String(item[asRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !local.isEmpty && !exported.isEmpty {
                    out.append((local, exported))
                }
            } else if let colonRange = item.range(of: ":") {
                let key = String(item[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let val = String(item[colonRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty && !val.isEmpty {
                    out.append((val, val))
                }
            } else {
                out.append((item, item))
            }
        }
        return out
    }

    // MARK: - 轻量化 TypeScript 类型剥离器

    private static func preprocessTypeScriptIfNeeded(_ source: String, force: Bool) -> String {
        let hasTSMarkers = force
            || source.contains("import type ")
            || source.contains("export type ")
            || source.contains("export interface ")
            || source.range(of: #"(?m)^\s*(interface|type|declare)\s+[A-Z]"#, options: .regularExpression) != nil
        guard hasTSMarkers else { return source }

        var code = source
        // 移除 import type ... / export type ... / interface ... { ... } / 多行 type Foo = { ... } 顶层类型定义
        let mask = LexicalMask(code)
        code = stripBalancedTopLevelTypeBlocks(code, mask: mask)
        // 剥离函数/方法/箭头函数的参数内联对象类型、参数类型、返回类型（含对象返回值）与函数声明泛型 <T>
        code = stripBalancedFunctionSignatures(code)

        let cleanPatterns: [(String, String)] = [
            // 移除 import { type A, b } 中的 `type ` 修饰符
            (#"(?m)\btype\s+(?=[A-Za-z0-9_$]+\s*(?:,|\}|as\b))"#, ""),
            // 移除 export type ... ; 或 export interface ... ; 单行
            (#"(?m)^[ \t]*export\s+type\s+[^;\n]+;?"#, ""),
            (#"(?m)^[ \t]*type\s+[A-Za-z0-9_$]+(?:<[^>\n]+>)?\s*=\s*[^;\n]+;?"#, ""),
            // 擦除常见 `as const` / `as unknown as T` / `as Foo<Bar>` / `as Foo | null`
            (#"\s+as\s+(?:const|unknown|any|never|void|string|number|boolean|[A-Z][A-Za-z0-9_$.]*(?:<[^()>;\n]+>)?(?:\[\])*(?:\s*\|\s*(?:null|undefined|[A-Z][A-Za-z0-9_$.]*))*)"#, ""),
            // 擦除变量/属性上的简单类型标注 `const x: Foo =`
            (#"(\b(?:const|let|var)\s+[A-Za-z_$][A-Za-z0-9_$]*)\s*:\s*[A-Za-z0-9_$.|&\[\]<>,'\s?]+(?==)"#, "$1 "),
            // 擦除泛型调用 `<Foo<Bar>>(` 或 `<ApiStatus & T>(`（避免误伤 `a < b` 比较运算，要求左邻接合法标识符且右紧邻 `(`）
            (#"(\b[A-Za-z_$][A-Za-z0-9_$]*)<(?:[^()<>\n;=]|<[^()<>\n;=]*>)+>\s*\("#, "$1(")
        ]

        for (pattern, replacement) in cleanPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                code = applyRegexOutsideNonCode(code, regex: regex, template: replacement)
            }
        }
        return code
    }

    /// 精确剥离函数/方法/箭头函数的 TypeScript 参数类型（含 `{ a: string }` 内联对象、解构参数标注）、返回类型及函数泛型 `<T>`
    private static func stripBalancedFunctionSignatures(_ source: String) -> String {
        let mask = LexicalMask(source)
        let chars = mask.chars
        let isCode = mask.isCode
        let n = chars.count
        guard n > 0 else { return source }

        func skipWSForward(_ idx: Int) -> Int {
            var i = idx
            while i < n && chars[i].isWhitespace { i += 1 }
            return i
        }
        func skipWSBackward(_ idx: Int) -> Int {
            var i = idx
            while i >= 0 && chars[i].isWhitespace { i -= 1 }
            return i
        }
        func isIdentChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == "$"
        }
        func prevWordRange(before idx: Int) -> (word: String, start: Int)? {
            let end = skipWSBackward(idx)
            guard end >= 0, isCode[end], isIdentChar(chars[end]) else { return nil }
            var start = end
            while start > 0 && isCode[start - 1] && isIdentChar(chars[start - 1]) {
                start -= 1
            }
            return (String(chars[start...end]), start)
        }
        func findMatchingClose(openIdx: Int, openCh: Character, closeCh: Character) -> Int? {
            var depth = 0
            var i = openIdx
            while i < n {
                if isCode[i] {
                    if chars[i] == openCh { depth += 1 }
                    else if chars[i] == closeCh {
                        depth -= 1
                        if depth == 0 { return i }
                    }
                }
                i += 1
            }
            return nil
        }
        func isLikelyTernaryTrueBranch(leftParen: Int) -> Bool {
            var i = leftParen - 1
            var pDepth = 0
            var bDepth = 0
            var sDepth = 0
            while i >= 0 {
                if isCode[i] {
                    let c = chars[i]
                    if c == ")" { pDepth += 1 }
                    else if c == "(" {
                        if pDepth == 0 { return false }
                        pDepth -= 1
                    } else if c == "}" { bDepth += 1 }
                    else if c == "{" {
                        if bDepth == 0 { return false }
                        bDepth -= 1
                    } else if c == "]" { sDepth += 1 }
                    else if c == "[" {
                        if sDepth == 0 { return false }
                        sDepth -= 1
                    } else if pDepth == 0 && bDepth == 0 && sDepth == 0 {
                        if c == "?" { return true }
                        if c == ";" || c == "=" || c == "," || c == ":" { return false }
                    }
                }
                i -= 1
            }
            return false
        }
        func scanReturnTypeEnd(colonIdx: Int) -> Int? {
            var i = skipWSForward(colonIdx + 1)
            var sawNonBraceToken = false
            var pDepth = 0
            var sDepth = 0
            var aDepth = 0
            while i < n {
                if !isCode[i] {
                    i += 1
                    continue
                }
                let c = chars[i]
                if c.isWhitespace {
                    i += 1
                    continue
                }
                if pDepth == 0 && sDepth == 0 && aDepth == 0 {
                    if c == "=" && i + 1 < n && isCode[i + 1] && chars[i + 1] == ">" {
                        return i
                    }
                    if c == "{" {
                        if let closeB = findMatchingClose(openIdx: i, openCh: "{", closeCh: "}") {
                            let afterB = skipWSForward(closeB + 1)
                            if afterB < n && isCode[afterB] {
                                let nc = chars[afterB]
                                if nc == "|" || nc == "&" || nc == "[" {
                                    sawNonBraceToken = true
                                    i = closeB + 1
                                    continue
                                }
                                if nc == "{" {
                                    return afterB
                                }
                                if nc == "=" && afterB + 1 < n && isCode[afterB + 1] && chars[afterB + 1] == ">" {
                                    return afterB
                                }
                            }
                        }
                        return sawNonBraceToken ? i : nil
                    }
                    if c == ";" || c == ")" || c == "]" || c == "}" || c == "," || c == "=" {
                        return nil
                    }
                    if c == "(" {
                        sawNonBraceToken = true
                        pDepth += 1
                        i += 1
                        continue
                    }
                    if c == "[" {
                        sawNonBraceToken = true
                        sDepth += 1
                        i += 1
                        continue
                    }
                    if c == "<" {
                        sawNonBraceToken = true
                        aDepth += 1
                        i += 1
                        continue
                    }
                    sawNonBraceToken = true
                    i += 1
                    continue
                }
                if c == "(" { pDepth += 1 }
                else if c == ")" && pDepth > 0 { pDepth -= 1 }
                else if c == "[" { sDepth += 1 }
                else if c == "]" && sDepth > 0 { sDepth -= 1 }
                else if c == "<" { aDepth += 1 }
                else if c == ">" && aDepth > 0 {
                    // 仅排除箭头 `=>` 中的 `>`
                    if i == 0 || chars[i - 1] != "=" { aDepth -= 1 }
                }
                i += 1
            }
            return nil
        }

        // 先匹配所有 `(` ... `)`
        var lpStack: [Int] = []
        var parenPairs: [(Int, Int)] = []
        for i in 0..<n where isCode[i] {
            if chars[i] == "(" {
                lpStack.append(i)
            } else if chars[i] == ")", let lp = lpStack.popLast() {
                parenPairs.append((lp, i))
            }
        }

        let controlKeywords: Set<String> = ["if", "else", "for", "while", "switch", "with", "catch", "return", "typeof", "void", "delete", "throw", "case"]
        var removals: [Range<Int>] = []

        for (lp, rp) in parenPairs {
            // 检查 lp 左边紧挨着的可选函数泛型 `<T, U>`
            var beforeSig = skipWSBackward(lp - 1)
            var genericRange: Range<Int>? = nil
            if beforeSig >= 0 && isCode[beforeSig] && chars[beforeSig] == ">" {
                var depth = 0
                var k = beforeSig
                var matchedOpen: Int? = nil
                while k >= 0 {
                    if isCode[k] {
                        if chars[k] == ">" { depth += 1 }
                        else if chars[k] == "<" {
                            depth -= 1
                            if depth == 0 { matchedOpen = k; break }
                        } else if chars[k] == ";" || chars[k] == "\n" || chars[k] == "{" || chars[k] == "}" {
                            break
                        }
                    }
                    k -= 1
                }
                if let gOpen = matchedOpen {
                    if let word = prevWordRange(before: gOpen - 1), !controlKeywords.contains(word.word) {
                        genericRange = gOpen..<(beforeSig + 1)
                        beforeSig = gOpen - 1
                    }
                }
            }

            let leftWord = prevWordRange(before: beforeSig)?.word
            if let lw = leftWord, controlKeywords.contains(lw) {
                continue
            }

            let afterRP = skipWSForward(rp + 1)
            guard afterRP < n, isCode[afterRP] else { continue }

            var isSignature = false
            var returnTypeRange: Range<Int>? = nil
            if chars[afterRP] == "=" && afterRP + 1 < n && isCode[afterRP + 1] && chars[afterRP + 1] == ">" {
                isSignature = true
            } else if chars[afterRP] == "{" {
                if leftWord != nil {
                    isSignature = true
                }
            } else if chars[afterRP] == ":" {
                if !isLikelyTernaryTrueBranch(leftParen: lp),
                   let retEnd = scanReturnTypeEnd(colonIdx: afterRP) {
                    isSignature = true
                    returnTypeRange = afterRP..<retEnd
                }
            }

            guard isSignature else { continue }
            if let g = genericRange { removals.append(g) }
            if let r = returnTypeRange { removals.append(r) }

            // 扫描参数列表 `(lp + 1 ..< rp)` 内部各参数的 `?` 与 `: TypeSpec`
            var p = skipWSForward(lp + 1)
            while p < rp {
                if chars[p] == "," { p = skipWSForward(p + 1); continue }
                if chars[p] == "." && p + 2 < rp && chars[p + 1] == "." && chars[p + 2] == "." {
                    p = skipWSForward(p + 3)
                }
                if p < rp && (chars[p] == "{" || chars[p] == "[") {
                    let closeChar: Character = chars[p] == "{" ? "}" : "]"
                    if let cIdx = findMatchingClose(openIdx: p, openCh: chars[p], closeCh: closeChar), cIdx < rp {
                        p = cIdx + 1
                    } else {
                        break
                    }
                } else {
                    while p < rp && isCode[p] && isIdentChar(chars[p]) { p += 1 }
                }
                p = skipWSForward(p)
                var typeStart: Int? = nil
                if p < rp && isCode[p] && chars[p] == "?" {
                    let afterQ = skipWSForward(p + 1)
                    if afterQ < rp && isCode[afterQ] && chars[afterQ] == ":" {
                        typeStart = p
                        p = afterQ
                    }
                } else if p < rp && isCode[p] && chars[p] == ":" {
                    typeStart = p
                }

                if let ts = typeStart {
                    var q = ts + (chars[ts] == "?" ? 1 : 0)
                    q = skipWSForward(q) // 此时应指向 ':'
                    if q < rp && chars[q] == ":" { q += 1 }
                    var dP = 0, dB = 0, dS = 0, dA = 0
                    while q < rp {
                        if isCode[q] {
                            let ch = chars[q]
                            if dP == 0 && dB == 0 && dS == 0 && dA == 0 {
                                if ch == "," { break }
                                if ch == "=" && !(q + 1 < rp && chars[q + 1] == ">") { break }
                            }
                            if ch == "(" { dP += 1 }
                            else if ch == ")" && dP > 0 { dP -= 1 }
                            else if ch == "{" { dB += 1 }
                            else if ch == "}" && dB > 0 { dB -= 1 }
                            else if ch == "[" { dS += 1 }
                            else if ch == "]" && dS > 0 { dS -= 1 }
                            else if ch == "<" { dA += 1 }
                            else if ch == ">" && dA > 0 {
                                if q == 0 || chars[q - 1] != "=" { dA -= 1 }
                            }
                        }
                        q += 1
                    }
                    removals.append(ts..<q)
                    p = q
                }
                // 跳转到下一个顶层 `,` 或结束
                var dP = 0, dB = 0, dS = 0
                while p < rp {
                    if isCode[p] {
                        let ch = chars[p]
                        if dP == 0 && dB == 0 && dS == 0 && ch == "," {
                            p += 1
                            break
                        }
                        if ch == "(" { dP += 1 }
                        else if ch == ")" && dP > 0 { dP -= 1 }
                        else if ch == "{" { dB += 1 }
                        else if ch == "}" && dB > 0 { dB -= 1 }
                        else if ch == "[" { dS += 1 }
                        else if ch == "]" && dS > 0 { dS -= 1 }
                    }
                    p += 1
                }
                p = skipWSForward(p)
            }
        }

        guard !removals.isEmpty else { return source }
        // 合并排序并去重重叠区间，按布尔删除标记保留代码字符
        var keep = [Bool](repeating: true, count: n)
        for range in removals {
            for idx in max(0, range.lowerBound)..<min(n, range.upperBound) {
                keep[idx] = false
            }
        }
        var out = String()
        out.reserveCapacity(n)
        for i in 0..<n where keep[i] {
            out.append(chars[i])
        }
        return out
    }

    /// 安全删除多行 `interface X { ... }`、`type X = { ... }`、`declare ...` 与 `import type { ... } from ...;`
    private static func stripBalancedTopLevelTypeBlocks(_ source: String, mask: LexicalMask) -> String {
        var result = source
        let blockKeywords = [
            #"(?m)^[ \t]*(?:export\s+)?interface\s+[A-Za-z0-9_$]+(?:<[^>\n]+>)?(?:\s+extends\s+[^{]+)?\s*\{"#,
            #"(?m)^[ \t]*(?:export\s+)?type\s+[A-Za-z0-9_$]+(?:<[^>\n]+>)?\s*=\s*\{"#,
            #"(?m)^[ \t]*declare\s+(?:const|let|var|function|class|interface|type|module|global)\b[^{;\n]*(?:\{|;)"#,
            #"(?ms)^[ \t]*import\s+type\s+[^;\n]*?from\s+['"][^'"]+['"][ \t]*;?"#
        ]
        for pat in blockKeywords {
            guard let regex = try? NSRegularExpression(pattern: pat) else { continue }
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }

            let currentMask = LexicalMask(result)
            var out = result
            for match in matches.reversed() {
                guard let startRange = Range(match.range, in: out) else { continue }
                let offset = currentMask.charOffset(forUTF16Offset: match.range.location)
                var probe = offset
                while probe < currentMask.chars.count && currentMask.chars[probe].isWhitespace {
                    probe += 1
                }
                guard probe < currentMask.isCode.count && currentMask.isCode[probe] else { continue }

                let matchedStr = String(out[startRange])
                if matchedStr.hasSuffix("{") {
                    // 按花括号配对找到整块 interface/declare 结束位置（沿字符索引线性步进，消除 O(N^2) distance 开销）
                    var idx = out.index(before: startRange.upperBound)
                    var cIdx = offset + max(matchedStr.count - 1, 0)
                    var depth = 0
                    while idx < out.endIndex {
                        if cIdx < currentMask.isCode.count && currentMask.isCode[cIdx] {
                            if out[idx] == "{" { depth += 1 }
                            else if out[idx] == "}" {
                                depth -= 1
                                if depth == 0 {
                                    let endIdx = out.index(after: idx)
                                    out.removeSubrange(startRange.lowerBound..<endIdx)
                                    break
                                }
                            }
                        }
                        idx = out.index(after: idx)
                        cIdx += 1
                    }
                } else {
                    out.removeSubrange(startRange)
                }
            }
            result = out
        }
        return result
    }

    private static func applyRegexOutsideNonCode(_ source: String, regex: NSRegularExpression, template: String) -> String {
        let mask = LexicalMask(source)
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return source }

        var out = source
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let offset = mask.charOffset(forUTF16Offset: match.range.location)
            var probe = offset
            while probe < mask.chars.count && mask.chars[probe].isWhitespace {
                probe += 1
            }
            guard probe < mask.isCode.count && mask.isCode[probe] else { continue }
            let replaced = regex.replacementString(for: match, in: out, offset: 0, template: template)
            out.replaceSubrange(range, with: replaced)
        }
        return out
    }
}

// MARK: - 插件定时调度器（真实 setTimeout / setInterval / clearTimeout / clearInterval）

private final class PluginTimerCenter: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: Int = 1
    private var timers: [Int: DispatchSourceTimer] = [:]

    func schedule(
        delayMs: Int,
        repeats: Bool,
        queue: DispatchQueue,
        handler: @escaping () -> Void
    ) -> Int {
        lock.lock()
        let id = nextID
        nextID += 1
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let clampedMs = repeats ? max(4, delayMs) : max(0, delayMs)
        let deadline = DispatchTime.now() + .milliseconds(clampedMs)
        if repeats {
            timer.schedule(deadline: deadline, repeating: .milliseconds(clampedMs), leeway: .milliseconds(1))
        } else {
            timer.schedule(deadline: deadline, leeway: .milliseconds(1))
        }
        timers[id] = timer
        lock.unlock()

        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let active = self.timers[id] != nil
            if !repeats {
                self.timers.removeValue(forKey: id)
            }
            self.lock.unlock()
            guard active else { return }
            if !repeats {
                timer.cancel()
            }
            handler()
        }
        timer.resume()
        return id
    }

    func cancel(id: Int) {
        lock.lock()
        let timer = timers.removeValue(forKey: id)
        lock.unlock()
        timer?.cancel()
    }

    func cancelAll() {
        lock.lock()
        let all = Array(timers.values)
        timers.removeAll()
        lock.unlock()
        for t in all { t.cancel() }
    }
}

// MARK: - JavaScript 插件音乐源实现（对应 plugin.Plugin）

public final class JSPluginSource: MusicSource, @unchecked Sendable {
    public static let appVersion: String = {
        if Bundle.main.bundleIdentifier == "com.egoist.mygomusic.ios",
           let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            let trimmed = ver.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, PluginInstaller.parseVersionNumbers(trimmed) != nil {
                return trimmed
            }
        }
        return "0.1.24.8"
    }()
    private static let defaultCallTimeout: TimeInterval = 30
    private static let signInCallTimeout: TimeInterval = 300

    public let manifest: PluginManifest
    public let pluginDir: URL
    public let dataDir: URL

    private let lock = NSLock()
    private let jsQueue = DispatchQueue(label: "com.mygomusic.plugin.js")
    private let storageIOQueue = DispatchQueue(label: "com.mygomusic.plugin.storage.io", qos: .utility)
    private var pendingStorageWriteWorkItem: DispatchWorkItem?
    private let timerCenter = PluginTimerCenter()
    private let httpClient = PluginHTTPClient()
    private let startTimeNs = DispatchTime.now().uptimeNanoseconds

    private var settingsMap: [String: String] = [:]
    private var storageMap: [String: Any] = [:]
    private var granted: Bool = false
    private var locales: [String: [String: String]] = [:]
    private var transpiled: PluginModuleTranspiler.TranspiledModule
    private var context: JSContext?

    public var onSignInPrompt: (@Sendable (SignInPrompt) -> Void)?
    public var onOpenURL: (@Sendable (URL) -> Void)?
    public var onWebSignIn: (@Sendable (WebSignInRequest) async throws -> String)?

    private static let pluginIDRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#)
    private static let placeholderRegex = try! NSRegularExpression(pattern: #"\{(setting|storage):([^{}]+)\}"#)

    public init(pluginDir: URL, dataRootDir: URL) throws {
        self.pluginDir = pluginDir.standardizedFileURL
        let manifestURL = self.pluginDir.appendingPathComponent("plugin.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let loadedManifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

        let idRange = NSRange(loadedManifest.id.startIndex..., in: loadedManifest.id)
        guard !loadedManifest.id.isEmpty,
              !loadedManifest.id.contains(".."),
              Self.pluginIDRegex.firstMatch(in: loadedManifest.id, range: idRange)?.range == idRange else {
            throw SourceError.message("Invalid plugin id: \(loadedManifest.id)")
        }

        // 检查 minAppVersion 要求
        if let minVer = loadedManifest.minAppVersion, !minVer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard PluginInstaller.parseVersionNumbers(minVer) != nil else {
                throw SourceError.message("minAppVersion is invalid: \(minVer)")
            }
            if PluginInstaller.isNewerVersion(minVer, than: Self.appVersion) {
                let pluginName = loadedManifest.name ?? loadedManifest.id
                throw SourceError.message(I18n.tf("%s needs MyGo Music %s or later", pluginName, minVer))
            }
        }

        self.manifest = loadedManifest
        self.dataDir = dataRootDir.appendingPathComponent(loadedManifest.id, isDirectory: true)

        // 校验 main 路径不得逃逸插件目录
        let relMain = (loadedManifest.main ?? "index.js").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relMain.isEmpty, !relMain.hasPrefix("/") else {
            throw SourceError.message("main must be a relative path in the plugin folder: \(relMain)")
        }
        let mainFile = self.pluginDir.appendingPathComponent(relMain).standardizedFileURL
        let dirPrefix = self.pluginDir.path.hasSuffix("/") ? self.pluginDir.path : self.pluginDir.path + "/"
        guard mainFile.path.hasPrefix(dirPrefix) else {
            throw SourceError.message("main escapes plugin directory: \(relMain)")
        }

        let transpiledCacheURL = self.dataDir.appendingPathComponent(".transpiled-cache-v2.json")
        self.transpiled = try PluginModuleTranspiler.bundleEntryCached(
            entryURL: mainFile,
            pluginDir: self.pluginDir,
            cacheFileURL: transpiledCacheURL
        )

        self.locales = Self.loadLocales(from: self.pluginDir)
        if let s = Self.loadJSONDictionary(from: dataDir.appendingPathComponent("settings.json")) {
            self.settingsMap = s
        }
        if let st = Self.loadAnyJSONDictionary(from: dataDir.appendingPathComponent("storage.json")) {
            self.storageMap = st
        }
        if let gData = try? Data(contentsOf: dataDir.appendingPathComponent("granted.json")),
           let g = try? JSONDecoder().decode(Bool.self, from: gData) {
            self.granted = g
        }
    }

    deinit {
        flushStorageSync()
        timerCenter.cancelAll()
        httpClient.invalidate()
    }

    /// 扫描插件 locales 目录下所有 <lang>.json 语言文件（对应 readLocales）
    private static func loadLocales(from dir: URL) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        let localesDir = dir.appendingPathComponent("locales", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: localesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return result
        }
        for file in files where file.pathExtension.lowercased() == "json" {
            let code = file.deletingPathExtension().lastPathComponent
            if let dict = loadJSONDictionary(from: file) {
                result[code] = dict
            }
        }
        return result
    }

    private static func loadJSONDictionary(from url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func loadAnyJSONDictionary(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// 将任意 JSON 兼容值（含顶层 Bool / Number / String / NSNull 及容器）安全编码为 UTF-8 数据，避免触发 ObjC 异常
    public static func encodeAnyJSON(_ obj: Any, pretty: Bool = false) -> Data? {
        if JSONSerialization.isValidJSONObject(obj) {
            let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : []
            return try? JSONSerialization.data(withJSONObject: obj, options: options)
        }
        // 非容器顶层值先包装为单元素数组，借 isValidJSONObject 安全校验并提取内部 JSON 文本，避免顶层类型引发 NSInvalidArgumentException
        let wrapped = [obj]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let arrData = try? JSONSerialization.data(withJSONObject: wrapped, options: []),
              arrData.count >= 2,
              arrData.first == UInt8(ascii: "["),
              arrData.last == UInt8(ascii: "]") else {
            return nil
        }
        return Data(arrData.dropFirst().dropLast())
    }

    private func saveEncodableJSON<T: Encodable>(_ value: T, fileName: String) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let target = dataDir.appendingPathComponent(fileName)
        try data.write(to: target, options: .atomic)
    }

    private func saveAnyJSON(_ obj: Any, fileName: String, pretty: Bool = false) throws {
        guard let data = Self.encodeAnyJSON(obj, pretty: pretty) else {
            throw SourceError.message("Invalid JSON payload for \(fileName)")
        }
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let target = dataDir.appendingPathComponent(fileName)
        try data.write(to: target, options: .atomic)
    }

    /// 安排异步防抖持久化插件 storage.json（避免批量写入 fileids 时在串行 jsQueue 上阻塞流调度）
    private func scheduleStoragePersistenceLocked() {
        pendingStorageWriteWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.writeStorageSnapshotToDisk()
        }
        pendingStorageWriteWorkItem = work
        storageIOQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func writeStorageSnapshotToDisk() {
        lock.lock()
        let snapshot = storageMap
        lock.unlock()
        try? saveAnyJSON(snapshot, fileName: "storage.json", pretty: false)
    }

    /// 立即将内存中待落盘的插件 storage 同步写入磁盘
    public func flushStorage() {
        flushStorageSync()
    }

    private func flushStorageSync() {
        lock.lock()
        let hadPending = pendingStorageWriteWorkItem != nil
        pendingStorageWriteWorkItem?.cancel()
        pendingStorageWriteWorkItem = nil
        let snapshot = storageMap
        lock.unlock()
        if hadPending {
            storageIOQueue.sync {
                try? saveAnyJSON(snapshot, fileName: "storage.json", pretty: false)
            }
        }
    }

    /// 插件内置翻译查找（对应 Plugin.t，兼容精确语言码与前缀匹配）
    public func translate(_ text: String) -> String {
        let lang = I18n.languageCode()
        if let dict = locales[lang], let tr = dict[text], !tr.isEmpty {
            return tr
        }
        let lowerLang = lang.lowercased()
        for (code, dict) in locales where code.lowercased() == lowerLang {
            if let tr = dict[text], !tr.isEmpty {
                return tr
            }
        }
        return text
    }

    /// 当前插件是否被授权执行外部进程（仅保存标志与 UI 展示用）
    public var hasProcessPermissionDeclaration: Bool {
        !(manifest.permissions?.process ?? []).isEmpty
    }

    public func isProcessGranted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return granted
    }

    public func setProcessGranted(_ value: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        granted = value
        try saveEncodableJSON(value, fileName: "granted.json")
    }

    // MARK: - 请求头插值（对应 Plugin.HeadersFor）

    public func headersFor(url: URL, kind: String) -> [String: String]? {
        guard let rules = manifest.requestHeaders, !rules.isEmpty,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        var out: [String: String]?
        for rule in rules {
            if let kinds = rule.kinds, !kinds.isEmpty, !kinds.contains(kind) {
                continue
            }
            guard ruleReaches(rule, host: host) else { continue }
            for (name, valueTemplate) in rule.headers {
                guard let filled = fillPlaceholders(valueTemplate) else { continue }
                if out == nil { out = [:] }
                if out?[name] == nil {
                    out?[name] = filled
                }
            }
        }
        return out
    }

    private func ruleReaches(_ rule: PluginRequestHeaders, host: String) -> Bool {
        let perms = manifest.permissions ?? PluginPermissions()
        for h in rule.hosts {
            if h.hasPrefix("{setting:") && h.hasSuffix("}") {
                let key = String(h.dropFirst("{setting:".count).dropLast())
                let configuredHost = Self.extractServerHost(settingsMap[key] ?? "")
                if configuredHost == host && perms.reaches(host: host) {
                    return true
                }
                continue
            }
            let lowerH = h.lowercased()
            if lowerH == host || (lowerH.hasPrefix("*.") && host.hasSuffix(String(lowerH.dropFirst(1)))) {
                return true
            }
        }
        return false
    }

    private static func extractServerHost(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if !s.contains("://") {
            s = "http://" + s
        }
        return URL(string: s)?.host?.lowercased() ?? ""
    }

    private func fillPlaceholders(_ template: String) -> String? {
        let ns = template as NSString
        let matches = Self.placeholderRegex.matches(in: template, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return template.contains("\r") || template.contains("\n") ? nil : template
        }

        var result = template
        for match in matches.reversed() {
            let fullRange = Range(match.range, in: result)!
            let kind = ns.substring(with: match.range(at: 1))
            let key = ns.substring(with: match.range(at: 2))
            var replacement = ""
            if kind == "setting" {
                replacement = settingsMap[key] ?? ""
            } else if kind == "storage" {
                if let val = storageMap[key] {
                    if let str = val as? String {
                        replacement = str
                    } else if !(val is NSNull),
                              let data = Self.encodeAnyJSON(val),
                              let jsonStr = String(data: data, encoding: .utf8) {
                        replacement = jsonStr
                    }
                }
            }
            if replacement.isEmpty {
                return nil
            }
            result.replaceSubrange(fullRange, with: replacement)
        }
        if result.contains("\r") || result.contains("\n") {
            return nil
        }
        return result
    }

    // MARK: - JSContext 初始化与 Host / WebAPI 注入

    private func ensureContext() throws -> JSContext {
        if let ctx = context {
            return ctx
        }
        guard let ctx = JSContext() else {
            throw SourceError.message("Failed to create JSContext")
        }

        timerCenter.cancelAll()
        installWebAPIPolyfills(into: ctx)
        installHostGlobal(into: ctx)

        ctx.evaluateScript(transpiled.code)
        if let ex = ctx.exception {
            let msg = ex.toString() ?? "Unknown JS error"
            ctx.exception = nil
            throw SourceError.message(msg)
        }
        self.context = ctx
        return ctx
    }

    /// 若运行时发生异常或死锁时重置 JS 上下文与挂起定时器
    public func resetRuntime() {
        jsQueue.async { [weak self] in
            guard let self else { return }
            self.timerCenter.cancelAll()
            self.context = nil
        }
    }

    private func installWebAPIPolyfills(into ctx: JSContext) {
        // console（保留插件调试输出，方便查错）
        let consoleObj = JSValue(newObjectIn: ctx)!
        let makeLogger: (String) -> @convention(block) () -> Void = { [weak self] level in
            let pluginID = self?.manifest.id ?? "plugin"
            return {
                let args = JSContext.currentArguments() as? [JSValue] ?? []
                let text = args.map { $0.toString() ?? "" }.joined(separator: " ")
                #if DEBUG
                print("[\(pluginID)][\(level)] \(text)")
                #endif
            }
        }
        consoleObj.setObject(makeLogger("log"), forKeyedSubscript: "log" as NSString)
        consoleObj.setObject(makeLogger("warn"), forKeyedSubscript: "warn" as NSString)
        consoleObj.setObject(makeLogger("error"), forKeyedSubscript: "error" as NSString)
        consoleObj.setObject(makeLogger("info"), forKeyedSubscript: "info" as NSString)
        consoleObj.setObject(makeLogger("debug"), forKeyedSubscript: "debug" as NSString)
        ctx.setObject(consoleObj, forKeyedSubscript: "console" as NSString)

        // 真实 DispatchSource 定时器引擎（支持传参、clearTimeout/clearInterval 真实取消）
        let scheduleTimerNative: @convention(block) (JSValue, JSValue, Bool, JSValue) -> Int = { [weak self] callback, delayVal, repeats, argsArrayVal in
            guard let self, callback.isObject else { return 0 }
            let delayMs = delayVal.isUndefined || delayVal.isNull ? 0 : Int(delayVal.toInt32())
            // 使用 JSManagedValue 绑定在当前虚拟机，避免野指针并允许取消时自动回收
            let managedCallback = JSManagedValue(value: callback)
            let managedArgs = JSManagedValue(value: argsArrayVal)
            ctx.virtualMachine.addManagedReference(managedCallback, withOwner: self)
            ctx.virtualMachine.addManagedReference(managedArgs, withOwner: self)

            return self.timerCenter.schedule(delayMs: delayMs, repeats: repeats, queue: self.jsQueue) { [weak self] in
                guard let self, let activeCtx = self.context else { return }
                guard let fn = managedCallback?.value, !fn.isUndefined else { return }
                var callArgs: [Any] = []
                if let arr = managedArgs?.value, arr.isArray {
                    let count = Int(arr.forProperty("length")?.toInt32() ?? 0)
                    for i in 0..<count {
                        if let v = arr.atIndex(i) {
                            callArgs.append(v)
                        }
                    }
                }
                _ = fn.call(withArguments: callArgs)
                if activeCtx.exception != nil {
                    activeCtx.exception = nil
                }
                if !repeats {
                    activeCtx.virtualMachine.removeManagedReference(managedCallback, withOwner: self)
                    activeCtx.virtualMachine.removeManagedReference(managedArgs, withOwner: self)
                }
            }
        }
        let clearTimerNative: @convention(block) (JSValue) -> Void = { [weak self] idVal in
            guard let self, !idVal.isUndefined, !idVal.isNull else { return }
            let id = Int(idVal.toInt32())
            if id > 0 {
                self.timerCenter.cancel(id: id)
            }
        }
        ctx.setObject(scheduleTimerNative, forKeyedSubscript: "__nativeScheduleTimer" as NSString)
        ctx.setObject(clearTimerNative, forKeyedSubscript: "__nativeClearTimer" as NSString)

        // performance.now() 单调高精度计时
        let nativePerformanceNow: @convention(block) () -> Double = { [weak self] in
            guard let self else { return 0 }
            let elapsedNs = DispatchTime.now().uptimeNanoseconds - self.startTimeNs
            return Double(elapsedNs) / 1_000_000.0
        }
        ctx.setObject(nativePerformanceNow, forKeyedSubscript: "__nativePerformanceNow" as NSString)

        // 标准单字节 Latin-1 btoa / atob 原生桥接
        let btoaBlock: @convention(block) (JSValue) -> JSValue = { val in
            guard let c = JSContext.current() else { return JSValue(undefinedIn: nil) }
            let str = val.toString() ?? ""
            var bytes: [UInt8] = []
            bytes.reserveCapacity(str.unicodeScalars.count)
            for scalar in str.unicodeScalars {
                if scalar.value > 0xFF {
                    c.exception = JSValue(newErrorFromMessage: "DOMException: Failed to execute 'btoa': The string to be encoded contains characters outside of the Latin1 range.", in: c)
                    return JSValue(undefinedIn: c)
                }
                bytes.append(UInt8(scalar.value))
            }
            return JSValue(object: Data(bytes).base64EncodedString(), in: c)
        }
        let atobBlock: @convention(block) (JSValue) -> JSValue = { val in
            guard let c = JSContext.current() else { return JSValue(undefinedIn: nil) }
            let raw = (val.toString() ?? "").filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: raw) else {
                c.exception = JSValue(newErrorFromMessage: "DOMException: Failed to execute 'atob': The string to be decoded is not correctly encoded.", in: c)
                return JSValue(undefinedIn: c)
            }
            let latin1 = String(data: data, encoding: .isoLatin1) ?? ""
            return JSValue(object: latin1, in: c)
        }
        ctx.setObject(btoaBlock, forKeyedSubscript: "btoa" as NSString)
        ctx.setObject(atobBlock, forKeyedSubscript: "atob" as NSString)

        // TextEncoder / TextDecoder 原生高速编解码桥接（支持 utf-8, gbk/gb18030, utf-16le/be, latin1）
        let nativeTextEncodeBase64: @convention(block) (String) -> String = { str in
            return Data(str.utf8).base64EncodedString()
        }
        let nativeTextDecodeBase64: @convention(block) (String, String, Bool) -> JSValue = { b64, encodingLabel, fatal in
            guard let c = JSContext.current() else { return JSValue(undefinedIn: nil) }
            guard let data = Data(base64Encoded: b64) else { return JSValue(object: "", in: c) }
            let norm = encodingLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let encoding: String.Encoding
            switch norm {
            case "", "utf-8", "utf8", "unicode-1-1-utf-8":
                if fatal {
                    guard let s = String(data: data, encoding: .utf8) else {
                        c.exception = JSValue(newErrorFromMessage: "TypeError: The encoded data was not valid for encoding utf-8", in: c)
                        return JSValue(undefinedIn: c)
                    }
                    return JSValue(object: s, in: c)
                }
                return JSValue(object: String(decoding: data, as: UTF8.self), in: c)
            case "latin1", "iso-8859-1", "iso8859-1", "windows-1252":
                return JSValue(object: String(data: data, encoding: .isoLatin1) ?? "", in: c)
            case "ascii", "us-ascii":
                return JSValue(object: String(data: data, encoding: .ascii) ?? String(decoding: data, as: UTF8.self), in: c)
            case "utf-16le", "utf-16":
                encoding = .utf16LittleEndian
            case "utf-16be":
                encoding = .utf16BigEndian
            case "gbk", "gb2312", "gb18030", "chinese", "csgb2312":
                let cfEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
                encoding = String.Encoding(rawValue: cfEnc)
            default:
                encoding = .utf8
            }
            if let decoded = String(data: data, encoding: encoding) {
                return JSValue(object: decoded, in: c)
            }
            if fatal {
                c.exception = JSValue(newErrorFromMessage: "TypeError: The encoded data was not valid for encoding \(encodingLabel)", in: c)
                return JSValue(undefinedIn: c)
            }
            return JSValue(object: String(decoding: data, as: UTF8.self), in: c)
        }
        ctx.setObject(nativeTextEncodeBase64, forKeyedSubscript: "__nativeTextEncodeB64" as NSString)
        ctx.setObject(nativeTextDecodeBase64, forKeyedSubscript: "__nativeTextDecodeB64" as NSString)

        // 原生 fetch 与 abort 桥接
        let nativeAbortFetch: @convention(block) (String) -> Void = { [weak self] reqID in
            self?.httpClient.abort(requestID: reqID)
        }
        ctx.setObject(nativeAbortFetch, forKeyedSubscript: "__nativeAbortFetch" as NSString)

        let nativeFetch: @convention(block) (String, String, JSValue, JSValue, JSValue) -> Void = { [weak self] reqID, urlString, optionsVal, resolve, reject in
            guard let self else { return }
            guard let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  let host = url.host?.lowercased() else {
                self.jsQueue.async {
                    _ = reject.call(withArguments: ["Invalid URL: \(urlString)"])
                }
                return
            }

            let perms = self.manifest.permissions ?? PluginPermissions()
            if !perms.reaches(host: host) {
                self.jsQueue.async {
                    _ = reject.call(withArguments: ["fetch to \(host) is not allowed by plugin network permissions"])
                }
                return
            }

            var request = URLRequest(url: url)
            request.setValue("mygo-music/0.1", forHTTPHeaderField: "User-Agent")
            var redirectMode = "follow"

            if optionsVal.isObject, let dict = optionsVal.toDictionary() {
                if let method = dict["method"] as? String, !method.isEmpty {
                    request.httpMethod = method.uppercased()
                }
                if let redirect = dict["redirect"] as? String {
                    redirectMode = redirect.lowercased()
                }
                if let headerPairs = dict["headerEntries"] as? [[Any]] {
                    var seenNames = Set<String>()
                    for pair in headerPairs where pair.count >= 2 {
                        let k = "\(pair[0])"
                        let v = "\(pair[1])"
                        if seenNames.contains(k.lowercased()) {
                            request.addValue(v, forHTTPHeaderField: k)
                        } else {
                            request.setValue(v, forHTTPHeaderField: k)
                            seenNames.insert(k.lowercased())
                        }
                    }
                } else if let headers = dict["headers"] as? [String: Any] {
                    for (k, v) in headers {
                        request.setValue("\(v)", forHTTPHeaderField: k)
                    }
                }
                if let bodyB64 = dict["bodyBase64"] as? String,
                   let bodyData = Data(base64Encoded: bodyB64) {
                    request.httpBody = bodyData
                } else if let bodyStr = dict["body"] as? String {
                    request.httpBody = Data(bodyStr.utf8)
                }
            }

            self.httpClient.perform(
                requestID: reqID,
                request: request,
                redirectMode: redirectMode,
                permissions: perms
            ) { [weak self] data, httpResp, error in
                guard let self else { return }
                if let error {
                    let message: String
                    if let urlErr = error as? URLError, urlErr.code == .cancelled {
                        message = "__ABORTED__"
                    } else if let urlError = error as? URLError,
                              urlError.code == .serverCertificateUntrusted ||
                              urlError.code == .secureConnectionFailed ||
                              urlError.code == .serverCertificateHasBadDate ||
                              urlError.code == .serverCertificateNotYetValid ||
                              urlError.code == .serverCertificateHasUnknownRoot ||
                              urlError.code == .clientCertificateRejected ||
                              urlError.code == .clientCertificateRequired {
                        message = "插件请求 https://\(host) 的证书未通过系统校验。请检查代理设置，或将该域名设为直连后重试；应用不会跳过证书验证。"
                    } else {
                        message = error.localizedDescription
                    }
                    self.jsQueue.async {
                        _ = reject.call(withArguments: [message])
                    }
                    return
                }

                // 在网络回调线程完成文本/Base64 预处理与 Header 拆解，避免阻塞串行 JS 队列
                let payload = PluginHTTPUtilities.buildFetchResponsePayload(
                    urlString: urlString,
                    data: data,
                    httpResp: httpResp
                )
                self.jsQueue.async {
                    _ = resolve.call(withArguments: [payload])
                }
            }
        }
        ctx.setObject(nativeFetch, forKeyedSubscript: "__nativeFetch" as NSString)

        // 注入完整标准 Web APIs（对应 moejs/webapi）
        let polyfillScript = #"""
        (function() {
            globalThis.setTimeout = function(fn, ms) {
                if (typeof fn === 'string') fn = new Function(fn);
                const args = Array.prototype.slice.call(arguments, 2);
                return __nativeScheduleTimer(fn, Number(ms) || 0, false, args);
            };
            globalThis.setInterval = function(fn, ms) {
                if (typeof fn === 'string') fn = new Function(fn);
                const args = Array.prototype.slice.call(arguments, 2);
                return __nativeScheduleTimer(fn, Number(ms) || 0, true, args);
            };
            globalThis.clearTimeout = function(id) { __nativeClearTimer(id); };
            globalThis.clearInterval = function(id) { __nativeClearTimer(id); };

            if (typeof globalThis.queueMicrotask !== 'function') {
                globalThis.queueMicrotask = function(fn) { Promise.resolve().then(fn); };
            }
            if (typeof globalThis.performance === 'undefined') {
                globalThis.performance = { now: function() { return __nativePerformanceNow(); } };
            } else if (typeof globalThis.performance.now !== 'function') {
                globalThis.performance.now = function() { return __nativePerformanceNow(); };
            }

            if (typeof globalThis.DOMException === 'undefined') {
                globalThis.DOMException = class DOMException extends Error {
                    constructor(message, name) {
                        super(message || '');
                        this.name = name || 'Error';
                    }
                };
            }

            if (typeof globalThis.AbortSignal === 'undefined') {
                globalThis.AbortSignal = class AbortSignal {
                    constructor() {
                        this.aborted = false;
                        this.reason = undefined;
                        this.onabort = null;
                        this._listeners = [];
                    }
                    addEventListener(type, fn, opts) {
                        if (type !== 'abort' || typeof fn !== 'function') return;
                        this._listeners.push({ fn: fn, once: !!(opts && opts.once) });
                    }
                    removeEventListener(type, fn) {
                        if (type !== 'abort') return;
                        this._listeners = this._listeners.filter(function(item) { return item.fn !== fn; });
                    }
                    dispatchEvent(ev) {
                        if (typeof this.onabort === 'function') {
                            try { this.onabort(ev); } catch (_) {}
                        }
                        const current = this._listeners.slice();
                        this._listeners = this._listeners.filter(function(item) { return !item.once; });
                        for (let i = 0; i < current.length; i++) {
                            try { current[i].fn.call(this, ev); } catch (_) {}
                        }
                        return true;
                    }
                    throwIfAborted() {
                        if (this.aborted) {
                            throw this.reason || new DOMException('The operation was aborted.', 'AbortError');
                        }
                    }
                    _triggerAbort(reason) {
                        if (this.aborted) return;
                        this.aborted = true;
                        this.reason = reason !== undefined ? reason : new DOMException('The operation was aborted.', 'AbortError');
                        this.dispatchEvent({ type: 'abort', target: this });
                    }
                    static abort(reason) {
                        const s = new AbortSignal();
                        s._triggerAbort(reason);
                        return s;
                    }
                    static timeout(ms) {
                        const s = new AbortSignal();
                        setTimeout(function() {
                            s._triggerAbort(new DOMException('The operation timed out.', 'TimeoutError'));
                        }, ms);
                        return s;
                    }
                };
            }

            if (typeof globalThis.AbortController === 'undefined') {
                globalThis.AbortController = class AbortController {
                    constructor() {
                        this.signal = new AbortSignal();
                    }
                    abort(reason) {
                        this.signal._triggerAbort(reason);
                    }
                };
            }

            function safeDecodeURIComponent(s) {
                try { return decodeURIComponent(s.replace(/\+/g, ' ')); }
                catch (_) { return s.replace(/\+/g, ' '); }
            }

            globalThis.URLSearchParams = class URLSearchParams {
                constructor(init) {
                    this._pairs = [];
                    if (!init) return;
                    if (typeof init === 'string') {
                        const s = init.startsWith('?') ? init.slice(1) : init;
                        if (!s) return;
                        for (const part of s.split('&')) {
                            if (part === '') continue;
                            const idx = part.indexOf('=');
                            if (idx >= 0) {
                                this._pairs.push([safeDecodeURIComponent(part.slice(0, idx)), safeDecodeURIComponent(part.slice(idx + 1))]);
                            } else {
                                this._pairs.push([safeDecodeURIComponent(part), '']);
                            }
                        }
                    } else if (init instanceof URLSearchParams || typeof init.entries === 'function') {
                        for (const pair of init.entries()) {
                            this._pairs.push([String(pair[0]), String(pair[1])]);
                        }
                    } else if (Array.isArray(init)) {
                        for (const pair of init) {
                            if (pair && pair.length >= 2) this._pairs.push([String(pair[0]), String(pair[1])]);
                        }
                    } else if (typeof init === 'object') {
                        for (const k of Object.keys(init)) {
                            this._pairs.push([String(k), String(init[k])]);
                        }
                    }
                }
                _changed() {
                    if (typeof this._onChange === 'function') this._onChange();
                }
                get size() { return this._pairs.length; }
                append(k, v) { this._pairs.push([String(k), String(v)]); this._changed(); }
                set(k, v) {
                    const key = String(k);
                    let replaced = false;
                    const next = [];
                    for (const p of this._pairs) {
                        if (p[0] === key) {
                            if (!replaced) { next.push([key, String(v)]); replaced = true; }
                        } else {
                            next.push(p);
                        }
                    }
                    if (!replaced) next.push([key, String(v)]);
                    this._pairs = next;
                    this._changed();
                }
                get(k) {
                    const found = this._pairs.find(p => p[0] === String(k));
                    return found ? found[1] : null;
                }
                getAll(k) {
                    const key = String(k);
                    return this._pairs.filter(p => p[0] === key).map(p => p[1]);
                }
                has(k, v) {
                    const key = String(k);
                    if (v === undefined) return this._pairs.some(p => p[0] === key);
                    const val = String(v);
                    return this._pairs.some(p => p[0] === key && p[1] === val);
                }
                delete(k) {
                    const key = String(k);
                    this._pairs = this._pairs.filter(p => p[0] !== key);
                    this._changed();
                }
                sort() {
                    this._pairs.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
                    this._changed();
                }
                forEach(cb, thisArg) {
                    for (const p of this._pairs) cb.call(thisArg, p[1], p[0], this);
                }
                *entries() { for (const p of this._pairs) yield [p[0], p[1]]; }
                *keys() { for (const p of this._pairs) yield p[0]; }
                *values() { for (const p of this._pairs) yield p[1]; }
                [Symbol.iterator]() { return this.entries(); }
                toString() {
                    return this._pairs.map(p => encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1])).join('&');
                }
            };

            function normalizePath(path) {
                const isAbs = path.startsWith('/');
                const segments = path.split('/');
                const stack = [];
                for (let i = 0; i < segments.length; i++) {
                    const seg = segments[i];
                    if (seg === '' || seg === '.') continue;
                    if (seg === '..') { if (stack.length > 0) stack.pop(); }
                    else stack.push(seg);
                }
                let out = (isAbs ? '/' : '') + stack.join('/');
                if (path.endsWith('/') && out !== '/' && !out.endsWith('/')) out += '/';
                return out || '/';
            }

            globalThis.URL = class URL {
                constructor(url, base) {
                    let raw = String(url === undefined ? '' : url);
                    if (base !== undefined && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(raw)) {
                        const b = base instanceof URL ? base : new URL(String(base));
                        if (raw.startsWith('//')) {
                            raw = b.protocol + raw;
                        } else if (raw.startsWith('#')) {
                            raw = b.origin + b.pathname + b.search + raw;
                        } else if (raw.startsWith('?')) {
                            raw = b.origin + b.pathname + raw;
                        } else if (raw.startsWith('/')) {
                            raw = b.origin + raw;
                        } else {
                            const dir = b.pathname.replace(/[^/]*$/, '');
                            raw = b.origin + normalizePath(dir + raw);
                        }
                    }
                    const m = raw.match(/^([a-zA-Z][a-zA-Z0-9+.-]*:)\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/);
                    if (!m) throw new TypeError('Invalid URL: ' + raw);
                    this.protocol = m[1].toLowerCase();
                    let authority = m[2] || '';
                    this.username = '';
                    this.password = '';
                    const at = authority.lastIndexOf('@');
                    if (at >= 0) {
                        const userinfo = authority.slice(0, at);
                        authority = authority.slice(at + 1);
                        const colon = userinfo.indexOf(':');
                        if (colon >= 0) {
                            this.username = userinfo.slice(0, colon);
                            this.password = userinfo.slice(colon + 1);
                        } else {
                            this.username = userinfo;
                        }
                    }
                    const portMatch = authority.match(/^(.*):(\d+)$/);
                    this.hostname = (portMatch ? portMatch[1] : authority).toLowerCase();
                    this.port = portMatch ? portMatch[2] : '';
                    this.pathname = m[3] ? normalizePath(m[3]) : '/';
                    const rawSearch = m[4] || '';
                    this._hash = m[5] || '';
                    this._searchParams = new URLSearchParams(rawSearch);
                    this._searchParams._onChange = () => {};
                }
                get host() { return this.port ? (this.hostname + ':' + this.port) : this.hostname; }
                set host(v) {
                    const s = String(v);
                    const pm = s.match(/^(.*):(\d+)$/);
                    this.hostname = (pm ? pm[1] : s).toLowerCase();
                    this.port = pm ? pm[2] : '';
                }
                get search() {
                    const s = this._searchParams.toString();
                    return s ? '?' + s : '';
                }
                set search(v) {
                    this._searchParams = new URLSearchParams(String(v || ''));
                }
                get searchParams() { return this._searchParams; }
                get hash() { return this._hash; }
                set hash(v) {
                    const s = String(v || '');
                    this._hash = s && !s.startsWith('#') ? '#' + s : s;
                }
                get origin() { return this.protocol + '//' + this.host; }
                get href() {
                    const auth = this.username ? (this.username + (this.password ? ':' + this.password : '') + '@') : '';
                    return this.protocol + '//' + auth + this.host + this.pathname + this.search + this._hash;
                }
                toString() { return this.href; }
                toJSON() { return this.href; }
            };

            function b64ToBytes(b64) {
                const bin = atob(b64 || '');
                const bytes = new Uint8Array(bin.length);
                for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                return bytes;
            }
            function bytesToB64(bytes) {
                const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
                let bin = '';
                const chunk = 8192;
                for (let i = 0; i < u8.length; i += chunk) {
                    bin += String.fromCharCode.apply(null, u8.subarray(i, i + chunk));
                }
                return btoa(bin);
            }

            globalThis.TextEncoder = class TextEncoder {
                get encoding() { return 'utf-8'; }
                encode(str) {
                    return b64ToBytes(__nativeTextEncodeB64(String(str === undefined ? '' : str)));
                }
            };

            globalThis.TextDecoder = class TextDecoder {
                constructor(encoding, options) {
                    this.encoding = String(encoding || 'utf-8').toLowerCase();
                    this.fatal = !!(options && options.fatal);
                    this.ignoreBOM = !!(options && options.ignoreBOM);
                }
                decode(input) {
                    if (input === undefined || input === null) return '';
                    const u8 = input instanceof Uint8Array
                        ? input
                        : (ArrayBuffer.isView(input) ? new Uint8Array(input.buffer, input.byteOffset, input.byteLength) : new Uint8Array(input));
                    if (u8.byteLength === 0) return '';
                    return __nativeTextDecodeB64(bytesToB64(u8), this.encoding, this.fatal);
                }
            };

            globalThis.Headers = class Headers {
                constructor(init) {
                    this._entries = [];
                    this._setCookies = [];
                    if (!init) return;
                    if (Array.isArray(init)) {
                        for (const pair of init) {
                            if (pair && pair.length >= 2) this.append(pair[0], pair[1]);
                        }
                    } else if (init instanceof Headers || typeof init.getSetCookie === 'function') {
                        if (typeof init.getSetCookie === 'function') {
                            const sc = init.getSetCookie();
                            for (const c of sc) this.append('set-cookie', c);
                        }
                        if (typeof init.forEach === 'function') {
                            init.forEach((v, k) => {
                                if (String(k).toLowerCase() !== 'set-cookie') this.append(k, v);
                            });
                        }
                    } else if (typeof init[Symbol.iterator] === 'function' && typeof init !== 'string') {
                        for (const pair of init) {
                            if (Array.isArray(pair) && pair.length >= 2) this.append(pair[0], pair[1]);
                        }
                    } else if (typeof init === 'object') {
                        for (const k of Object.keys(init)) {
                            this.append(k, init[k]);
                        }
                    }
                }
                append(name, value) {
                    const key = String(name).toLowerCase();
                    const val = String(value);
                    if (key === 'set-cookie') {
                        this._setCookies.push(val);
                    }
                    this._entries.push([key, val]);
                }
                set(name, value) {
                    const key = String(name).toLowerCase();
                    const val = String(value);
                    this._entries = this._entries.filter(p => p[0] !== key);
                    this._entries.push([key, val]);
                    if (key === 'set-cookie') this._setCookies = [val];
                }
                get(name) {
                    const key = String(name).toLowerCase();
                    const vals = this._entries.filter(p => p[0] === key).map(p => p[1]);
                    return vals.length ? vals.join(', ') : null;
                }
                getSetCookie() {
                    if (this._setCookies.length) return this._setCookies.slice();
                    return this._entries.filter(p => p[0] === 'set-cookie').map(p => p[1]);
                }
                has(name) {
                    const key = String(name).toLowerCase();
                    return this._entries.some(p => p[0] === key);
                }
                delete(name) {
                    const key = String(name).toLowerCase();
                    this._entries = this._entries.filter(p => p[0] !== key);
                    if (key === 'set-cookie') this._setCookies = [];
                }
                _rawPairs() {
                    return this._entries.slice();
                }
                _groupedPairs() {
                    const map = new Map();
                    for (const [k, v] of this._entries) {
                        if (map.has(k)) map.set(k, map.get(k) + ', ' + v);
                        else map.set(k, v);
                    }
                    return Array.from(map.entries()).sort((a, b) => a[0].localeCompare(b[0]));
                }
                forEach(cb, thisArg) {
                    for (const [k, v] of this._groupedPairs()) cb.call(thisArg, v, k, this);
                }
                *entries() {
                    for (const [k, v] of this._entries) yield [k, v];
                }
                *keys() {
                    for (const [k] of this._entries) yield k;
                }
                *values() {
                    for (const [, v] of this._entries) yield v;
                }
                [Symbol.iterator]() { return this.entries(); }
            };

            globalThis.Response = class Response {
                constructor(body, init) {
                    const opts = init || {};
                    this.status = opts.status !== undefined ? Number(opts.status) : 200;
                    this.statusText = opts.statusText !== undefined ? String(opts.statusText) : '';
                    this.ok = this.status >= 200 && this.status < 300;
                    this.url = opts.url ? String(opts.url) : '';
                    this.redirected = !!opts.redirected;
                    this.headers = opts.headers instanceof Headers ? opts.headers : new Headers(opts.headers);
                    this._text = body === undefined || body === null ? '' : (typeof body === 'string' ? body : String(body));
                    this._base64 = opts._base64 || null;
                    this.bodyUsed = false;
                }
                text() { this.bodyUsed = true; return Promise.resolve(this._text); }
                json() {
                    this.bodyUsed = true;
                    try { return Promise.resolve(JSON.parse(this._text)); }
                    catch (e) { return Promise.reject(e); }
                }
                arrayBuffer() {
                    this.bodyUsed = true;
                    if (this._base64 !== null) return Promise.resolve(b64ToBytes(this._base64).buffer);
                    return Promise.resolve(new TextEncoder().encode(this._text).buffer);
                }
                bytes() {
                    return this.arrayBuffer().then(buf => new Uint8Array(buf));
                }
                clone() {
                    return new Response(this._text, {
                        status: this.status,
                        statusText: this.statusText,
                        url: this.url,
                        redirected: this.redirected,
                        headers: new Headers(this.headers),
                        _base64: this._base64
                    });
                }
            };

            globalThis.Request = class Request {
                constructor(input, init) {
                    const opts = init || {};
                    if (input instanceof Request) {
                        this.url = input.url;
                        this.method = opts.method || input.method || 'GET';
                        this.headers = new Headers(opts.headers || input.headers);
                        this.body = opts.body !== undefined ? opts.body : input.body;
                        this.redirect = opts.redirect || input.redirect || 'follow';
                        this.signal = opts.signal !== undefined ? opts.signal : input.signal;
                    } else {
                        this.url = String(input);
                        this.method = opts.method || 'GET';
                        this.headers = new Headers(opts.headers);
                        this.body = opts.body;
                        this.redirect = opts.redirect || 'follow';
                        this.signal = opts.signal;
                    }
                }
            };

            let fetchCounter = 1;
            globalThis.fetch = function(input, options) {
                const req = input instanceof Request ? new Request(input, options) : new Request(input, options);
                const opts = {
                    method: req.method,
                    redirect: req.redirect,
                    headerEntries: req.headers._rawPairs()
                };
                if (req.body !== undefined && req.body !== null) {
                    if (typeof URLSearchParams !== 'undefined' && req.body instanceof URLSearchParams) {
                        opts.body = req.body.toString();
                        if (!req.headers.has('content-type')) {
                            opts.headerEntries.push(['content-type', 'application/x-www-form-urlencoded;charset=UTF-8']);
                        }
                    } else if (req.body instanceof ArrayBuffer || ArrayBuffer.isView(req.body)) {
                        opts.bodyBase64 = bytesToB64(req.body);
                    } else if (typeof req.body === 'string') {
                        opts.body = req.body;
                    } else if (typeof req.body === 'object') {
                        opts.body = JSON.stringify(req.body);
                    } else {
                        opts.body = String(req.body);
                    }
                }

                const signal = req.signal;
                if (signal && signal.aborted) {
                    return Promise.reject(signal.reason || new DOMException('The operation was aborted.', 'AbortError'));
                }

                const reqId = 'f_' + (fetchCounter++);
                return new Promise(function(resolve, reject) {
                    let settled = false;
                    let onAbort = null;
                    const cleanup = function() {
                        if (signal && onAbort) signal.removeEventListener('abort', onAbort);
                    };
                    if (signal && typeof signal.addEventListener === 'function') {
                        onAbort = function() {
                            if (settled) return;
                            settled = true;
                            __nativeAbortFetch(reqId);
                            cleanup();
                            reject(signal.reason || new DOMException('The operation was aborted.', 'AbortError'));
                        };
                        signal.addEventListener('abort', onAbort, { once: true });
                    }

                    __nativeFetch(reqId, req.url, opts, function(raw) {
                        if (settled) return;
                        settled = true;
                        cleanup();
                        const h = new Headers();
                        if (Array.isArray(raw.headerEntries)) {
                            for (const pair of raw.headerEntries) {
                                if (pair && pair.length >= 2) h.append(pair[0], pair[1]);
                            }
                        }
                        if (Array.isArray(raw.setCookies) && raw.setCookies.length > 0) {
                            h._setCookies = raw.setCookies.slice();
                        }
                        resolve(new Response(raw.text, {
                            status: raw.status,
                            statusText: raw.statusText,
                            url: raw.url,
                            redirected: raw.redirected,
                            headers: h,
                            _base64: raw.base64
                        }));
                    }, function(errMsg) {
                        if (settled) return;
                        settled = true;
                        cleanup();
                        if (errMsg === '__ABORTED__') {
                            reject(new DOMException('The operation was aborted.', 'AbortError'));
                        } else {
                            reject(new Error(errMsg));
                        }
                    });
                });
            };
        })();
        """#
        ctx.evaluateScript(polyfillScript)
    }

    private func installHostGlobal(into ctx: JSContext) {
        let hostObj = JSValue(newObjectIn: ctx)!
        hostObj.setObject("darwin", forKeyedSubscript: "platform" as NSString)
        hostObj.setObject("arm64", forKeyedSubscript: "arch" as NSString)
        hostObj.setObject(Self.appVersion, forKeyedSubscript: "appVersion" as NSString)
        hostObj.setObject(pluginDir.path, forKeyedSubscript: "dir" as NSString)
        hostObj.setObject(dataDir.path, forKeyedSubscript: "dataDir" as NSString)

        // host.storage
        let storageObj = JSValue(newObjectIn: ctx)!
        let storageGet: @convention(block) (String) -> JSValue = { [weak self] key in
            guard let self, let ctx = JSContext.current() else { return JSValue(undefinedIn: JSContext.current()) }
            self.lock.lock()
            let val = self.storageMap[key]
            self.lock.unlock()
            guard let val else { return JSValue(undefinedIn: ctx) }
            if let data = Self.encodeAnyJSON(val),
               let jsonStr = String(data: data, encoding: .utf8) {
                return ctx.objectForKeyedSubscript("JSON").objectForKeyedSubscript("parse").call(withArguments: [jsonStr])
            }
            return JSValue(object: val, in: ctx)
        }
        let storageSet: @convention(block) (String, JSValue) -> Void = { [weak self] key, jsVal in
            guard let self, let ctx = JSContext.current() else { return }
            if jsVal.isUndefined { return }
            let jsonVal = ctx.objectForKeyedSubscript("JSON").objectForKeyedSubscript("stringify").call(withArguments: [jsVal])
            guard let jsonStr = jsonVal?.toString(),
                  let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                return
            }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.storageMap[key] = obj
            self.scheduleStoragePersistenceLocked()
        }
        let storageRemove: @convention(block) (String) -> Void = { [weak self] key in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.storageMap.removeValue(forKey: key)
            self.scheduleStoragePersistenceLocked()
        }
        storageObj.setObject(storageGet, forKeyedSubscript: "get" as NSString)
        storageObj.setObject(storageSet, forKeyedSubscript: "set" as NSString)
        storageObj.setObject(storageRemove, forKeyedSubscript: "remove" as NSString)
        hostObj.setObject(storageObj, forKeyedSubscript: "storage" as NSString)

        // host.language(), host.t(), host.setting()
        let languageFn: @convention(block) () -> String = { I18n.languageCode() }
        let translateFn: @convention(block) (String) -> String = { [weak self] text in
            self?.translate(text) ?? text
        }
        let settingFn: @convention(block) (String) -> String = { [weak self] key in
            self?.setting(key) ?? ""
        }
        hostObj.setObject(languageFn, forKeyedSubscript: "language" as NSString)
        hostObj.setObject(translateFn, forKeyedSubscript: "t" as NSString)
        hostObj.setObject(settingFn, forKeyedSubscript: "setting" as NSString)

        // host.crypto
        let cryptoObj = JSValue(newObjectIn: ctx)!
        let md5Fn: @convention(block) (String) -> String = { PluginCrypto.md5Hex($0) }
        let sha1Fn: @convention(block) (String) -> String = { PluginCrypto.sha1Hex($0) }
        let sha256Fn: @convention(block) (String) -> String = { PluginCrypto.sha256Hex($0) }
        let hmacSha256Fn: @convention(block) (String, String) -> String = { PluginCrypto.hmacSha256Hex(key: $0, text: $1) }
        let aesEcbFn: @convention(block) (String, String) -> JSValue = { key, text in
            guard let ctx = JSContext.current() else { return JSValue(undefinedIn: nil) }
            do {
                return JSValue(object: try PluginCrypto.aesEcbEncryptHex(key: key, text: text), in: ctx)
            } catch {
                ctx.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: ctx)
                return JSValue(undefinedIn: ctx)
            }
        }
        let aesCbcFn: @convention(block) (String, String, String) -> JSValue = { key, iv, text in
            guard let ctx = JSContext.current() else { return JSValue(undefinedIn: nil) }
            do {
                return JSValue(object: try PluginCrypto.aesCbcEncryptHex(key: key, iv: iv, text: text), in: ctx)
            } catch {
                ctx.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: ctx)
                return JSValue(undefinedIn: ctx)
            }
        }
        cryptoObj.setObject(md5Fn, forKeyedSubscript: "md5" as NSString)
        cryptoObj.setObject(sha1Fn, forKeyedSubscript: "sha1" as NSString)
        cryptoObj.setObject(sha256Fn, forKeyedSubscript: "sha256" as NSString)
        cryptoObj.setObject(hmacSha256Fn, forKeyedSubscript: "hmacSha256" as NSString)
        cryptoObj.setObject(aesEcbFn, forKeyedSubscript: "aesEcbEncrypt" as NSString)
        cryptoObj.setObject(aesCbcFn, forKeyedSubscript: "aesCbcEncrypt" as NSString)
        hostObj.setObject(cryptoObj, forKeyedSubscript: "crypto" as NSString)

        // host.openURL
        let openURLFn: @convention(block) (String) -> Void = { [weak self] urlStr in
            guard let url = URL(string: urlStr),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                if let ctx = JSContext.current() {
                    ctx.exception = JSValue(newErrorFromMessage: "not a web address: \(urlStr)", in: ctx)
                }
                return
            }
            self?.onOpenURL?(url)
        }
        hostObj.setObject(openURLFn, forKeyedSubscript: "openURL" as NSString)

        // host.signInPrompt
        let signInPromptFn: @convention(block) (JSValue) -> Void = { [weak self] val in
            guard let dict = val.toDictionary() else { return }
            let prompt = SignInPrompt(qr: dict["qr"] as? String, text: dict["text"] as? String)
            self?.onSignInPrompt?(prompt)
        }
        hostObj.setObject(signInPromptFn, forKeyedSubscript: "signInPrompt" as NSString)

        // host.removeDataDir
        let removeDataDirFn: @convention(block) (String) -> Void = { [weak self] name in
            guard let self else { return }
            let cleaned = (name as NSString).standardizingPath
            guard !cleaned.isEmpty, cleaned != ".", !cleaned.hasPrefix("/"), !cleaned.contains("..") else {
                if let ctx = JSContext.current() {
                    ctx.exception = JSValue(newErrorFromMessage: "not a folder of the plugin's data: \(name)", in: ctx)
                }
                return
            }
            let target = self.dataDir.appendingPathComponent(cleaned)
            try? FileManager.default.removeItem(at: target)
        }
        hostObj.setObject(removeDataDirFn, forKeyedSubscript: "removeDataDir" as NSString)

        // host.spawn 降级校验与说明（iOS 沙箱禁止 fork/exec 外部桌面二进制）
        let spawnFn: @convention(block) (JSValue) -> JSValue = { [weak self] _ in
            guard let ctx = JSContext.current() else { return JSValue(undefinedIn: nil) }
            let programs = self?.manifest.permissions?.process ?? []
            if programs.isEmpty {
                ctx.exception = JSValue(newErrorFromMessage: "spawn needs the process permission", in: ctx)
            } else if self?.isProcessGranted() == false {
                ctx.exception = JSValue(newErrorFromMessage: "the listener hasn't allowed this plugin to start programs", in: ctx)
            } else {
                ctx.exception = JSValue(newErrorFromMessage: "External programs (spawn/ffmpeg) cannot run inside the iOS sandbox", in: ctx)
            }
            return JSValue(undefinedIn: ctx)
        }
        hostObj.setObject(spawnFn, forKeyedSubscript: "spawn" as NSString)

        // host.webSignIn 原生桥接：严格返回 { cookie: "..." } 对象以对齐 internal/plugin/host.go
        let nativeWebSignIn: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak self] optsVal, resolve, reject in
            guard let self else { return }
            guard let dict = optsVal.toDictionary() else {
                self.jsQueue.async { _ = reject.call(withArguments: ["webSignIn requires an options object"]) }
                return
            }
            let urlStr = (dict["url"] as? String) ?? ""
            let cookiesOfStr = (dict["cookiesOf"] as? String) ?? ""
            let untilList = (dict["until"] as? [Any])?.compactMap { $0 as? String } ?? []
            let userAgent = dict["userAgent"] as? String

            guard let u = URL(string: urlStr),
                  let scheme = u.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
                  let cUrl = URL(string: cookiesOfStr),
                  let cScheme = cUrl.scheme?.lowercased(), (cScheme == "http" || cScheme == "https"),
                  let cHost = cUrl.host?.lowercased(),
                  !untilList.isEmpty else {
                self.jsQueue.async { _ = reject.call(withArguments: ["webSignIn needs valid url, cookiesOf, and until"]) }
                return
            }

            let perms = self.manifest.permissions ?? PluginPermissions()
            if !perms.reaches(host: cHost) {
                self.jsQueue.async {
                    _ = reject.call(withArguments: ["webSignIn cookiesOf \(cHost) is not allowed by plugin network permissions"])
                }
                return
            }

            guard let handler = self.onWebSignIn else {
                self.jsQueue.async { _ = reject.call(withArguments: ["webSignIn is not available in this context"]) }
                return
            }

            let req = WebSignInRequest(
                pluginId: self.manifest.id,
                pluginName: self.translate(self.manifest.name ?? self.manifest.id),
                url: urlStr,
                cookiesOf: cookiesOfStr,
                until: untilList,
                userAgent: userAgent
            )

            Task {
                do {
                    let cookieHeader = try await handler(req)
                    self.jsQueue.async {
                        // 返回 { cookie } 字典与 Go 端 rt.FromGo(map[string]any{"cookie": cookie}) 一致
                        _ = resolve.call(withArguments: [["cookie": cookieHeader]])
                    }
                } catch {
                    self.jsQueue.async {
                        _ = reject.call(withArguments: [error.localizedDescription])
                    }
                }
            }
        }
        ctx.setObject(nativeWebSignIn, forKeyedSubscript: "__nativeWebSignIn" as NSString)

        // host.waitForRedirect 原生桥接：返回解析后的查询参数字典对象（对齐 internal/plugin/host.go）
        let nativeWaitForRedirect: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak self] optsVal, resolve, reject in
            guard let self else { return }
            let perms = self.manifest.permissions ?? PluginPermissions()
            guard !(perms.network ?? []).isEmpty else {
                self.jsQueue.async { _ = reject.call(withArguments: ["waitForRedirect needs the network permission"]) }
                return
            }

            var port: UInt16 = 0
            var expectedPath: String = "/"
            var pageText = "You're signed in. You can close this page."
            var timeoutSeconds: TimeInterval = 300

            if optsVal.isNumber {
                port = UInt16(clamping: optsVal.toInt32())
            } else if optsVal.isObject, let dict = optsVal.toDictionary() {
                if let p = dict["port"] as? NSNumber {
                    port = UInt16(clamping: p.intValue)
                }
                if let pathStr = dict["path"] as? String, !pathStr.isEmpty {
                    expectedPath = pathStr.hasPrefix("/") ? pathStr : "/" + pathStr
                }
                if let pageStr = dict["page"] as? String, !pageStr.isEmpty {
                    pageText = pageStr
                }
                if let ms = dict["timeout"] as? NSNumber, ms.doubleValue > 0 {
                    timeoutSeconds = min(600, max(5, ms.doubleValue / 1000.0))
                }
            }
            guard port >= 1024 else {
                self.jsQueue.async { _ = reject.call(withArguments: ["waitForRedirect requires a port >= 1024"]) }
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let queryParams = try Self.listenForSingleLocalRedirect(
                        port: port,
                        expectedPath: expectedPath,
                        pageText: pageText,
                        timeoutSeconds: timeoutSeconds
                    )
                    self.jsQueue.async {
                        _ = resolve.call(withArguments: [queryParams])
                    }
                } catch {
                    self.jsQueue.async {
                        _ = reject.call(withArguments: [error.localizedDescription])
                    }
                }
            }
        }
        ctx.setObject(nativeWaitForRedirect, forKeyedSubscript: "__nativeWaitForRedirect" as NSString)

        ctx.setObject(hostObj, forKeyedSubscript: "host" as NSString)
        ctx.evaluateScript("""
        host.webSignIn = function(opts) {
            return new Promise(function(resolve, reject) {
                __nativeWebSignIn(opts || {}, resolve, function(msg) { reject(new Error(msg)); });
            });
        };
        host.waitForRedirect = function(opts) {
            return new Promise(function(resolve, reject) {
                __nativeWaitForRedirect(opts || {}, resolve, function(msg) { reject(new Error(msg)); });
            });
        };
        """)
    }

    /// 在 127.0.0.1:<port> 启动一次性 HTTP 监听捕获 OAuth 登录回调并解析返回 query 参数字典
    private static func listenForSingleLocalRedirect(
        port: UInt16,
        expectedPath: String,
        pageText: String,
        timeoutSeconds: TimeInterval
    ) throws -> [String: String] {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else {
            throw SourceError.message("socket() failed")
        }
        defer { Darwin.close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            throw SourceError.message("bind(127.0.0.1:\(port)) failed")
        }
        guard Darwin.listen(sock, 4) == 0 else {
            throw SourceError.message("listen() failed")
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            var readSet = fd_set()
            _ = withUnsafeMutableBytes(of: &readSet) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            let fdIndex = Int(sock) / 32
            let fdBit = Int32(1) << (Int(sock) % 32)
            withUnsafeMutablePointer(to: &readSet.fds_bits) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Int32.self)
                raw[fdIndex] |= fdBit
            }
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            let ready = Darwin.select(sock + 1, &readSet, nil, nil, &tv)
            if ready <= 0 { continue }

            let client = Darwin.accept(sock, nil, nil)
            if client < 0 { continue }
            defer { Darwin.close(client) }

            var buf = [UInt8](repeating: 0, count: 8192)
            let n = Darwin.read(client, &buf, buf.count - 1)
            guard n > 0 else { continue }
            let reqStr = String(decoding: buf.prefix(n), as: UTF8.self)
            guard let firstLine = reqStr.split(separator: "\r\n", maxSplits: 1).first else { continue }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else { continue }
            let reqTarget = String(parts[1])
            let components = URLComponents(string: "http://127.0.0.1\(reqTarget)")
            let pathOnly = components?.path ?? "/"

            if expectedPath != "/" && pathOnly != expectedPath {
                let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = notFound.withCString { Darwin.write(client, $0, strlen($0)) }
                continue
            }

            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(pageText.utf8.count)\r\nConnection: close\r\n\r\n\(pageText)"
            _ = resp.withCString { Darwin.write(client, $0, strlen($0)) }

            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] {
                if query[item.name] == nil {
                    query[item.name] = item.value ?? ""
                }
            }
            return query
        }
        throw SourceError.message("timed out waiting for the sign-in to come back")
    }

    // MARK: - 通用 JS 函数调用与解码（附带超时保护防卡死）

    private func callJSJSON(
        _ functionName: String,
        args: [String: Any]? = nil,
        timeout: TimeInterval = defaultCallTimeout
    ) async throws -> Data? {
        guard can(functionName) else {
            throw SourceError.unsupported(functionName)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let stateLock = OSAllocatedUnfairLock(initialState: (finished: false, timer: nil as DispatchSourceTimer?))
            let finishOnce: @Sendable (Result<Data?, Error>) -> Void = { result in
                let shouldResume = stateLock.withLock { state -> Bool in
                    guard !state.finished else { return false }
                    state.finished = true
                    state.timer?.cancel()
                    state.timer = nil
                    return true
                }
                if shouldResume {
                    continuation.resume(with: result)
                }
            }

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self] in
                finishOnce(.failure(SourceError.message("Plugin call '\(functionName)' timed out")))
                if functionName != "signIn" {
                    self?.resetRuntime()
                }
            }
            stateLock.withLock { state in
                if !state.finished {
                    state.timer = timer
                    timer.resume()
                }
            }

            jsQueue.async {
                do {
                    let ctx = try self.ensureContext()
                    guard let exportsObj = ctx.objectForKeyedSubscript("__exports"),
                          let fn = exportsObj.objectForKeyedSubscript(functionName),
                          !fn.isUndefined else {
                        finishOnce(.failure(SourceError.unsupported(functionName)))
                        return
                    }

                    var callArgs: [Any] = []
                    if let args {
                        callArgs.append(args)
                    }
                    let result = fn.call(withArguments: callArgs)
                    if let ex = ctx.exception {
                        let err = Self.parseJSError(ex)
                        ctx.exception = nil
                        finishOnce(.failure(err))
                        return
                    }

                    guard let result, !result.isUndefined, !result.isNull else {
                        finishOnce(.success(nil))
                        return
                    }

                    if result.isObject, let thenFn = result.forProperty("then"), thenFn.isObject {
                        let onFulfilled: @convention(block) (JSValue) -> Void = { resolvedVal in
                            if resolvedVal.isUndefined || resolvedVal.isNull {
                                finishOnce(.success(nil))
                                return
                            }
                            let jsonVal = ctx.objectForKeyedSubscript("JSON")
                                .objectForKeyedSubscript("stringify")
                                .call(withArguments: [resolvedVal])
                            let jsonStr = jsonVal?.toString() ?? "null"
                            finishOnce(.success(Data(jsonStr.utf8)))
                        }
                        let onRejected: @convention(block) (JSValue) -> Void = { reasonVal in
                            finishOnce(.failure(Self.parseJSError(reasonVal)))
                        }
                        _ = result.invokeMethod("then", withArguments: [
                            JSValue(object: onFulfilled, in: ctx)!,
                            JSValue(object: onRejected, in: ctx)!
                        ])
                    } else {
                        let jsonVal = ctx.objectForKeyedSubscript("JSON")
                            .objectForKeyedSubscript("stringify")
                            .call(withArguments: [result])
                        let jsonStr = jsonVal?.toString() ?? "null"
                        finishOnce(.success(Data(jsonStr.utf8)))
                    }
                } catch {
                    finishOnce(.failure(error))
                }
            }
        }
    }

    private func callJSDecodable<T: Decodable>(_ type: T.Type, _ functionName: String, args: [String: Any]? = nil) async throws -> T {
        guard let data = try await callJSJSON(functionName, args: args) else {
            throw SourceError.unavailable("Empty response from \(functionName)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func parseJSError(_ jsVal: JSValue) -> SourceError {
        let code = jsVal.forProperty("code")?.toString()
        let message = jsVal.forProperty("message")?.toString() ?? jsVal.toString() ?? "Plugin error"
        switch code {
        case "signIn": return .signIn(message)
        case "setup": return .setup(message)
        case "unavailable": return .unavailable(message)
        case "unsupported": return .unsupported(message)
        default: return .message(message)
        }
    }

    private func stampTrack(_ track: Track) -> Track {
        var copy = track
        copy.source = manifest.id
        return copy
    }

    private func stampTracks(_ tracks: [Track]?) -> [Track]? {
        tracks?.map(stampTrack)
    }

    private func stampBrowse(_ browse: Browse) -> Browse {
        var b = browse
        if let sections = b.sections {
            b.sections = sections.map { sec in
                var s = sec
                s.tracks = stampTracks(s.tracks)
                return s
            }
        }
        return b
    }

    // MARK: - MusicSource 协议实现

    public func info() -> SourceInfo {
        let translatedSettings = manifest.settings?.map { s in
            PluginSettingSpec(
                key: s.key,
                label: translate(s.label),
                help: s.help.map(translate),
                link: s.link,
                type: s.type,
                options: s.options?.map { opt in
                    PluginSettingOption(value: opt.value, label: translate(opt.label))
                }
            )
        }
        let translatedNav = manifest.navigation?.map { n in
            NavItem(
                title: n.title.map(translate),
                page: n.page,
                builtin: n.builtin,
                icon: n.icon
            )
        }
        return SourceInfo(
            id: manifest.id,
            name: translate(manifest.name ?? manifest.id),
            version: manifest.version,
            playback: manifest.playback ?? .stream,
            settings: translatedSettings,
            navigation: translatedNav
        )
    }

    public func can(_ capability: String) -> Bool {
        transpiled.exports.contains(capability)
    }

    public func setting(_ key: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return settingsMap[key] ?? ""
    }

    public func setSetting(_ key: String, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            lock.lock()
            defer { lock.unlock() }
            if trimmed.isEmpty {
                settingsMap.removeValue(forKey: key)
            } else {
                settingsMap[key] = trimmed
            }
            try saveEncodableJSON(settingsMap, fileName: "settings.json")
        }

        if can("setSetting") {
            Task {
                _ = try? await callJSJSON("setSetting", args: ["key": key, "value": trimmed])
            }
        }
    }

    public func signIn() async throws -> Account? {
        guard let data = try await callJSJSON("signIn", timeout: Self.signInCallTimeout) else { return nil }
        return try JSONDecoder().decode(Account?.self, from: data)
    }

    public func signOut() async throws {
        _ = try await callJSJSON("signOut")
        flushStorageSync()
    }

    public func account() async throws -> Account? {
        guard can("account") else { return nil }
        guard let data = try await callJSJSON("account") else { return nil }
        return try JSONDecoder().decode(Account?.self, from: data)
    }

    public func search(query: String, kind: SearchKind, offset: Int) async throws -> SearchResult {
        var res = try await callJSDecodable(
            SearchResult.self,
            "search",
            args: ["query": query, "kind": kind.rawValue, "offset": offset]
        )
        res.tracks = stampTracks(res.tracks)
        return res
    }

    public func suggest(query: String) async throws -> [String] {
        try await callJSDecodable([String].self, "suggest", args: ["query": query])
    }

    public func playlists() async throws -> [Playlist] {
        var list = try await callJSDecodable([Playlist].self, "playlists")
        for i in list.indices {
            list[i].tracks = stampTracks(list[i].tracks)
        }
        return list
    }

    public func playlist(id: String) async throws -> Playlist {
        var pl = try await callJSDecodable(Playlist.self, "playlist", args: ["id": id])
        pl.tracks = stampTracks(pl.tracks)
        return pl
    }

    public func album(id: String) async throws -> AlbumPage {
        var page = try await callJSDecodable(AlbumPage.self, "album", args: ["id": id])
        page.tracks = stampTracks(page.tracks)
        return page
    }

    public func artist(id: String) async throws -> ArtistPage {
        var page = try await callJSDecodable(ArtistPage.self, "artist", args: ["id": id])
        page.tracks = stampTracks(page.tracks)
        return page
    }

    public func liked(offset: Int) async throws -> TrackPage {
        var page = try await callJSDecodable(TrackPage.self, "liked", args: ["offset": offset])
        page.tracks = stampTracks(page.tracks)
        return page
    }

    public func recent() async throws -> [Track] {
        let tracks = try await callJSDecodable([Track].self, "recent")
        return tracks.map(stampTrack)
    }

    public func home() async throws -> Browse {
        let b = try await callJSDecodable(Browse.self, "home")
        return stampBrowse(b)
    }

    public func browse(page: String) async throws -> Browse {
        let b = try await callJSDecodable(Browse.self, "browse", args: ["page": page])
        return stampBrowse(b)
    }

    public func isLiked(ids: [String]) async throws -> [String: Bool] {
        try await callJSDecodable([String: Bool].self, "isLiked", args: ["ids": ids])
    }

    public func like(id: String, on: Bool) async throws {
        _ = try await callJSJSON("like", args: ["id": id, "on": on])
    }

    public func likeEpisode(id: String, on: Bool) async throws {
        _ = try await callJSJSON("likeEpisode", args: ["id": id, "on": on])
    }

    public func createPlaylist(name: String) async throws -> Playlist {
        var pl = try await callJSDecodable(Playlist.self, "createPlaylist", args: ["name": name])
        pl.tracks = stampTracks(pl.tracks)
        return pl
    }

    public func renamePlaylist(id: String, name: String) async throws {
        _ = try await callJSJSON("renamePlaylist", args: ["id": id, "name": name])
    }

    public func deletePlaylist(id: String) async throws {
        _ = try await callJSJSON("deletePlaylist", args: ["id": id])
    }

    public func addToPlaylist(id: String, trackIds: [String]) async throws {
        _ = try await callJSJSON("addToPlaylist", args: ["id": id, "trackIds": trackIds])
    }

    public func removeFromPlaylist(id: String, trackIds: [String]) async throws {
        _ = try await callJSJSON("removeFromPlaylist", args: ["id": id, "trackIds": trackIds])
    }

    public func movePlaylistTrack(id: String, from: Int, to: Int) async throws {
        _ = try await callJSJSON("movePlaylistTrack", args: ["id": id, "from": from, "to": to])
    }

    public func savePlaylist(id: String, on: Bool) async throws {
        _ = try await callJSJSON("savePlaylist", args: ["id": id, "on": on])
    }

    public func followArtist(id: String, on: Bool) async throws {
        _ = try await callJSJSON("followArtist", args: ["id": id, "on": on])
    }

    public func saveAlbum(id: String, on: Bool) async throws {
        _ = try await callJSJSON("saveAlbum", args: ["id": id, "on": on])
    }

    public func savedAlbums(offset: Int) async throws -> AlbumList {
        try await callJSDecodable(AlbumList.self, "savedAlbums", args: ["offset": offset])
    }

    public func shows() async throws -> [Show] {
        try await callJSDecodable([Show].self, "shows")
    }

    public func show(id: String, offset: Int) async throws -> ShowPage {
        var page = try await callJSDecodable(ShowPage.self, "show", args: ["id": id, "offset": offset])
        page.episodes = stampTracks(page.episodes)
        return page
    }

    public func subscribeShow(id: String, on: Bool) async throws {
        _ = try await callJSJSON("subscribeShow", args: ["id": id, "on": on])
    }

    public func stations() async throws -> [Station] {
        try await callJSDecodable([Station].self, "stations")
    }

    public func stationNext(id: String) async throws -> [Track] {
        let tracks = try await callJSDecodable([Track].self, "stationNext", args: ["id": id])
        return tracks.map(stampTrack)
    }

    public func comments(trackId: String, offset: Int) async throws -> CommentPage {
        try await callJSDecodable(CommentPage.self, "comments", args: ["trackId": trackId, "offset": offset])
    }

    public func likeComment(trackId: String, commentId: String, on: Bool) async throws {
        _ = try await callJSJSON("likeComment", args: ["trackId": trackId, "commentId": commentId, "on": on])
    }

    public func postComment(trackId: String, text: String) async throws -> Comment {
        try await callJSDecodable(Comment.self, "postComment", args: ["trackId": trackId, "text": text])
    }

    public func lyrics(id: String) async throws -> RawLyrics {
        try await callJSDecodable(RawLyrics.self, "lyrics", args: ["id": id])
    }

    public func stream(id: String, quality: String) async throws -> StreamInfo {
        var st = try await callJSDecodable(StreamInfo.self, "stream", args: ["id": id, "quality": quality])
        if let u = URL(string: st.url),
           let ruleHeaders = headersFor(url: u, kind: PluginRequestHeaders.kindAudio) {
            var merged = ruleHeaders
            if let existing = st.headers {
                for (k, v) in existing {
                    merged[k] = v
                }
            }
            st.headers = merged
        }
        return st
    }

    public func played(track: Track) async {
        guard can("played") else { return }
        _ = try? await callJSJSON("played", args: ["id": track.id])
    }

    public func remotePlay(ids: [String], start: Int, position: Int64) async throws {
        _ = try await callJSJSON("remotePlay", args: ["ids": ids, "start": start, "position": position])
    }

    public func remotePause() async throws {
        _ = try await callJSJSON("remotePause")
    }

    public func remoteResume() async throws {
        _ = try await callJSJSON("remoteResume")
    }

    public func remoteSeek(position: Int64) async throws {
        _ = try await callJSJSON("remoteSeek", args: ["position": position])
    }

    public func remoteVolume(percent: Int) async throws {
        _ = try await callJSJSON("remoteVolume", args: ["percent": percent])
    }

    public func remoteState() async throws -> RemoteState? {
        guard let data = try await callJSJSON("remoteState") else { return nil }
        return try JSONDecoder().decode(RemoteState?.self, from: data)
    }

    public func remoteDevices() async throws -> [RemoteDevice] {
        try await callJSDecodable([RemoteDevice].self, "remoteDevices")
    }

    public func remoteUse(deviceId: String) async throws {
        _ = try await callJSJSON("remoteUse", args: ["deviceId": deviceId])
    }
}

// PluginEngine.swift
// 对应原项目 internal/plugin/plugin.go, host.go, headers.go, source.go
// 使用 Apple 原生 JavaScriptCore 执行 MyGo Music 的 JS/TS 插件

import CommonCrypto
import CryptoKit
import Foundation
@preconcurrency import JavaScriptCore

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
        navigation: [NavItem]? = nil
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
        let data = Data(text.utf8)
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
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
}

// MARK: - ES Module 语法转换器

/// 将插件中的 ES Module export 语法转换为 JavaScriptCore 可直接执行的脚本，并提取导出的函数名列表
public enum PluginModuleTranspiler {
    public struct TranspiledModule: Sendable {
        public let code: String
        public let exports: Set<String>
    }

    public static func transpile(_ source: String) -> TranspiledModule {
        var exports = Set<String>()
        var transformed = source

        // 1. 处理 export async function name(...)
        let asyncFnRegex = try! NSRegularExpression(pattern: #"(?m)^\s*export\s+async\s+function\s+([A-Za-z0-9_$]+)"#)
        for match in asyncFnRegex.matches(in: transformed, range: NSRange(transformed.startIndex..., in: transformed)) {
            if let r = Range(match.range(at: 1), in: transformed) {
                exports.insert(String(transformed[r]))
            }
        }
        transformed = asyncFnRegex.stringByReplacingMatches(
            in: transformed,
            range: NSRange(transformed.startIndex..., in: transformed),
            withTemplate: "async function $1"
        )

        // 2. 处理 export function name(...)
        let fnRegex = try! NSRegularExpression(pattern: #"(?m)^\s*export\s+function\s+([A-Za-z0-9_$]+)"#)
        for match in fnRegex.matches(in: transformed, range: NSRange(transformed.startIndex..., in: transformed)) {
            if let r = Range(match.range(at: 1), in: transformed) {
                exports.insert(String(transformed[r]))
            }
        }
        transformed = fnRegex.stringByReplacingMatches(
            in: transformed,
            range: NSRange(transformed.startIndex..., in: transformed),
            withTemplate: "function $1"
        )

        // 3. 处理 export const/let/var name = ...
        let varRegex = try! NSRegularExpression(pattern: #"(?m)^\s*export\s+(const|let|var)\s+([A-Za-z0-9_$]+)"#)
        for match in varRegex.matches(in: transformed, range: NSRange(transformed.startIndex..., in: transformed)) {
            if let r = Range(match.range(at: 2), in: transformed) {
                exports.insert(String(transformed[r]))
            }
        }
        transformed = varRegex.stringByReplacingMatches(
            in: transformed,
            range: NSRange(transformed.startIndex..., in: transformed),
            withTemplate: "$1 $2"
        )

        // 4. 处理 export { a, b as c }
        var aliasAssignments: [String] = []
        let listRegex = try! NSRegularExpression(pattern: #"(?m)^\s*export\s*\{([^}]+)\}\s*;?"#)
        let listMatches = listRegex.matches(in: transformed, range: NSRange(transformed.startIndex..., in: transformed))
        for match in listMatches {
            guard let innerRange = Range(match.range(at: 1), in: transformed) else { continue }
            let items = transformed[innerRange].split(separator: ",")
            for item in items {
                let parts = item.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                if parts.count == 3 && parts[1] == "as" {
                    let localName = parts[0]
                    let exportedName = parts[2]
                    exports.insert(exportedName)
                    aliasAssignments.append("globalThis.__exports[\"\(exportedName)\"] = \(localName);")
                } else if parts.count == 1 {
                    let name = parts[0]
                    exports.insert(name)
                    aliasAssignments.append("globalThis.__exports[\"\(name)\"] = \(name);")
                }
            }
        }
        transformed = listRegex.stringByReplacingMatches(
            in: transformed,
            range: NSRange(transformed.startIndex..., in: transformed),
            withTemplate: ""
        )

        // 组装模块包装代码
        var footer = "\nglobalThis.__exports = globalThis.__exports || {};\n"
        for name in exports {
            footer += "if (typeof \(name) !== 'undefined') { globalThis.__exports[\"\(name)\"] = \(name); }\n"
        }
        for assign in aliasAssignments {
            footer += assign + "\n"
        }

        let finalCode = "(function() {\n" + transformed + "\n" + footer + "})();"
        return TranspiledModule(code: finalCode, exports: exports)
    }
}

// MARK: - JavaScript 插件音乐源实现（对应 plugin.Plugin）

public final class JSPluginSource: MusicSource, @unchecked Sendable {
    public let manifest: PluginManifest
    public let pluginDir: URL
    public let dataDir: URL

    private let lock = NSLock()
    private let jsQueue = DispatchQueue(label: "com.mygomusic.plugin.js")
    private let transpiled: PluginModuleTranspiler.TranspiledModule
    private var locales: [String: [String: String]] = [:]
    private var settingsMap: [String: String] = [:]
    private var storageMap: [String: Any] = [:]
    private var context: JSContext?

    public var onOpenURL: (@Sendable (URL) -> Void)?
    public var onSignInPrompt: (@Sendable (SignInPrompt) -> Void)?
    public var onWebSignIn: (@Sendable (WebSignInRequest) async throws -> String)?

    private static let placeholderRegex = try! NSRegularExpression(pattern: #"\{(setting|storage):([^{}]+)\}"#)

    /// 从插件目录加载并编译插件（对应 plugin.Load）
    public init(pluginDir: URL, dataRootDir: URL) throws {
        self.pluginDir = pluginDir
        let manifestURL = pluginDir.appendingPathComponent("plugin.json")
        let manifestData = try Data(contentsOf: manifestURL)
        var loadedManifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

        guard PluginInstaller.isValidPluginID(loadedManifest.id) else {
            throw SourceError.message("\(pluginDir.path): plugin.json needs a valid id")
        }
        if loadedManifest.name == nil || loadedManifest.name?.isEmpty == true {
            loadedManifest.name = loadedManifest.id
        }
        if loadedManifest.playback == nil {
            loadedManifest.playback = .stream
        }
        if loadedManifest.main == nil || loadedManifest.main?.isEmpty == true {
            loadedManifest.main = "index.js"
        }

        self.manifest = loadedManifest
        self.dataDir = dataRootDir.appendingPathComponent(loadedManifest.id, isDirectory: true)

        let mainFile = pluginDir.appendingPathComponent(loadedManifest.main ?? "index.js")
        let rawSource = try String(contentsOf: mainFile, encoding: .utf8)
        self.transpiled = PluginModuleTranspiler.transpile(rawSource)

        self.locales = Self.loadLocales(from: pluginDir)
        self.settingsMap = Self.loadJSONDictionary(from: dataDir.appendingPathComponent("settings.json")) ?? [:]
        self.storageMap = Self.loadAnyJSONDictionary(from: dataDir.appendingPathComponent("storage.json")) ?? [:]
    }

    // MARK: - 本地化与持久化

    private static func loadLocales(from dir: URL) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        let localesDir = dir.appendingPathComponent("locales", isDirectory: true)
        for code in ["zh-CN"] {
            let fileURL = localesDir.appendingPathComponent("\(code).json")
            if let data = try? Data(contentsOf: fileURL),
               let dict = try? JSONDecoder().decode([String: String].self, from: data) {
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

    private func saveJSON(_ obj: Any, fileName: String) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        let target = dataDir.appendingPathComponent(fileName)
        try data.write(to: target, options: .atomic)
    }

    /// 插件内置翻译查找（对应 Plugin.t）
    public func translate(_ text: String) -> String {
        let lang = I18n.languageCode()
        if let dict = locales[lang], let tr = dict[text], !tr.isEmpty {
            return tr
        }
        return text
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
                              let data = try? JSONSerialization.data(withJSONObject: val),
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

    // MARK: - JSContext 初始化与 Host 注入

    private func ensureContext() throws -> JSContext {
        if let ctx = context {
            return ctx
        }
        guard let ctx = JSContext() else {
            throw SourceError.message("Failed to create JSContext")
        }

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

    private func installWebAPIPolyfills(into ctx: JSContext) {
        // console
        let consoleLog: @convention(block) () -> Void = { [weak self] in
            guard let self else { return }
            let args = JSContext.currentArguments() ?? []
            let msg = args.compactMap { ($0 as? JSValue)?.toString() }.joined(separator: " ")
            print("[plugin:\(self.manifest.id)] \(msg)")
        }
        let consoleObj = JSValue(newObjectIn: ctx)!
        consoleObj.setObject(consoleLog, forKeyedSubscript: "log" as NSString)
        consoleObj.setObject(consoleLog, forKeyedSubscript: "info" as NSString)
        consoleObj.setObject(consoleLog, forKeyedSubscript: "warn" as NSString)
        consoleObj.setObject(consoleLog, forKeyedSubscript: "error" as NSString)
        ctx.setObject(consoleObj, forKeyedSubscript: "console" as NSString)

        // setTimeout / clearTimeout / setInterval / clearInterval
        let setTimeoutBlock: @convention(block) (JSValue, JSValue) -> Int = { [weak self] callback, delayVal in
            let ms = max(0, Int(delayVal.toInt32()))
            let id = Int.random(in: 1...Int.max)
            self?.jsQueue.asyncAfter(deadline: .now() + .milliseconds(ms)) {
                _ = callback.call(withArguments: [])
            }
            return id
        }
        let clearTimeoutBlock: @convention(block) (Int) -> Void = { _ in }
        ctx.setObject(setTimeoutBlock, forKeyedSubscript: "setTimeout" as NSString)
        ctx.setObject(clearTimeoutBlock, forKeyedSubscript: "clearTimeout" as NSString)
        ctx.setObject(setTimeoutBlock, forKeyedSubscript: "setInterval" as NSString)
        ctx.setObject(clearTimeoutBlock, forKeyedSubscript: "clearInterval" as NSString)

        // atob / btoa 原生桥接
        let btoaBlock: @convention(block) (String) -> String = { str in
            return Data(str.utf8).base64EncodedString()
        }
        let atobBlock: @convention(block) (String) -> String = { b64 in
            guard let d = Data(base64Encoded: b64) else { return "" }
            return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
        }
        ctx.setObject(btoaBlock, forKeyedSubscript: "btoa" as NSString)
        ctx.setObject(atobBlock, forKeyedSubscript: "atob" as NSString)

        // 原生 fetch 桥接（带网络权限校验与二进制 Base64 支持）
        let nativeFetch: @convention(block) (String, JSValue, JSValue, JSValue) -> Void = { [weak self] urlString, optionsVal, resolve, reject in
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
            if optionsVal.isObject, let dict = optionsVal.toDictionary() {
                if let method = dict["method"] as? String {
                    request.httpMethod = method
                }
                if let headers = dict["headers"] as? [String: Any] {
                    for (k, v) in headers {
                        request.setValue("\(v)", forHTTPHeaderField: k)
                    }
                }
                if let bodyStr = dict["body"] as? String {
                    request.httpBody = Data(bodyStr.utf8)
                }
            }

            URLSession.shared.dataTask(with: request) { data, response, error in
                self.jsQueue.async {
                    if let error {
                        let message: String
                        if let urlError = error as? URLError,
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
                        _ = reject.call(withArguments: [message])
                        return
                    }
                    let httpResp = response as? HTTPURLResponse
                    let status = httpResp?.statusCode ?? 200
                    let rawData = data ?? Data()
                    let text = String(data: rawData, encoding: .utf8)
                        ?? String(data: rawData, encoding: .isoLatin1)
                        ?? ""
                    let base64 = rawData.base64EncodedString()
                    var headersMap: [String: String] = [:]
                    if let fields = httpResp?.allHeaderFields {
                        for (k, v) in fields {
                            headersMap["\(k)".lowercased()] = "\(v)"
                        }
                    }
                    let payload: [String: Any] = [
                        "status": status,
                        "ok": (200...299).contains(status),
                        "url": httpResp?.url?.absoluteString ?? urlString,
                        "text": text,
                        "base64": base64,
                        "headers": headersMap
                    ]
                    _ = resolve.call(withArguments: [payload])
                }
            }.resume()
        }
        ctx.setObject(nativeFetch, forKeyedSubscript: "__nativeFetch" as NSString)

        // 注入 fetch / URL / URLSearchParams / TextEncoder / TextDecoder polyfill
        let polyfillScript = """
        if (typeof URLSearchParams === 'undefined') {
            globalThis.URLSearchParams = class URLSearchParams {
                constructor(init) {
                    this._pairs = [];
                    if (!init) return;
                    if (typeof init === 'string') {
                        const s = init.startsWith('?') ? init.slice(1) : init;
                        if (!s) return;
                        for (const part of s.split('&')) {
                            const idx = part.indexOf('=');
                            if (idx >= 0) {
                                this._pairs.push([
                                    decodeURIComponent(part.slice(0, idx).replace(/\\+/g, ' ')),
                                    decodeURIComponent(part.slice(idx + 1).replace(/\\+/g, ' '))
                                ]);
                            } else {
                                this._pairs.push([decodeURIComponent(part.replace(/\\+/g, ' ')), '']);
                            }
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
                append(k, v) { this._pairs.push([String(k), String(v)]); }
                set(k, v) {
                    const key = String(k);
                    this._pairs = this._pairs.filter(p => p[0] !== key);
                    this._pairs.push([key, String(v)]);
                }
                get(k) {
                    const found = this._pairs.find(p => p[0] === String(k));
                    return found ? found[1] : null;
                }
                has(k) { return this._pairs.some(p => p[0] === String(k)); }
                delete(k) { this._pairs = this._pairs.filter(p => p[0] !== String(k)); }
                toString() {
                    return this._pairs.map(p => encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1])).join('&');
                }
            };
        }
        if (typeof URL === 'undefined') {
            globalThis.URL = class URL {
                constructor(url, base) {
                    let full = String(url || '');
                    if (base && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(full)) {
                        const b = String(base).replace(/\\/+$/, '');
                        full = full.startsWith('/') ? b + full : b + '/' + full;
                    }
                    const m = full.match(/^([a-zA-Z][a-zA-Z0-9+.-]*:)\\/\\/([^\\/?#]+)([^?#]*)(\\?[^#]*)?(#.*)?$/);
                    this.protocol = m ? m[1] : 'https:';
                    this.host = m ? m[2] : '';
                    this.hostname = this.host.split(':')[0];
                    this.port = this.host.includes(':') ? this.host.split(':')[1] : '';
                    this.pathname = (m && m[3]) ? m[3] : '/';
                    const rawSearch = (m && m[4]) ? m[4] : '';
                    this.hash = (m && m[5]) ? m[5] : '';
                    this.searchParams = new URLSearchParams(rawSearch);
                }
                get search() {
                    const s = this.searchParams.toString();
                    return s ? '?' + s : '';
                }
                get origin() { return this.protocol + '//' + this.host; }
                get href() { return this.origin + this.pathname + this.search + this.hash; }
                toString() { return this.href; }
            };
        }
        if (typeof TextEncoder === 'undefined') {
            globalThis.TextEncoder = class TextEncoder {
                encode(str) {
                    const utf8 = unescape(encodeURIComponent(String(str || '')));
                    const arr = new Uint8Array(utf8.length);
                    for (let i = 0; i < utf8.length; i++) arr[i] = utf8.charCodeAt(i);
                    return arr;
                }
            };
        }
        if (typeof TextDecoder === 'undefined') {
            globalThis.TextDecoder = class TextDecoder {
                decode(bytes) {
                    if (!bytes) return '';
                    const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
                    let bin = '';
                    for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
                    try { return decodeURIComponent(escape(bin)); } catch { return bin; }
                }
            };
        }
        globalThis.fetch = function(url, options) {
            const opts = Object.assign({}, options || {});
            if (opts.body && typeof opts.body !== 'string') {
                if (typeof URLSearchParams !== 'undefined' && opts.body instanceof URLSearchParams) {
                    opts.body = opts.body.toString();
                } else if (typeof opts.body === 'object') {
                    opts.body = JSON.stringify(opts.body);
                }
            }
            return new Promise(function(resolve, reject) {
                __nativeFetch(String(url), opts, function(raw) {
                    resolve({
                        status: raw.status,
                        ok: raw.ok,
                        url: raw.url,
                        headers: {
                            get: function(name) {
                                return raw.headers[String(name).toLowerCase()] || null;
                            },
                            has: function(name) {
                                return Boolean(raw.headers[String(name).toLowerCase()]);
                            }
                        },
                        text: function() { return Promise.resolve(raw.text); },
                        json: function() {
                            try {
                                return Promise.resolve(JSON.parse(raw.text));
                            } catch (e) {
                                return Promise.reject(e);
                            }
                        },
                        arrayBuffer: function() {
                            const bin = atob(raw.base64 || '');
                            const bytes = new Uint8Array(bin.length);
                            for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                            return Promise.resolve(bytes.buffer);
                        }
                    });
                }, function(errMsg) {
                    reject(new Error(errMsg));
                });
            });
        };
        """
        ctx.evaluateScript(polyfillScript)
    }

    private func installHostGlobal(into ctx: JSContext) {
        let hostObj = JSValue(newObjectIn: ctx)!
        hostObj.setObject("darwin", forKeyedSubscript: "platform" as NSString)
        hostObj.setObject("arm64", forKeyedSubscript: "arch" as NSString)
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
            if let data = try? JSONSerialization.data(withJSONObject: val, options: [.fragmentsAllowed]),
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
            self.storageMap[key] = obj
            try? self.saveJSON(self.storageMap, fileName: "storage.json")
            self.lock.unlock()
        }
        let storageRemove: @convention(block) (String) -> Void = { [weak self] key in
            guard let self else { return }
            self.lock.lock()
            self.storageMap.removeValue(forKey: key)
            try? self.saveJSON(self.storageMap, fileName: "storage.json")
            self.lock.unlock()
        }
        storageObj.setObject(storageGet, forKeyedSubscript: "get" as NSString)
        storageObj.setObject(storageSet, forKeyedSubscript: "set" as NSString)
        storageObj.setObject(storageRemove, forKeyedSubscript: "remove" as NSString)
        hostObj.setObject(storageObj, forKeyedSubscript: "storage" as NSString)

        // host.language() 与 host.t(text)
        let languageFn: @convention(block) () -> String = {
            return I18n.languageCode()
        }
        let translateFn: @convention(block) (String) -> String = { [weak self] text in
            return self?.translate(text) ?? text
        }
        let settingFn: @convention(block) (String) -> String = { [weak self] key in
            return self?.setting(key) ?? ""
        }
        hostObj.setObject(languageFn, forKeyedSubscript: "language" as NSString)
        hostObj.setObject(translateFn, forKeyedSubscript: "t" as NSString)
        hostObj.setObject(settingFn, forKeyedSubscript: "setting" as NSString)

        // host.crypto
        let cryptoObj = JSValue(newObjectIn: ctx)!
        let md5Fn: @convention(block) (String) -> String = { text in
            return PluginCrypto.md5Hex(text)
        }
        let aesEcbFn: @convention(block) (String, String) -> JSValue = { key, text in
            guard let ctx = JSContext.current() else { return JSValue(undefinedIn: nil) }
            do {
                let hex = try PluginCrypto.aesEcbEncryptHex(key: key, text: text)
                return JSValue(object: hex, in: ctx)
            } catch {
                ctx.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: ctx)
                return JSValue(undefinedIn: ctx)
            }
        }
        cryptoObj.setObject(md5Fn, forKeyedSubscript: "md5" as NSString)
        cryptoObj.setObject(aesEcbFn, forKeyedSubscript: "aesEcbEncrypt" as NSString)
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

        // host.webSignIn 原生桥接（对应 internal/plugin/host.go 中的 webSignIn）
        let nativeWebSignIn: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak self] optsVal, resolve, reject in
            guard let self else { return }
            guard let dict = optsVal.toDictionary() else {
                self.jsQueue.async {
                    _ = reject.call(withArguments: ["webSignIn requires an options object"])
                }
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
                self.jsQueue.async {
                    _ = reject.call(withArguments: ["webSignIn needs valid url, cookiesOf, and until"])
                }
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
                self.jsQueue.async {
                    _ = reject.call(withArguments: ["webSignIn is not available in this context"])
                }
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
                        _ = resolve.call(withArguments: [cookieHeader])
                    }
                } catch {
                    self.jsQueue.async {
                        _ = reject.call(withArguments: [error.localizedDescription])
                    }
                }
            }
        }
        ctx.setObject(nativeWebSignIn, forKeyedSubscript: "__nativeWebSignIn" as NSString)

        // host.waitForRedirect 原生桥接（对应 internal/plugin/host.go 中的 waitForRedirect）
        let nativeWaitForRedirect: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak self] optsVal, resolve, reject in
            guard let self else { return }
            var port: UInt16 = 0
            var expectedPath: String = "/"
            if optsVal.isNumber {
                port = UInt16(clamping: optsVal.toInt32())
            } else if optsVal.isObject, let dict = optsVal.toDictionary() {
                if let p = dict["port"] as? NSNumber {
                    port = UInt16(clamping: p.intValue)
                }
                if let pathStr = dict["path"] as? String, !pathStr.isEmpty {
                    expectedPath = pathStr.hasPrefix("/") ? pathStr : "/" + pathStr
                }
            }
            guard port >= 1024 else {
                self.jsQueue.async {
                    _ = reject.call(withArguments: ["waitForRedirect requires a port >= 1024"])
                }
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let fullURL = try Self.listenForSingleLocalRedirect(port: port, expectedPath: expectedPath)
                    self.jsQueue.async {
                        _ = resolve.call(withArguments: [fullURL])
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

    /// 在 127.0.0.1:<port> 启动一次性 HTTP 监听以捕获 OAuth 登录回调
    private static func listenForSingleLocalRedirect(port: UInt16, expectedPath: String) throws -> String {
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

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            var readSet = fd_set()
            _ = withUnsafeMutableBytes(of: &readSet) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            let fdIndex = Int(sock) / 32
            let fdBit = Int32(1) << (Int(sock) % 32)
            withUnsafeMutablePointer(to: &readSet.fds_bits) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Int32.self)
                raw[fdIndex] |= fdBit
            }
            var tv = timeval(tv_sec: 2, tv_usec: 0)
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
            let pathOnly = reqTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

            if expectedPath != "/" && pathOnly != expectedPath {
                let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = notFound.withCString { Darwin.write(client, $0, strlen($0)) }
                continue
            }

            let html = "<!doctype html><meta charset=utf-8><title>MyGo Music</title><style>body{font:16px -apple-system,sans-serif;padding:48px;text-align:center;background:#141416;color:#fff}</style><p>Done. You can close this tab and return to MyGo Music.</p>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            _ = resp.withCString { Darwin.write(client, $0, strlen($0)) }
            return "http://127.0.0.1:\(port)\(reqTarget)"
        }
        throw SourceError.message("Timed out waiting for sign-in redirect")
    }

    // MARK: - 通用 JS 函数调用与解码

    private func callJSJSON(_ functionName: String, args: [String: Any]? = nil) async throws -> Data? {
        guard can(functionName) else {
            throw SourceError.unsupported(functionName)
        }

        return try await withCheckedThrowingContinuation { continuation in
            jsQueue.async {
                do {
                    let ctx = try self.ensureContext()
                    guard let exportsObj = ctx.objectForKeyedSubscript("__exports"),
                          let fn = exportsObj.objectForKeyedSubscript(functionName),
                          !fn.isUndefined else {
                        continuation.resume(throwing: SourceError.unsupported(functionName))
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
                        continuation.resume(throwing: err)
                        return
                    }

                    guard let result, !result.isUndefined, !result.isNull else {
                        continuation.resume(returning: nil)
                        return
                    }

                    // 检测 Promise（具有 then 方法）
                    if result.isObject, let thenFn = result.forProperty("then"), thenFn.isObject {
                        let onFulfilled: @convention(block) (JSValue) -> Void = { resolvedVal in
                            if resolvedVal.isUndefined || resolvedVal.isNull {
                                continuation.resume(returning: nil)
                                return
                            }
                            let jsonVal = ctx.objectForKeyedSubscript("JSON")
                                .objectForKeyedSubscript("stringify")
                                .call(withArguments: [resolvedVal])
                            let jsonStr = jsonVal?.toString() ?? "null"
                            continuation.resume(returning: Data(jsonStr.utf8))
                        }
                        let onRejected: @convention(block) (JSValue) -> Void = { reasonVal in
                            continuation.resume(throwing: Self.parseJSError(reasonVal))
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
                        continuation.resume(returning: Data(jsonStr.utf8))
                    }
                } catch {
                    continuation.resume(throwing: error)
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
                link: s.link
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
        lock.lock()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            settingsMap.removeValue(forKey: key)
        } else {
            settingsMap[key] = trimmed
        }
        try saveJSON(settingsMap, fileName: "settings.json")
        lock.unlock()

        if can("setSetting") {
            Task {
                _ = try? await callJSJSON("setSetting", args: ["key": key, "value": trimmed])
            }
        }
    }

    public func signIn() async throws -> Account? {
        guard let data = try await callJSJSON("signIn") else { return nil }
        return try JSONDecoder().decode(Account?.self, from: data)
    }

    public func signOut() async throws {
        _ = try await callJSJSON("signOut")
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

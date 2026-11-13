// MyGoMusicTests.swift
// 验证 MyGo Music iOS 版核心引擎（歌词、JS 插件运行时、本地音乐库、律动算法、仓库解析）与原版 Go 实现的一致性

#if canImport(XCTest)
import AVFoundation
import Compression
import Foundation
import XCTest
@testable import MyGoMusicCore
@testable import MyGoMusicUI

final class MyGoMusicTests: XCTestCase {

    // MARK: - 1. 歌词解析、翻译对齐、逐字均摊与间奏检测测试

    func testLyricsEngineLRCAndTranslationAndSpreadWords() {
        let lrc = """
        [00:00.00]作词 : 林夕
        [00:01.00][00:10.00]Hello 世界
        [00:04.00]Second line
        """
        let translation = """
        [00:01.20]你好世界
        [00:04.10]第二行
        """

        let lines = LyricsEngine.build(lrc: lrc, translation: translation)
        XCTAssertEqual(lines.count, 4)

        // 第一行是作词演职员信息
        XCTAssertTrue(LyricsEngine.isCredit(lines[0].text))
        // 第二行 00:01.00 应匹配到 00:01.20 的翻译（差距 200ms < 1500ms）
        XCTAssertEqual(lines[1].text, "Hello 世界")
        XCTAssertEqual(lines[1].translation, "你好世界")
        // "Hello 世界" 应该被切分为 ["Hello ", "世", "界"] 三个逐字单元
        XCTAssertEqual(lines[1].words.map(\.text), ["Hello ", "世", "界"])

        // 测试二分查找当前歌词行
        XCTAssertEqual(LyricsEngine.index(in: lines, at: 0.5), 0)
        XCTAssertEqual(LyricsEngine.index(in: lines, at: 2.0), 1)
        XCTAssertEqual(LyricsEngine.index(in: lines, at: 5.0), 2)
        XCTAssertEqual(LyricsEngine.index(in: lines, at: 11.0), 3)

        // 测试间奏检测（忽略作词行，提取长度 >= 2.0s 的静音段）
        let quiets = LyricsEngine.quiets(in: lines, trackLength: 20.0, least: 2.0)
        XCTAssertFalse(quiets.isEmpty)
        // 最后一行 10s~16s 结束后到 20s 之间有 4s 尾奏
        XCTAssertEqual(quiets.last?.from, 16.0)
        XCTAssertEqual(quiets.last?.to, 20.0)
    }

    func testAppSettingsDecodesLegacyFilesWithMissingKeys() throws {
        let minimal = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(minimal.source, "kugou-lite")
        XCTAssertEqual(minimal.quality, .high)
        XCTAssertTrue(minimal.fog)
        XCTAssertTrue(minimal.smoke)
        XCTAssertTrue(minimal.fade)
        XCTAssertTrue(minimal.growFromCover)
        XCTAssertTrue(minimal.lockScreenLyrics)
        XCTAssertEqual(minimal.githubToken, "")
        XCTAssertTrue(minimal.pluginUpdates.isEmpty)
        XCTAssertTrue(minimal.searchHistory.isEmpty)

        let legacyJSON = #"{"language":"zh-CN","source":"local","volume":0.4}"#
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.language, .chinese)
        XCTAssertEqual(legacy.source, "local")
        XCTAssertEqual(legacy.volume, 0.4)
        XCTAssertTrue(legacy.fog)
        XCTAssertTrue(legacy.smoke)
        XCTAssertTrue(legacy.lockScreenLyrics)
    }

    // MARK: - 2. 无内置 demo 资源的 JavaScript 插件运行测试

    func testJavaScriptPluginRuntimeFromTemporaryFixture() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mygo-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let pluginsDir = tmpRoot.appendingPathComponent("plugins", isDirectory: true)
        let dataDir = tmpRoot.appendingPathComponent("plugin-data", isDirectory: true)
        let pluginDir = pluginsDir.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "id": "fixture",
            "name": "Fixture",
            "main": "index.js",
            "playback": "stream"
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try manifestData.write(to: pluginDir.appendingPathComponent("plugin.json"))
        let pluginSource = #"""
        const likes = {};
        const track = {
          id: "track-1", name: "Fixture Song", duration: 120000,
          artists: [{ id: "artist-1", name: "Fixture Artist" }],
          album: { id: "album-1", name: "Fixture Album", artists: [{ id: "artist-1", name: "Fixture Artist" }] }
        };
        export function home() { return { title: "Fixture Home", sections: [{ title: "Fixture Tracks", tracks: [track] }] }; }
        export function search(args) { return { tracks: args.query ? [track] : [] }; }
        export function suggest() { return ["Fixture Song"]; }
        export function lyrics() { return { lrc: "[00:01.00]Fixture lyric" }; }
        export function stream() { return { url: "https://example.com/fixture.mp3", type: "mp3" }; }
        export function isLiked(args) { const result = {}; args.ids.forEach(id => result[id] = !!likes[id]); return result; }
        export function like(args) { likes[args.id] = args.on; }
        """#
        try pluginSource.write(to: pluginDir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let discovered = PluginInstaller.discover(pluginsDir: pluginsDir, dataRootDir: dataDir)
        XCTAssertEqual(discovered.count, 1)

        let plugin = discovered[0]
        XCTAssertEqual(plugin.manifest.id, "fixture")
        XCTAssertTrue(plugin.can("home"))
        XCTAssertTrue(plugin.can("search"))
        XCTAssertTrue(plugin.can("lyrics"))
        XCTAssertTrue(plugin.can("stream"))

        let home = try await plugin.home()
        XCTAssertEqual(home.title, "Fixture Home")
        XCTAssertEqual(home.sections?.first?.tracks?.first?.source, "fixture")

        let search = try await plugin.search(query: "Fixture", kind: .tracks, offset: 0)
        XCTAssertEqual(search.tracks?.first?.name, "Fixture Song")
        XCTAssertEqual(search.tracks?.first?.source, "fixture")
        let suggestions = try await plugin.suggest(query: "Fi")
        XCTAssertEqual(suggestions, ["Fixture Song"])

        let rawLyrics = try await plugin.lyrics(id: "track-1")
        XCTAssertEqual(LyricsEngine.fromSource(rawLyrics).first?.text, "Fixture lyric")
        let stream = try await plugin.stream(id: "track-1", quality: "high")
        XCTAssertEqual(stream.type, "mp3")

        try await plugin.like(id: "track-1", on: true)
        let liked = try await plugin.isLiked(ids: ["track-1", "track-2"])
        XCTAssertEqual(liked["track-1"], true)
        XCTAssertEqual(liked["track-2"], false)

        let invalidPluginDir = tmpRoot.appendingPathComponent("invalid-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidPluginDir, withIntermediateDirectories: true)
        try manifestData.write(to: invalidPluginDir.appendingPathComponent("plugin.json"))
        let invalidUpdate = PendingPlugin(sourcePath: invalidPluginDir, manifest: plugin.manifest)
        XCTAssertThrowsError(try PluginInstaller.install(invalidUpdate, into: pluginsDir, dataRootDir: dataDir))
        XCTAssertTrue(PluginInstaller.discover(pluginsDir: pluginsDir, dataRootDir: dataDir).contains { $0.manifest.id == "fixture" })

        let traversal = PendingPlugin(sourcePath: invalidPluginDir, manifest: PluginManifest(id: "../escape"))
        XCTAssertThrowsError(try PluginInstaller.install(traversal, into: pluginsDir, dataRootDir: dataDir))
    }

    // MARK: - 3. 插件加密算法 (MD5 & AES-ECB) 与 RequestHeaders 占位符插值测试

    func testPluginCryptoAndRequestHeaders() throws {
        // 验证 MD5
        XCTAssertEqual(PluginCrypto.md5Hex("mygo-music"), "acb1fe17e40ab3ed67c6254f7aa15ab2")

        // 验证 AES-ECB + PKCS#7 填充加密
        let encryptedHex = try PluginCrypto.aesEcbEncryptHex(key: "0123456789abcdef", text: "hello mygo")
        XCTAssertEqual(encryptedHex.count, 32) // 16 字节块 -> 32 个十六进制字符

        // 验证网络权限通配符匹配
        let perms = PluginPermissions(network: ["api.example.com", "*.music.163.com"])
        XCTAssertTrue(perms.reaches(host: "api.example.com"))
        XCTAssertTrue(perms.reaches(host: "interface.music.163.com"))
        XCTAssertFalse(perms.reaches(host: "evil.com"))
    }

    // MARK: - 4. GitHub 仓库地址解析与本地音乐源扫描测试

    func testPluginInstallerParseRepoAndLocalSource() async throws {
        XCTAssertEqual(try PluginInstaller.parseRepo("egoist/mygo-music"), "egoist/mygo-music")
        XCTAssertEqual(try PluginInstaller.parseRepo("https://github.com/egoist/mygo-music-youtube-music/tree/main"), "egoist/mygo-music-youtube-music")
        XCTAssertEqual(try PluginInstaller.parseRepo("git@github.com:AkinoKaede/mygo-music-netease-cloud-music.git"), "AkinoKaede/mygo-music-netease-cloud-music")
        XCTAssertTrue(PluginInstaller.isNewerVersion("0.2.0", than: "0.1.20"))
        XCTAssertFalse(PluginInstaller.isNewerVersion("0.1.8", than: "0.1.20"))

        // 测试本地音乐源扫描与同目录 .lrc 歌词读取
        let tmpLocalDir = FileManager.default.temporaryDirectory.appendingPathComponent("mygo-local-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpLocalDir) }

        let local = LocalMusicSource(dataDir: tmpLocalDir)
        let pickedFolder = tmpLocalDir.appendingPathComponent("picked-folder", isDirectory: true)
        let nestedFolder = pickedFolder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        try Self.writeTestWAV(to: nestedFolder.appendingPathComponent("EGOIST - Departures.wav"))
        try "[00:01.00]あなたにおくるアイの歌".write(
            to: nestedFolder.appendingPathComponent("EGOIST - Departures.lrc"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(local.importAudioFiles([pickedFolder]), 1)
        XCTAssertEqual(local.trackCount(), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.defaultMusicFolder.appendingPathComponent("EGOIST - Departures.lrc").path))

        XCTAssertEqual(local.importAudioFiles([pickedFolder]), 1)
        XCTAssertEqual(local.trackCount(), 2)

        let searchRes = try await local.search(query: "Departures", kind: .tracks, offset: 0)
        XCTAssertEqual(searchRes.tracks?.count, 2)
        let track = searchRes.tracks![0]
        XCTAssertEqual(track.name, "Departures")
        XCTAssertEqual(track.artistNames, "EGOIST")

        let rawLyrics = try await local.lyrics(id: track.id)
        let parsedLyrics = LyricsEngine.fromSource(rawLyrics)
        XCTAssertEqual(parsedLyrics.count, 1)
        XCTAssertEqual(LyricsEngine.lang(of: parsedLyrics), "ja")
    }

    private static func writeTestWAV(to url: URL) throws {
        let sampleRate: UInt32 = 8_000
        let sampleCount: UInt32 = sampleRate
        let dataSize = sampleCount * 2
        var data = Data()
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36) + dataSize)
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(sampleRate)
        appendLE(sampleRate * 2)
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        data.append(contentsOf: "data".utf8)
        appendLE(dataSize)
        for index in 0..<sampleCount {
            let value = Int16(sin(Double(index) * 0.1) * 5_000)
            appendLE(value)
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - 5. 律动舞台物理与分行算法测试

    func testStageMathAlgorithms() {
        let lines = LyricsEngine.build(lrc: "[00:01.00]Spring words into the stage with sparks and glow")
        XCTAssertEqual(lines.count, 1)
        let line = lines[0]

        let shapes = StageMath.stageShapes(for: line, fontSize: 36)
        XCTAssertEqual(shapes.count, line.words.count)
        XCTAssertTrue(shapes.last?.last == true)

        let upcomingWord = line.words[line.words.count - 1]
        let upcomingState = StageMath.wordState(
            word: upcomingWord,
            shape: shapes[shapes.count - 1],
            pos: upcomingWord.start - 0.5
        )
        XCTAssertGreaterThan(upcomingState.opacity, 0, "未唱到的字仍应可辨认，整句不应缺字")

        let flowRows = StageMath.flowRows(for: line, shapes: shapes, fontSize: 36, availableWidth: 180)
        XCTAssertGreaterThan(flowRows.count, 1)
        XCTAssertEqual(flowRows.flatMap { $0 }, Array(line.words.indices))

        let partitaRows = StageMath.partitaRows(for: line, height: 600)
        XCTAssertFalse(partitaRows.isEmpty)

        let tiltParts = StageMath.tiltParts(for: line)
        XCTAssertFalse(tiltParts.isEmpty)
    }

    // MARK: - 6. 生态插件（B 站 / 网易云）TS 多文件打包、Polyfill 与容错解码测试

    func testEcosystemPluginTSBundlingAbortTimerGetSetCookieAndMinAppVersion() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mygo-eco-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let pluginsDir = tmpRoot.appendingPathComponent("plugins", isDirectory: true)
        let dataDir = tmpRoot.appendingPathComponent("plugin-data", isDirectory: true)
        let pluginDir = pluginsDir.appendingPathComponent("eco-sim", isDirectory: true)
        let libDir = pluginDir.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "id": "eco-sim",
            "name": "Eco Sim",
            "version": "1.0.0",
            "minAppVersion": "0.1.21",
            "main": "index.ts",
            "playback": "stream",
            "permissions": ["network": ["*.bilibili.com", "*.music.163.com"]],
            "settings": [
                ["key": "cookie", "label": "Cookie", "type": "password"],
                ["key": "mode", "label": "Mode", "type": "select", "options": [["value": "hi", "label": "Hi-Res"]]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            .write(to: pluginDir.appendingPathComponent("plugin.json"))

        try """
        export interface SignIn { bvid: string; }
        export function sign(arg: SignIn): string { return host.crypto.md5(arg.bvid); }
        export function splitSetCookies(): string[] {
            const h = new Headers([
                ["set-cookie", "A=1; Expires=Thu, 01 Jan 2099 00:00:00 GMT; Path=/"],
                ["set-cookie", "B=2; Path=/"]
            ]);
            return h.getSetCookie();
        }
        """.write(to: libDir.appendingPathComponent("utils.ts"), atomically: true, encoding: .utf8)

        try """
        import { sign, splitSetCookies } from "./lib/utils.ts";
        async function loadHome(): Promise<any> {
            const c = new AbortController();
            let fired = false;
            c.signal.addEventListener("abort", () => { fired = true; });
            c.abort();
            if (!c.signal.aborted || !fired) throw new Error("abort failed");
            const list = splitSetCookies();
            if (list.length !== 2) throw new Error("cookie split failed");
            let canceled = false;
            const bad = setTimeout(() => { canceled = true; }, 5);
            clearTimeout(bad);
            const label = await new Promise<string>((r) => setTimeout(() => r("ok"), 20));
            if (canceled) throw new Error("clearTimeout failed");
            return { title: sign({ bvid: "BV1" }) + ":" + label, sections: [] };
        }
        function resolveStream(): any {
            return { url: "https://upos.bilivideo.com/audio.m4s?x=1", type: "m4s", headers: { "Referer": "https://www.bilibili.com" } };
        }
        export { loadHome as home, resolveStream as stream };
        """.write(to: pluginDir.appendingPathComponent("index.ts"), atomically: true, encoding: .utf8)

        // 不满足 minAppVersion 的插件应被拒绝加载并记录到 failures
        let badDir = pluginsDir.appendingPathComponent("too-new", isDirectory: true)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["id": "too-new", "name": "Too New", "minAppVersion": "99.0.0", "main": "index.js"])
            .write(to: badDir.appendingPathComponent("plugin.json"))
        try "export function home() { return {}; }".write(to: badDir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let res = PluginInstaller.discoverDetailed(pluginsDir: pluginsDir, dataRootDir: dataDir)
        XCTAssertEqual(res.plugins.count, 1)
        XCTAssertEqual(res.failures.count, 1)
        let plugin = res.plugins[0]
        let home = try await plugin.home()
        XCTAssertTrue((home.title ?? "").hasSuffix(":ok"))
        let s = try await plugin.stream(id: "1", quality: "high")
        XCTAssertEqual(s.type, "m4s")

        let mergedCookies = PluginHTTPUtilities.splitSetCookieHeader(
            "MUSIC_U=abc; Expires=Thu, 01 Jan 2099 00:00:00 GMT; Path=/, __csrf=xyz; Path=/"
        )
        XCTAssertEqual(mergedCookies.count, 2)
    }

    // MARK: - 7. 磁盘缓存 LRU、流媒体 UTType、编码兼容与 .ogg 过滤测试

    func testCacheLRUStreamUTTypeTextFallbackAndCustomNavigation() throws {
        // AudioDiskCache LRU
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mygo-lru-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let cache = AudioDiskCache(cacheDir: cacheRoot)
        cache.limitMB = 1
        let payload = Data(repeating: 0x33, count: 480 * 1024)
        let k1 = AudioDiskCache.cacheKey(sourceID: "s", trackID: "1", quality: "high")
        let k2 = AudioDiskCache.cacheKey(sourceID: "s", trackID: "2", quality: "high")
        let k3 = AudioDiskCache.cacheKey(sourceID: "s", trackID: "3", quality: "high")
        _ = try cache.store(data: payload, key: k1, fileExtension: "mp3")
        Thread.sleep(forTimeInterval: 0.02)
        _ = try cache.store(data: payload, key: k2, fileExtension: "mp3")
        Thread.sleep(forTimeInterval: 0.02)
        _ = cache.cachedFileURL(forKey: k1)
        Thread.sleep(forTimeInterval: 0.02)
        _ = try cache.store(data: payload, key: k3, fileExtension: "mp3")
        XCTAssertNil(cache.cachedFileURL(forKey: k2))
        XCTAssertNotNil(cache.cachedFileURL(forKey: k1))
        XCTAssertNotNil(cache.cachedFileURL(forKey: k3))
        cache.clear()
        XCTAssertEqual(cache.usedBytes(), 0)

        // AudioStreamProxy UTType
        let biliURL = URL(string: "https://upos-sz-mirror.bilivideo.com/track?e=1")!
        XCTAssertEqual(AudioStreamProxy.resolveAudioUTType(streamType: "m4s", responseMIMEType: nil, url: biliURL), AVFileType.mp4.rawValue)
        XCTAssertEqual(AudioStreamProxy.resolveAudioUTType(streamType: "flac", responseMIMEType: nil, url: biliURL), "org.xiph.flac")
        XCTAssertEqual(AudioStreamProxy.resolveAudioUTType(streamType: nil, responseMIMEType: "audio/mpeg", url: biliURL), AVFileType.mp3.rawValue)

        // GB18030 解码与 .ogg 过滤
        let gbk = Data([0xC4, 0xE3, 0xBA, 0xC3]) // "你好"
        XCTAssertEqual(LocalMusicSource.decodeTextWithFallback(gbk), "你好")

        // 自定义导航标题
        let info = SourceInfo(id: "s", name: "S", navigation: [NavItem(title: "定制首页", builtin: "home", icon: "star")])
        XCTAssertEqual(info.customTitle(forBuiltin: "home"), "定制首页")
        XCTAssertEqual(info.customIcon(forBuiltin: "home"), "star")
    }

    // MARK: - 8. 进程权限授权持久化与顶层 JSON 基础类型安全编码回归测试

    @MainActor
    func testProcessPermissionGrantPersistenceAndJSONSafety() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mygo-grant-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let model = AppModel(baseDataDir: tmpRoot)
        let pluginDir = model.pluginsDir.appendingPathComponent("bili-grant-test", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "id": "bili-grant-test",
            "name": "Bili Grant Test",
            "version": "0.4.2",
            "main": "index.js",
            "permissions": [
                "network": ["api.bilibili.com", "*.bilivideo.com"],
                "process": ["ffmpeg"]
            ],
            "requestHeaders": [[
                "hosts": ["*.bilivideo.com"],
                "headers": ["X-Flag": "{storage:flag}", "X-Count": "{storage:count}"]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            .write(to: pluginDir.appendingPathComponent("plugin.json"))

        try """
        export function home() {
            host.storage.set("flag", true);
            host.storage.set("count", 42);
            return { title: "ok", sections: [] };
        }
        export function runSpawn() {
            return host.spawn({ command: "ffmpeg" });
        }
        """.write(to: pluginDir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        model.reloadPlugins()
        guard let plugin = model.pluginSources.first(where: { $0.manifest.id == "bili-grant-test" }) else {
            XCTFail("未发现测试插件")
            return
        }
        XCTAssertTrue(plugin.hasProcessPermissionDeclaration)
        XCTAssertFalse(plugin.isProcessGranted())

        // 触发 AppModel 授权流程，不应因顶层 Bool 序列化抛出 NSInvalidArgumentException
        model.grantProcessPermission(for: "bili-grant-test")
        XCTAssertTrue(plugin.isProcessGranted())

        // 重新加载后应保留授权状态
        model.reloadPlugins()
        let reloaded = model.pluginSources.first(where: { $0.manifest.id == "bili-grant-test" })
        XCTAssertEqual(reloaded?.isProcessGranted(), true)

        // 执行 storage 基础类型写入 + headers 插值 + 非法 JSON 安全兜底
        _ = try await reloaded?.home()
        let headers = reloaded?.headersFor(url: URL(string: "https://upos.bilivideo.com/a.m4s")!, kind: "audio")
        XCTAssertEqual(headers?["X-Flag"], "true")
        XCTAssertEqual(headers?["X-Count"], "42")
        XCTAssertNil(JSPluginSource.encodeAnyJSON(Double.nan))
        XCTAssertEqual(String(data: JSPluginSource.encodeAnyJSON(true) ?? Data(), encoding: .utf8), "true")
    }

    // MARK: - 10. 流媒体分流与 AudioStreamProxy 协议协商回归测试

    @MainActor
    func testStreamProxyProtocolNegotiationAndDirectRouting() async throws {
        // 1) 直链分流判定（网易云带 User-Agent/Referer 的 MP3/FLAC 优先直连携头播放；.m4s 与含 Cookie 走代理）
        let neteaseMP3 = StreamInfo(
            url: "https://m701.music.126.net/demo.mp3",
            type: "mp3",
            quality: "320",
            headers: ["User-Agent": "MockUA/1.0", "Referer": "https://music.163.com/"]
        )
        XCTAssertFalse(PlayerEngine.shouldUseStreamProxy(url: URL(string: neteaseMP3.url)!, stream: neteaseMP3))
        XCTAssertEqual(PlayerEngine.directAssetHTTPHeaders(for: neteaseMP3)["Referer"], "https://music.163.com/")

        let neteaseFLAC = StreamInfo(
            url: "https://m801.music.126.net/lossless.flac",
            type: "flac",
            quality: "lossless",
            headers: ["User-Agent": "MockUA/1.0", "Referer": "https://music.163.com/"]
        )
        XCTAssertFalse(PlayerEngine.shouldUseStreamProxy(url: URL(string: neteaseFLAC.url)!, stream: neteaseFLAC))

        let neteaseOuter = StreamInfo(url: "https://music.163.com/song/media/outer/url?id=999", headers: [:])
        XCTAssertFalse(PlayerEngine.shouldUseStreamProxy(url: URL(string: neteaseOuter.url)!, stream: neteaseOuter))

        let cookieMP3 = StreamInfo(url: "https://cdn.example.com/private.mp3", type: "mp3", headers: ["Cookie": "MUSIC_U=mock"])
        XCTAssertTrue(PlayerEngine.shouldUseStreamProxy(url: URL(string: cookieMP3.url)!, stream: cookieMP3))

        let biliM4S = StreamInfo(url: "https://upos.bilivideo.com/123.m4s", type: "audio/mp4", headers: ["Referer": "https://www.bilibili.com/"])
        XCTAssertTrue(PlayerEngine.shouldUseStreamProxy(url: URL(string: biliM4S.url)!, stream: biliM4S))

        // 无格式提示 URL 的代理路径不得伪造 .mp4 扩展名
        let rawNoExtProxy = AudioStreamProxy(
            remoteURL: URL(string: "https://cdn.example.com/audio?id=100")!,
            headers: [:],
            streamTypeHint: nil,
            cacheKey: nil,
            diskCache: nil
        )
        XCTAssertEqual(rawNoExtProxy.makeProxyAssetURL().pathExtension, "")

        // 2) 使用内存 WAV 数据 + URLProtocol 测试真实 AVURLAsset / AVPlayerItem 状态流转
        let wavData = Self.makeTestPCM16WAVData(durationSeconds: 0.35)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-stream-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let diskCache = AudioDiskCache(cacheDir: cacheDir)
        diskCache.limitMB = 20

        // 2a) 支持 206 Partial Content 的标准上游（带自定义 Header，URL 不含扩展名）
        MockAudioStreamURLProtocol.configure(payload: wavData, supportsByteRange: true)
        let config206 = URLSessionConfiguration.ephemeral
        config206.protocolClasses = [MockAudioStreamURLProtocol.self]

        let proxy206 = AudioStreamProxy(
            remoteURL: URL(string: "https://mock.music.126.net/stream?token=206")!,
            headers: ["Referer": "https://music.163.com/", "Cookie": "MUSIC_U=mock"],
            streamTypeHint: nil,
            cacheKey: "wav-206-key",
            diskCache: diskCache,
            sessionConfiguration: config206
        )
        let asset206 = AVURLAsset(url: proxy206.makeProxyAssetURL())
        asset206.resourceLoader.setDelegate(proxy206, queue: proxy206.delegateQueue)
        let item206 = AVPlayerItem(asset: asset206)
        let player206 = AVPlayer(playerItem: item206)
        player206.isMuted = true
        player206.play()

        let ready206 = try await Self.waitForReadyToPlay(item: item206, timeoutSeconds: 8)
        XCTAssertTrue(ready206, "206 分片响应下 AVPlayerItem 应进入 readyToPlay，而非卡死在缓冲")
        XCTAssertGreaterThan(MockAudioStreamURLProtocol.recordedRequestCount(), 0)
        XCTAssertEqual(MockAudioStreamURLProtocol.lastSeenReferer(), "https://music.163.com/")
        player206.pause()
        player206.replaceCurrentItem(with: nil as AVPlayerItem?)
        proxy206.invalidate()

        // 2b) 忽略 Range、直接返回 200 OK 的上游（不得误报 isByteRangeAccessSupported=true 或陷入死循环）
        MockAudioStreamURLProtocol.configure(payload: wavData, supportsByteRange: false)
        let config200 = URLSessionConfiguration.ephemeral
        config200.protocolClasses = [MockAudioStreamURLProtocol.self]

        let proxy200 = AudioStreamProxy(
            remoteURL: URL(string: "https://mock.music.126.net/stream?token=200")!,
            headers: ["User-Agent": "MockClient/1.0"],
            streamTypeHint: "wav",
            cacheKey: "wav-200-key",
            diskCache: diskCache,
            sessionConfiguration: config200
        )
        let asset200 = AVURLAsset(url: proxy200.makeProxyAssetURL())
        asset200.resourceLoader.setDelegate(proxy200, queue: proxy200.delegateQueue)
        let item200 = AVPlayerItem(asset: asset200)
        let player200 = AVPlayer(playerItem: item200)
        player200.isMuted = true
        player200.play()

        let ready200 = try await Self.waitForReadyToPlay(item: item200, timeoutSeconds: 8)
        XCTAssertTrue(ready200, "上游返回 200 OK（无 Range 支持）时 AVPlayerItem 仍应就绪，不得无限重发 Range 请求")
        XCTAssertLessThanOrEqual(MockAudioStreamURLProtocol.recordedRequestCount(), 4)
        player200.pause()
        player200.replaceCurrentItem(with: nil as AVPlayerItem?)
        proxy200.invalidate()

        // 2c) 上游未报错但中途截断响应字节时，不得伪报正常 EOF 从而卡死或污染磁盘缓存
        MockAudioStreamURLProtocol.configure(payload: wavData, supportsByteRange: false, behavior: .truncatedEOF)
        let configTruncated = URLSessionConfiguration.ephemeral
        configTruncated.protocolClasses = [MockAudioStreamURLProtocol.self]

        let proxyTruncated = AudioStreamProxy(
            remoteURL: URL(string: "https://mock.music.126.net/stream?token=trunc")!,
            headers: [:],
            streamTypeHint: "wav",
            cacheKey: "wav-truncated-key",
            diskCache: diskCache,
            sessionConfiguration: configTruncated
        )
        let assetTruncated = AVURLAsset(url: proxyTruncated.makeProxyAssetURL())
        assetTruncated.resourceLoader.setDelegate(proxyTruncated, queue: proxyTruncated.delegateQueue)
        let itemTruncated = AVPlayerItem(asset: assetTruncated)
        let playerTruncated = AVPlayer(playerItem: itemTruncated)
        playerTruncated.isMuted = true
        playerTruncated.play()

        let truncatedStatus = try await Self.waitForItemStatus(item: itemTruncated, timeoutSeconds: 6)
        XCTAssertEqual(truncatedStatus, .failed, "截断不完整的流应按失败处理并触发上层报错或重连，而非卡死或误认为成功")
        XCTAssertNil(diskCache.cachedFileURL(forKey: "wav-truncated-key"))
        playerTruncated.pause()
        playerTruncated.replaceCurrentItem(with: nil as AVPlayerItem?)
        proxyTruncated.invalidate()
    }

    @MainActor
    private static func waitForItemStatus(item: AVPlayerItem, timeoutSeconds: TimeInterval) async throws -> AVPlayerItem.Status {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if item.status == .readyToPlay || item.status == .failed {
                return item.status
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return item.status
    }

    @MainActor
    private static func waitForReadyToPlay(item: AVPlayerItem, timeoutSeconds: TimeInterval) async throws -> Bool {
        let status = try await waitForItemStatus(item: item, timeoutSeconds: timeoutSeconds)
        if status == .failed {
            XCTFail("AVPlayerItem 加载失败: \(item.error?.localizedDescription ?? "unknown")")
            return false
        }
        return status == .readyToPlay
    }

    /// 构造标准 16-bit 单声道 PCM WAV 音频字节，供 AVPlayerItem 内存端到端解码测试使用
    private static func makeTestPCM16WAVData(durationSeconds: Double, sampleRate: Int = 44100) -> Data {
        let frameCount = max(1, Int(Double(sampleRate) * durationSeconds))
        let dataByteCount = frameCount * 2
        let riffChunkSize = UInt32(36 + dataByteCount)

        var data = Data()
        data.reserveCapacity(44 + dataByteCount)
        func appendASCII(_ s: String) {
            data.append(contentsOf: s.utf8)
        }
        func appendLE16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendLE32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendLE32(riffChunkSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendLE32(16) // PCM fmt chunk size
        appendLE16(1)  // PCM format
        appendLE16(1)  // Mono
        appendLE32(UInt32(sampleRate))
        appendLE32(UInt32(sampleRate * 2))
        appendLE16(2)  // Block align
        appendLE16(16) // Bits per sample
        appendASCII("data")
        appendLE32(UInt32(dataByteCount))

        for i in 0..<frameCount {
            let sample = Int16(sin(2.0 * .pi * 440.0 * Double(i) / Double(sampleRate)) * 8000.0)
            appendLE16(UInt16(bitPattern: sample))
        }
        return data
    }

    // MARK: - 11. 锁屏媒体栏实时单行歌词映射与设置持久化测试

    @MainActor
    func testLockScreenLyricsMetadataAndSettingToggle() throws {
        let track = Track(
            id: "lock-track-1",
            source: "netease",
            name: "迷星叫",
            artists: [Artist(id: "a1", name: "MyGO!!!!!")],
            album: Album(id: "al1", name: "迷星叫 - Single"),
            duration: 210_000
        )
        let lines: [LyricLine] = [
            LyricLine(at: 5.0, text: "迷い子でもいい"),
            LyricLine(at: 10.0, text: "迷い子でもいいと", translation: "就算迷茫也无妨"),
            LyricLine(at: 16.0, text: "   ")
        ]

        // 1) 未进入首句歌词时间戳之前：显示原歌名和歌手
        let beforeFirst = PlayerEngine.buildNowPlayingDisplayMetadata(
            track: track,
            lyrics: lines,
            position: 1.5,
            lockScreenLyricsEnabled: true
        )
        XCTAssertEqual(beforeFirst.title, "迷星叫")
        XCTAssertEqual(beforeFirst.artist, "MyGO!!!!!")
        XCTAssertNil(beforeFirst.lyricIndex)

        // 2) 命中无翻译歌词行：主标题显示当前歌词，副标题显示 "歌名 - 歌手"
        let firstLine = PlayerEngine.buildNowPlayingDisplayMetadata(
            track: track,
            lyrics: lines,
            position: 6.2,
            lockScreenLyricsEnabled: true
        )
        XCTAssertEqual(firstLine.title, "迷い子でもいい")
        XCTAssertEqual(firstLine.artist, "迷星叫 - MyGO!!!!!")
        XCTAssertEqual(firstLine.lyricIndex, 0)

        // 3) 命中带翻译歌词行：主标题显示原文歌词，副标题显示 "翻译 · 歌名"
        let secondLine = PlayerEngine.buildNowPlayingDisplayMetadata(
            track: track,
            lyrics: lines,
            position: 11.0,
            lockScreenLyricsEnabled: true
        )
        XCTAssertEqual(secondLine.title, "迷い子でもいいと")
        XCTAssertEqual(secondLine.artist, "就算迷茫也无妨 · 迷星叫")
        XCTAssertEqual(secondLine.lyricIndex, 1)

        // 4) 命中空白清屏行：自动回退原曲信息，防止锁屏变空白
        let blankLine = PlayerEngine.buildNowPlayingDisplayMetadata(
            track: track,
            lyrics: lines,
            position: 17.0,
            lockScreenLyricsEnabled: true
        )
        XCTAssertEqual(blankLine.title, "迷星叫")
        XCTAssertEqual(blankLine.artist, "MyGO!!!!!")
        XCTAssertNil(blankLine.lyricIndex)

        // 5) 关闭开关后任何位置均只返回原曲信息，并验证 AppModel 持久化开关生效
        let disabledMeta = PlayerEngine.buildNowPlayingDisplayMetadata(
            track: track,
            lyrics: lines,
            position: 11.0,
            lockScreenLyricsEnabled: false
        )
        XCTAssertEqual(disabledMeta.title, "迷星叫")
        XCTAssertNil(disabledMeta.lyricIndex)

        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-locklyric-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let model = AppModel(baseDataDir: tmpRoot)
        XCTAssertTrue(model.settings.lockScreenLyrics)
        XCTAssertEqual(model.player.lockScreenLyricsProvider?(), true)

        model.settings.lockScreenLyrics = false
        let reloadedModel = AppModel(baseDataDir: tmpRoot)
        XCTAssertFalse(reloadedModel.settings.lockScreenLyrics)
        XCTAssertEqual(reloadedModel.player.lockScreenLyricsProvider?(), false)
    }

    // MARK: - 12. 烟雾进度特效定位与悬浮胶囊主视图基础校验

    @MainActor
    func testProgressSmokeLayoutAndMainViewConstruction() {
        XCTAssertEqual(ProgressSmokeView.anchorOffsetFromBottom(scale: 1.0), 10.0)
        XCTAssertEqual(ProgressSmokeView.anchorOffsetFromBottom(scale: 0.5), 5.0)

        let smoke = ProgressSmokeView(
            progress: 0.45,
            level: 0.6,
            horizontalInset: 6,
            scale: 1.0,
            useAdditiveBlend: true
        )
        XCTAssertEqual(smoke.horizontalInset, 6)
        XCTAssertEqual(smoke.scale, 1.0)
        XCTAssertTrue(smoke.useAdditiveBlend)

        // 验证桌面“小烟囱/火车排气”几何演化：初生贴口纤细非零 -> 随年龄向左上方斜飞散大
        let nozzleWisp = ProgressSmokeView.wispGeometry(
            spawnX: 200,
            anchorY: 118,
            birth: 100,
            age: 0.06,
            strength: 0.8,
            scale: 1.0,
            respectQuietGate: false
        )
        let driftedWisp = ProgressSmokeView.wispGeometry(
            spawnX: 200,
            anchorY: 118,
            birth: 100,
            age: 0.90,
            strength: 0.8,
            scale: 1.0,
            respectQuietGate: false
        )
        XCTAssertNotNil(nozzleWisp)
        XCTAssertNotNil(driftedWisp)
        if let n = nozzleWisp, let d = driftedWisp {
            XCTAssertLessThan(n.radiusX, 4.0, "刚离开白点喷口时应紧细清晰，不成大糊球")
            XCTAssertGreaterThan(n.alpha, 0.15, "紧贴喷口不可悬空透明断根")
            XCTAssertLessThan(d.center.x, 192.0, "蒸汽随时间向左侧斜向飘散")
            XCTAssertLessThan(d.center.y, 108.0, "蒸汽随时间向正上方升腾")
            XCTAssertGreaterThan(d.radiusX, n.radiusX * 2.2, "飘远后逐步扩散融为柔雾")
            XCTAssertLessThan(d.alpha, n.alpha, "尾部透明度随之自然消隐")
        }

        _ = MyGoTheme.brightenAccentColor(.gray)
        _ = MyGoTheme.mix(MyGoTheme.accent, with: .white, ratio: 0.35)

        // 验证遵循 Apple HIG 规范的悬浮液态玻璃底部导航栏尺寸（饱满圆润胶囊与同心内衬）
        XCTAssertGreaterThanOrEqual(FloatingTabBarMetrics.barHeight, 64.0)
        XCTAssertEqual(
            FloatingTabBarMetrics.activePillHeight,
            FloatingTabBarMetrics.barHeight - FloatingTabBarMetrics.outerInset * 2,
            accuracy: 0.01
        )
        XCTAssertGreaterThanOrEqual(FloatingTabBarMetrics.iconSize, 21.0)
        XCTAssertGreaterThan(FloatingTabBarMetrics.bottomInsetEmptyPlayer, FloatingTabBarMetrics.barHeight)
        XCTAssertGreaterThan(FloatingTabBarMetrics.bottomInsetWithMiniPlayer, FloatingTabBarMetrics.bottomInsetEmptyPlayer)

        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let model = AppModel(baseDataDir: tmpRoot)
        _ = MainView().environmentObject(model)
        _ = MiniPlayerBarView().environmentObject(model)
    }

    // MARK: - 13. 缓冲超时看门狗、OGG 格式拦截与灰色无权限歌曲队列跳过回归测试

    @MainActor
    func testPlayerEngineWatchdogTimeoutAndUnavailableQueueSkipping() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-watchdog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let wavData = Self.makeTestPCM16WAVData(durationSeconds: 0.35)
        let mockConfig = URLSessionConfiguration.ephemeral
        mockConfig.protocolClasses = [MockAudioStreamURLProtocol.self]

        let source = MockPlaybackSource()
        let engine = PlayerEngine(cacheDir: tmpDir)
        engine.directBufferTimeoutSeconds = 0.25
        engine.proxyBufferTimeoutSeconds = 0.35
        engine.proxySessionConfiguration = mockConfig
        engine.sourceResolver = { id in id == source.info().id ? source : nil }

        // 1) 卡死挂起流触发看门狗超时：应退出无限「正在缓冲…」转圈并展示超时提示
        MockAudioStreamURLProtocol.configure(payload: wavData, supportsByteRange: true, behavior: .stallForever)
        source.streamHandler = { _, _ in
            StreamInfo(
                url: "https://mock.music.126.net/stalled",
                type: nil,
                headers: ["Cookie": "MOCK=1"] // 直接进入 AudioStreamProxy 挂起验证看门狗
            )
        }
        let stallTrack = Track(id: "stall-1", source: source.info().id, name: "Stall Track")
        engine.playTrack([stallTrack], at: 0)

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline && (engine.isLoading || engine.errorMessage == nil) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(engine.isLoading, "长时间卡在缓冲的歌曲必须在看门狗超时后退出转圈状态")
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.errorMessage, I18n.t("Playback timed out while buffering. Please try again."))

        // 2) OGG 格式应提前报错拦截，不得无休止卡在解码阶段
        source.streamHandler = { _, _ in
            StreamInfo(url: "https://mock.music.126.net/song.ogg", type: "ogg", headers: ["Referer": "https://music.163.com/"])
        }
        let oggTrack = Track(id: "ogg-1", source: source.info().id, name: "OGG Track")
        engine.playTrack([oggTrack], at: 0)
        let oggDeadline = Date().addingTimeInterval(2.0)
        while Date() < oggDeadline && (engine.isLoading || engine.errorMessage == nil) {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertFalse(engine.isLoading)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertTrue(engine.errorMessage?.contains("OGG") == true)

        // 3) 灰色无权限（unavailable）歌曲：整单播/上一首/下一首自动跳过；单点灰歌保留明确无权限提示
        source.streamHandler = { id, _ in
            if id == "grey-0" || id == "grey-2" {
                throw SourceError.unavailable("当前账号无完整播放权限，或歌曲在当前地区不可用")
            }
            return StreamInfo(
                url: "https://mock.music.126.net/\(id).wav",
                type: "wav",
                headers: ["Cookie": "MOCK=1"]
            )
        }
        MockAudioStreamURLProtocol.configure(payload: wavData, supportsByteRange: true, behavior: .normal)
        let grey0 = Track(id: "grey-0", source: source.info().id, name: "Grey VIP 0", unavailable: true)
        let ok1 = Track(id: "ok-1", source: source.info().id, name: "Playable 1", unavailable: false)
        let grey2 = Track(id: "grey-2", source: source.info().id, name: "Grey VIP 2", unavailable: true)
        let ok3 = Track(id: "ok-3", source: source.info().id, name: "Playable 3", unavailable: false)

        engine.playQueue([grey0, ok1, grey2, ok3], start: 0)
        XCTAssertEqual(engine.currentTrack?.id, "ok-1")
        engine.next()
        XCTAssertEqual(engine.currentTrack?.id, "ok-3")
        engine.previous()
        XCTAssertEqual(engine.currentTrack?.id, "ok-1")

        // 全灰列表直接提示无可用曲目，不再空转加载
        engine.playQueue([grey0, grey2], start: 0)
        XCTAssertFalse(engine.isLoading)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.errorMessage, I18n.t("No playable tracks in this list (VIP or copyright restricted)"))

        // 用户主动点某首灰歌时仍给出明确插件原因
        engine.playTrack([grey0, ok1], at: 0)
        let unavailDeadline = Date().addingTimeInterval(2.0)
        while Date() < unavailDeadline && (engine.isLoading || engine.errorMessage == nil) {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertFalse(engine.isLoading)
        XCTAssertTrue(engine.errorMessage?.contains("完整播放权限") == true)
        engine.pause()

        // 4) 带 Referer 的标准 wav 优先走原生直连；当直连不可达进入 .failed 或超时卡顿时自动静默回退 AudioStreamProxy 重试并成功就绪
        engine.directBufferTimeoutSeconds = 0.25
        engine.proxyBufferTimeoutSeconds = 4.0
        source.streamHandler = { id, _ in
            StreamInfo(
                url: "https://mock.music.126.net/\(id).wav",
                type: "wav",
                headers: ["User-Agent": "MockUA/1.0", "Referer": "https://music.163.com/"]
            )
        }
        MockAudioStreamURLProtocol.configure(payload: wavData, supportsByteRange: true, behavior: .normal)
        let fallbackTrack = Track(id: "fallback-1", source: source.info().id, name: "Fallback Track", unavailable: false)
        engine.playTrack([fallbackTrack], at: 0)
        let fbDeadline = Date().addingTimeInterval(5.0)
        while Date() < fbDeadline && (MockAudioStreamURLProtocol.recordedRequestCount() == 0 || engine.isLoading) {
            if engine.errorMessage != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(MockAudioStreamURLProtocol.recordedRequestCount(), 0, "直连失败后应自动回退 AudioStreamProxy 并带上 Referer 发起重试")
        XCTAssertEqual(MockAudioStreamURLProtocol.lastSeenReferer(), "https://music.163.com/")
        XCTAssertFalse(engine.isLoading)
        XCTAssertNil(engine.errorMessage)
        engine.pause()
    }

    @MainActor
    func testStageVisualizerUpgradedPhysicsFFTAndRhythmSync() async throws {
        // 1) 拖动进度预览与播放时钟接管
        XCTAssertEqual(
            StageMath.stagePosition(playbackPosition: 12.0, scrubbingPosition: 42.5),
            42.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            StageMath.stagePosition(playbackPosition: 12.0, scrubbingPosition: nil),
            12.025,
            accuracy: 0.0001
        )

        // 2) 旧行 0.40s easeOutCubic 叠化退场斜率 ((1 - 0.5)^3 = 0.125)
        XCTAssertEqual(StageMath.lineExitOpacity(nextLineStart: 10.0, at: 10.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(StageMath.lineExitOpacity(nextLineStart: 10.0, at: 10.2), 0.125, accuracy: 0.0001)
        XCTAssertEqual(StageMath.lineExitOpacity(nextLineStart: 10.0, at: 10.4), 0.0, accuracy: 0.0001)

        // 3) 构造含逐字时间轴的测试歌词与长短对比
        let shortWords = [
            LyricWord(text: "迷", start: 10.0, end: 10.35),
            LyricWord(text: "子", start: 10.35, end: 10.7),
            LyricWord(text: "と", start: 10.7, end: 11.0),
            LyricWord(text: "な", start: 11.0, end: 11.4),
            LyricWord(text: "る", start: 11.4, end: 11.9)
        ]
        let stageLine = LyricLine(at: 10.0, end: 12.2, text: "迷子となる", words: shortWords)

        // Flow 舞台落位（命中桌面三档高度表 [-0.11, 0.0, 0.09]）
        let flowPlace = StageMath.flowPlacement(for: stageLine, containerWidth: 360)
        XCTAssertTrue([-0.11, 0.0, 0.09].contains(flowPlace.verticalShiftRatio))

        // 光束火花数：普通词 9 条 / 行末词 16 条 / 超出持续时长清空
        let midSparks = StageMath.sparkStreaks(size: CGSize(width: 44, height: 48), since: 0.14, seed: 10.0, isLastWord: false)
        let lastSparks = StageMath.sparkStreaks(size: CGSize(width: 44, height: 48), since: 0.14, seed: 11.4, isLastWord: true)
        XCTAssertEqual(midSparks.count, 9)
        XCTAssertEqual(lastSparks.count, 16)
        XCTAssertTrue(StageMath.sparkStreaks(size: CGSize(width: 44, height: 48), since: 1.5, seed: 10.0, isLastWord: false).isEmpty)

        // Steps 导标状态三阶段流转
        let pRow = PartitaRow(from: 0, to: shortWords.count, x: -24, y: 12, scale: 1.0, left: true)
        let upcomingRow = StageMath.partitaRowMotion(words: shortWords[...], row: pRow, pos: 8.5)
        let singingRow = StageMath.partitaRowMotion(words: shortWords[...], row: pRow, pos: 10.5)
        let pastRow = StageMath.partitaRowMotion(words: shortWords[...], row: pRow, pos: 12.5)
        XCTAssertEqual(upcomingRow.guideState, .upcoming)
        XCTAssertEqual(singingRow.guideState, .singing)
        XCTAssertEqual(pastRow.guideState, .past)
        XCTAssertGreaterThan(singingRow.guideProgress, 0.5)

        // Tilt 超宽文本自适应防折行字号压缩 + 斜体上下交错波浪
        var wideWords: [LyricWord] = []
        for idx in 0..<24 {
            let st = 20.0 + Double(idx) * 0.18
            wideWords.append(LyricWord(text: "響", start: st, end: st + 0.18))
        }
        let wideLine = LyricLine(at: 20.0, end: 25.0, text: String(repeating: "響", count: 24), words: wideWords)
        let fitted = StageMath.fitTiltLayout(for: wideLine, maxWidth: 210, baseFontSize: 38)
        XCTAssertLessThan(fitted.fontSize, 38.0)
        XCTAssertGreaterThanOrEqual(fitted.fittedLineRatio, 0.48)

        let leanPart = TiltPart(from: 0, to: 4, lean: true, tail: false)
        let evenChar = StageMath.tiltCharMotion(partSince: 0.25, charDuration: 0.35, charStart: 10.0, charOrderIndex: 0, part: leanPart, size: 32, pos: 10.12)
        let oddChar = StageMath.tiltCharMotion(partSince: 0.25, charDuration: 0.35, charStart: 10.35, charOrderIndex: 1, part: leanPart, size: 32, pos: 10.12)
        XCTAssertLessThan(evenChar.waveOffsetY * oddChar.waveOffsetY, 0, "斜体倾诉句相邻字符应当上下交替波浪错位")

        // 4) Quiet 静音热评调度 (>=8s 且过滤 >140字超长评论)
        let quietLines = [
            LyricLine(at: 1.0, end: 4.0, text: "第一句", words: [LyricWord(text: "第一句", start: 1.0, end: 4.0)]),
            LyricLine(at: 26.0, end: 30.0, text: "副歌开始", words: [LyricWord(text: "副歌", start: 26.0, end: 28.0)])
        ]
        let validComment = Comment(id: "c1", author: "燈", text: "一辈子一起组乐队吧", likes: 520)
        let tooLongComment = Comment(id: "c2", author: "长文", text: String(repeating: "啊", count: 150), likes: 10)
        XCTAssertNil(
            StageMath.activeQuietComment(
                lines: quietLines,
                trackDuration: 60.0,
                lyricsLoaded: true,
                hotCommentsEnabled: true,
                comments: [validComment, tooLongComment],
                at: 4.5
            ),
            "静音前 1.2s 内不应过早弹出热评"
        )
        let midQuiet = StageMath.activeQuietComment(
            lines: quietLines,
            trackDuration: 60.0,
            lyricsLoaded: true,
            hotCommentsEnabled: true,
            comments: [tooLongComment, validComment],
            at: 12.0
        )
        XCTAssertEqual(midQuiet?.comment.id, "c1", "应过滤超长评论并精准命中有效热评")
        let dots = StageMath.interludeDotsState(pos: 25.4, from: 4.0, to: 26.0)
        XCTAssertGreaterThan(dots.preCuePulse, 0.3, "间奏将尽前 1.2s 应激活起唱预提醒")

        // 5) 音律平滑滤波 + 歌词节拍启发式包络
        let high = AudioRhythmState(bands: [0.95, 0.70, 0.85, 0.40, 0.25], bass: 0.92, vocal: 0.88, treble: 0.35, energy: 0.85, beatPulse: 0.95, isRealAudio: true)
        let low = AudioRhythmState.idle
        let attacked = high.smoothed(from: low, dt: 1.0 / 60.0)
        let decayed = low.smoothed(from: high, dt: 1.0 / 60.0)
        XCTAssertGreaterThan(attacked.bass - low.bass, high.bass - decayed.bass, "Attack 响应速率应快于 Decay 回落")

        let fallbackRhythm = StageMath.lyricRhythm(at: 10.35, lines: [stageLine], isPlaying: true)
        XCTAssertFalse(fallbackRhythm.isRealAudio)
        XCTAssertGreaterThan(fallbackRhythm.beatPulse, 0.2)

        // 6) 本地重低音 85Hz WAV 真音频 vDSP FFT 扫谱与 PlayerEngine.sampleAudioRhythm 闭环校验
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage-bass-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let sampleRate = 44_100
        let totalSamples = sampleRate * 2 // 2秒 85Hz 纯重低音脉冲 WAV
        var pcm = [Int16](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            let t = Double(i) / Double(sampleRate)
            // 每 0.5 秒一个强低频鼓点包络 + 持续 85Hz 贝斯
            let beatPhase = t.truncatingRemainder(dividingBy: 0.5)
            let env = beatPhase < 0.14 ? 0.92 : 0.35
            let v = sin(2.0 * .pi * 85.0 * t) * env
            pcm[i] = Int16(max(-32767, min(32767, Int(v * 30000.0))))
        }
        var wavBytes = Data()
        func appendLE16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { wavBytes.append(contentsOf: $0) } }
        func appendLE32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { wavBytes.append(contentsOf: $0) } }
        let dataChunkSize = UInt32(totalSamples * 2)
        wavBytes.append(contentsOf: "RIFF".utf8); appendLE32(36 + dataChunkSize)
        wavBytes.append(contentsOf: "WAVE".utf8)
        wavBytes.append(contentsOf: "fmt ".utf8); appendLE32(16)
        appendLE16(1); appendLE16(1) // PCM, Mono
        appendLE32(UInt32(sampleRate)); appendLE32(UInt32(sampleRate * 2))
        appendLE16(2); appendLE16(16)
        wavBytes.append(contentsOf: "data".utf8); appendLE32(dataChunkSize)
        pcm.withUnsafeBytes { wavBytes.append(contentsOf: $0) }
        try wavBytes.write(to: wavURL, options: .atomic)

        let engine = PlayerEngine(cacheDir: FileManager.default.temporaryDirectory.appendingPathComponent("fft-test-cache-\(UUID().uuidString)", isDirectory: true))
        let mockSource = MockPlaybackSource()
        mockSource.streamHandler = { _, _ in
            StreamInfo(url: wavURL.absoluteString, type: "wav")
        }
        engine.sourceResolver = { _ in mockSource }
        let localTrack = Track(
            id: "fft-bass-test",
            source: mockSource.info().id,
            name: "Bass Pulse WAV",
            duration: 2
        )
        engine.playQueue([localTrack], start: 0)
        var sampled = AudioRhythmState.idle
        let fftDeadline = Date().addingTimeInterval(5.0)
        while Date() < fftDeadline {
            sampled = engine.sampleAudioRhythm(at: 0.06, lines: [stageLine], isScrubbing: true)
            if sampled.isRealAudio && sampled.bass > 0.25 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        engine.pause()

        XCTAssertTrue(sampled.isRealAudio, "本地 WAV 应当由 vDSP 硬件 FFT 解码出真实音频节拍")
        XCTAssertGreaterThan(sampled.bass, sampled.treble, "85Hz 重低音测试波的低频能量必须显著高于高频空气感能量")
        XCTAssertGreaterThan(Double(sampled.bands[0]), Double(sampled.bands[4]))
    }

    @MainActor
    func testStageVisualizerMotionSafetyAndPanePersistence() throws {
        // 1) 验证开启过律动视图（lyricsStage == true）的设置持久化后，启动默认面板自动恢复为 .stage
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage-pane-persist-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let stageDir = tempRoot.appendingPathComponent("stage-enabled", isDirectory: true)
        let lyricsDir = tempRoot.appendingPathComponent("lyrics-default", isDirectory: true)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lyricsDir, withIntermediateDirectories: true)

        var stageSettings = AppSettings()
        stageSettings.lyricsStage = true
        stageSettings.stageStyle = .partita
        try JSONEncoder().encode(stageSettings).write(to: stageDir.appendingPathComponent("settings.json"))

        let stageApp = AppModel(baseDataDir: stageDir)
        XCTAssertEqual(stageApp.activeNowPlayingPane, .stage, "保存了 lyricsStage=true 后启动时应恢复为律动面板")

        var lyricsSettings = AppSettings()
        lyricsSettings.lyricsStage = false
        try JSONEncoder().encode(lyricsSettings).write(to: lyricsDir.appendingPathComponent("settings.json"))

        let lyricsApp = AppModel(baseDataDir: lyricsDir)
        XCTAssertEqual(lyricsApp.activeNowPlayingPane, .lyrics, "未开启律动时默认应处于滚动歌词面板")

        // 2) 验证窄屏 Flow 断行与渲染间距一致，不再提前把「春日影」拆成两行
        let lrc = """
        [00:01.00]MyGO!!!!! - 春日影
        [00:04.00]迷星叫响在暮色街头
        [00:07.00]穿过清晨微风
        """
        let lines = LyricsEngine.build(lrc: lrc, translation: "")
        XCTAssertEqual(lines.count, 3)

        let stageContentWidth = 345.0 // 393pt iPhone 16 Pro 减去左右各 24pt 安全边距
        let titleFontSize = min(40.0, 393.0 * 0.078) * 0.88 // 与 StageFlowLineView 13~22字自适应字号一致 (~27pt)
        let shapes = StageMath.stageShapes(for: lines[0], fontSize: titleFontSize, spreadScale: 0.42)
        let rows = StageMath.flowRows(
            for: lines[0],
            shapes: shapes,
            fontSize: titleFontSize,
            availableWidth: stageContentWidth,
            marginScale: 0.92
        )
        XCTAssertEqual(rows.count, 1, "iPhone 16 Pro 可用宽度下『MyGO!!!!! - 春日影』应完整保持在同一行不误劈")

        let nineCharFontSize = min(40.0, 393.0 * 0.078) * 0.94
        let shapes2 = StageMath.stageShapes(for: lines[1], fontSize: nineCharFontSize, spreadScale: 0.42)
        let rows2 = StageMath.flowRows(
            for: lines[1],
            shapes: shapes2,
            fontSize: nineCharFontSize,
            availableWidth: stageContentWidth,
            marginScale: 0.92
        )
        XCTAssertEqual(rows2.count, 1, "9字常规歌词在手机端居中宽度下应整行舒展展示")

        // 3) 验证连续时间采样时行索引、词动态以及旧行叠化退场持续推进
        XCTAssertEqual(LyricsEngine.index(in: lines, at: 0.5), -1)
        XCTAssertEqual(LyricsEngine.index(in: lines, at: 3.2), 0)
        XCTAssertEqual(LyricsEngine.index(in: lines, at: 6.2), 1)

        let targetWord = lines[0].words[1]
        let targetShape = shapes[1]
        let stateBefore = StageMath.stageWordState(word: targetWord, shape: targetShape, pos: 0.5)
        let stateActive = StageMath.stageWordState(word: targetWord, shape: targetShape, pos: targetWord.start + 0.12)
        XCTAssertGreaterThan(stateActive.opacity, stateBefore.opacity, "进入演唱时刻时单词不透明度必须提升")
        XCTAssertGreaterThan(stateActive.scale, stateBefore.scale, "进入演唱时刻时单词缩放应弹跳放大")
        XCTAssertGreaterThan(stateActive.brightness, stateBefore.brightness, "进入演唱时刻时单词亮度应点亮")

        let exitOpacityMid = StageMath.lineExitOpacity(nextLineStart: lines[1].at, at: lines[1].at + 0.15)
        XCTAssertGreaterThan(exitOpacityMid, 0.0)
        XCTAssertLessThan(exitOpacityMid, 1.0, "切换至下一句时旧行应在 0.4s 退场窗口内平滑叠化消隐")

        // 4) 验证 Flow 在 3s 整倍时间戳下不再全数共振锁死在同一落位（左上角）
        let periodicLines = (0..<12).map { idx in
            LyricLine(
                at: TimeInterval(idx * 3),
                end: TimeInterval(idx * 3 + 2),
                text: "第\(idx)句示例歌词",
                words: [LyricWord(text: "第\(idx)句示例歌词", start: TimeInterval(idx * 3), end: TimeInterval(idx * 3 + 2))]
            )
        }
        let placements = periodicLines.map { StageMath.flowPlacement(for: $0, containerWidth: 345) }
        XCTAssertGreaterThan(Set(placements.map(\.alignment)).count, 1, "Flow 横向错落不应在 3s 周期时间戳上全部锁死于左上角")
        XCTAssertGreaterThan(Set(placements.map(\.verticalShiftRatio)).count, 1, "Flow 纵向浮沉不应全部锁死在顶部")
    }

    // MARK: - 16. 系统硬件音量双向同步与防回弹拖动锁测试

    @MainActor
    func testSystemVolumeObserverBidirectionalSyncAndDragLock() async throws {
        var fakeSystemVolume = 0.35
        var writtenValues: [Double] = []

        let observer = SystemVolumeObserver(
            readSystemVolume: { fakeSystemVolume },
            writeSystemVolume: { newVal in
                writtenValues.append(newVal)
                fakeSystemVolume = newVal
            },
            autoStart: false
        )

        // 1) 初始化应与系统音量对齐
        XCTAssertEqual(observer.volume, 0.35, accuracy: 0.001)

        // 2) 模拟按下实体音量键：外部系统音量升至 0.62，UI 同步跟随
        fakeSystemVolume = 0.62
        observer.receiveExternalVolumeUpdate(0.62)
        XCTAssertEqual(observer.volume, 0.62, accuracy: 0.001)

        // 3) 模拟用户拖动滑块：期间阻止 KVO 旧值回弹，松手后对齐实际步进后的硬件值
        observer.beginDragging()
        XCTAssertTrue(observer.isDragging)
        observer.setUserVolume(0.85)
        XCTAssertEqual(observer.volume, 0.85, accuracy: 0.001)
        XCTAssertEqual(writtenValues.last ?? -1, 0.85, accuracy: 0.001)

        observer.receiveExternalVolumeUpdate(0.62)
        XCTAssertEqual(observer.volume, 0.85, accuracy: 0.001, "拖动过程中应屏蔽系统旧值反向覆盖")

        // 模拟硬件步进（如 iPhone 16 级步长）实际落在 0.8125
        fakeSystemVolume = 0.8125
        observer.endDragging(unlockDelayNanoseconds: 20_000_000)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(observer.isDragging)
        XCTAssertEqual(observer.volume, 0.8125, accuracy: 0.001, "松手解锁后应回读硬件步进后的实际输出音量")

        // 4) 跳过防抖冷却窗口后，系统外部按键下调再次正常联动
        try await Task.sleep(nanoseconds: 290_000_000)
        fakeSystemVolume = 0.25
        observer.receiveExternalVolumeUpdate(0.25)
        XCTAssertEqual(observer.volume, 0.25, accuracy: 0.001)

        // 5) 验证静音与恢复静音前非零音量同步写入系统音量
        observer.toggleMute()
        XCTAssertEqual(observer.volume, 0.0, accuracy: 0.001)
        XCTAssertEqual(fakeSystemVolume, 0.0, accuracy: 0.001)
        observer.toggleMute()
        XCTAssertEqual(observer.volume, 0.25, accuracy: 0.001)
        XCTAssertEqual(fakeSystemVolume, 0.25, accuracy: 0.001)
    }

    // MARK: - 17. iOS 沙盒重装容器 UUID 变动时本地音轨与曲库路径自动迁移测试

    func testLocalSourceRelocatesStaleSandboxContainerPaths() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mygo-migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let oldLocalDir = root
            .appendingPathComponent("Containers/Data/Application/OLD-UUID-1111/Library/Application Support/MyGoMusic/local", isDirectory: true)
        let newLocalDir = root
            .appendingPathComponent("Containers/Data/Application/NEW-UUID-2222/Library/Application Support/MyGoMusic/local", isDirectory: true)
        let newMusicDir = newLocalDir.appendingPathComponent("MusicFiles", isDirectory: true)
        try fm.createDirectory(at: newMusicDir, withIntermediateDirectories: true)

        let wavData = Self.makeTestPCM16WAVData(durationSeconds: 0.25)
        let wavURL = newMusicDir.appendingPathComponent("MyGO - Haruhikage.wav")
        let lrcURL = newMusicDir.appendingPathComponent("MyGO - Haruhikage.lrc")
        try wavData.write(to: wavURL)
        try "[00:01.00]migrated lyrics line\n".data(using: .utf8)?.write(to: lrcURL)

        let staleTrackID = oldLocalDir
            .appendingPathComponent("MusicFiles/MyGO - Haruhikage.wav")
            .path
        let staleFolder = oldLocalDir.appendingPathComponent("MusicFiles").path
        let rawLibJSON: [String: Any] = [
            "folders": [staleFolder, newMusicDir.path],
            "likes": [staleTrackID],
            "recent": [staleTrackID],
            "playlists": [
                ["id": "p1", "name": "TestList", "tracks": [staleTrackID]]
            ]
        ]
        let libData = try JSONSerialization.data(withJSONObject: rawLibJSON)
        try libData.write(to: newLocalDir.appendingPathComponent("library.json"))

        let source = LocalMusicSource(dataDir: newLocalDir)
        let stream = try await source.stream(id: staleTrackID, quality: "lossless")
        XCTAssertEqual(URL(string: stream.url)?.path, wavURL.path, "旧沙盒容器音轨 ID 应自动重定向到当前新容器文件")

        let lyrics = try await source.lyrics(id: staleTrackID)
        XCTAssertTrue(lyrics.lrc?.contains("migrated lyrics line") == true, "旧沙盒音轨应正确加载新容器同名 LRC")

        let likedMap = try await source.isLiked(ids: [staleTrackID, wavURL.path])
        XCTAssertEqual(likedMap[staleTrackID], true)
        XCTAssertEqual(likedMap[wavURL.path], true)
        XCTAssertEqual(source.folders(), [newMusicDir.path], "应清理失效的历史沙盒容器 MusicFiles 冗余路径")
    }
}

/// 测试用最小内存音源，用于精确返回流信息或无权限错误
private final class MockPlaybackSource: MusicSource, @unchecked Sendable {
    var streamHandler: (String, String) async throws -> StreamInfo = { id, _ in
        StreamInfo(url: "https://mock.music.126.net/\(id).wav", type: "wav")
    }

    func info() -> SourceInfo {
        SourceInfo(id: "mock-source", name: "Mock", version: "1.0.0", playback: .stream)
    }
    func can(_ capability: String) -> Bool { capability == "stream" }
    func setting(_ key: String) -> String { "" }
    func setSetting(_ key: String, value: String) throws {}
    func signIn() async throws -> Account? { nil }
    func signOut() async throws {}
    func account() async throws -> Account? { nil }
    func search(query: String, kind: SearchKind, offset: Int) async throws -> SearchResult { SearchResult() }
    func suggest(query: String) async throws -> [String] { [] }
    func playlists() async throws -> [Playlist] { [] }
    func playlist(id: String) async throws -> Playlist { Playlist(id: id, name: "") }
    func album(id: String) async throws -> AlbumPage { AlbumPage(album: Album(id: id, name: "")) }
    func artist(id: String) async throws -> ArtistPage { ArtistPage(artist: Artist(id: id, name: "")) }
    func liked(offset: Int) async throws -> TrackPage { TrackPage(tracks: []) }
    func recent() async throws -> [Track] { [] }
    func home() async throws -> Browse { Browse(sections: []) }
    func browse(page: String) async throws -> Browse { Browse(sections: []) }
    func isLiked(ids: [String]) async throws -> [String: Bool] { [:] }
    func like(id: String, on: Bool) async throws {}
    func likeEpisode(id: String, on: Bool) async throws {}
    func createPlaylist(name: String) async throws -> Playlist { Playlist(id: "1", name: name) }
    func renamePlaylist(id: String, name: String) async throws {}
    func deletePlaylist(id: String) async throws {}
    func addToPlaylist(id: String, trackIds: [String]) async throws {}
    func removeFromPlaylist(id: String, trackIds: [String]) async throws {}
    func movePlaylistTrack(id: String, from: Int, to: Int) async throws {}
    func savePlaylist(id: String, on: Bool) async throws {}
    func followArtist(id: String, on: Bool) async throws {}
    func saveAlbum(id: String, on: Bool) async throws {}
    func savedAlbums(offset: Int) async throws -> AlbumList { AlbumList(albums: []) }
    func shows() async throws -> [Show] { [] }
    func show(id: String, offset: Int) async throws -> ShowPage { ShowPage(show: Show(id: id, name: "")) }
    func subscribeShow(id: String, on: Bool) async throws {}
    func stations() async throws -> [Station] { [] }
    func stationNext(id: String) async throws -> [Track] { [] }
    func comments(trackId: String, offset: Int) async throws -> CommentPage { CommentPage(comments: []) }
    func likeComment(trackId: String, commentId: String, on: Bool) async throws {}
    func postComment(trackId: String, text: String) async throws -> Comment {
        Comment(id: "1", author: "u", text: text)
    }
    func lyrics(id: String) async throws -> RawLyrics { RawLyrics() }
    func stream(id: String, quality: String) async throws -> StreamInfo {
        try await streamHandler(id, quality)
    }
    func played(track: Track) async {}
    func remotePlay(ids: [String], start: Int, position: Int64) async throws {}
    func remotePause() async throws {}
    func remoteResume() async throws {}
    func remoteSeek(position: Int64) async throws {}
    func remoteVolume(percent: Int) async throws {}
    func remoteState() async throws -> RemoteState? { nil }
    func remoteDevices() async throws -> [RemoteDevice] { [] }
    func remoteUse(deviceId: String) async throws {}
}

/// 内存拦截 URLProtocol，用于在沙盒无真实端口条件下验证 AudioStreamProxy 的 Range / 200 OK / 超时 / 截断协议处理
private final class MockAudioStreamURLProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior {
        case normal
        case stallForever
        case truncatedEOF
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var payloadData = Data()
    nonisolated(unsafe) private static var byteRangeEnabled = true
    nonisolated(unsafe) private static var requestCount = 0
    nonisolated(unsafe) private static var lastReferer: String?
    nonisolated(unsafe) private static var mockBehavior: Behavior = .normal

    static func configure(payload: Data, supportsByteRange: Bool, behavior: Behavior = .normal) {
        lock.lock()
        defer { lock.unlock() }
        payloadData = payload
        byteRangeEnabled = supportsByteRange
        requestCount = 0
        lastReferer = nil
        mockBehavior = behavior
    }

    static func recordedRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    static func lastSeenReferer() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastReferer
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mock.music.126.net"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let snapshot: (data: Data, allowRange: Bool, behavior: Behavior) = Self.lock.withLock {
            Self.requestCount += 1
            if let ref = request.value(forHTTPHeaderField: "Referer") {
                Self.lastReferer = ref
            }
            return (Self.payloadData, Self.byteRangeEnabled, Self.mockBehavior)
        }

        if snapshot.behavior == .stallForever {
            // 故意挂起不发送任何响应，用于触发 PlayerEngine 看门狗超时检测
            return
        }

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let total = snapshot.data.count
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        var statusCode = 200
        var headers: [String: String] = [
            "Content-Type": "audio/wav"
        ]
        var slice = snapshot.data

        if snapshot.allowRange,
           let rangeHeader,
           rangeHeader.hasPrefix("bytes=") {
            let spec = String(rangeHeader.dropFirst("bytes=".count))
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(parts.first ?? "") ?? 0
            let parsedEnd = (parts.count > 1 && !parts[1].isEmpty) ? (Int(parts[1]) ?? (total - 1)) : (total - 1)
            let end = min(max(start, parsedEnd), max(0, total - 1))
            if start >= total {
                statusCode = 416
                headers["Content-Range"] = "bytes */\(total)"
                slice = Data()
            } else {
                statusCode = 206
                headers["Accept-Ranges"] = "bytes"
                headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
                headers["Content-Length"] = "\(end - start + 1)"
                slice = snapshot.data.subdata(in: start..<(end + 1))
            }
        } else {
            headers["Content-Length"] = "\(total)"
        }

        if let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        if snapshot.behavior == .truncatedEOF {
            let partial = slice.prefix(min(16, slice.count))
            if !partial.isEmpty {
                client?.urlProtocol(self, didLoad: partial)
            }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if !slice.isEmpty {
            client?.urlProtocol(self, didLoad: slice)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif

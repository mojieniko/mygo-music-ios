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
        // 1) 直链分流判定（网易云/直链 MP3/FLAC 不强制走代理，B 站 m4s 与带头流走代理）
        let neteaseMP3 = StreamInfo(url: "https://m701.music.126.net/demo.mp3", type: "mp3", quality: "320")
        XCTAssertFalse(PlayerEngine.shouldUseStreamProxy(url: URL(string: neteaseMP3.url)!, stream: neteaseMP3))

        let neteaseOuter = StreamInfo(url: "https://music.163.com/song/media/outer/url?id=999", headers: [:])
        XCTAssertFalse(PlayerEngine.shouldUseStreamProxy(url: URL(string: neteaseOuter.url)!, stream: neteaseOuter))

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
    }

    @MainActor
    private static func waitForReadyToPlay(item: AVPlayerItem, timeoutSeconds: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if item.status == .readyToPlay {
                return true
            }
            if item.status == .failed {
                XCTFail("AVPlayerItem 加载失败: \(item.error?.localizedDescription ?? "unknown")")
                return false
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return item.status == .readyToPlay
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
}

/// 内存拦截 URLProtocol，用于在沙盒无真实端口条件下验证 AudioStreamProxy 的 Range / 200 OK 协议协商
private final class MockAudioStreamURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var payloadData = Data()
    nonisolated(unsafe) private static var byteRangeEnabled = true
    nonisolated(unsafe) private static var requestCount = 0
    nonisolated(unsafe) private static var lastReferer: String?

    static func configure(payload: Data, supportsByteRange: Bool) {
        lock.lock()
        defer { lock.unlock() }
        payloadData = payload
        byteRangeEnabled = supportsByteRange
        requestCount = 0
        lastReferer = nil
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
        let snapshot: (data: Data, allowRange: Bool) = Self.lock.withLock {
            Self.requestCount += 1
            if let ref = request.value(forHTTPHeaderField: "Referer") {
                Self.lastReferer = ref
            }
            return (Self.payloadData, Self.byteRangeEnabled)
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
        if !slice.isEmpty {
            client?.urlProtocol(self, didLoad: slice)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif

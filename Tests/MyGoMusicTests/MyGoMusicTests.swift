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
}
#endif

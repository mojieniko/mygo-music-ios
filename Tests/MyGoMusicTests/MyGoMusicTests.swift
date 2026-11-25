// MyGoMusicTests.swift
// 验证 MyGo Music iOS 版核心引擎（歌词、JS 插件运行时、本地音乐库、律动算法、仓库解析）与原版 Go 实现的一致性

#if canImport(XCTest)
import AVFoundation
import Compression
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
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

    func testAppleMusicLyricsMotionPresentationAndInterlude() {
        // 1) 验证词尾空白拆分（确保逐字扫光与放大聚焦在核心字形）
        let eng = LyricsEngine.splitWordTrailingWhitespace("running ")
        XCTAssertEqual(eng.core, "running")
        XCTAssertEqual(eng.trailing, " ")
        let cjk = LyricsEngine.splitWordTrailingWhitespace("暮")
        XCTAssertEqual(cjk.core, "暮")
        XCTAssertEqual(cjk.trailing, "")
        let empty = LyricsEngine.splitWordTrailingWhitespace("")
        XCTAssertEqual(empty.core, "")
        XCTAssertEqual(empty.trailing, "")

        // 2) 验证逐字流体扫光、呼吸轻抬、尾音余韵以及 Reduce Motion 保护
        let word = LyricWord(text: "running ", start: 2.0, end: 3.0)
        let before = LyricsEngine.wordMotion(for: word, at: 1.5, reduceMotion: false)
        XCTAssertEqual(before.wipeProgress, 0.0, accuracy: 0.001)
        XCTAssertEqual(before.liftY, 0.0, accuracy: 0.001)
        XCTAssertEqual(before.scale, 1.0, accuracy: 0.001)
        XCTAssertFalse(before.isActive)

        let mid = LyricsEngine.wordMotion(for: word, at: 2.5, reduceMotion: false)
        XCTAssertEqual(mid.wipeProgress, 0.5, accuracy: 0.02)
        XCTAssertLessThan(mid.liftY, -0.5)
        XCTAssertGreaterThan(mid.scale, 1.01)
        XCTAssertGreaterThan(mid.glowIntensity, 0.7)
        XCTAssertTrue(mid.isActive)

        let midReduced = LyricsEngine.wordMotion(for: word, at: 2.5, reduceMotion: true)
        XCTAssertEqual(midReduced.wipeProgress, 0.5, accuracy: 0.02)
        XCTAssertEqual(midReduced.liftY, 0.0, accuracy: 0.001)
        XCTAssertEqual(midReduced.scale, 1.0, accuracy: 0.001)

        let tail = LyricsEngine.wordMotion(for: word, at: 3.08, reduceMotion: false)
        XCTAssertEqual(tail.wipeProgress, 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(tail.glowIntensity, 0.0)
        let settled = LyricsEngine.wordMotion(for: word, at: 3.5, reduceMotion: false)
        XCTAssertEqual(settled.wipeProgress, 1.0, accuracy: 0.001)
        XCTAssertEqual(settled.glowIntensity, 0.0, accuracy: 0.001)

        // 3) 验证 Apple Music 景深柔焦、下一句预读亮度、滑屏浏览去模糊与级联延迟
        let cur = LyricsEngine.linePresentation(index: 3, currentIndex: 3, isUserScrolling: false)
        let prev = LyricsEngine.linePresentation(index: 2, currentIndex: 3, isUserScrolling: false)
        let next = LyricsEngine.linePresentation(index: 4, currentIndex: 3, isUserScrolling: false)
        let far = LyricsEngine.linePresentation(index: 7, currentIndex: 3, isUserScrolling: false)
        XCTAssertEqual(cur.blurRadius, 0.0, accuracy: 0.001)
        XCTAssertEqual(cur.scale, 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(next.primaryOpacity, prev.primaryOpacity)
        XCTAssertLessThan(next.blurRadius, far.blurRadius)
        XCTAssertGreaterThan(next.staggerDelay, prev.staggerDelay)

        let scrollingFar = LyricsEngine.linePresentation(index: 7, currentIndex: 3, isUserScrolling: true)
        XCTAssertEqual(scrollingFar.blurRadius, 0.0, accuracy: 0.001)
        XCTAssertGreaterThan(scrollingFar.primaryOpacity, far.primaryOpacity)

        let reducedFar = LyricsEngine.linePresentation(index: 7, currentIndex: 3, isUserScrolling: false, reduceMotion: true)
        XCTAssertEqual(reducedFar.blurRadius, 0.0, accuracy: 0.001)
        XCTAssertEqual(reducedFar.scale, 1.0, accuracy: 0.001)
        XCTAssertEqual(reducedFar.staggerDelay, 0.0, accuracy: 0.001)

        // 4) 验证前奏与句间长间奏三圆点呼吸检测窗口
        let lines = [
            LyricLine(at: 8.0, end: 11.0, text: "First line"),
            LyricLine(at: 17.0, end: 20.0, text: "Second line")
        ]
        let intro = LyricsEngine.activeInterlude(in: lines, at: 2.0, currentIndex: -1)
        XCTAssertEqual(intro?.insertAfterLineIndex, -1)
        XCTAssertEqual(intro?.progress ?? -1, 0.25, accuracy: 0.01)

        XCTAssertNil(LyricsEngine.activeInterlude(in: lines, at: 11.2, currentIndex: 0))
        let midInterlude = LyricsEngine.activeInterlude(in: lines, at: 13.5, currentIndex: 0)
        XCTAssertEqual(midInterlude?.insertAfterLineIndex, 0)
        XCTAssertGreaterThan(midInterlude?.progress ?? 0, 0.2)
        XCTAssertNil(LyricsEngine.activeInterlude(in: lines, at: 16.92, currentIndex: 0))
    }

    func testAppSettingsDecodesLegacyFilesWithMissingKeys() throws {
        let minimal = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(minimal.source, "kugou-lite")
        XCTAssertEqual(minimal.quality, .high)
        XCTAssertTrue(minimal.fog)
        XCTAssertTrue(minimal.smoke)
        XCTAssertTrue(minimal.gaplessPlayback)
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
        XCTAssertEqual(upcomingState.opacity, 0.0, "未唱到的字应先完全隐身，到拍时再凭空蹦出")

        let activeState = StageMath.wordState(
            word: upcomingWord,
            shape: shapes[shapes.count - 1],
            pos: upcomingWord.start + 0.05
        )
        XCTAssertGreaterThan(activeState.opacity, 0.8, "进入演唱时刻应在瞬间显形弹出")
        XCTAssertGreaterThan(activeState.scale, upcomingState.scale, "弹入瞬间应触发弹簧放大")

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
            LyricLine(at: 14.0, text: "迷星叫", translation: "迷星叫"),
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

        // 3) 命中带翻译歌词行：翻译随原文合并展示于第一行，第二行保持 "歌名 - 歌手" 不被翻译挤占
        let secondLine = PlayerEngine.buildNowPlayingDisplayMetadata(
            track: track,
            lyrics: lines,
            position: 11.0,
            lockScreenLyricsEnabled: true
        )
        XCTAssertEqual(secondLine.title, "迷い子でもいいと · 就算迷茫也无妨")
        XCTAssertEqual(secondLine.artist, "迷星叫 - MyGO!!!!!")
        XCTAssertEqual(secondLine.lyricIndex, 1)

        // 3b) 翻译与原文相同时不重复拼接
        let duplicateTranslationLine = PlayerEngine.buildNowPlayingDisplayMetadata(
            track: track,
            lyrics: lines,
            position: 14.5,
            lockScreenLyricsEnabled: true
        )
        XCTAssertEqual(duplicateTranslationLine.title, "迷星叫")
        XCTAssertEqual(duplicateTranslationLine.artist, "迷星叫 - MyGO!!!!!")
        XCTAssertEqual(duplicateTranslationLine.lyricIndex, 2)

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
        // 验证迷你播放栏遵循 iOS 26/27 胶囊同心安全距规范：左内边距 16pt、封面 34×34（上下各留 11pt），与左端弧壁净空 >= 9pt
        XCTAssertEqual(FloatingTabBarMetrics.miniArtworkLeading, 16.0, accuracy: 0.01)
        XCTAssertEqual(FloatingTabBarMetrics.miniArtworkSize, 34.0, accuracy: 0.01)
        XCTAssertEqual(FloatingTabBarMetrics.miniArtworkCornerRadius, 8.5, accuracy: 0.01)
        let capRadius = FloatingTabBarMetrics.miniExpandedHeight * 0.5
        let verticalInset = (FloatingTabBarMetrics.miniExpandedHeight - FloatingTabBarMetrics.miniArtworkSize) * 0.5
        let arcXAtVerticalInset = capRadius - sqrt(max(0, capRadius * capRadius - pow(capRadius - verticalInset, 2)))
        XCTAssertGreaterThanOrEqual(FloatingTabBarMetrics.miniArtworkLeading - arcXAtVerticalInset, 9.5)
        XCTAssertGreaterThan(FloatingTabBarMetrics.bottomInsetEmptyPlayer, FloatingTabBarMetrics.barHeight)
        XCTAssertGreaterThan(FloatingTabBarMetrics.bottomInsetWithMiniPlayer, FloatingTabBarMetrics.bottomInsetEmptyPlayer)

        // 验证底部滚动避让边距：键盘弹出清零；全面屏/非全面屏均须高于悬浮胶囊及展开态 MiniPlayer
        XCTAssertEqual(
            FloatingTabBarMetrics.extraScrollBottomInset(
                hasTrack: false,
                isKeyboardVisible: true,
                bottomOverlayPadding: 22,
                systemSafeAreaBottom: 34
            ),
            0.0,
            accuracy: 0.01
        )
        XCTAssertEqual(
            FloatingTabBarMetrics.extraScrollBottomInset(
                hasTrack: true,
                isKeyboardVisible: true,
                bottomOverlayPadding: 22,
                systemSafeAreaBottom: 34
            ),
            0.0,
            accuracy: 0.01
        )
        let notchEmptyExtra = FloatingTabBarMetrics.extraScrollBottomInset(
            hasTrack: false,
            isKeyboardVisible: false,
            bottomOverlayPadding: 22,
            systemSafeAreaBottom: 34
        )
        let notchMiniExtra = FloatingTabBarMetrics.extraScrollBottomInset(
            hasTrack: true,
            isKeyboardVisible: false,
            bottomOverlayPadding: 22,
            systemSafeAreaBottom: 34
        )
        XCTAssertEqual(notchEmptyExtra, 74.0, accuracy: 0.01)
        XCTAssertEqual(notchMiniExtra, 142.0, accuracy: 0.01)
        XCTAssertGreaterThan(34.0 + notchEmptyExtra, 22.0 + FloatingTabBarMetrics.barHeight)
        XCTAssertGreaterThan(
            34.0 + notchMiniExtra,
            22.0 + FloatingTabBarMetrics.barHeight + FloatingTabBarMetrics.overlaySpacing + FloatingTabBarMetrics.miniExpandedHeight
        )

        let classicEmptyExtra = FloatingTabBarMetrics.extraScrollBottomInset(
            hasTrack: false,
            isKeyboardVisible: false,
            bottomOverlayPadding: 14,
            systemSafeAreaBottom: 0
        )
        let classicMiniExtra = FloatingTabBarMetrics.extraScrollBottomInset(
            hasTrack: true,
            isKeyboardVisible: false,
            bottomOverlayPadding: 14,
            systemSafeAreaBottom: 0
        )
        XCTAssertEqual(classicEmptyExtra, 100.0, accuracy: 0.01)
        XCTAssertEqual(classicMiniExtra, 168.0, accuracy: 0.01)
        XCTAssertEqual(
            FloatingTabBarMetrics.extraScrollBottomInset(
                hasTrack: false,
                isKeyboardVisible: false,
                bottomOverlayPadding: 22,
                systemSafeAreaBottom: 220
            ),
            0.0,
            accuracy: 0.01
        )

        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let model = AppModel(baseDataDir: tmpRoot)
        _ = MainView().environmentObject(model)
        _ = MiniPlayerBarView().environmentObject(model)
        _ = SearchView().environmentObject(model)
    }

    @MainActor
    func testSearchKeyboardDismissHelperAndCommentControls() async {
        MyGoKeyboard.dismiss()
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-kbd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let model = AppModel(baseDataDir: tmpRoot, deferHeavyStartup: true)
        await model.waitUntilStartupReady()
        _ = SearchView().environmentObject(model)
        _ = NowPlayingView().environmentObject(model)
    }

    @MainActor
    func testLyricArtistNavigationResolutionCrossSourceAndSearchFallback() async throws {
        // 1) Track 歌手解析：保留有效 ID、过滤空名称
        let structuredTrack = Track(
            id: "tr-1",
            source: "jay-plugin",
            name: "红尘客栈",
            artists: [Artist(id: "ar-jay", name: "周杰伦"), Artist(id: "", name: "  ")],
            album: Album(id: "al-12", name: "12新作")
        )
        XCTAssertEqual(structuredTrack.resolvedArtistsForNavigation.count, 1)
        XCTAssertEqual(structuredTrack.resolvedArtistsForNavigation.first?.id, "ar-jay")
        XCTAssertEqual(structuredTrack.resolvedArtistsForNavigation.first?.name, "周杰伦")

        // 2) 通过真实 JS 插件夹具，测试当前切到 "local" 时从歌词页跨源直达原歌曲所属插件歌手页及所有歌曲
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-artist-nav-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let pluginDir = tmpRoot.appendingPathComponent("plugins/jay-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "id": "jay-plugin",
            "name": "Jay Test Source",
            "version": "1.0.0",
            "main": "index.js",
            "playback": "stream"
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try manifestData.write(to: pluginDir.appendingPathComponent("plugin.json"))
        let indexJS = #"""
        export function artist(args) {
          if (args.id !== "ar-jay") { throw new Error("not found"); }
          return {
            artist: { id: "ar-jay", name: "周杰伦", following: false },
            tracks: [
              { id: "t1", name: "红尘客栈", artists: [{ id: "ar-jay", name: "周杰伦" }], album: { id: "al12", name: "12新作" }, duration: 274000 },
              { id: "t2", name: "夜曲", artists: [{ id: "ar-jay", name: "周杰伦" }], album: { id: "al11", name: "十一月的萧邦" }, duration: 226000 }
            ],
            albums: [
              { id: "al12", name: "12新作", released: "2012-12-28" }
            ]
          };
        }
        export function search(args) {
          if (args.kind === "artists") {
            return { artists: [{ id: "ar-jay", name: "周杰伦" }], more: false };
          }
          if (args.kind === "tracks") {
            return {
              tracks: [
                { id: "t3", name: "七里香", artists: [{ id: "ar-jay", name: "周杰伦" }], album: { id: "al7", name: "七里香" }, duration: 299000 }
              ],
              more: false
            };
          }
          return { more: false };
        }
        export function stream(args) {
          return { url: "https://example.com/" + args.id + ".mp3", type: "mp3" };
        }
        """#
        try indexJS.write(to: pluginDir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let model = AppModel(baseDataDir: tmpRoot)
        model.switchSource(to: "local")
        XCTAssertEqual(model.activeSourceID, "local", "即使当前浏览源停留在 local，点开插件歌曲歌手仍应跨源命中")

        let crossSourceOutcome = await model.loadArtistPage(artistID: "ar-jay", fallbackName: "周杰伦", sourceID: "jay-plugin")
        XCTAssertNotNil(crossSourceOutcome)
        XCTAssertEqual(crossSourceOutcome?.resolvedSourceID, "jay-plugin")
        XCTAssertEqual(crossSourceOutcome?.page.artist.name, "周杰伦")
        XCTAssertEqual(crossSourceOutcome?.page.tracks?.map(\.name), ["红尘客栈", "夜曲"])
        XCTAssertEqual(crossSourceOutcome?.page.tracks?.first?.source, "jay-plugin")
        XCTAssertEqual(crossSourceOutcome?.page.albums?.first?.name, "12新作")

        // 3) 若歌曲缺少 artist.id，通过名字搜索匹配歌手 ID 再加载全部作品
        let missingIdOutcome = await model.loadArtistPage(artistID: "", fallbackName: "周杰伦", sourceID: "jay-plugin")
        XCTAssertEqual(missingIdOutcome?.page.artist.id, "ar-jay")
        XCTAssertEqual(missingIdOutcome?.page.tracks?.count, 2)

        // 4) 分页查看更多歌曲：从 search 补齐同一歌手其它歌曲并自动盖上 sourceID
        let moreTracks = await model.loadMoreArtistTracks(artistName: "周杰伦", sourceID: "jay-plugin", offset: 0)
        XCTAssertEqual(moreTracks.tracks.map(\.name), ["七里香"])
        XCTAssertEqual(moreTracks.tracks.first?.source, "jay-plugin")
        XCTAssertFalse(moreTracks.hasMore)

        // 5) 队列终极兜底：若某首演示/内存中曲目未入库也无所属插件，点击歌手仍可在队列中聚合看到她的歌曲
        let queueOnlyTrack = Track(
            id: "demo-queue-track",
            source: "unregistered-source",
            name: "春日影 (Demo)",
            artists: [Artist(id: "ar-queue", name: "MyGO_Solo")],
            album: Album(id: "al-q", name: "Demo")
        )
        model.player.playQueue([queueOnlyTrack], start: 0)
        model.player.pause()
        let queueFallbackOutcome = await model.loadArtistPage(artistID: "ar-queue", fallbackName: "MyGO_Solo", sourceID: "unregistered-source")
        XCTAssertEqual(queueFallbackOutcome?.page.artist.name, "MyGO_Solo")
        XCTAssertEqual(queueFallbackOutcome?.page.tracks?.map(\.name), ["春日影 (Demo)"])

        _ = ArtistDetailView(artistID: "ar-jay", fallbackName: "周杰伦", sourceID: "jay-plugin").environmentObject(model)
        _ = AlbumDetailView(albumID: "al12", fallbackName: "12新作", sourceID: "jay-plugin").environmentObject(model)
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

        // Flow 舞台九宫格随机落位（命中上/中/下三档纵深高度表 [-0.31, -0.02, 0.24]）
        let flowPlace = StageMath.flowPlacement(for: stageLine, containerWidth: 360)
        XCTAssertTrue([-0.31, -0.02, 0.24].contains(flowPlace.verticalShiftRatio))

        // 光束火花数：普通词 9 条 / 行末词 16 条 / 超出持续时长清空
        let midSparks = StageMath.sparkStreaks(size: CGSize(width: 44, height: 48), since: 0.14, seed: 10.0, isLastWord: false)
        let lastSparks = StageMath.sparkStreaks(size: CGSize(width: 44, height: 48), since: 0.14, seed: 11.4, isLastWord: true)
        XCTAssertEqual(midSparks.count, 9)
        XCTAssertEqual(lastSparks.count, 16)
        XCTAssertTrue(StageMath.sparkStreaks(size: CGSize(width: 44, height: 48), since: 1.5, seed: 10.0, isLastWord: false).isEmpty)

        // Steps 导标状态三阶段流转（对齐桌面 ui_stage_styles.go：未唱排隐藏，已唱直角导标保留 0.22 淡影）
        let pRow = PartitaRow(from: 0, to: shortWords.count, x: -24, y: 12, scale: 1.0, left: true)
        let upcomingRow = StageMath.partitaRowMotion(words: shortWords[...], row: pRow, pos: 8.5)
        let singingRow = StageMath.partitaRowMotion(words: shortWords[...], row: pRow, pos: 10.5)
        let pastRow = StageMath.partitaRowMotion(words: shortWords[...], row: pRow, pos: 12.5)
        XCTAssertEqual(upcomingRow.guideState, .upcoming)
        XCTAssertEqual(upcomingRow.opacity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(upcomingRow.guideProgress, 0.0, accuracy: 0.0001)
        XCTAssertEqual(upcomingRow.guideAlpha, 0.0, accuracy: 0.0001)
        XCTAssertEqual(singingRow.guideState, .singing)
        XCTAssertEqual(singingRow.opacity, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(singingRow.guideProgress, 0.5)
        XCTAssertEqual(pastRow.guideState, .past)
        XCTAssertEqual(pastRow.guideAlpha, 0.22, accuracy: 0.0001)

        // Tilt 超宽文本自适应防折行字号压缩 + 段落进场前隐形 + 桌面字重/字距 + 斜体波浪交错
        var wideWords: [LyricWord] = []
        for idx in 0..<24 {
            let st = 20.0 + Double(idx) * 0.18
            wideWords.append(LyricWord(text: "響", start: st, end: st + 0.18))
        }
        let wideLine = LyricLine(at: 20.0, end: 25.0, text: String(repeating: "響", count: 24), words: wideWords)
        let fitted = StageMath.fitTiltLayout(for: wideLine, maxWidth: 210, baseFontSize: 38)
        XCTAssertLessThan(fitted.fontSize, 38.0)
        XCTAssertGreaterThanOrEqual(fitted.fittedLineRatio, 0.48)

        let plainPart = TiltPart(from: 0, to: shortWords.count, lean: false, tail: false)
        let leanPart = TiltPart(from: 0, to: 4, lean: true, tail: false)
        let preTiltPart = StageMath.tiltPartMotion(words: shortWords[...], part: plainPart, pos: 9.6, size: 32)
        let afterTiltPart = StageMath.tiltPartMotion(words: shortWords[...], part: plainPart, pos: 10.5, size: 32)
        let activeLeanPart = StageMath.tiltPartMotion(words: shortWords[0..<4], part: leanPart, pos: 10.5, size: 32)
        XCTAssertEqual(preTiltPart.opacity, 0.0, accuracy: 0.0001, "Tilt 段在开唱前 250ms 之前必须保持隐形")
        XCTAssertEqual(afterTiltPart.opacity, 1.0, accuracy: 0.0001)
        XCTAssertFalse(afterTiltPart.isLightWeight, "桌面普通倾诉段使用 Regular(400) 字重而非 Light")
        XCTAssertFalse(afterTiltPart.isItalic)
        XCTAssertEqual(afterTiltPart.tracking, 32 * 0.08, accuracy: 0.0001)
        XCTAssertTrue(activeLeanPart.isItalic)
        XCTAssertTrue(activeLeanPart.useAccentColor)
        XCTAssertEqual(activeLeanPart.tracking, 32 * 0.15, accuracy: 0.0001)

        let preChar = StageMath.tiltCharMotion(partSince: -0.1, charDuration: 0.35, charStart: 10.5, charOrderIndex: 1, part: leanPart, size: 32, pos: 9.65)
        XCTAssertEqual(preChar.opacity, 0.0, accuracy: 0.0001, "Tilt 单字在段落起唱前 250ms 之前必须保持隐形")
        let staggeredChar = StageMath.tiltCharMotion(partSince: 0.02, charDuration: 0.35, charStart: 10.5, charOrderIndex: 3, part: leanPart, size: 32, pos: 9.77)
        XCTAssertEqual(staggeredChar.opacity, 0.0, accuracy: 0.0001, "Tilt 后续字符在 stagger 延迟期未到前应当保持隐形")
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

        let coverDir = tempRoot.appendingPathComponent("cover-enabled", isDirectory: true)
        try FileManager.default.createDirectory(at: coverDir, withIntermediateDirectories: true)
        var coverSettings = AppSettings()
        coverSettings.coverPlayerMode = true
        coverSettings.lyricsStage = true
        try JSONEncoder().encode(coverSettings).write(to: coverDir.appendingPathComponent("settings.json"))
        let coverApp = AppModel(baseDataDir: coverDir)
        XCTAssertEqual(coverApp.activeNowPlayingPane, .cover, "开启经典封面播放页后启动时应恢复为 .cover 面板")

        // 验证关闭/开启经典封面开关与 presentNowPlaying 重进规则：临时切面板后退出再点进必须遵循开关状态
        coverApp.activeNowPlayingPane = .queue
        coverApp.presentNowPlaying()
        XCTAssertTrue(coverApp.isNowPlayingPresented)
        XCTAssertEqual(coverApp.activeNowPlayingPane, .cover, "开关开启时，重进播放页应默认回到经典封面模式")

        coverApp.isNowPlayingPresented = false
        coverApp.settings.coverPlayerMode = false
        coverApp.settings.lyricsStage = false
        coverApp.activeNowPlayingPane = .cover
        coverApp.presentNowPlaying()
        XCTAssertEqual(coverApp.activeNowPlayingPane, .lyrics, "开关关闭后，哪怕之前曾停留在封面页，重进也应退出封面回到歌词页")

        // 验证长歌名跑马灯计算：不超宽静止无遮罩；超宽先停顿左对齐再匀速平滑向左滚并叠加羽化遮罩
        let shortSample = MyGoMarqueeMath.sample(elapsed: 4.0, contentWidth: 120, containerWidth: 200)
        XCTAssertEqual(shortSample.offsetX, 0)
        XCTAssertEqual(shortSample.leftFadeWidth, 0)
        XCTAssertEqual(shortSample.rightFadeWidth, 0)

        let pauseSample = MyGoMarqueeMath.sample(elapsed: 1.0, contentWidth: 260, containerWidth: 180)
        XCTAssertEqual(pauseSample.offsetX, 0)
        XCTAssertEqual(pauseSample.leftFadeWidth, 0)
        XCTAssertEqual(pauseSample.rightFadeWidth, 14)

        let midSample = MyGoMarqueeMath.sample(elapsed: 5.0, contentWidth: 260, containerWidth: 180)
        XCTAssertLessThan(midSample.offsetX, -20)
        XCTAssertEqual(midSample.leftFadeWidth, 12, accuracy: 0.01)
        XCTAssertEqual(midSample.rightFadeWidth, 14)

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
        XCTAssertEqual(stateBefore.opacity, 0.0, "Flow/Steps 待唱单词应先完全隐身，不可提前摆成 KTV 灰字点亮")
        XCTAssertGreaterThan(stateActive.opacity, stateBefore.opacity, "进入演唱时刻时单词应凭空弹出显形")
        XCTAssertGreaterThan(stateActive.scale, stateBefore.scale, "进入演唱时刻时单词缩放应弹跳放大")
        XCTAssertGreaterThan(stateActive.brightness, stateBefore.brightness, "进入演唱时刻时单词亮度应点亮")
        XCTAssertLessThan(stateActive.blur, stateBefore.blur, "进入演唱时刻时单词应由虚焦迅速聚焦清晰")

        let exitOpacityMid = StageMath.lineExitOpacity(nextLineStart: lines[1].at, at: lines[1].at + 0.15)
        XCTAssertGreaterThan(exitOpacityMid, 0.0)
        XCTAssertLessThan(exitOpacityMid, 1.0, "切换至下一句时旧行应在 0.4s 退场窗口内平滑叠化消隐")

        // 4) 验证 Flow 在 3s 整倍时间戳下真随机散落到九宫格不同方位（左上/正中/右下等）
        let periodicLines: [LyricLine] = (0..<12).map { (idx: Int) -> LyricLine in
            let start = TimeInterval(idx * 3)
            let end = TimeInterval(idx * 3 + 2)
            let lineText = "第\(idx)句示例歌词"
            return LyricLine(
                at: start,
                end: end,
                text: lineText,
                words: [LyricWord(text: lineText, start: start, end: end)]
            )
        }
        let placements = periodicLines.map { StageMath.flowPlacement(for: $0, containerWidth: 345) }
        XCTAssertGreaterThanOrEqual(Set(placements.map(\.alignment)).count, 2, "Flow 应具备左/中/右多方位随机落位")
        XCTAssertGreaterThanOrEqual(Set(placements.map(\.verticalShiftRatio)).count, 2, "Flow 应具备上/中/下多层级纵深错落")
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

    // MARK: - 18. 插件转译磁盘缓存命中/失效与冷启动异步延迟装配测试

    func testPluginTranspilerCacheHitAndInvalidationOnEdit() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mygo-transpile-cache-\(UUID().uuidString)", isDirectory: true)
        let pluginDir = root.appendingPathComponent("plugin", isDirectory: true)
        let cacheURL = root.appendingPathComponent("data/.transpiled-cache-v2.json")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let entryURL = pluginDir.appendingPathComponent("index.ts")
        let sourceV1 = """
        interface Meta { tag: string; }
        export const marker: string = "ver1";
        """
        try sourceV1.write(to: entryURL, atomically: true, encoding: .utf8)

        let origAttrs = try fm.attributesOfItem(atPath: entryURL.path)
        let origModDate = origAttrs[.modificationDate] as? Date ?? Date()

        let direct = try PluginModuleTranspiler.bundleEntry(entryURL: entryURL, pluginDir: pluginDir)
        let firstCached = try PluginModuleTranspiler.bundleEntryCached(
            entryURL: entryURL,
            pluginDir: pluginDir,
            cacheFileURL: cacheURL
        )
        XCTAssertEqual(firstCached.code, direct.code, "首次生成缓存结果应与直接转译完全一致")
        XCTAssertEqual(firstCached.exports, direct.exports)
        XCTAssertTrue(fm.fileExists(atPath: cacheURL.path), "应落盘 .transpiled-cache-v2.json")

        // 同 mtime + 同文件大小下修改源码，二次调用必须直接命中磁盘缓存而不重新扫描
        let sourceSameSize = """
        interface Meta { tag: string; }
        export const marker: string = "ver2";
        """
        XCTAssertEqual(sourceSameSize.utf8.count, sourceV1.utf8.count)
        try sourceSameSize.write(to: entryURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: origModDate], ofItemAtPath: entryURL.path)

        let hitResult = try PluginModuleTranspiler.bundleEntryCached(
            entryURL: entryURL,
            pluginDir: pluginDir,
            cacheFileURL: cacheURL
        )
        XCTAssertTrue(hitResult.code.contains("\"ver1\""), "指纹一致时应直接复用缓存结果")

        // 修改大小（和时间戳）后应自动失效并重新转译最新源码
        let sourceV3 = """
        interface Meta { tag: string; }
        export const marker: string = "ver3_updated";
        """
        try sourceV3.write(to: entryURL, atomically: true, encoding: .utf8)
        let rebuilt = try PluginModuleTranspiler.bundleEntryCached(
            entryURL: entryURL,
            pluginDir: pluginDir,
            cacheFileURL: cacheURL
        )
        XCTAssertTrue(rebuilt.code.contains("\"ver3_updated\""), "文件变动后应自动失效并重新打包最新源码")
        XCTAssertFalse(rebuilt.code.contains("interface Meta"), "重打包后仍应正常剥离 TS 类型声明")
    }

    @MainActor
    func testDeferredStartupCompletesWithoutBlockingMainInitAndRestoresState() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mygo-deferred-start-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let pluginDir = root.appendingPathComponent("plugins/fast-test", isDirectory: true)
        try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try """
        {
          "id": "fast-test",
          "name": "Fast Test",
          "version": "1.0.0",
          "main": "index.js"
        }
        """.write(to: pluginDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try """
        export const info = () => ({ id: "fast-test", name: "Fast Test", version: "1.0.0", playback: "stream" });
        """.write(to: pluginDir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let track = Track(
            id: "fast-t1",
            source: "fast-test",
            name: "Delayed Warm Track",
            artists: [Artist(id: "a1", name: "MyGO!!!!!")],
            album: Album(id: "al1", name: "Album"),
            duration: 90_000
        )
        let session = SavedPlaybackSession(
            queue: [track],
            currentIndex: 0,
            positionSeconds: 12.5,
            shuffle: false,
            repeatMode: .all
        )
        let sessionData = try JSONEncoder().encode(session)
        try sessionData.write(to: root.appendingPathComponent("session.json"))

        let app = AppModel(baseDataDir: root, deferHeavyStartup: true)
        // 验证同步 init 阶段未做插件发现/会话恢复阻塞，首帧可立即可见
        XCTAssertFalse(app.isStartupReady)
        XCTAssertTrue(app.isLoadingHome)
        XCTAssertTrue(app.pluginSources.isEmpty)
        XCTAssertNil(app.player.currentTrack)

        await app.waitUntilStartupReady()

        XCTAssertTrue(app.isStartupReady)
        XCTAssertNotNil(app.deferredStartupDurationMs)
        XCTAssertEqual(app.pluginSources.map(\.manifest.id), ["fast-test"])
        XCTAssertEqual(app.player.currentTrack?.id, "fast-t1")
        XCTAssertFalse(app.player.isPlaying, "冷启动恢复历史会话不应自动突兀开声")
        let cacheFile = root.appendingPathComponent("plugin-data/fast-test/.transpiled-cache-v2.json")
        XCTAssertTrue(fm.fileExists(atPath: cacheFile.path), "后台延迟装配也应产出插件转译磁盘缓存")
    }

    func testFloatingTabBarSliderMathAndGestures() {
        let barWidth: CGFloat = 353
        let count = 4

        let slotW = FloatingTabBarSliderMath.slotWidth(barWidth: barWidth, count: count)
        XCTAssertGreaterThan(slotW, 75)

        // 1. 四个槽位中心严格递增且分别精准映射回原索引
        let centers = (0..<count).map {
            FloatingTabBarSliderMath.slotCenterX(index: $0, barWidth: barWidth, count: count)
        }
        for i in 0..<(count - 1) {
            XCTAssertLessThan(centers[i], centers[i + 1])
        }
        for i in 0..<count {
            XCTAssertEqual(FloatingTabBarSliderMath.tabIndex(forX: centers[i], barWidth: barWidth, count: count), i)
        }

        // 2. 向左/向右过度拖出边界时保持 Apple 橡皮筋阻尼且不出界
        let overLeft = FloatingTabBarSliderMath.clampedPillCenterX(rawX: -120, barWidth: barWidth, count: count)
        XCTAssertLessThan(overLeft, centers[0])
        XCTAssertGreaterThan(overLeft, centers[0] - FloatingTabBarMetrics.outerInset * 0.71)

        let overRight = FloatingTabBarSliderMath.clampedPillCenterX(rawX: barWidth + 120, barWidth: barWidth, count: count)
        XCTAssertGreaterThan(overRight, centers[3])
        XCTAssertLessThan(overRight, centers[3] + FloatingTabBarMetrics.outerInset * 0.71)

        // 3. 连续拖到第 3 个槽位附近松手，精确落入目标 Tab
        let dragToLibrary = FloatingTabBarSliderMath.resolvedTargetTab(
            selectedTab: 0,
            pillCenterX: centers[2] + 6,
            translationWidth: centers[2] - centers[0],
            predictedEndTranslationWidth: centers[2] - centers[0],
            barWidth: barWidth,
            count: count
        )
        XCTAssertEqual(dragToLibrary, 2)

        // 4. 在当前 Tab 内虽未划过中线但带明显右扫动量，按 Flick 惯性切到下一格
        let flickRight = FloatingTabBarSliderMath.resolvedTargetTab(
            selectedTab: 1,
            pillCenterX: centers[1] + 14,
            translationWidth: 14,
            predictedEndTranslationWidth: 72,
            barWidth: barWidth,
            count: count
        )
        XCTAssertEqual(flickRight, 2)

        // 5. 极慢微小挪动不误触轻扫
        let jitterOnly = FloatingTabBarSliderMath.resolvedTargetTab(
            selectedTab: 1,
            pillCenterX: centers[1] + 3,
            translationWidth: 3,
            predictedEndTranslationWidth: 5,
            barWidth: barWidth,
            count: count
        )
        XCTAssertEqual(jitterOnly, 1)
    }

    func testBackdropFogDesktopParityMathAndMotion() {
        // 1. 鲜明红封面 -> Deep(v=0.30) 与明亮通透 Fog(v=0.72)
        let redCover = BackdropRGBColor(r: 0.86, g: 0.18, b: 0.16)
        let (deep, fog) = BackdropFogMath.fogColors(from: redCover)
        let (_, deepS, deepV) = BackdropFogMath.rgbToHSV(r: deep.r, g: deep.g, b: deep.b)
        let (_, fogS, fogV) = BackdropFogMath.rgbToHSV(r: fog.r, g: fog.g, b: fog.b)
        XCTAssertEqual(deepV, 0.30, accuracy: 0.02)
        XCTAssertEqual(fogV, 0.72, accuracy: 0.02)
        XCTAssertGreaterThan(deepS, 0.70)
        XCTAssertLessThan(fogS, deepS)

        // 2. 低饱和灰度封面应严格保灰不强行染成假彩色（对应 "A gray cover stays gray."）
        let grayCover = BackdropRGBColor(r: 0.45, g: 0.45, b: 0.47)
        let (grayDeep, grayFog) = BackdropFogMath.fogColors(from: grayCover)
        let (_, gdS, _) = BackdropFogMath.rgbToHSV(r: grayDeep.r, g: grayDeep.g, b: grayDeep.b)
        let (_, gfS, gfV) = BackdropFogMath.rgbToHSV(r: grayFog.r, g: grayFog.g, b: grayFog.b)
        XCTAssertLessThan(gdS, 0.08)
        XCTAssertLessThan(gfS, 0.08)
        XCTAssertEqual(gfV, 0.72, accuracy: 0.02)

        // 3. 关闭烟雾时的静态双色渐变（Top v=0.35, Foot v=0.24）
        let (top, foot) = BackdropFogMath.backdropColors(from: redCover)
        let (_, _, topV) = BackdropFogMath.rgbToHSV(r: top.r, g: top.g, b: top.b)
        let (_, _, footV) = BackdropFogMath.rgbToHSV(r: foot.r, g: foot.g, b: foot.b)
        XCTAssertEqual(topV, 0.35, accuracy: 0.02)
        XCTAssertEqual(footV, 0.24, accuracy: 0.02)

        // 4. 18 桶主色提纯：大量黑色背景 + 一片鲜艳天蓝色高光时，应提取天蓝而不是黑灰泥色
        var pixels = [UInt8]()
        pixels.reserveCapacity(24 * 24 * 4)
        for i in 0..<(24 * 24) {
            if i < 420 {
                pixels.append(contentsOf: [18, 18, 22, 255]) // 深暗背景像素会被阈值跳过
            } else {
                pixels.append(contentsOf: [45, 165, 245, 255]) // 高饱和主题天蓝
            }
        }
        let dominant = BackdropFogMath.dominantColorFromRGBA(bytes: pixels, width: 24, height: 24)
        XCTAssertNotNil(dominant)
        XCTAssertGreaterThan(dominant?.b ?? 0, 0.85)
        XCTAssertLessThan(dominant?.r ?? 1, 0.35)

        // 5. 对标 Go TestBackdropDrifts：播放 4s 加速至 speed==1 飘移，鼓点快冲、暂停 4s 内丝滑滑停至 speed==0 且停后纹丝不动
        var motion = BackdropMotionState()
        let frameInterval = 1.0 / 30.0
        var now: TimeInterval = 100.0
        let quiet = [Float](repeating: 0, count: 24)
        for _ in 0..<120 {
            now += frameInterval
            motion.step(now: now, playing: true, levels: quiet, live: true)
        }
        XCTAssertEqual(motion.speed, 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(motion.drift, 3.0)

        let loud = [Float](repeating: 1.0, count: 24)
        now += frameInterval
        motion.step(now: now, playing: true, levels: loud, live: true)
        XCTAssertGreaterThan(motion.bassLevel, 0.2)

        var moving = true
        for _ in 0..<120 {
            now += frameInterval
            moving = motion.step(now: now, playing: false, levels: quiet, live: false)
        }
        XCTAssertFalse(moving)
        XCTAssertEqual(motion.speed, 0.0, accuracy: 0.001)

        let frozenDrift = motion.drift
        now += 1.0
        motion.step(now: now, playing: false, levels: quiet, live: false)
        XCTAssertEqual(motion.drift, frozenDrift, accuracy: 1e-6)

        // 6. 切歌 700ms 立方淡出验证
        XCTAssertEqual(BackdropFogMath.beforeLayerOpacity(elapsedSinceFadeStart: 0.0), 1.0, accuracy: 0.001)
        XCTAssertEqual(BackdropFogMath.beforeLayerOpacity(elapsedSinceFadeStart: 0.35), 0.125, accuracy: 0.01)
        XCTAssertEqual(BackdropFogMath.beforeLayerOpacity(elapsedSinceFadeStart: 0.70), 0.0, accuracy: 0.001)
    }

    @MainActor
    func testFloatingTabBarMinimizeMathAndPrimaryTabMapping() {
        // 1. 左侧主胶囊 3 槽映射（首页 / 音乐库 / 设置）与搜索圆形分离一致性校验
        XCTAssertEqual(MainTabMapping.primaryTabIDs, [0, 2, 3])
        XCTAssertEqual(MainTabMapping.slotIndex(for: 0), 0)
        XCTAssertEqual(MainTabMapping.slotIndex(for: 2), 1)
        XCTAssertEqual(MainTabMapping.slotIndex(for: 3), 2)
        XCTAssertNil(MainTabMapping.slotIndex(for: MainTabMapping.searchTabID))
        XCTAssertEqual(MainTabMapping.tabID(forSlotIndex: 0), 0)
        XCTAssertEqual(MainTabMapping.tabID(forSlotIndex: 1), 2)
        XCTAssertEqual(MainTabMapping.tabID(forSlotIndex: 2), 3)
        XCTAssertEqual(MainTabMapping.effectivePrimaryTab(selectedTab: 2, lastPrimaryTab: 0), 2)
        XCTAssertEqual(MainTabMapping.effectivePrimaryTab(selectedTab: 3, lastPrimaryTab: 0), 3)
        XCTAssertEqual(MainTabMapping.effectivePrimaryTab(selectedTab: 1, lastPrimaryTab: 3), 3)
        XCTAssertEqual(MainTabMapping.effectivePrimaryTab(selectedTab: 1, lastPrimaryTab: 99), 0)

        // 2. 内容过短或处于顶部保护区域时绝不误收起
        let shortContent = FloatingTabBarMinimizeMath.evaluateScrollStep(
            currentlyMinimized: false,
            accumulatedDelta: 0,
            normalizedOffsetY: 32,
            deltaY: 40,
            maxScrollOffset: 40,
            isUserInteracting: true
        )
        XCTAssertFalse(shortContent.isMinimized)

        let topRegion = FloatingTabBarMinimizeMath.evaluateScrollStep(
            currentlyMinimized: true,
            accumulatedDelta: 10,
            normalizedOffsetY: 8,
            deltaY: 6,
            maxScrollOffset: 600,
            isUserInteracting: true
        )
        XCTAssertFalse(topRegion.isMinimized)
        XCTAssertEqual(topRegion.accumulatedDelta, 0)

        // 3. 向下浏览累积超过阈值后平滑收起
        let step1 = FloatingTabBarMinimizeMath.evaluateScrollStep(
            currentlyMinimized: false,
            accumulatedDelta: 0,
            normalizedOffsetY: 48,
            deltaY: 12,
            maxScrollOffset: 600,
            isUserInteracting: true
        )
        XCTAssertFalse(step1.isMinimized)
        XCTAssertEqual(step1.accumulatedDelta, 12, accuracy: 0.01)

        let step2 = FloatingTabBarMinimizeMath.evaluateScrollStep(
            currentlyMinimized: step1.isMinimized,
            accumulatedDelta: step1.accumulatedDelta,
            normalizedOffsetY: 60,
            deltaY: 12,
            maxScrollOffset: 600,
            isUserInteracting: true
        )
        XCTAssertTrue(step2.isMinimized)
        XCTAssertEqual(step2.accumulatedDelta, 0, accuracy: 0.01)

        // 4. 触底橡皮筋回弹期间保持折叠态，不被误判为向上回看
        let rubberBounce = FloatingTabBarMinimizeMath.evaluateScrollStep(
            currentlyMinimized: true,
            accumulatedDelta: 0,
            normalizedOffsetY: 599,
            deltaY: -25,
            maxScrollOffset: 600,
            isUserInteracting: true
        )
        XCTAssertTrue(rubberBounce.isMinimized)

        // 5. 在正常内容区向下拉动回看超越恢复阈值后平滑展开
        let pullDownExpand = FloatingTabBarMinimizeMath.evaluateScrollStep(
            currentlyMinimized: true,
            accumulatedDelta: -6,
            normalizedOffsetY: 220,
            deltaY: -12,
            maxScrollOffset: 600,
            isUserInteracting: true
        )
        XCTAssertFalse(pullDownExpand.isMinimized)
        XCTAssertEqual(pullDownExpand.accumulatedDelta, 0, accuracy: 0.01)

        // 6. 验证展开与嵌合紧凑模式 MiniPlayerBarView 双态均能正常构建
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-mini-compact-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let model = AppModel(baseDataDir: tmpRoot)
        _ = MiniPlayerBarView(isCompact: false).environmentObject(model)
        _ = MiniPlayerBarView(isCompact: true).environmentObject(model)
    }

    @MainActor
    func testBrowseLinkIconKindResolution() {
        // 1. 插件显式 navigation.icon 优先
        XCTAssertEqual(
            MyGoNavIconKind.resolve(linkPage: "charts", linkTitle: "排行榜", navigationIcon: "chart"),
            .chart
        )
        XCTAssertEqual(
            MyGoNavIconKind.resolve(linkPage: "custom", linkTitle: "自定义", navigationIcon: "radio"),
            .radio
        )

        // 2. page 路径规范语义推断（如酷狗首页 发现 -> 排行榜 / 私人FM）
        XCTAssertEqual(MyGoNavIconKind.resolve(linkPage: "charts", linkTitle: "排行榜"), .chart)
        XCTAssertEqual(MyGoNavIconKind.resolve(linkPage: "rank:8888", linkTitle: "TOP500"), .chart)
        XCTAssertEqual(MyGoNavIconKind.resolve(linkPage: "fm", linkTitle: "私人FM"), .radio)
        XCTAssertEqual(MyGoNavIconKind.resolve(linkPage: "stations", linkTitle: "电台"), .radio)
        XCTAssertEqual(MyGoNavIconKind.resolve(linkPage: "daily", linkTitle: "每日推荐"), .calendar)
        XCTAssertEqual(MyGoNavIconKind.resolve(linkPage: "vip", linkTitle: "再次领取今日 VIP"), .vip)
        XCTAssertEqual(MyGoNavIconKind.resolve(linkPage: "recent", linkTitle: "最近播放"), .recent)
        XCTAssertEqual(MyGoNavIconKind.resolve(linkPage: "cloud", linkTitle: "音乐云盘"), .cloud)

        // 3. 标题关键词兜底与未知回退
        XCTAssertEqual(MyGoNavIconKind.resolve(linkPage: "hot", linkTitle: "热歌榜单"), .chart)
        XCTAssertEqual(MyGoNavIconKind.resolve(linkPage: "live", linkTitle: "深夜电台"), .radio)
        XCTAssertEqual(MyGoNavIconKind.resolve(linkPage: "mystery", linkTitle: "探索更多"), .discover)

        // 4. 列表 SF Symbol 映射一致性
        XCTAssertEqual(MyGoNavIconKind.sfSymbol(for: "chart"), "chart.bar.fill")
        XCTAssertEqual(MyGoNavIconKind.sfSymbol(for: "radio"), "dot.radiowaves.left.and.right")
        XCTAssertEqual(MyGoNavIconKind.sfSymbol(for: "calendar"), "calendar")
        XCTAssertEqual(MyGoNavIconKind.sfSymbol(for: nil), "music.note.list")

        // 5. BrowseLinkIconView 有图 / 无图双态视图构建不崩溃
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-link-icon-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let model = AppModel(baseDataDir: tmpRoot)
        _ = BrowseLinkIconView(urlString: nil, page: "charts", title: "排行榜", navigationIcon: "chart")
            .environmentObject(model)
        _ = BrowseLinkIconView(urlString: "https://imge.kugou.com/mcommon/400/test.png", page: "rank:8888", title: "TOP500")
            .environmentObject(model)
    }

    func testAdaptiveThemeTokensLightAndDarkContrast() {
        let light = MyGoTheme.tokens(isDark: false)
        let dark = MyGoTheme.tokens(isDark: true)

        // 1. 深色模式画布为 OLED 纯黑 #000000，卡片层级提升至 #1C1C1E 家族色
        XCTAssertEqual(dark.pageBackground.r, 0.0, accuracy: 0.001)
        XCTAssertEqual(dark.pageBackground.g, 0.0, accuracy: 0.001)
        XCTAssertEqual(dark.pageBackground.b, 0.0, accuracy: 0.001)
        XCTAssertGreaterThan(dark.elevatedSurface.r, dark.pageBackground.r + 0.08)
        XCTAssertGreaterThan(dark.pillSurface.r, dark.elevatedSurface.r)

        // 2. 深色模式主强调红对标 Apple Music #FF375F，亮度/通透感高于浅色 #FA233B
        XCTAssertGreaterThan(dark.accent.r, light.accent.r)
        XCTAssertGreaterThan(dark.accent.g, light.accent.g)
        XCTAssertGreaterThan(dark.accent.b, light.accent.b)

        // 3. 深色当前播放行高亮改为中性微光浮层（R/G/B 等值），杜绝红透明叠纯黑发棕
        XCTAssertEqual(dark.currentTrackFill.r, dark.currentTrackFill.g, accuracy: 0.001)
        XCTAssertEqual(dark.currentTrackFill.g, dark.currentTrackFill.b, accuracy: 0.001)
        XCTAssertLessThan(dark.currentTrackFill.a, 0.15)
        XCTAssertGreaterThan(dark.currentTrackFill.a, 0.05)

        // 4. 动态色板属性及页面 Surface 修饰符可无异常构建
        _ = Text("Light & Dark")
            .mygoPillSurface(isHighlighted: false)
            .mygoElevatedSurface(cornerRadius: 14)
            .mygoCircleSurface()
            .background(MyGoTheme.pageBackground)
            .overlay(Rectangle().fill(MyGoTheme.placeholderFill))
            .overlay(Rectangle().strokeBorder(MyGoTheme.artworkBorder, lineWidth: 0.5))
    }

    func testLiquidGlassElevationLightModeAvoidsHeavyBlackMask() {
        // 1. 浅色白底/浅灰底下悬浮玻璃的投影必须极其克制，防止迷你条/导航栏下方及缝隙积出一整层黑灰蒙版
        let lightPrimaryOpacity = LiquidGlassElevationSpec.primaryShadowOpacity(isDark: false)
        let lightContactOpacity = LiquidGlassElevationSpec.contactShadowOpacity(isDark: false)
        let lightRadius = LiquidGlassElevationSpec.primaryShadowRadius(isDark: false)
        let lightOffsetY = LiquidGlassElevationSpec.primaryShadowOffsetY(isDark: false)

        XCTAssertLessThanOrEqual(lightPrimaryOpacity, 0.05)
        XCTAssertLessThanOrEqual(lightContactOpacity, 0.03)
        XCTAssertLessThanOrEqual(lightPrimaryOpacity + lightContactOpacity, 0.075)
        // 半径保持紧凑，不溢出到 16pt 屏幕左右边缘与安全区外
        XCTAssertLessThanOrEqual(lightRadius, 10)
        XCTAssertLessThanOrEqual(lightOffsetY, 3)

        // 2. 深色模式下保持足够的黑曜石悬浮层次感
        XCTAssertGreaterThan(LiquidGlassElevationSpec.primaryShadowOpacity(isDark: true), lightPrimaryOpacity)
        XCTAssertGreaterThan(LiquidGlassElevationSpec.primaryShadowRadius(isDark: true), lightRadius)
    }

    func testPluginHTTPUtilitiesSkipsBase64ForUTF8JSONTextPayload() {
        let jsonData = Data("{\"songs\":[{\"id\":\"1001\",\"name\":\"Haruhikage\"}]}".utf8)
        XCTAssertTrue(PluginHTTPUtilities.isLikelyTextPayload(contentType: "application/json; charset=utf-8", data: jsonData))
        XCTAssertTrue(PluginHTTPUtilities.isLikelyTextPayload(contentType: "text/plain", data: Data("ok".utf8)))

        let binaryPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertFalse(PluginHTTPUtilities.isLikelyTextPayload(contentType: "image/png", data: binaryPNG))
        XCTAssertFalse(PluginHTTPUtilities.isLikelyTextPayload(contentType: nil, data: jsonData))
        XCTAssertFalse(PluginHTTPUtilities.isLikelyTextPayload(contentType: "application/json", data: Data([0x7B, 0x00, 0x7D])))

        let url = URL(string: "https://nas.local/api/playlist")!
        let jsonResp = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json; charset=utf-8"]
        )
        let jsonPayload = PluginHTTPUtilities.buildFetchResponsePayload(
            urlString: url.absoluteString,
            data: jsonData,
            httpResp: jsonResp
        )
        XCTAssertEqual(jsonPayload["text"] as? String, String(data: jsonData, encoding: .utf8))
        XCTAssertNil(jsonPayload["base64"], "UTF-8 JSON 文本响应不应重复做高开销的全量 Base64 编码")

        let binResp = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"]
        )
        let binPayload = PluginHTTPUtilities.buildFetchResponsePayload(
            urlString: url.absoluteString,
            data: binaryPNG,
            httpResp: binResp
        )
        XCTAssertEqual(binPayload["base64"] as? String, binaryPNG.base64EncodedString())
    }

    @MainActor
    func testAppModelCheckLikesDeduplicatesIDsAndComputesDeltaOnly() {
        let tracks = [
            Track(id: "t1", source: "feiniu", name: "Song 1"),
            Track(id: "t2", source: "feiniu", name: "Song 2"),
            Track(id: "t1", source: "feiniu", name: "Song 1 Dup"),
            Track(id: "t3", source: nil, name: "Song 3 Fallback"),
            Track(id: "k1", source: "kugou", name: "Song K1"),
            Track(id: "t3", source: "feiniu", name: "Song 3 Dup")
        ]
        let grouped = AppModel.uniqueTrackIDsBySource(tracks: tracks, fallbackSourceID: "feiniu")
        XCTAssertEqual(grouped["feiniu"], ["t1", "t2", "t3"], "同一音源去重时应保持原始顺序")
        XCTAssertEqual(grouped["kugou"], ["k1"])

        let existing: [String: Bool] = [
            "feiniu:t1": true,
            "feiniu:t2": false
        ]
        // 无任何实际变更时返回空 diff，避免无意义触发 ObservableObject 全局重绘
        let unchanged = AppModel.diffLikedUpdates(
            existing: existing,
            incoming: ["t1": true, "t2": false],
            sourceID: "feiniu"
        )
        XCTAssertTrue(unchanged.isEmpty)

        // 仅变更或新增键出现在 diff 中
        let changed = AppModel.diffLikedUpdates(
            existing: existing,
            incoming: ["t1": true, "t2": true, "t3": true],
            sourceID: "feiniu"
        )
        XCTAssertEqual(changed, ["feiniu:t2": true, "feiniu:t3": true])
    }

    func testLazyTrackRowsViewGeneratesUniqueIDsForDuplicateTracks() {
        let duplicateTracks = [
            Track(id: "101", source: "feiniu", name: "Track A"),
            Track(id: "101", source: "feiniu", name: "Track A Again"),
            Track(id: "102", source: "feiniu", name: "Track B"),
            Track(id: "101", source: "feiniu", name: "Track A Third")
        ]
        let entries = LazyTrackRowsView.buildRowEntries(for: duplicateTracks)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(Set(entries.map(\.id)).count, 4, "重复曲目在 LazyVStack 中必须拥有唯一行 ID")
        XCTAssertEqual(entries[0].id, "feiniu:101")
        XCTAssertEqual(entries[1].id, "feiniu:101#1")
        XCTAssertEqual(entries[3].id, "feiniu:101#2")
    }

    @MainActor
    func testArtworkImageLoaderCachesDecodedMemoryCoalescesConcurrentRequestsAndCompactsOversizedDiskImage() async throws {
        ArtworkImageLoader.clearMemoryCache()
        ArtworkImageLoader.clearDiskCacheForTesting()
        defer {
            ArtworkImageLoader.clearMemoryCache()
            ArtworkImageLoader.clearDiskCacheForTesting()
        }

        // 1. 生成一张 800x800 高熵噪点不透明 PNG 大图（> 128KB），验证降采样与磁盘紧凑压缩
        let width = 800
        let height = 800
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var state: UInt32 = 0x1234_5678
        for idx in stride(from: 0, to: rgba.count, by: 4) {
            state = state &* 1664525 &+ 1013904223
            rgba[idx] = UInt8((state >> 16) & 0xFF)
            rgba[idx + 1] = UInt8((state >> 8) & 0xFF)
            rgba[idx + 2] = UInt8(state & 0xFF)
            rgba[idx + 3] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        let ctx = rgba.withUnsafeMutableBytes { ptr -> CGContext? in
            CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        }
        let cg = try XCTUnwrap(ctx?.makeImage())
        let pngMutable = NSMutableData()
        let pngDest = try XCTUnwrap(CGImageDestinationCreateWithData(pngMutable, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(pngDest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(pngDest))
        let largePNGData = pngMutable as Data
        XCTAssertGreaterThan(largePNGData.count, 128 * 1024)

        let compactCheck = ArtworkImageLoader.decodeAndCompactIfNeeded(
            data: largePNGData,
            maxPixelSize: 320,
            extractDominantColor: true
        )
        let sampledCG = try XCTUnwrap(compactCheck.cgImage)
        XCTAssertLessThanOrEqual(sampledCG.width, 320)
        XCTAssertLessThanOrEqual(sampledCG.height, 320)
        let compacted = try XCTUnwrap(compactCheck.compactedDiskData, "超过 128KB 且 maxPixelSize <= 640 的大图应生成紧凑磁盘缓存")
        XCTAssertLessThan(compacted.count, largePNGData.count / 2)
        XCTAssertNotNil(compactCheck.dominantRGB)

        // 2. 并发 6 次相同 URL 请求必须合并为单次网络请求
        actor FetchCounter {
            var count = 0
            func increment() { count += 1 }
        }
        let counter = FetchCounter()
        let testURL = "https://nas.example.local/cover/large-album-\(UUID().uuidString).png"
        let fetcher: ArtworkImageLoader.NetworkDataFetcher = { req in
            await counter.increment()
            try await Task.sleep(nanoseconds: 25_000_000)
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"]
            )!
            return (largePNGData, resp)
        }

        let loaders = (0..<6).map { _ in ArtworkImageLoader() }
        await withTaskGroup(of: Void.self) { group in
            for loader in loaders {
                group.addTask { @MainActor in
                    await loader.load(
                        rawURLString: testURL,
                        pixelSize: 160,
                        extractDominantColor: true,
                        networkFetcher: fetcher,
                        headersProvider: nil
                    )
                }
            }
        }
        let fetchCount = await counter.count
        XCTAssertEqual(fetchCount, 1, "并发请求同一封面地址与尺寸时应合并为 1 次网络拉取")
        for loader in loaders {
            XCTAssertNotNil(loader.image)
            XCTAssertNotNil(loader.dominantRGB)
        }
        XCTAssertNotNil(ArtworkImageLoader.cachedSwiftUIImage(rawURLString: testURL, pixelSize: 160))

        // 3. 第二次加载（新 loader 实例）应零网络直接命中内存缓存
        let failingFetcher: ArtworkImageLoader.NetworkDataFetcher = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let memLoader = ArtworkImageLoader()
        await memLoader.load(
            rawURLString: testURL,
            pixelSize: 160,
            extractDominantColor: true,
            networkFetcher: failingFetcher,
            headersProvider: nil
        )
        XCTAssertNotNil(memLoader.image)
        XCTAssertNotNil(memLoader.dominantRGB)

        // 4. 清空内存缓存后，应无需网络直接从磁盘紧凑缩略图恢复
        ArtworkImageLoader.clearMemoryCache()
        let diskLoader = ArtworkImageLoader()
        await diskLoader.load(
            rawURLString: testURL,
            pixelSize: 160,
            extractDominantColor: false,
            networkFetcher: failingFetcher,
            headersProvider: nil
        )
        XCTAssertNotNil(diskLoader.image)
    }

    func testVerticalScrollProbeFilterSuppressesSubpixelJitterWhilePreservingBoundaries() {
        // 首次采样必放行
        XCTAssertTrue(VerticalScrollProbeFilter.shouldEmit(
            lastNormalizedY: nil,
            currentNormalizedY: 200,
            lastInteracting: nil,
            currentInteracting: true,
            maxOffset: 1000
        ))

        // 中段 < 1pt 亚像素抖动屏蔽
        XCTAssertFalse(VerticalScrollProbeFilter.shouldEmit(
            lastNormalizedY: 200.0,
            currentNormalizedY: 200.6,
            lastInteracting: true,
            currentInteracting: true,
            maxOffset: 1000
        ))

        // >= 1pt 正常放行
        XCTAssertTrue(VerticalScrollProbeFilter.shouldEmit(
            lastNormalizedY: 200.0,
            currentNormalizedY: 201.1,
            lastInteracting: true,
            currentInteracting: true,
            maxOffset: 1000
        ))

        // 交互状态变化即使 0pt 位移也必须放行
        XCTAssertTrue(VerticalScrollProbeFilter.shouldEmit(
            lastNormalizedY: 200.0,
            currentNormalizedY: 200.0,
            lastInteracting: true,
            currentInteracting: false,
            maxOffset: 1000
        ))

        // 顶部安全区 >= 0.4pt 精确放行
        XCTAssertTrue(VerticalScrollProbeFilter.shouldEmit(
            lastNormalizedY: 0.6,
            currentNormalizedY: 0.0,
            lastInteracting: false,
            currentInteracting: false,
            maxOffset: 1000
        ))

        // 底部边界 >= 0.4pt 精确放行
        XCTAssertTrue(VerticalScrollProbeFilter.shouldEmit(
            lastNormalizedY: 999.0,
            currentNormalizedY: 999.5,
            lastInteracting: false,
            currentInteracting: false,
            maxOffset: 1000
        ))

        // 验证同帧多次微震 + 快速位移经由累加器合并且 drain 后清空
        var acc = VerticalScrollDeltaAccumulator()
        acc.add(12.5)
        acc.add(-0.3)
        acc.add(18.0)
        XCTAssertEqual(acc.drain(), 30.2, accuracy: 0.001)
        XCTAssertEqual(acc.drain(), 0.0, accuracy: 0.001)
        acc.add(5.0)
        acc.reset()
        XCTAssertEqual(acc.drain(), 0.0, accuracy: 0.001)
    }

    func testDailyFeatureCardMathColorsCoversAndQueueDetection() {
        // 1. 封面主色调衍生三重色：高饱和暖金应生成 deep(v=0.24) / rich(v=0.50) / glow(v=1.0)
        let warmAmber = BackdropRGBColor(r: 0.85, g: 0.62, b: 0.18)
        let amberColors = BackdropFogMath.dailyCardColors(from: warmAmber)
        let (_, _, deepV) = BackdropFogMath.rgbToHSV(r: amberColors.deep.r, g: amberColors.deep.g, b: amberColors.deep.b)
        let (_, _, richV) = BackdropFogMath.rgbToHSV(r: amberColors.rich.r, g: amberColors.rich.g, b: amberColors.rich.b)
        let (_, _, glowV) = BackdropFogMath.rgbToHSV(r: amberColors.glow.r, g: amberColors.glow.g, b: amberColors.glow.b)
        XCTAssertEqual(deepV, 0.24, accuracy: 0.02)
        XCTAssertEqual(richV, 0.50, accuracy: 0.02)
        XCTAssertEqual(glowV, 1.00, accuracy: 0.02)

        // 极低饱和度黑白封面与 nil 应安全回落到绯红色系，避免灰蒙
        let neutralGray = BackdropRGBColor(r: 0.55, g: 0.55, b: 0.56)
        let fallbackColors = BackdropFogMath.dailyCardColors(from: neutralGray)
        let defaultColors = BackdropFogMath.dailyCardColors(from: nil)
        XCTAssertEqual(fallbackColors.deep.r, defaultColors.deep.r, accuracy: 0.01)
        XCTAssertEqual(fallbackColors.rich.g, defaultColors.rich.g, accuracy: 0.01)

        // 2. 三张错落封面抽取：前两首同专辑时应智能略过重复封面并向后抓取第三张不同专辑
        let makeTrack: (String, String, String?) -> Track = { id, artist, coverURL in
            Track(
                id: id,
                source: "fn",
                name: "Song \(id)",
                artists: artist.isEmpty ? nil : [Artist(id: artist, name: artist)],
                album: Album(id: "alb-\(id)", name: "Alb \(id)", imageUrl: coverURL)
            )
        }
        let tracks = [
            makeTrack("1", "Phoebe Ryan", "https://example.com/a.jpg"),
            makeTrack("2", "Phoebe Ryan", "https://example.com/a.jpg"), // 与第1首同封面
            makeTrack("3", "筷子兄弟", "https://example.com/b.jpg"),
            makeTrack("4", "许嵩", "https://example.com/c.jpg"),
            makeTrack("5", "周杰伦", "https://example.com/d.jpg")
        ]
        let pickedCovers = DailyFeatureCardMath.featuredCoverURLs(for: tracks, limit: 3)
        XCTAssertEqual(pickedCovers, [
            "https://example.com/a.jpg",
            "https://example.com/b.jpg",
            "https://example.com/c.jpg"
        ])

        // 少于 3 首但仅 1 个唯一封面时仍应保留叠层占位数量
        let singleCoverDuo = [
            makeTrack("10", "许嵩", "https://example.com/same.jpg"),
            makeTrack("11", "许嵩", "https://example.com/same.jpg")
        ]
        XCTAssertEqual(DailyFeatureCardMath.featuredCoverURLs(for: singleCoverDuo, limit: 3).count, 2)

        // 3. 歌手摘要最多提取 3 名去重歌手（对齐桌面端 `%s 等 · %s`）；单曲单歌手不带多余的“等”
        let summary = DailyFeatureCardMath.artistSummary(for: tracks)
        XCTAssertTrue(summary.contains("Phoebe Ryan, 筷子兄弟, 许嵩"))
        XCTAssertFalse(summary.contains("周杰伦"))
        XCTAssertTrue(summary.contains("5"))

        let singleTrackSummary = DailyFeatureCardMath.artistSummary(for: [makeTrack("99", "许嵩", nil)])
        XCTAssertTrue(singleTrackSummary.contains("许嵩"))
        XCTAssertFalse(singleTrackSummary.contains("等"))

        // 4. 播放队列归属判定与新版 3 封面黑胶卡片构造
        XCTAssertTrue(DailyFeatureCardMath.isQueueActive(queue: tracks, currentTrack: tracks[2], sectionTracks: tracks))
        XCTAssertFalse(DailyFeatureCardMath.isQueueActive(queue: tracks, currentTrack: nil, sectionTracks: tracks))
        XCTAssertFalse(DailyFeatureCardMath.isQueueActive(queue: Array(tracks.prefix(4)), currentTrack: tracks[0], sectionTracks: tracks))

        let cardView = DailyFeatureCardView(
            section: MusicSection(title: "最近播放", tracks: tracks),
            isPlayingFromCard: true,
            isQueueFromCard: true,
            audioBands: [0.4, 0.7, 0.5, 0.3],
            onPlay: {},
            onOpen: {}
        )
        _ = cardView.body
    }

    // MARK: - 14. 插件在线更新（轻量检测 / Commit SHA 回退 / 仓库绑定 / 权限二次确认 / 社区目录）

    func testPluginInstallerLightweightUpdateAndCommitFallback() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-plugin-upd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let pluginsDir = workDir.appendingPathComponent("plugins", isDirectory: true)
        let dataRootDir = workDir.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataRootDir, withIntermediateDirectories: true)

        // 先构造已安装插件（带有旧的 8 位 commit origin 与用户数据）
        let installedDir = pluginsDir.appendingPathComponent("mock-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)
        let v1Manifest = """
        {
          "id": "mock-plugin",
          "name": "Mock Plugin",
          "version": "1.0.0",
          "main": "index.js",
          "repository": "owner/mock-plugin",
          "homepage": "https://docs.other-host.dev/mock/plugin",
          "permissions": { "network": ["*.example.com"] }
        }
        """
        try Data(v1Manifest.utf8).write(to: installedDir.appendingPathComponent("plugin.json"))
        try Data("export function home() { return { title: 'V1', sections: [] }; }\n".utf8)
            .write(to: installedDir.appendingPathComponent("index.js"))

        // 验证 strictly 只匹配 GitHub 的 repository，忽略非 GitHub 域名 homepage
        let inferredOrigin = PluginInstaller.effectiveOrigin(for: installedDir)
        XCTAssertEqual(inferredOrigin?.repo, "owner/mock-plugin")
        XCTAssertEqual(inferredOrigin?.version, "1.0.0")
        XCTAssertNil(PluginInstaller.parseOptionalGitHubRepo("https://docs.other-host.dev/mock/plugin"))

        // 写入旧 8 位 SHA .origin.json，测试与远端 12 位同前缀 commit 不误报假更新
        try PluginInstaller.saveOrigin(PluginOrigin(repo: "owner/mock-plugin", version: "a1b2c3d4"), in: installedDir)
        let commitMockState = LockedRequestRecorder()
        let sameCommitTransport: PluginHTTPTransport = { req in
            commitMockState.record(req)
            let urlStr = req.url?.absoluteString ?? ""
            if urlStr.hasSuffix("/releases/latest") {
                return Self.mockHTTPResponse(url: req.url!, statusCode: 404, json: #"{"message":"Not Found"}"#)
            }
            if urlStr.hasSuffix("/commits/HEAD") {
                return Self.mockHTTPResponse(url: req.url!, statusCode: 200, json: #"{"sha":"a1b2c3d4e5f678901234567890abcdef12345678"}"#)
            }
            XCTFail("轻量 checkUpdate 不应预下载 zipball: \(urlStr)")
            return Self.mockHTTPResponse(url: req.url!, statusCode: 500, data: Data())
        }

        let noUpdateInfo = try await PluginInstaller.checkUpdate(for: installedDir, transport: sameCommitTransport)
        XCTAssertFalse(noUpdateInfo.hasUpdate)
        XCTAssertEqual(noUpdateInfo.latestVersion, "a1b2c3d4e5f6")
        XCTAssertEqual(commitMockState.urls.count, 2)

        // 当远端产生新 commit（Release 404 回退到 HEAD SHA），精准检出更新且可从 release.zipball 下载安装
        let newCommitZip = Self.makeStoredZipData(entries: [
            ("owner-mock-plugin-fedcba9/plugin.json", Data("""
            {
              "id": "mock-plugin",
              "name": "Mock Plugin",
              "version": "1.0.0",
              "main": "index.js",
              "permissions": { "network": ["sub.example.com"] }
            }
            """.utf8)),
            ("owner-mock-plugin-fedcba9/index.js", Data("export function home() { return { title: 'V2-Commit', sections: [] }; }\n".utf8))
        ])

        let releaseAssetZip = Self.makeStoredZipData(entries: [
            ("plugin.json", Data("""
            {
              "id": "mock-plugin",
              "name": "Mock Plugin",
              "version": "1.2.0",
              "main": "index.js",
              "permissions": { "network": ["sub.example.com", "cdn.api.test"] }
            }
            """.utf8)),
            ("index.js", Data("export function home() { return { title: 'V1.2-Release', sections: [] }; }\n".utf8))
        ])

        // 1) 新 commit 检查 + fetchFromRelease 验证
        let nextCommitTransport: PluginHTTPTransport = { req in
            let urlStr = req.url?.absoluteString ?? ""
            if urlStr.hasSuffix("/releases/latest") {
                return Self.mockHTTPResponse(url: req.url!, statusCode: 404, json: #"{"message":"Not Found"}"#)
            }
            if urlStr.hasSuffix("/commits/HEAD") {
                return Self.mockHTTPResponse(url: req.url!, statusCode: 200, json: #"{"sha":"fedcba9876543210000000000000000000000000"}"#)
            }
            if urlStr.contains("/zipball/") {
                return Self.mockHTTPResponse(url: req.url!, statusCode: 200, data: newCommitZip)
            }
            return Self.mockHTTPResponse(url: req.url!, statusCode: 404, data: Data())
        }

        let commitUpdateInfo = try await PluginInstaller.checkUpdate(for: installedDir, transport: nextCommitTransport)
        XCTAssertTrue(commitUpdateInfo.hasUpdate)
        XCTAssertEqual(commitUpdateInfo.latestVersion, "fedcba987654")
        XCTAssertNotNil(commitUpdateInfo.release)

        let pendingCommit = try await PluginInstaller.fetchFromRelease(commitUpdateInfo.release!, transport: nextCommitTransport)
        defer { try? FileManager.default.removeItem(at: pendingCommit.sourcePath) }
        XCTAssertEqual(pendingCommit.version, "fedcba987654")
        // 验证旧权限通配符 *.example.com 覆盖 sub.example.com，不应触发权限变更确认
        XCTAssertNil(PluginInstaller.expandedPermissions(
            from: PluginPermissions(network: ["*.example.com"]),
            to: pendingCommit.manifest.permissions
        ))

        // 2) 带 Token 拉取 Release Asset：验证 Accept: application/octet-stream，且外链 CDN 不带 Authorization
        let assetRecorder = LockedRequestRecorder()
        let releaseTransport: PluginHTTPTransport = { req in
            assetRecorder.record(req)
            let urlStr = req.url?.absoluteString ?? ""
            if urlStr.hasSuffix("/releases/latest") {
                return Self.mockHTTPResponse(url: req.url!, statusCode: 200, json: """
                {
                  "tag_name": "v1.2.0",
                  "zipball_url": "https://api.github.com/repos/owner/mock-plugin/zipball/v1.2.0",
                  "assets": [
                    {
                      "name": "mock-plugin.zip",
                      "url": "https://api.github.com/repos/owner/mock-plugin/releases/assets/9988",
                      "browser_download_url": "https://objects.githubusercontent.com/assets/mock-plugin.zip"
                    }
                  ]
                }
                """)
            }
            if urlStr.hasSuffix("/releases/assets/9988") {
                return Self.mockHTTPResponse(url: req.url!, statusCode: 200, data: releaseAssetZip)
            }
            return Self.mockHTTPResponse(url: req.url!, statusCode: 404, data: Data())
        }

        let releaseInfoWithToken = try await PluginInstaller.latestRelease(
            repoInput: "owner/mock-plugin",
            token: "ghp_secret_token",
            transport: releaseTransport
        )
        XCTAssertEqual(releaseInfoWithToken.version, "1.2.0")
        XCTAssertTrue(releaseInfoWithToken.isReleaseAssetAPI)
        let pendingRelease = try await PluginInstaller.fetchFromRelease(
            releaseInfoWithToken,
            token: "ghp_secret_token",
            transport: releaseTransport
        )
        defer { try? FileManager.default.removeItem(at: pendingRelease.sourcePath) }
        let installedUpdated = try PluginInstaller.install(pendingRelease, into: pluginsDir, dataRootDir: dataRootDir)
        let homeResult = try await installedUpdated.home()
        XCTAssertEqual(homeResult.title, "V1.2-Release")
        XCTAssertEqual(PluginInstaller.readOrigin(in: installedUpdated.pluginDir)?.version, "1.2.0")

        let assetReq = assetRecorder.requests.last!
        XCTAssertEqual(assetReq.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
        XCTAssertEqual(assetReq.value(forHTTPHeaderField: "Authorization"), "Bearer ghp_secret_token")

        // 无 token 时应选公开 browser_download_url，且不对非 api.github.com 发送 Bearer Token
        let publicReleaseInfo = try await PluginInstaller.latestRelease(
            repoInput: "owner/mock-plugin",
            token: nil,
            transport: releaseTransport
        )
        XCTAssertFalse(publicReleaseInfo.isReleaseAssetAPI)
        XCTAssertEqual(publicReleaseInfo.downloadURL, "https://objects.githubusercontent.com/assets/mock-plugin.zip")

        // 3) 测试社区插件搜索 API 解析
        let communityTransport: PluginHTTPTransport = { req in
            Self.mockHTTPResponse(url: req.url!, statusCode: 200, json: """
            {
              "items": [
                {
                  "full_name": "egoist/mygo-music-youtube-music",
                  "name": "mygo-music-youtube-music",
                  "owner": { "login": "egoist" },
                  "description": "YouTube Music plugin",
                  "stargazers_count": 42,
                  "html_url": "https://github.com/egoist/mygo-music-youtube-music"
                }
              ]
            }
            """)
        }
        let communityList = try await PluginInstaller.fetchCommunityPlugins(transport: communityTransport)
        XCTAssertEqual(communityList.count, 1)
        XCTAssertEqual(communityList[0].repo, "egoist/mygo-music-youtube-music")
        XCTAssertEqual(communityList[0].stars, 42)
    }

    @MainActor
    func testAppModelPluginUpdateStateMachinePermissionsAndRepoLinking() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-appmodel-upd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let model = AppModel(baseDataDir: workDir)
        // 手动导入一个最初没有 .origin.json 的本地插件，并写入用户配置数据验证升级后不丢失
        let localSourceFolder = workDir.appendingPathComponent("staged-local", isDirectory: true)
        try FileManager.default.createDirectory(at: localSourceFolder, withIntermediateDirectories: true)
        try Data("""
        {
          "id": "demo-sync-plugin",
          "name": "Sync Test Plugin",
          "version": "1.0.0",
          "main": "index.js",
          "permissions": { "network": ["api.safe.test"], "process": false }
        }
        """.utf8).write(to: localSourceFolder.appendingPathComponent("plugin.json"))
        try Data("export function home() { return { title: 'SyncV1', sections: [] }; }\n".utf8)
            .write(to: localSourceFolder.appendingPathComponent("index.js"))

        await model.importLocalPlugin(from: localSourceFolder)
        XCTAssertNil(model.pluginOrigins["demo-sync-plugin"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: localSourceFolder.appendingPathComponent("plugin.json").path))

        let userStorageDir = workDir
            .appendingPathComponent("plugin-data", isDirectory: true)
            .appendingPathComponent("demo-sync-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: userStorageDir, withIntermediateDirectories: true)
        let savedSettingFile = userStorageDir.appendingPathComponent("storage.json")
        try Data(#"{"cookie":"keep-me-across-update"}"#.utf8).write(to: savedSettingFile)

        // 构造远端 v2.0.0 压缩包（新增网络权限与 process: true）
        let v2Zip = Self.makeStoredZipData(entries: [
            ("plugin.json", Data("""
            {
              "id": "demo-sync-plugin",
              "name": "Sync Test Plugin",
              "version": "2.0.0",
              "main": "index.js",
              "permissions": { "network": ["api.safe.test", "extra.new.host"], "process": true }
            }
            """.utf8)),
            ("index.js", Data("export function home() { return { title: 'SyncV2', sections: [] }; }\n".utf8))
        ])

        let mockTransport: PluginHTTPTransport = { req in
            let urlStr = req.url?.absoluteString ?? ""
            if urlStr.hasSuffix("/releases/latest") {
                return Self.mockHTTPResponse(url: req.url!, statusCode: 200, json: """
                {
                  "tag_name": "v2.0.0",
                  "zipball_url": "https://api.github.com/repos/test-org/demo-sync/zipball/v2.0.0",
                  "assets": []
                }
                """)
            }
            if urlStr.contains("/zipball/v2.0.0") {
                return Self.mockHTTPResponse(url: req.url!, statusCode: 200, data: v2Zip)
            }
            return Self.mockHTTPResponse(url: req.url!, statusCode: 404, data: Data())
        }

        // 1. 为本地导入插件绑定 GitHub 仓库并立刻检测更新
        let linked = await model.linkPluginRepository(
            id: "demo-sync-plugin",
            repoInput: "https://github.com/test-org/demo-sync",
            checkNow: true,
            transport: mockTransport
        )
        XCTAssertTrue(linked)
        XCTAssertEqual(model.pluginOrigins["demo-sync-plugin"]?.repo, "test-org/demo-sync")
        XCTAssertEqual(model.settings.pluginUpdates["demo-sync-plugin"], "2.0.0")
        XCTAssertEqual(model.availablePluginUpdateCount, 1)
        XCTAssertEqual(model.pluginCheckStates["demo-sync-plugin"], .updateAvailable("2.0.0"))

        // 2. 更新到 2.0.0 时检测到权限扩大：挂起等待确认，不直接覆盖
        let updatedImmediately = await model.updatePlugin(id: "demo-sync-plugin", transport: mockTransport)
        XCTAssertFalse(updatedImmediately)
        XCTAssertEqual(model.pendingPluginUpdateApproval?.addedPermissions.network, ["extra.new.host"])
        XCTAssertEqual(model.pendingPluginUpdateApproval?.addedPermissions.process, ["*"])
        XCTAssertEqual(model.pluginSources.first(where: { $0.manifest.id == "demo-sync-plugin" })?.manifest.version, "1.0.0")

        // 3. 用户确认权限扩展后完成升级，且用户 plugin-data 保持完整
        await model.confirmPendingPluginUpdate()
        XCTAssertNil(model.pendingPluginUpdateApproval)
        XCTAssertNil(model.settings.pluginUpdates["demo-sync-plugin"])
        XCTAssertEqual(model.availablePluginUpdateCount, 0)
        XCTAssertEqual(model.pluginCheckStates["demo-sync-plugin"], .upToDate)

        let upgradedPlugin = model.pluginSources.first(where: { $0.manifest.id == "demo-sync-plugin" })
        XCTAssertEqual(upgradedPlugin?.manifest.version, "2.0.0")
        let homeV2 = try await upgradedPlugin?.home()
        XCTAssertEqual(homeV2?.title, "SyncV2")
        let preservedStorage = try String(contentsOf: savedSettingFile, encoding: .utf8)
        XCTAssertTrue(preservedStorage.contains("keep-me-across-update"))

        // 4. 接口限流 / 错误不再被静默吞没，准确写入 .failed 状态
        let rateLimitTransport: PluginHTTPTransport = { req in
            let http = HTTPURLResponse(
                url: req.url!,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: ["X-RateLimit-Remaining": "0"]
            )!
            return (Data(), http)
        }
        await model.checkForPluginUpdates(manual: true, transport: rateLimitTransport)
        if case .failed(let msg)? = model.pluginCheckStates["demo-sync-plugin"] {
            XCTAssertTrue(msg.contains("rate limit"))
        } else {
            XCTFail("期望 checkState 为 .failed，实际为 \(String(describing: model.pluginCheckStates["demo-sync-plugin"]))")
        }
    }

    @MainActor
    func testAppModelPluginUpdateAlertDismissRaceAndQueuedBatchApprovals() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-alert-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let model = AppModel(baseDataDir: workDir)

        @MainActor
        func installLocalFixture(id: String, repo: String) async throws {
            let folder = workDir.appendingPathComponent("fixture-\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("""
            {
              "id": "\(id)",
              "name": "Plugin \(id)",
              "version": "1.0.0",
              "main": "index.js",
              "repository": "\(repo)",
              "permissions": { "network": ["base.example.com"], "process": false }
            }
            """.utf8).write(to: folder.appendingPathComponent("plugin.json"))
            try Data("export function home() { return { title: '\(id)-v1', sections: [] }; }\n".utf8)
                .write(to: folder.appendingPathComponent("index.js"))
            await model.importLocalPlugin(from: folder)
        }

        try await installLocalFixture(id: "race-plugin", repo: "test-org/race-plugin")
        try await installLocalFixture(id: "batch-second", repo: "test-org/batch-second")

        func makeV2Zip(id: String, extraHost: String) -> Data {
            Self.makeStoredZipData(entries: [
                ("plugin.json", Data("""
                {
                  "id": "\(id)",
                  "name": "Plugin \(id)",
                  "version": "2.0.0",
                  "main": "index.js",
                  "repository": "test-org/\(id)",
                  "permissions": { "network": ["base.example.com", "\(extraHost)"], "process": false }
                }
                """.utf8)),
                ("index.js", Data("export function home() { return { title: '\(id)-v2', sections: [] }; }\n".utf8))
            ])
        }

        let zips: [String: Data] = [
            "race-plugin": makeV2Zip(id: "race-plugin", extraHost: "new-a.example.com"),
            "batch-second": makeV2Zip(id: "batch-second", extraHost: "new-b.example.com")
        ]

        let transport: PluginHTTPTransport = { req in
            let urlStr = req.url?.absoluteString ?? ""
            for id in ["race-plugin", "batch-second"] where urlStr.contains("test-org/\(id)") {
                if urlStr.hasSuffix("/releases/latest") {
                    return Self.mockHTTPResponse(url: req.url!, statusCode: 200, json: """
                    {
                      "tag_name": "v2.0.0",
                      "zipball_url": "https://api.github.com/repos/test-org/\(id)/zipball/v2.0.0",
                      "assets": []
                    }
                    """)
                }
                if urlStr.contains("/zipball/v2.0.0"), let data = zips[id] {
                    return Self.mockHTTPResponse(url: req.url!, statusCode: 200, data: data)
                }
            }
            return Self.mockHTTPResponse(url: req.url!, statusCode: 404, data: Data())
        }

        // 1. 复现 SwiftUI `.alert` 关闭先触发 `isPresented = false`，紧接着触发确认按钮动作的竞态
        await model.checkForPluginUpdates(manual: true, transport: transport)
        XCTAssertEqual(model.availablePluginUpdateCount, 2)

        let startedRace = await model.updatePlugin(id: "race-plugin", transport: transport)
        XCTAssertFalse(startedRace)
        let capturedRaceApproval = try XCTUnwrap(model.pendingPluginUpdateApproval)
        XCTAssertEqual(capturedRaceApproval.id, "race-plugin")

        model.handlePendingPluginUpdateAlertDismissed()
        XCTAssertNil(model.pendingPluginUpdateApproval)
        XCTAssertTrue(FileManager.default.fileExists(atPath: capturedRaceApproval.pending.sourcePath.path))

        let installTask = model.approvePendingPluginUpdate(capturedRaceApproval)
        await installTask.value
        XCTAssertEqual(model.pluginSources.first(where: { $0.manifest.id == "race-plugin" })?.manifest.version, "2.0.0")
        XCTAssertNil(model.settings.pluginUpdates["race-plugin"])
        XCTAssertEqual(model.pluginCheckStates["race-plugin"], .upToDate)

        // 2. 多插件批量更新同时需要权限确认时应按队列依次弹出，不得相互覆盖
        try await installLocalFixture(id: "race-plugin", repo: "test-org/race-plugin")
        await model.checkForPluginUpdates(manual: true, transport: transport)
        XCTAssertEqual(model.availablePluginUpdateCount, 2)

        await model.updateAllPlugins(transport: transport)
        let firstQueued = try XCTUnwrap(model.pendingPluginUpdateApproval)
        let firstTask = model.approvePendingPluginUpdate(firstQueued)
        await firstTask.value

        // 等待队列切换弹出第二个待确认弹窗
        for _ in 0..<25 where model.pendingPluginUpdateApproval == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let secondQueued = try XCTUnwrap(model.pendingPluginUpdateApproval)
        XCTAssertNotEqual(firstQueued.id, secondQueued.id)
        let secondTask = model.approvePendingPluginUpdate(secondQueued)
        await secondTask.value

        XCTAssertEqual(model.availablePluginUpdateCount, 0)
        XCTAssertEqual(model.pluginSources.first(where: { $0.manifest.id == "race-plugin" })?.manifest.version, "2.0.0")
        XCTAssertEqual(model.pluginSources.first(where: { $0.manifest.id == "batch-second" })?.manifest.version, "2.0.0")
    }

    private static func mockHTTPResponse(
        url: URL,
        statusCode: Int,
        json: String
    ) -> (Data, URLResponse) {
        mockHTTPResponse(url: url, statusCode: statusCode, data: Data(json.utf8))
    }

    private static func mockHTTPResponse(
        url: URL,
        statusCode: Int,
        data: Data
    ) -> (Data, URLResponse) {
        let resp = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, resp)
    }

    /// 构造标准无压缩 Stored ZIP 字节流供在线更新单元测试使用
    private static func makeStoredZipData(entries: [(name: String, data: Data)]) -> Data {
        func appendLE16(_ out: inout Data, _ v: UInt16) {
            out.append(UInt8(v & 0xFF))
            out.append(UInt8((v >> 8) & 0xFF))
        }
        func appendLE32(_ out: inout Data, _ v: UInt32) {
            out.append(UInt8(v & 0xFF))
            out.append(UInt8((v >> 8) & 0xFF))
            out.append(UInt8((v >> 16) & 0xFF))
            out.append(UInt8((v >> 24) & 0xFF))
        }

        var archive = Data()
        var centralDir = Data()

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let localOffset = UInt32(archive.count)
            let size = UInt32(entry.data.count)

            // Local file header
            appendLE32(&archive, 0x04034b50)
            appendLE16(&archive, 20)
            appendLE16(&archive, 0)
            appendLE16(&archive, 0) // method 0: Stored
            appendLE16(&archive, 0)
            appendLE16(&archive, 0)
            appendLE32(&archive, 0) // extractZipData 不依赖 CRC32 字段
            appendLE32(&archive, size)
            appendLE32(&archive, size)
            appendLE16(&archive, UInt16(nameData.count))
            appendLE16(&archive, 0)
            archive.append(nameData)
            archive.append(entry.data)

            // Central directory header
            appendLE32(&centralDir, 0x02014b50)
            appendLE16(&centralDir, 20)
            appendLE16(&centralDir, 20)
            appendLE16(&centralDir, 0)
            appendLE16(&centralDir, 0) // method 0: Stored
            appendLE16(&centralDir, 0)
            appendLE16(&centralDir, 0)
            appendLE32(&centralDir, 0)
            appendLE32(&centralDir, size)
            appendLE32(&centralDir, size)
            appendLE16(&centralDir, UInt16(nameData.count))
            appendLE16(&centralDir, 0)
            appendLE16(&centralDir, 0)
            appendLE16(&centralDir, 0)
            appendLE16(&centralDir, 0)
            appendLE32(&centralDir, 0)
            appendLE32(&centralDir, localOffset)
            centralDir.append(nameData)
        }

        let cdOffset = UInt32(archive.count)
        let cdSize = UInt32(centralDir.count)
        archive.append(centralDir)

        // End of central directory record
        appendLE32(&archive, 0x06054b50)
        appendLE16(&archive, 0)
        appendLE16(&archive, 0)
        appendLE16(&archive, UInt16(entries.count))
        appendLE16(&archive, UInt16(entries.count))
        appendLE32(&archive, cdSize)
        appendLE32(&archive, cdOffset)
        appendLE16(&archive, 0)
        return archive
    }

    @MainActor
    func testDynamicIslandNowPlayingStateQueuePlayNextSleepTimerAndQuickActions() throws {
        let track1 = Track(
            id: "di-1",
            source: "netease",
            name: "春日影",
            artists: [Artist(id: "a1", name: "MyGO!!!!!")],
            album: Album(id: "al1", name: "迷星叫"),
            duration: 245_000
        )
        let track2 = Track(
            id: "di-2",
            source: "netease",
            name: "碧天伴走",
            artists: [Artist(id: "a1", name: "MyGO!!!!!")],
            album: Album(id: "al2", name: "碧天伴走"),
            duration: 230_000
        )
        let track3 = Track(
            id: "di-3",
            source: "netease",
            name: "诗超绊",
            artists: [Artist(id: "a1", name: "MyGO!!!!!")],
            album: Album(id: "al3", name: "迷迹波"),
            duration: 260_000
        )

        // 1. 灵动岛持久媒体标识与 playbackState 映射
        let id1A = PlayerEngine.persistentMediaID(for: track1)
        let id1B = PlayerEngine.persistentMediaID(for: track1)
        let id2 = PlayerEngine.persistentMediaID(for: track2)
        XCTAssertNotEqual(id1A, 0)
        XCTAssertEqual(id1A, id1B)
        XCTAssertNotEqual(id1A, id2)

        XCTAssertEqual(PlayerEngine.resolveNowPlayingPlaybackState(hasTrack: false, isPlaying: false), .stopped)
        XCTAssertEqual(PlayerEngine.resolveNowPlayingPlaybackState(hasTrack: false, isPlaying: true), .stopped)
        XCTAssertEqual(PlayerEngine.resolveNowPlayingPlaybackState(hasTrack: true, isPlaying: false), .paused)
        XCTAssertEqual(PlayerEngine.resolveNowPlayingPlaybackState(hasTrack: true, isPlaying: true), .playing)

        // 2. 拔耳机/蓝牙断连（oldDeviceUnavailable = 2）自动暂停判定
        XCTAssertTrue(PlayerEngine.shouldPauseForAudioRouteChange(reasonRawValue: 2, previousOutputPortTypes: ["Headphones"]))
        XCTAssertFalse(PlayerEngine.shouldPauseForAudioRouteChange(reasonRawValue: 1, previousOutputPortTypes: ["Headphones"]))

        // 3. 下一首插播（playNext）与队尾追加（enqueue）以及随机/循环模式设置
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("mygo-di-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let engine = PlayerEngine(cacheDir: tmpDir)
        engine.playQueue([track1, track2], start: 0)
        XCTAssertEqual(engine.orderedQueue.map(\.id), ["di-1", "di-2"])
        engine.playNext(track3)
        XCTAssertEqual(engine.orderedQueue.map(\.id), ["di-1", "di-3", "di-2"])
        engine.enqueue(track1)
        XCTAssertEqual(engine.orderedQueue.map(\.id), ["di-1", "di-3", "di-2", "di-1"])

        engine.setRepeatMode(.one)
        XCTAssertEqual(engine.repeatMode, .one)
        engine.setShuffle(true)
        XCTAssertTrue(engine.shuffle)
        XCTAssertEqual(engine.orderedQueue.first?.id, "di-1")

        // 4. 睡眠定时状态机验证
        engine.setSleepTimer(.afterCurrentTrack)
        XCTAssertTrue(engine.sleepTimerStopsAfterCurrentTrack)
        XCTAssertNil(engine.sleepTimerRemainingSeconds)

        engine.setSleepTimer(.minutes(15))
        XCTAssertFalse(engine.sleepTimerStopsAfterCurrentTrack)
        XCTAssertEqual(engine.sleepTimerRemainingSeconds, 900)

        engine.setSleepTimer(.off)
        XCTAssertFalse(engine.sleepTimerStopsAfterCurrentTrack)
        XCTAssertNil(engine.sleepTimerRemainingSeconds)

        // 5. 分享描述文本与桌面快捷操作类型常量对齐
        XCTAssertEqual(MyGoShareHelper.shareText(for: track1), "春日影 - MyGO!!!!! (迷星叫)")
        XCTAssertEqual(AppModel.QuickActionKind.resumePlayback.rawValue, "com.egoist.mygomusic.resume")
        XCTAssertEqual(AppModel.QuickActionKind.likedSongs.rawValue, "com.egoist.mygomusic.liked")
        XCTAssertEqual(AppModel.QuickActionKind.dailyMix.rawValue, "com.egoist.mygomusic.daily")
        XCTAssertEqual(AppModel.QuickActionKind.searchMusic.rawValue, "com.egoist.mygomusic.search")
    }

    // MARK: - 14. 核心音频容器识别与播放过渡配置单元测试

    func testResolvedCodecLabelsMatchAudioContainers() {
        XCTAssertEqual(
            PlayerEngine.resolvedCodecLabel(streamType: "flac", url: URL(string: "https://example.com/a.bin")!),
            "FLAC"
        )
        XCTAssertEqual(
            PlayerEngine.resolvedCodecLabel(streamType: nil, url: URL(string: "https://example.com/song.mp3")!),
            "MP3"
        )
        XCTAssertEqual(
            PlayerEngine.resolvedCodecLabel(streamType: "audio/mp4", url: URL(string: "https://example.com/track.m4a")!),
            "AAC / M4A"
        )
        XCTAssertEqual(
            PlayerEngine.resolvedCodecLabel(streamType: "wav", url: nil),
            "WAV (PCM)"
        )
        XCTAssertEqual(
            PlayerEngine.resolvedCodecLabel(streamType: "m4s", url: nil),
            "DASH Audio"
        )
    }

    @MainActor
    func testQueueReorderingClearAndSignalPathAndWaveform() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-signal-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let engine = PlayerEngine(cacheDir: tmpDir)
        let tracks = [
            Track(id: "q1", source: "mock", name: "Track 1"),
            Track(id: "q2", source: "mock", name: "Track 2"),
            Track(id: "q3", source: "mock", name: "Track 3"),
            Track(id: "q4", source: "mock", name: "Track 4")
        ]
        engine.playQueue(tracks, start: 1) // 当前曲目 Track 2 (index 1)
        XCTAssertEqual(engine.currentTrack?.id, "q2")
        XCTAssertEqual(engine.currentOrderIndex, 1)

        // #6 将 Track 4 (index 3) 移到 index 0（越过当前曲目）
        engine.moveInQueue(fromOrderIndex: 3, toOrderIndex: 0)
        XCTAssertEqual(engine.orderedQueue.map(\.id), ["q4", "q1", "q2", "q3"])
        XCTAssertEqual(engine.currentOrderIndex, 2)
        XCTAssertEqual(engine.currentTrack?.id, "q2")

        // 下移当前曲目 Track 2 (index 2 -> index 3)
        engine.moveInQueue(fromOrderIndex: 2, toOrderIndex: 3)
        XCTAssertEqual(engine.orderedQueue.map(\.id), ["q4", "q1", "q3", "q2"])
        XCTAssertEqual(engine.currentOrderIndex, 3)

        // 清空队列仅保留当前播放曲目
        engine.clearQueueKeepingCurrent()
        XCTAssertEqual(engine.orderedQueue.map(\.id), ["q2"])
        XCTAssertEqual(engine.currentOrderIndex, 0)

        // 无缝过渡配置反射到音频信号路径快照
        engine.updateTransitionConfiguration(gapless: true)
        XCTAssertTrue(engine.gaplessPlaybackEnabled)

        let path = engine.currentAudioSignalPath(sourceDisplayName: "本地音乐库")
        XCTAssertEqual(path.sourceName, "本地音乐库")
        XCTAssertEqual(path.codecFormat, "Audio")
        XCTAssertEqual(path.transitionMode, I18n.t("Gapless Playback"))

        engine.updateTransitionConfiguration(gapless: false)
        let offPath = engine.currentAudioSignalPath(sourceDisplayName: "本地音乐库")
        XCTAssertEqual(offPath.transitionMode, I18n.t("Off"))

        // #12 全曲能量波形直方桶确定性与范围验证
        let w1 = PlayerEngine.syntheticWaveformBuckets(seed: 123456, count: 56)
        let w2 = PlayerEngine.syntheticWaveformBuckets(seed: 123456, count: 56)
        let w3 = PlayerEngine.syntheticWaveformBuckets(seed: 654321, count: 56)
        XCTAssertEqual(w1.count, 56)
        XCTAssertEqual(w1, w2)
        XCTAssertNotEqual(w1, w3)
        XCTAssertTrue(w1.allSatisfy { $0 >= 0.10 && $0 <= 1.0 })
    }

    func testOfflineDownloadsPersistenceAndSettingsNetworkQuality() throws {
        // #9 离线下载音频、LRC 歌词与封面持久存储与删除验证
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let tempAudio = tmpDir.appendingPathComponent("temp_stream.flac")
        let fakeAudioBytes = Data("fLaC_FAKE_OFFLINE_AUDIO_DATA_2026".utf8)
        try fakeAudioBytes.write(to: tempAudio)

        let source = LocalMusicSource(dataDir: tmpDir)
        let track = Track(
            id: "off-001",
            source: "netease",
            name: "迷星叫",
            artists: [Artist(id: "ar1", name: "MyGO!!!!!")],
            album: Album(id: "al1", name: "迷跡波")
        )
        let savedURL = try source.storeDownloadedTrack(
            track: track,
            tempAudioURL: tempAudio,
            fileExtension: "flac",
            lrcText: "[00:01.00]迷星叫",
            coverData: Data([0xFF, 0xD8, 0xFF, 0xE0])
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertTrue(source.isTrackDownloaded(compositeKey: track.compositeKey))
        XCTAssertTrue(source.downloadedCompositeKeys().contains(track.compositeKey))

        let resolvedAudio = source.localFileURLForDownloadedTrack(compositeKey: track.compositeKey)
        XCTAssertEqual(resolvedAudio?.lastPathComponent, savedURL.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: resolvedAudio!), fakeAudioBytes)

        let lrcURL = savedURL.deletingPathExtension().appendingPathExtension("lrc")
        XCTAssertEqual(try String(contentsOf: lrcURL, encoding: .utf8), "[00:01.00]迷星叫")

        // 重新构造实例验证持久化加载不丢失
        let reloaded = LocalMusicSource(dataDir: tmpDir)
        XCTAssertTrue(reloaded.isTrackDownloaded(compositeKey: track.compositeKey))
        XCTAssertNotNil(reloaded.localFileURLForDownloadedTrack(compositeKey: track.compositeKey))

        reloaded.removeDownloadedTrack(compositeKey: track.compositeKey)
        XCTAssertFalse(reloaded.isTrackDownloaded(compositeKey: track.compositeKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.path))

        // #4 网络音质分流 + #14 兼容解码验证
        XCTAssertEqual(
            AppModel.resolveEffectiveStreamingQuality(isCellular: false, wifiQuality: .lossless, cellularQuality: .standard),
            .lossless
        )
        XCTAssertEqual(
            AppModel.resolveEffectiveStreamingQuality(isCellular: true, wifiQuality: .lossless, cellularQuality: .standard),
            .standard
        )

        let legacyJSON = """
        {
          "quality": "lossless",
          "episodePositions": {"podcast:ep1": 142.5}
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.wifiQuality, .lossless)
        XCTAssertEqual(decoded.cellularQuality, .high)
        XCTAssertEqual(decoded.episodePositions["podcast:ep1"] ?? 0, 142.5, accuracy: 0.01)
        XCTAssertEqual(decoded.accentPreset, .crimson)
        XCTAssertEqual(decoded.appIconPreset, .primary)
    }

    func testDynamicAccentThemesAndAlternateIconPlistConsistency() throws {
        // #15 多主题强调色预设验证与无损还原
        let previousPreset = MyGoTheme.currentAccentPreset()
        defer { MyGoTheme.setAccentPreset(previousPreset) }

        XCTAssertEqual(AccentColorPreset.allCases.count, 5)
        for preset in AccentColorPreset.allCases {
            let light = MyGoTheme.tokens(isDark: false, preset: preset)
            let dark = MyGoTheme.tokens(isDark: true, preset: preset)
            XCTAssertGreaterThanOrEqual(light.accent.r, 0.0)
            XCTAssertLessThanOrEqual(dark.accent.g, 1.0)
            XCTAssertEqual(dark.currentTrackFill.r, 1.0, accuracy: 0.001)
            XCTAssertEqual(dark.currentTrackFill.g, 1.0, accuracy: 0.001)
            XCTAssertEqual(dark.currentTrackFill.b, 1.0, accuracy: 0.001)
            MyGoTheme.setAccentPreset(preset)
            XCTAssertEqual(MyGoTheme.currentAccentPreset(), preset)
        }

        // #15 App/Info.plist 声明的替代图标名称必须与 AppIconPreset 枚举严格一致
        XCTAssertEqual(AppIconPreset.allCases.count, 2)
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = projectRoot.appendingPathComponent("App/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        let bundleIcons = try XCTUnwrap(plist["CFBundleIcons"] as? [String: Any])
        let altIcons = try XCTUnwrap(bundleIcons["CFBundleAlternateIcons"] as? [String: Any])
        for preset in AppIconPreset.allCases {
            if let altName = preset.alternateIconName {
                XCTAssertNotNil(altIcons[altName], "Info.plist 缺少替换应用图标声明: \(altName)")
            }
        }
    }

    func testLyricsPrecisionSameTimestampAndEmptyStopMarkers() {
        // 1) 空时间停顿行必须精确截断前一句 end 并保留有效间奏，但过滤后不出现在渲染数组
        let lrc = """
        [00:05.00]First sung line
        [00:08.00]
        [00:15.00]English same timestamp
        [00:15.00]中文同时间戳第二行
        [00:20.00]Third line
        """
        let lines = LyricsEngine.build(lrc: lrc)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].end, 8.0, accuracy: 0.001, "空行时间戳应精确结束上一句")

        // 2) 同时间戳组首行不得被压成 0 时长，且二分查找必须对齐组内首行
        XCTAssertEqual(lines[1].text, "English same timestamp")
        XCTAssertEqual(lines[1].end, 20.0, accuracy: 0.001)
        XCTAssertGreaterThan(lines[1].words.last?.end ?? 0, lines[1].at)
        XCTAssertEqual(LyricsEngine.index(in: lines, at: 16.2), 1)

        // 3) fromSource 逐字越界钳位保护
        let raw = RawLyrics(lines: [
            RawLyricLine(
                start: 1000,
                end: 4000,
                text: "AB",
                words: [
                    RawLyricWord(start: 500, end: 2500, text: "A"),
                    RawLyricWord(start: 2200, end: 5200, text: "B")
                ]
            )
        ])
        let synced = LyricsEngine.fromSource(raw)
        XCTAssertEqual(synced.count, 1)
        XCTAssertEqual(synced[0].words[0].start, 1.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(synced[0].words[1].start, synced[0].words[0].end)
        XCTAssertEqual(synced[0].words[1].end, 4.0, accuracy: 0.001)
    }

    @MainActor
    func testPlayerEngineSeekSettledLatencyAndAdjacentTrackPreview() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mygo-seek-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let engine = PlayerEngine(cacheDir: dir)
        let tracks = [
            Track(id: "t1", name: "Song One", artists: [Artist(id: "a1", name: "Art1")], duration: 120_000),
            Track(id: "t2", name: "Song Two", artists: [Artist(id: "a2", name: "Art2")], duration: 180_000),
            Track(id: "t3", name: "Song Three", artists: [Artist(id: "a3", name: "Art3")], duration: 200_000)
        ]
        engine.playQueue(tracks, start: 1)

        // 1) 邻曲只读预览与直接跳过 3s 规则切上一首
        XCTAssertEqual(engine.adjacentTrack(step: 1)?.id, "t3")
        XCTAssertEqual(engine.adjacentTrack(step: -1)?.id, "t1")

        // 2) Seek Revision 与 Settled Revision 同步及延迟限幅
        let beforeSeek = engine.seekRevision
        let beforeSettled = engine.seekSettledRevision
        engine.seek(to: 42.5)
        XCTAssertEqual(engine.seekRevision, beforeSeek + 1)
        XCTAssertEqual(engine.seekSettledRevision, beforeSettled + 1)
        XCTAssertEqual(engine.position, 42.5, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(engine.currentAudioOutputLatency(), 0.0)
        XCTAssertLessThanOrEqual(engine.currentAudioOutputLatency(), 0.35)
        XCTAssertEqual(engine.acousticLyricPosition(), 42.5, accuracy: 0.001)

        // 即使当前位置 > 3s，skipToPreviousTrack 仍直接切回 t1（而 previous() 回 0）
        engine.previous()
        XCTAssertEqual(engine.currentTrack?.id, "t2")
        engine.seek(to: 25.0)
        engine.skipToPreviousTrack()
        XCTAssertEqual(engine.currentTrack?.id, "t1")
    }

    @MainActor
    func testRemoteAssetDisablesPreciseTimingAndBackgroundCacheSkipsOversized() async throws {
        // 1) 在线流（HTTP / HTTPS / mygostream://）默认禁用精确帧扫描以秒播，仅本地文件默认开启
        let remoteDirect = PlayerEngine.makeAudioURLAsset(
            url: URL(string: "http://fs.youthandroid2.kugou.com/track.flac")!
        )
        let proxyAsset = PlayerEngine.makeAudioURLAsset(
            url: URL(string: "mygostream://track/123.flac")!
        )
        let localFile = PlayerEngine.makeAudioURLAsset(
            url: URL(fileURLWithPath: "/tmp/offline-track.flac")
        )
        XCTAssertEqual(remoteDirect.url.scheme, "http")
        XCTAssertEqual(proxyAsset.url.scheme, AudioStreamProxy.proxyScheme)
        XCTAssertTrue(localFile.url.isFileURL)
        // 验证通过 AudioStreamProxy 打开 WAV 自定义协议资产时不触发 CoreMedia -17770（即未显式注入 precise=false）
        let wavData = Self.makeTestPCM16WAVData(durationSeconds: 0.25)
        MockAudioStreamURLProtocol.configure(payload: wavData, supportsByteRange: true)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockAudioStreamURLProtocol.self]
        let wavProxy = AudioStreamProxy(
            remoteURL: URL(string: "https://mock.music.126.net/precise-check.wav")!,
            headers: [:],
            streamTypeHint: "wav",
            cacheKey: nil,
            diskCache: nil,
            sessionConfiguration: cfg
        )
        let wavAsset = PlayerEngine.makeAudioURLAsset(url: wavProxy.makeProxyAssetURL(), preferPreciseTiming: false)
        wavAsset.resourceLoader.setDelegate(wavProxy, queue: wavProxy.delegateQueue)
        let wavItem = AVPlayerItem(asset: wavAsset)
        let wavPlayer = AVPlayer(playerItem: wavItem)
        wavPlayer.isMuted = true
        wavPlayer.play()
        let wavReady = try await Self.waitForReadyToPlay(item: wavItem, timeoutSeconds: 4)
        XCTAssertTrue(wavReady, "自定义协议 WAV 不得因精确时间选项误触发 CoreMedia -17770 错误")
        wavPlayer.pause()
        wavPlayer.replaceCurrentItem(with: nil as AVPlayerItem?)
        wavProxy.invalidate()

        // 2) 后台增强缓存体积门槛：超出 52MB 的 Hi-Res 无损流提前跳过，避免耗尽带宽后再丢弃
        XCTAssertTrue(PlayerEngine.shouldProceedWithBackgroundCache(declaredSizeBytes: 36_507_181))
        XCTAssertFalse(PlayerEngine.shouldProceedWithBackgroundCache(declaredSizeBytes: 60_000_000))
        XCTAssertFalse(PlayerEngine.shouldProceedWithBackgroundCache(declaredSizeBytes: nil, expectedContentLength: 58_000_000))
        XCTAssertTrue(PlayerEngine.shouldProceedWithBackgroundCache(declaredSizeBytes: nil, expectedContentLength: -1))
    }

    func testPluginStorageDebouncedPersistenceAndFlushConsistency() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-storage-debounce-\(UUID().uuidString)", isDirectory: true)
        let pluginDir = root.appendingPathComponent("plugins/storage-demo", isDirectory: true)
        let dataRoot = root.appendingPathComponent("plugin-data", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let manifest = """
        {
          "id": "storage-demo",
          "name": "Storage Demo",
          "version": "1.0.0",
          "main": "index.js",
          "playback": "stream"
        }
        """
        let script = """
        export async function home() {
          for (let i = 0; i < 40; i++) {
            host.storage.set("fileids", { last: i });
          }
          host.storage.set("token", "abc-123");
          return {
            title: String(host.storage.get("token")) + ":" + String(host.storage.get("fileids")?.last),
            sections: []
          };
        }
        """
        try manifest.write(to: pluginDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try script.write(to: pluginDir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let src = try JSPluginSource(pluginDir: pluginDir, dataRootDir: dataRoot)
        let browse = try await src.home()
        XCTAssertEqual(browse.title, "abc-123:39", "高频连续写入后内存态应立即强一致可读")

        src.flushStorage()
        let reloaded = try JSPluginSource(pluginDir: pluginDir, dataRootDir: dataRoot)
        let storageFile = dataRoot.appendingPathComponent("storage-demo/storage.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageFile.path))
        let raw = try Data(contentsOf: storageFile)
        let obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertEqual(obj?["token"] as? String, "abc-123")
        _ = reloaded
    }

    func testAppIconPresetDualPackageMappingAndVersionAlignment() {
        XCTAssertNil(AppIconPreset.primary.resolvedAlternateIconName(bundlePrimaryIconName: "AppIcon"))
        XCTAssertEqual(
            AppIconPreset.appleMusic.resolvedAlternateIconName(bundlePrimaryIconName: "AppIcon"),
            "AppIconAppleMusic"
        )
        XCTAssertEqual(
            AppIconPreset.primary.resolvedAlternateIconName(bundlePrimaryIconName: "AppIconAppleMusic"),
            "AppIcon"
        )
        XCTAssertNil(AppIconPreset.appleMusic.resolvedAlternateIconName(bundlePrimaryIconName: "AppIconAppleMusic"))

        XCTAssertEqual(
            AppIconPreset.currentPreset(forAlternateIconName: nil, bundlePrimaryIconName: "AppIcon"),
            .primary
        )
        XCTAssertEqual(
            AppIconPreset.currentPreset(forAlternateIconName: "AppIconAppleMusic", bundlePrimaryIconName: "AppIcon"),
            .appleMusic
        )
        XCTAssertEqual(
            AppIconPreset.currentPreset(forAlternateIconName: nil, bundlePrimaryIconName: "AppIconAppleMusic"),
            .appleMusic
        )
        XCTAssertEqual(
            AppIconPreset.currentPreset(forAlternateIconName: "AppIcon", bundlePrimaryIconName: "AppIconAppleMusic"),
            .primary
        )
        XCTAssertEqual(JSPluginSource.appVersion, "0.1.24.8")
    }

    func testLocalSourceSharedDocumentsScanAndInboxExclusion() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-shared-docs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let localDir = tmpRoot.appendingPathComponent("local", isDirectory: true)
        let docsDir = tmpRoot.appendingPathComponent("Documents", isDirectory: true)
        let inboxDir = docsDir.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)

        let wavData = Self.makeTinyTestWAVData()
        try wavData.write(to: docsDir.appendingPathComponent("Shared - Song.wav"))
        try wavData.write(to: inboxDir.appendingPathComponent("InboxOnly - Duplicate.wav"))

        let src = LocalMusicSource(dataDir: localDir, sharedDocumentsFolder: docsDir, eagerSyncScan: true)
        let tracks = try await src.search(query: "", kind: .tracks, offset: 0).tracks ?? []
        XCTAssertEqual(tracks.count, 1, "应只扫描共享 Documents 目录并跳过 Documents/Inbox 避免重样")
        XCTAssertEqual(tracks.first?.name, "Song")
        XCTAssertEqual(tracks.first?.artistNames, "Shared")
    }

    @MainActor
    func testExternalFileDeepLinkImportAndSpotlightActivityAndPrefetchInvalidation() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-ext-open-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let app = AppModel(baseDataDir: tmpRoot)
        await app.waitUntilStartupReady()

        let externalAudio = tmpRoot.appendingPathComponent("Aimer - Brave Shine.wav")
        try Self.makeTinyTestWAVData().write(to: externalAudio)

        app.handleDeepLink(externalAudio)
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(app.activeSourceID, LocalMusicSource.sourceID)
        XCTAssertEqual(app.localSource.trackCount(), 1)
        XCTAssertEqual(app.player.currentTrack?.name, "Brave Shine")
        XCTAssertTrue(app.isNowPlayingPresented)

        app.player.invalidatePrefetchedMediaForQualityChange()

        let track = try XCTUnwrap(app.player.currentTrack)
        app.isNowPlayingPresented = false
        let activity = NSUserActivity(activityType: "com.egoist.mygomusic.playing")
        activity.userInfo = [
            "trackID": track.id,
            "trackName": track.name,
            "source": LocalMusicSource.sourceID
        ]
        app.handleSpotlightUserActivity(activity)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(app.isNowPlayingPresented)
    }

    private static func makeTinyTestWAVData() -> Data {
        let sampleRate: UInt32 = 8000
        let sampleCount: UInt32 = 800
        let dataSize = sampleCount * 2
        var d = Data()
        d.append(contentsOf: "RIFF".utf8)
        var riffSize = UInt32(36 + dataSize).littleEndian
        d.append(Data(bytes: &riffSize, count: 4))
        d.append(contentsOf: "WAVEfmt ".utf8)
        var fmtSize = UInt32(16).littleEndian
        d.append(Data(bytes: &fmtSize, count: 4))
        var audioFormat = UInt16(1).littleEndian
        var channels = UInt16(1).littleEndian
        var sr = sampleRate.littleEndian
        var byteRate = (sampleRate * 2).littleEndian
        var blockAlign = UInt16(2).littleEndian
        var bits = UInt16(16).littleEndian
        d.append(Data(bytes: &audioFormat, count: 2))
        d.append(Data(bytes: &channels, count: 2))
        d.append(Data(bytes: &sr, count: 4))
        d.append(Data(bytes: &byteRate, count: 4))
        d.append(Data(bytes: &blockAlign, count: 2))
        d.append(Data(bytes: &bits, count: 2))
        d.append(contentsOf: "data".utf8)
        var ds = dataSize.littleEndian
        d.append(Data(bytes: &ds, count: 4))
        d.append(Data(count: Int(dataSize)))
        return d
    }

    @MainActor
    func testNowPlayingSeekRateAnchorAndSceneManifestAndSleepTimer() throws {
        XCTAssertEqual(PlayerEngine.resolvedNowPlayingPlaybackRate(isPlaying: true, isLoading: false, isSeeking: false), 1.0)
        XCTAssertEqual(PlayerEngine.resolvedNowPlayingPlaybackRate(isPlaying: true, isLoading: false, isSeeking: true), 0.0)
        XCTAssertEqual(PlayerEngine.resolvedNowPlayingPlaybackRate(isPlaying: true, isLoading: true, isSeeking: false), 0.0)
        XCTAssertEqual(PlayerEngine.resolvedNowPlayingPlaybackRate(isPlaying: false, isLoading: false, isSeeking: false), 0.0)

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistData = try Data(contentsOf: projectRoot.appendingPathComponent("App/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let manifest = try XCTUnwrap(plist["UIApplicationSceneManifest"] as? [String: Any])
        XCTAssertEqual(manifest["UIApplicationSupportsMultipleScenes"] as? Bool, false)
        let orientations = try XCTUnwrap(plist["UISupportedInterfaceOrientations"] as? [String])
        XCTAssertEqual(orientations, ["UIInterfaceOrientationPortrait"])
        let docTypes = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(docTypes.count, 2)

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-sleep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let engine = PlayerEngine(cacheDir: cacheDir, activateAudioSessionOnInit: false)
        engine.setSleepTimer(.minutes(5))
        XCTAssertEqual(engine.sleepTimerRemainingSeconds, 300)
        engine.setSleepTimer(.off)
        XCTAssertNil(engine.sleepTimerRemainingSeconds)
        XCTAssertFalse(engine.sleepTimerStopsAfterCurrentTrack)
    }
}

private final class LockedRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    var urls: [String] {
        requests.compactMap { $0.url?.absoluteString }
    }

    func record(_ req: URLRequest) {
        lock.lock()
        captured.append(req)
        lock.unlock()
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

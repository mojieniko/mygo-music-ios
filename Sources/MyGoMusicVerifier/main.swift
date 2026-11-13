// main.swift
// MyGo Music iOS 版自检测试运行器（支持在无完整 Xcode.app 仅有 CommandLineTools 的环境下直接运行全套验证）

import AVFoundation
import Compression
import Foundation
import MyGoMusicCore
import MyGoMusicUI

private func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) throws {
    if a != b {
        throw NSError(domain: "MyGoMusicVerifier", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "断言失败 (\(file):\(line)): 期望 \(b)，实际 \(a). \(message)"
        ])
    }
}

private func assertTrue(_ cond: Bool, _ message: String = "", file: String = #file, line: Int = #line) throws {
    if !cond {
        throw NSError(domain: "MyGoMusicVerifier", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "断言失败 (\(file):\(line)): 条件不为 true. \(message)"
        ])
    }
}

@main
struct MyGoMusicVerifier {
    static func main() async {
        do {
            print("▶ [1/8] 验证 LyricsEngine（LRC多时间戳解析、翻译对齐、逐字均摊、演职员表与间奏检测）...")
            try verifyLyricsEngine()
            print("  ✓ LyricsEngine 通过")

            print("▶ [2/8] 验证 JavaScriptCore 插件引擎（基础夹具 + B 站/网易云多文件 TS、AbortController、setTimeout、getSetCookie、minAppVersion）...")
            try await verifyPluginRuntime()
            print("  ✓ JavaScriptCore 插件引擎与生态适配 通过")

            print("▶ [3/8] 验证 PluginCrypto（MD5、AES-128-ECB）、网络权限通配符与 Go 风格宽容模型解码...")
            try verifyPluginCryptoAndModels()
            print("  ✓ PluginCrypto、权限检查与宽容解码 通过")

            print("▶ [4/8] 验证 PluginInstaller（流式 ZIP Deflate/__MACOSX 解压/仓库解析）与 LocalMusicSource（GB18030/.ogg过滤）...")
            try await verifyInstallerAndLocalSource()
            print("  ✓ PluginInstaller 与 LocalMusicSource 通过")

            print("▶ [5/8] 验证 StageMath Folia 律动舞台物理与分行算法（流光、云阶、倾诉、火花）...")
            try verifyStageMath()
            print("  ✓ StageMath 律动舞台算法 通过")

            print("▶ [6/8] 验证 AudioDiskCache（limitMB=0 禁用、LRU 磁盘容量淘汰与清空）...")
            try verifyAudioDiskCacheLRU()
            print("  ✓ AudioDiskCache LRU 缓存淘汰 通过")

            print("▶ [7/8] 验证 AudioStreamProxy 音频格式 UTType 识别（.m4s/mp4/flac/mp3）...")
            try verifyStreamUTTypeMapping()
            print("  ✓ AudioStreamProxy 音频格式识别 通过")

            print("▶ [8/8] 验证 SourceInfo 自定义导航标题与图标扩展...")
            try verifySourceNavigationCustomization()
            print("  ✓ SourceInfo 自定义导航扩展 通过")

            print("\n🎉 所有 8 组核心测试套件全部通过！")
        } catch {
            fputs("❌ 测试失败: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func verifyLyricsEngine() throws {
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
        try assertEqual(lines.count, 4)
        try assertTrue(LyricsEngine.isCredit(lines[0].text))
        try assertEqual(lines[1].text, "Hello 世界")
        try assertEqual(lines[1].translation, "你好世界")
        try assertEqual(lines[1].words.map(\.text), ["Hello ", "世", "界"])

        try assertEqual(LyricsEngine.index(in: lines, at: 0.5), 0)
        try assertEqual(LyricsEngine.index(in: lines, at: 2.0), 1)
        try assertEqual(LyricsEngine.index(in: lines, at: 5.0), 2)
        try assertEqual(LyricsEngine.index(in: lines, at: 11.0), 3)

        let quiets = LyricsEngine.quiets(in: lines, trackLength: 20.0, least: 2.0)
        try assertTrue(!quiets.isEmpty)
        try assertEqual(quiets.last?.from, 16.0)
        try assertEqual(quiets.last?.to, 20.0)

        // 验证锁屏媒体栏实时歌词元数据结构生成
        let track = Track(
            id: "tr-lyric",
            name: "春日影",
            artists: [Artist(id: "a1", name: "MyGO!!!!!")],
            album: Album(id: "al1", name: "迷星叫")
        )
        let metaDisabled = PlayerEngine.buildNowPlayingDisplayMetadata(
            track: track,
            lyrics: lines,
            position: 2.0,
            lockScreenLyricsEnabled: false
        )
        try assertEqual(metaDisabled.title, "春日影")
        try assertEqual(metaDisabled.artist, "MyGO!!!!!")
        try assertTrue(metaDisabled.lyricIndex == nil)

        let metaActive = PlayerEngine.buildNowPlayingDisplayMetadata(
            track: track,
            lyrics: lines,
            position: 2.0,
            lockScreenLyricsEnabled: true
        )
        try assertEqual(metaActive.title, "Hello 世界")
        try assertEqual(metaActive.artist, "你好世界 · 春日影")
        try assertEqual(metaActive.lyricIndex, 1)
    }

    static func verifyPluginRuntime() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mygo-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let pluginsDir = tmpRoot.appendingPathComponent("plugins", isDirectory: true)
        let dataDir = tmpRoot.appendingPathComponent("plugin-data", isDirectory: true)
        let pluginDir = pluginsDir.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifest = ["id": "fixture", "name": "Fixture", "main": "index.js", "playback": "stream"]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try manifestData.write(to: pluginDir.appendingPathComponent("plugin.json"))
        let pluginSource = #"""
        const track = { id: "track-1", name: "Fixture Song", duration: 120000,
          artists: [{ id: "artist-1", name: "Fixture Artist" }],
          album: { id: "album-1", name: "Fixture Album" } };
        export function home() { return { title: "Fixture Home", sections: [{ title: "Fixture", tracks: [track] }] }; }
        export function search(args) { return { tracks: args.query ? [track] : [] }; }
        export function lyrics() { return { lrc: "[00:01.00]Fixture lyric" }; }
        export function stream() { return { url: "https://example.com/fixture.mp3", type: "mp3" }; }
        """#
        try pluginSource.write(to: pluginDir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let discovered = PluginInstaller.discover(pluginsDir: pluginsDir, dataRootDir: dataDir)
        try assertEqual(discovered.count, 1)

        let plugin = discovered[0]
        try assertEqual(plugin.manifest.id, "fixture")
        try assertTrue(plugin.can("home"))
        try assertTrue(plugin.can("search"))
        let home = try await plugin.home()
        try assertEqual(home.title, "Fixture Home")
        try assertEqual(home.sections?.first?.tracks?.first?.source, "fixture")
        let result = try await plugin.search(query: "Fixture", kind: .tracks, offset: 0)
        try assertEqual(result.tracks?.first?.name, "Fixture Song")
        let lyrics = try await plugin.lyrics(id: "track-1")
        try assertEqual(LyricsEngine.fromSource(lyrics).first?.text, "Fixture lyric")
        let stream = try await plugin.stream(id: "track-1", quality: "high")
        try assertEqual(stream.type, "mp3")

        // 2. 验证 B 站/网易云风格：多文件 TS 模块导入 + 类型剥离 + export { a as b } + AbortController + setTimeout/clearTimeout + getSetCookie + host.crypto
        let biliDir = pluginsDir.appendingPathComponent("bili-netease-sim", isDirectory: true)
        let libDir = biliDir.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)

        let simManifest: [String: Any] = [
            "id": "bili-sim",
            "name": "Bili & NetEase Sim",
            "version": "1.2.3",
            "minAppVersion": "0.1.21",
            "main": "index.ts",
            "playback": "stream",
            "permissions": [
                "network": ["*.bilibili.com", "*.music.163.com"],
                "process": ["ffmpeg"]
            ],
            "requestHeaders": [[
                "hosts": ["*.bilivideo.com"],
                "kinds": ["audio"],
                "headers": [
                    "X-Num": "{storage:num}",
                    "X-Flag": "{storage:flag}"
                ]
            ]],
            "settings": [
                ["key": "cookie", "label": "Cookie", "type": "password"],
                ["key": "lossless", "label": "Lossless", "type": "boolean"],
                ["key": "quality", "label": "Quality", "type": "select", "options": [["value": "flac", "label": "FLAC"], ["value": "320", "label": "320k"]]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: simManifest, options: [.prettyPrinted])
            .write(to: biliDir.appendingPathComponent("plugin.json"))

        let helperTS = #"""
        export interface WbiParams { bvid: string; cid: number; }
        export type SignResult = string;
        export function signWbi(params: WbiParams): SignResult {
            return host.crypto.md5(params.bvid + ":" + String(params.cid));
        }
        export function checkCookieSplit(): string[] {
            const h = new Headers([
                ["set-cookie", "MUSIC_U=token_val; Expires=Thu, 01 Jan 2099 00:00:00 GMT; Path=/"],
                ["set-cookie", "__csrf=csrf_val; Path=/"]
            ]);
            return h.getSetCookie();
        }
        """#
        try helperTS.write(to: libDir.appendingPathComponent("helper.ts"), atomically: true, encoding: .utf8)

        let entryTS = #"""
        import { signWbi, checkCookieSplit } from "./lib/helper.ts";

        interface InternalTrack { id: string; name: string; }

        async function loadHome(): Promise<any> {
            const ctrl = new AbortController();
            let abortedTriggered = false;
            ctrl.signal.addEventListener("abort", () => { abortedTriggered = true; });
            ctrl.abort("manual-cancel");
            if (!ctrl.signal.aborted || !abortedTriggered) {
                throw new Error("AbortController failed");
            }

            let cancelledTimerRan = false;
            const badTimer = setTimeout(() => { cancelledTimerRan = true; }, 5);
            clearTimeout(badTimer);

            const timerMsg = await new Promise<string>((resolve) => {
                setTimeout(() => resolve("timer-ok"), 25);
            });
            if (cancelledTimerRan) {
                throw new Error("clearTimeout did not cancel timer");
            }

            const cookies = checkCookieSplit();
            if (cookies.length !== 2 || !cookies[0].includes("MUSIC_U=token_val") || !cookies[1].includes("__csrf=csrf_val")) {
                throw new Error("getSetCookie split mismatch: " + JSON.stringify(cookies));
            }

            const sig = signWbi({ bvid: "BV1xx", cid: 9527 });
            const enc = host.crypto.aesEcbEncrypt("0123456789abcdef", "netease");
            host.storage.set("num", 123);
            host.storage.set("flag", true);
            if (host.storage.get("num") !== 123 || host.storage.get("flag") !== true) {
                throw new Error("storage primitive roundtrip failed");
            }
            const t: InternalTrack = { id: "BV1xx:9527", name: sig + "|" + enc + "|" + timerMsg };
            return {
                title: "Sim Home",
                sections: [{
                    title: "Featured",
                    tracks: [{ id: t.id, name: t.name, duration: 180000, artists: [{ id: "up1", name: "UP" }], album: { id: "a1", name: "Col" } }]
                }]
            };
        }

        function resolveStream(args: { id: string; quality: string }): any {
            return {
                url: "https://upos-sz-mirror.bilivideo.com/upgcxcode/95/27/video.m4s?e=123",
                type: "m4s",
                headers: { "Referer": "https://www.bilibili.com" }
            };
        }

        export { loadHome as home, resolveStream as stream };
        """#
        try entryTS.write(to: biliDir.appendingPathComponent("index.ts"), atomically: true, encoding: .utf8)

        // 3. 放入一个要求 minAppVersion 过高（99.0.0）的插件，验证 discoverDetailed 拦截并返回失败原因
        let incompatibleDir = pluginsDir.appendingPathComponent("too-new", isDirectory: true)
        try FileManager.default.createDirectory(at: incompatibleDir, withIntermediateDirectories: true)
        let incompatibleManifest: [String: Any] = [
            "id": "too-new",
            "name": "Future Plugin",
            "minAppVersion": "99.0.0",
            "main": "index.js"
        ]
        try JSONSerialization.data(withJSONObject: incompatibleManifest, options: [.prettyPrinted])
            .write(to: incompatibleDir.appendingPathComponent("plugin.json"))
        try "export function home() { return {}; }".write(to: incompatibleDir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let detailed = PluginInstaller.discoverDetailed(pluginsDir: pluginsDir, dataRootDir: dataDir)
        try assertEqual(detailed.plugins.count, 2)
        try assertEqual(detailed.failures.count, 1)
        try assertEqual(detailed.failures.first?.folderName, "too-new")

        guard let biliPlugin = detailed.plugins.first(where: { $0.manifest.id == "bili-sim" }) else {
            throw NSError(domain: "MyGoMusicVerifier", code: 2, userInfo: [NSLocalizedDescriptionKey: "未加载 bili-sim 插件"])
        }
        try assertTrue(biliPlugin.can("home"))
        try assertTrue(biliPlugin.can("stream"))
        try assertEqual(biliPlugin.info().settings?.count, 3)
        try assertEqual(biliPlugin.info().settings?[2].options?.count, 2)

        let simHome = try await biliPlugin.home()
        let firstTitle = simHome.sections?.first?.tracks?.first?.name ?? ""
        try assertTrue(firstTitle.hasSuffix("|timer-ok"), "预期定时器与多文件 TS 打包输出后缀为 |timer-ok，实际 \(firstTitle)")

        let m4sStream = try await biliPlugin.stream(id: "BV1xx:9527", quality: "high")
        try assertEqual(m4sStream.type, "m4s")
        try assertEqual(m4sStream.headers?["Referer"], "https://www.bilibili.com")

        try biliPlugin.setSetting("quality", value: "flac")
        try assertEqual(biliPlugin.setting("quality"), "flac")

        // 验证进程权限持久化（此前顶层 Bool 写入曾引发 NSInvalidArgumentException 闪退）
        try assertTrue(biliPlugin.hasProcessPermissionDeclaration)
        try assertEqual(biliPlugin.isProcessGranted(), false)
        try biliPlugin.setProcessGranted(true)
        try assertEqual(biliPlugin.isProcessGranted(), true)

        let reloadedBili = try JSPluginSource(pluginDir: biliDir, dataRootDir: dataDir)
        try assertEqual(reloadedBili.isProcessGranted(), true)

        // 验证顶层基础类型 storage 占位符插值与非法 JSON 值安全防护
        let reqHeaders = biliPlugin.headersFor(url: URL(string: "https://upos.bilivideo.com/test.m4s")!, kind: "audio")
        try assertEqual(reqHeaders?["X-Num"], "123")
        try assertEqual(reqHeaders?["X-Flag"], "true")
        try assertTrue(JSPluginSource.encodeAnyJSON(Double.nan) == nil, "非有限浮点数不应导致原生异常崩溃")
    }

    static func verifyPluginCryptoAndModels() throws {
        try assertEqual(PluginCrypto.md5Hex("mygo-music"), "acb1fe17e40ab3ed67c6254f7aa15ab2")
        let encryptedHex = try PluginCrypto.aesEcbEncryptHex(key: "0123456789abcdef", text: "hello mygo")
        try assertEqual(encryptedHex.count, 32)

        let perms = PluginPermissions(network: ["api.example.com", "*.music.163.com"])
        try assertTrue(perms.reaches(host: "api.example.com"))
        try assertTrue(perms.reaches(host: "interface.music.163.com"))
        try assertTrue(!perms.reaches(host: "evil.com"))

        // 验证合并 Set-Cookie 字符串拆分不会在 Expires 日期逗号处误切
        let splitCookies = PluginHTTPUtilities.splitSetCookieHeader(
            "MUSIC_U=abc123; Expires=Thu, 01 Jan 2099 00:00:00 GMT; Path=/; HttpOnly, __csrf=xyz; Expires=Fri, 02 Jan 2099 00:00:00 GMT; Path=/"
        )
        try assertEqual(splitCookies.count, 2)
        try assertTrue(splitCookies[0].contains("MUSIC_U=abc123"))
        try assertTrue(splitCookies[1].contains("__csrf=xyz"))

        // Go 风格宽容 JSON 解码（数字 ID 转字符串、more 宽容布尔、v0.1.23 设置字段）
        let lossyTrackJSON = #"{"id": 987654, "name": "NumID Track", "duration": 201500, "album": {"id": 11, "name": "Alb"}, "artists": [{"id": 22, "name": "Art"}]}"#
        let decodedTrack = try JSONDecoder().decode(Track.self, from: Data(lossyTrackJSON.utf8))
        try assertEqual(decodedTrack.id, "987654")
        try assertEqual(decodedTrack.album.id, "11")
        try assertEqual(decodedTrack.artists?.first?.id, "22")

        let lossyCommentJSON = #"{"id": 555, "author": "UserA", "avatarUrl": "https://img.example/a.png", "text": "Nice!", "time": 1700000000000, "likes": 42, "liked": 1}"#
        let decodedComment = try JSONDecoder().decode(Comment.self, from: Data(lossyCommentJSON.utf8))
        try assertEqual(decodedComment.id, "555")
        try assertEqual(decodedComment.liked, true)
        try assertEqual(decodedComment.avatarUrl, "https://img.example/a.png")

        let lossyPageJSON = #"{"tracks": [], "more": "true"}"#
        let decodedPage = try JSONDecoder().decode(TrackPage.self, from: Data(lossyPageJSON.utf8))
        try assertEqual(decodedPage.more, true)
    }

    static func verifyInstallerAndLocalSource() async throws {
        try assertEqual(try PluginInstaller.parseRepo("egoist/mygo-music"), "egoist/mygo-music")
        try assertEqual(try PluginInstaller.parseRepo("https://github.com/egoist/mygo-music-youtube-music/tree/main"), "egoist/mygo-music-youtube-music")
        try assertEqual(try PluginInstaller.parseRepo("git@github.com:AkinoKaede/mygo-music-netease-cloud-music.git"), "AkinoKaede/mygo-music-netease-cloud-music")
        try assertTrue(PluginInstaller.isNewerVersion("0.2.0", than: "0.1.20"))
        try assertTrue(!PluginInstaller.isNewerVersion("0.1.8", than: "0.1.20"))

        // 验证 compression_stream 流式 ZIP Deflate 解压 + __MACOSX 跳过 + 深层根目录穿透
        let zipWorkDir = FileManager.default.temporaryDirectory.appendingPathComponent("mygo-zip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: zipWorkDir) }
        try FileManager.default.createDirectory(at: zipWorkDir, withIntermediateDirectories: true)

        let zipURL = zipWorkDir.appendingPathComponent("nested-plugin.zip")
        let manifestJSON = """
        {
          "id": "zip-plugin",
          "name": "Zip Deflate Plugin",
          "version": "0.1.0",
          "main": "index.js",
          "playback": "stream"
        }
        """
        let repeatedComment = String(repeating: "// deflate compression buffer padding for realistic archive size\n", count: 8)
        let zipPluginJS = repeatedComment + "\nexport function home() { return { title: 'From Deflate Zip', sections: [] }; }\n"
        try writeDeflateZip(
            entries: [
                ("__MACOSX/._plugin.json", Data("mac-metadata-junk".utf8)),
                ("repo-main/plugin/plugin.json", Data(manifestJSON.utf8)),
                ("repo-main/plugin/index.js", Data(zipPluginJS.utf8))
            ],
            to: zipURL
        )
        let pendingFromZip = try PluginInstaller.openFromLocal(zipURL)
        defer { try? FileManager.default.removeItem(at: pendingFromZip.sourcePath) }
        try assertEqual(pendingFromZip.manifest.id, "zip-plugin")
        let zipInstallPluginsDir = zipWorkDir.appendingPathComponent("installed-plugins", isDirectory: true)
        let zipInstallDataDir = zipWorkDir.appendingPathComponent("installed-data", isDirectory: true)
        let installedZipPlugin = try PluginInstaller.install(pendingFromZip, into: zipInstallPluginsDir, dataRootDir: zipInstallDataDir)
        let zipHome = try await installedZipPlugin.home()
        try assertEqual(zipHome.title, "From Deflate Zip")

        // 验证本地编码识别与扫描（UTF-8 BOM / GB18030 + 过滤不支持的 .ogg）
        let gbkBytes = Data([0xC4, 0xE3, 0xBA, 0xC3, 0xCA, 0xC0, 0xBD, 0xE7]) // "你好世界" (GBK / GB18030)
        try assertEqual(LocalMusicSource.decodeTextWithFallback(gbkBytes), "你好世界")
        var bomUTF8 = Data([0xEF, 0xBB, 0xBF])
        bomUTF8.append(Data("[00:01.00]歌词".utf8))
        try assertEqual(LocalMusicSource.decodeTextWithFallback(bomUTF8), "[00:01.00]歌词")

        let tmpLocalDir = FileManager.default.temporaryDirectory.appendingPathComponent("mygo-local-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpLocalDir) }

        let local = LocalMusicSource(dataDir: tmpLocalDir)
        let sampleWAV = local.defaultMusicFolder.appendingPathComponent("EGOIST - Departures.wav")
        let sampleLRC = local.defaultMusicFolder.appendingPathComponent("EGOIST - Departures.lrc")
        let unsupportedOGG = local.defaultMusicFolder.appendingPathComponent("Skip - Unsupported.ogg")
        try writeTestWAV(to: sampleWAV)
        try "[00:01.00]あなたにおくるアイの歌".write(to: sampleLRC, atomically: true, encoding: .utf8)
        try Data("OggS".utf8).write(to: unsupportedOGG)

        local.rescan()
        try assertEqual(local.trackCount(), 1)

        let searchRes = try await local.search(query: "Departures", kind: .tracks, offset: 0)
        try assertEqual(searchRes.tracks?.count, 1)
        let track = searchRes.tracks![0]
        try assertEqual(track.name, "Departures")
        try assertEqual(track.artistNames, "EGOIST")

        let rawLyrics = try await local.lyrics(id: track.id)
        let parsedLyrics = LyricsEngine.fromSource(rawLyrics)
        try assertEqual(parsedLyrics.count, 1)
        try assertEqual(LyricsEngine.lang(of: parsedLyrics), "ja")
    }

    static func verifyStageMath() throws {
        let lines = LyricsEngine.build(lrc: "[00:01.00]Spring words into the stage with sparks and glow")
        try assertEqual(lines.count, 1)
        let line = lines[0]

        let shapes = StageMath.stageShapes(for: line, fontSize: 36)
        try assertEqual(shapes.count, line.words.count)
        try assertTrue(shapes.last?.last == true)

        let partitaRows = StageMath.partitaRows(for: line, height: 600)
        try assertTrue(!partitaRows.isEmpty)

        let tiltParts = StageMath.tiltParts(for: line)
        try assertTrue(!tiltParts.isEmpty)
    }

    static func verifyAudioDiskCacheLRU() throws {
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mygo-cache-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let cache = AudioDiskCache(cacheDir: cacheRoot)
        cache.limitMB = 0
        let disabledKey = AudioDiskCache.cacheKey(sourceID: "s", trackID: "off", quality: "high")
        _ = try cache.store(data: Data(repeating: 0x41, count: 1024), key: disabledKey, fileExtension: "mp3")
        try assertTrue(cache.cachedFileURL(forKey: disabledKey) == nil, "limitMB=0 时不应落盘缓存")

        cache.limitMB = 1 // 限制上限 1 MB
        let chunk = Data(repeating: 0x5A, count: 480 * 1024) // 单条 480 KB
        let k1 = AudioDiskCache.cacheKey(sourceID: "s", trackID: "t1", quality: "high")
        let k2 = AudioDiskCache.cacheKey(sourceID: "s", trackID: "t2", quality: "high")
        let k3 = AudioDiskCache.cacheKey(sourceID: "s", trackID: "t3", quality: "high")

        _ = try cache.store(data: chunk, key: k1, fileExtension: "mp3")
        Thread.sleep(forTimeInterval: 0.02)
        _ = try cache.store(data: chunk, key: k2, fileExtension: "mp3")
        Thread.sleep(forTimeInterval: 0.02)
        // 访问 k1 刷新其 LRU 时间戳，此时 k2 变为最久未访问
        _ = cache.cachedFileURL(forKey: k1)
        Thread.sleep(forTimeInterval: 0.02)
        // 写入 k3 (480KB * 3 > 1MB)，应触发 LRU 淘汰掉 k2 而保留 k1 与 k3
        _ = try cache.store(data: chunk, key: k3, fileExtension: "mp3")

        try assertTrue(cache.cachedFileURL(forKey: k2) == nil, "最久未访问的 k2 应被 LRU 淘汰")
        try assertTrue(cache.cachedFileURL(forKey: k1) != nil, "刚访问过的热点缓存 k1 应保留")
        try assertTrue(cache.cachedFileURL(forKey: k3) != nil, "新写入的 k3 应保留")
        try assertTrue(cache.usedBytes() <= 1024 * 1024)

        cache.clear()
        try assertEqual(cache.usedBytes(), 0)
    }

    static func verifyStreamUTTypeMapping() throws {
        let biliURL = URL(string: "https://upos-sz-mirror.bilivideo.com/upgcxcode/12/34/audio?os=bcache")!
        try assertEqual(
            AudioStreamProxy.resolveAudioUTType(streamType: "m4s", responseMIMEType: "application/octet-stream", url: biliURL),
            AVFileType.mp4.rawValue
        )
        try assertEqual(
            AudioStreamProxy.resolveAudioUTType(streamType: "flac", responseMIMEType: nil, url: biliURL),
            "org.xiph.flac"
        )
        try assertEqual(
            AudioStreamProxy.resolveAudioUTType(streamType: nil, responseMIMEType: "audio/mpeg", url: biliURL),
            AVFileType.mp3.rawValue
        )
        let m4aURL = URL(string: "https://cdn.example.com/song.m4a?token=abc")!
        try assertEqual(
            AudioStreamProxy.resolveAudioUTType(streamType: nil, responseMIMEType: nil, url: m4aURL),
            AVFileType.m4a.rawValue
        )

        // 直链分流判断：标准 HTTP 直链优先原生 AVURLAsset，仅 .m4s 或带自定义 headers 才走代理
        let directMP3 = StreamInfo(url: "https://m701.music.126.net/song.mp3", type: "mp3", headers: nil)
        try assertTrue(!PlayerEngine.shouldUseStreamProxy(url: URL(string: directMP3.url)!, stream: directMP3))

        let directOuterNoExt = StreamInfo(url: "https://music.163.com/song/media/outer/url?id=123", headers: [:])
        try assertTrue(!PlayerEngine.shouldUseStreamProxy(url: URL(string: directOuterNoExt.url)!, stream: directOuterNoExt))

        let directFLAC = StreamInfo(url: "https://m8.music.126.net/track.flac", type: "flac")
        try assertTrue(!PlayerEngine.shouldUseStreamProxy(url: URL(string: directFLAC.url)!, stream: directFLAC))

        let hlsWithHeaders = StreamInfo(url: "https://cdn.example.com/live.m3u8", type: "application/vnd.apple.mpegurl", headers: ["Referer": "https://music.163.com"])
        try assertTrue(!PlayerEngine.shouldUseStreamProxy(url: URL(string: hlsWithHeaders.url)!, stream: hlsWithHeaders))

        let biliM4S = StreamInfo(url: "https://upos.bilivideo.com/audio.m4s")
        try assertTrue(PlayerEngine.shouldUseStreamProxy(url: URL(string: biliM4S.url)!, stream: biliM4S))

        let customHeaderMP3 = StreamInfo(url: "https://cdn.example.com/track.mp3", type: "mp3", headers: ["Referer": "https://www.bilibili.com/"])
        try assertTrue(PlayerEngine.shouldUseStreamProxy(url: URL(string: customHeaderMP3.url)!, stream: customHeaderMP3))

        // makeProxyAssetURL 不应对未知无后缀直链强行伪造 .mp4 扩展名
        let unknownProxy = AudioStreamProxy(
            remoteURL: URL(string: "https://cdn.example.com/track?id=1")!,
            headers: [:],
            streamTypeHint: nil,
            cacheKey: nil,
            diskCache: nil
        )
        try assertEqual(unknownProxy.makeProxyAssetURL().pathExtension, "")

        let mp3HintProxy = AudioStreamProxy(
            remoteURL: URL(string: "https://cdn.example.com/track?id=2")!,
            headers: [:],
            streamTypeHint: "audio/mpeg",
            cacheKey: nil,
            diskCache: nil
        )
        try assertEqual(mp3HintProxy.makeProxyAssetURL().pathExtension, "mp3")
    }

    static func verifySourceNavigationCustomization() throws {
        let info = SourceInfo(
            id: "netease",
            name: "网易云音乐",
            version: "0.2.0",
            navigation: [
                NavItem(title: "云村推荐", builtin: "home", icon: "star"),
                NavItem(title: "红心歌单", builtin: "liked", icon: "heart")
            ]
        )
        try assertEqual(info.customTitle(forBuiltin: "home"), "云村推荐")
        try assertEqual(info.customIcon(forBuiltin: "home"), "star")
        try assertEqual(info.customTitle(forBuiltin: "liked"), "红心歌单")
        try assertTrue(info.customTitle(forBuiltin: "stations") == nil)
    }

    private static func writeDeflateZip(entries: [(name: String, data: Data)], to url: URL) throws {
        func appendLE16(_ buf: inout Data, _ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { buf.append(contentsOf: $0) }
        }
        func appendLE32(_ buf: inout Data, _ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { buf.append(contentsOf: $0) }
        }
        func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFFFFFF
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    let mask = UInt32(bitPattern: -Int32(crc & 1))
                    crc = (crc >> 1) ^ (0xEDB88320 & mask)
                }
            }
            return ~crc
        }
        func rawDeflate(_ input: Data) -> (method: UInt16, payload: Data) {
            guard !input.isEmpty else { return (0, Data()) }
            let dstCap = max(input.count + 128, 512)
            var dst = [UInt8](repeating: 0, count: dstCap)
            let outLen = input.withUnsafeBytes { srcPtr -> Int in
                guard let base = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_encode_buffer(&dst, dstCap, base, input.count, nil, COMPRESSION_ZLIB)
            }
            if outLen > 0 {
                return (8, Data(dst.prefix(outLen)))
            }
            return (0, input)
        }

        var archive = Data()
        var centralDir = Data()

        for (name, plain) in entries {
            let nameData = Data(name.utf8)
            let checksum = crc32(plain)
            let (method, compressed) = rawDeflate(plain)
            let localOffset = UInt32(archive.count)

            // Local file header (PK\x03\x04)
            appendLE32(&archive, 0x04034B50)
            appendLE16(&archive, 20)
            appendLE16(&archive, 0x0800) // UTF-8 filename flag
            appendLE16(&archive, method)
            appendLE16(&archive, 0)
            appendLE16(&archive, 0)
            appendLE32(&archive, checksum)
            appendLE32(&archive, UInt32(compressed.count))
            appendLE32(&archive, UInt32(plain.count))
            appendLE16(&archive, UInt16(nameData.count))
            appendLE16(&archive, 0)
            archive.append(nameData)
            archive.append(compressed)

            // Central directory file header (PK\x01\x02)
            appendLE32(&centralDir, 0x02014B50)
            appendLE16(&centralDir, 20)
            appendLE16(&centralDir, 20)
            appendLE16(&centralDir, 0x0800)
            appendLE16(&centralDir, method)
            appendLE16(&centralDir, 0)
            appendLE16(&centralDir, 0)
            appendLE32(&centralDir, checksum)
            appendLE32(&centralDir, UInt32(compressed.count))
            appendLE32(&centralDir, UInt32(plain.count))
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

        // End of central directory (PK\x05\x06)
        appendLE32(&archive, 0x06054B50)
        appendLE16(&archive, 0)
        appendLE16(&archive, 0)
        appendLE16(&archive, UInt16(entries.count))
        appendLE16(&archive, UInt16(entries.count))
        appendLE32(&archive, cdSize)
        appendLE32(&archive, cdOffset)
        appendLE16(&archive, 0)

        try archive.write(to: url, options: .atomic)
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
}

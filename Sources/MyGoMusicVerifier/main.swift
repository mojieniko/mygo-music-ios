// main.swift
// MyGo Music iOS 版自检测试运行器（支持在无完整 Xcode.app 仅有 CommandLineTools 的环境下直接运行全套验证）

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
            print("▶ [1/5] 验证 LyricsEngine（LRC多时间戳解析、翻译对齐、逐字均摊、演职员表与间奏检测）...")
            try verifyLyricsEngine()
            print("  ✓ LyricsEngine 通过")

            print("▶ [2/5] 验证 JavaScriptCore 插件引擎（临时插件夹具）...")
            try await verifyPluginRuntime()
            print("  ✓ JavaScriptCore 插件引擎 通过")

            print("▶ [3/5] 验证 PluginCrypto（MD5、AES-128-ECB + PKCS#7）与网络权限通配符...")
            try verifyPluginCryptoAndPermissions()
            print("  ✓ PluginCrypto 与权限检查 通过")

            print("▶ [4/5] 验证 PluginInstaller 仓库解析与 LocalMusicSource WAV/.lrc 读取...")
            try await verifyInstallerAndLocalSource()
            print("  ✓ PluginInstaller 与 LocalMusicSource 通过")

            print("▶ [5/5] 验证 StageMath Folia 律动舞台物理与分行算法（流光、云阶、倾诉、火花）...")
            try verifyStageMath()
            print("  ✓ StageMath 律动舞台算法 通过")

            print("\n🎉 所有 5 组核心测试套件全部通过！")
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
    }

    static func verifyPluginCryptoAndPermissions() throws {
        try assertEqual(PluginCrypto.md5Hex("mygo-music"), "acb1fe17e40ab3ed67c6254f7aa15ab2")
        let encryptedHex = try PluginCrypto.aesEcbEncryptHex(key: "0123456789abcdef", text: "hello mygo")
        try assertEqual(encryptedHex.count, 32)

        let perms = PluginPermissions(network: ["api.example.com", "*.music.163.com"])
        try assertTrue(perms.reaches(host: "api.example.com"))
        try assertTrue(perms.reaches(host: "interface.music.163.com"))
        try assertTrue(!perms.reaches(host: "evil.com"))
    }

    static func verifyInstallerAndLocalSource() async throws {
        try assertEqual(try PluginInstaller.parseRepo("egoist/mygo-music"), "egoist/mygo-music")
        try assertEqual(try PluginInstaller.parseRepo("https://github.com/egoist/mygo-music-youtube-music/tree/main"), "egoist/mygo-music-youtube-music")
        try assertEqual(try PluginInstaller.parseRepo("git@github.com:AkinoKaede/mygo-music-netease-cloud-music.git"), "AkinoKaede/mygo-music-netease-cloud-music")
        try assertTrue(PluginInstaller.isNewerVersion("0.2.0", than: "0.1.20"))
        try assertTrue(!PluginInstaller.isNewerVersion("0.1.8", than: "0.1.20"))

        let tmpLocalDir = FileManager.default.temporaryDirectory.appendingPathComponent("mygo-local-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpLocalDir) }

        let local = LocalMusicSource(dataDir: tmpLocalDir)
        let sampleWAV = local.defaultMusicFolder.appendingPathComponent("EGOIST - Departures.wav")
        let sampleLRC = local.defaultMusicFolder.appendingPathComponent("EGOIST - Departures.lrc")
        try writeTestWAV(to: sampleWAV)
        try "[00:01.00]あなたにおくるアイの歌".write(to: sampleLRC, atomically: true, encoding: .utf8)

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

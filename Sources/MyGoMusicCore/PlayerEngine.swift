// PlayerEngine.swift
// 对应原项目 internal/player/player.go, remote.go, cache.go 的播放队列与音频引擎

import AVFoundation
import Combine
import CryptoKit
import Foundation
import MediaPlayer
import MediaToolbox
import UniformTypeIdentifiers
import os
#if canImport(UIKit)
import UIKit
#endif


private final class AudioBandMeter: @unchecked Sendable {
    private let bandLock = OSAllocatedUnfairLock<UInt64>(initialState: 0x0000001F_1F1F1F1F)
    private var sampleRate = 44_100.0
    private var windowSize = 2_048
    private var channelCount = 2
    private var nonInterleaved = false
    private var isFloat = true
    private var bitsPerChannel = 32
    private var coefficients = (0.0, 0.0, 0.0, 0.0, 0.0)

    func configure(format: AudioStreamBasicDescription, maxFrames: Int) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
        windowSize = max(512, maxFrames)
        channelCount = max(1, Int(format.mChannelsPerFrame))
        nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        bitsPerChannel = Int(format.mBitsPerChannel)

        let frequencies = (70.0, 250.0, 800.0, 2_500.0, 8_000.0)
        coefficients = (
            coefficient(for: frequencies.0),
            coefficient(for: frequencies.1),
            coefficient(for: frequencies.2),
            coefficient(for: frequencies.3),
            coefficient(for: frequencies.4)
        )
    }

    func readBands() -> [Float] {
        let packed = bandLock.withLock { $0 }
        return [
            Float(packed & 0xFF) / 255,
            Float((packed >> 8) & 0xFF) / 255,
            Float((packed >> 16) & 0xFF) / 255,
            Float((packed >> 24) & 0xFF) / 255,
            Float((packed >> 32) & 0xFF) / 255
        ]
    }

    func analyze(_ list: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard frameCount > 0, bitsPerChannel == 16 || bitsPerChannel == 32 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard !buffers.isEmpty else { return }

        var q1a = 0.0, q2a = 0.0
        var q1b = 0.0, q2b = 0.0
        var q1c = 0.0, q2c = 0.0
        var q1d = 0.0, q2d = 0.0
        var q1e = 0.0, q2e = 0.0

        for frame in 0..<frameCount {
            var sample = 0.0
            if nonInterleaved {
                let channels = min(channelCount, buffers.count)
                guard channels > 0 else { return }
                for channel in 0..<channels {
                    sample += sampleValue(buffers[channel].mData, index: frame)
                }
                sample /= Double(channels)
            } else {
                let buffer = buffers[0]
                for channel in 0..<channelCount {
                    sample += sampleValue(buffer.mData, index: frame * channelCount + channel)
                }
                sample /= Double(channelCount)
            }

            let qa = sample + coefficients.0 * q1a - q2a
            q2a = q1a; q1a = qa
            let qb = sample + coefficients.1 * q1b - q2b
            q2b = q1b; q1b = qb
            let qc = sample + coefficients.2 * q1c - q2c
            q2c = q1c; q1c = qc
            let qd = sample + coefficients.3 * q1d - q2d
            q2d = q1d; q1d = qd
            let qe = sample + coefficients.4 * q1e - q2e
            q2e = q1e; q1e = qe
        }

        let count = Double(frameCount)
        let a = normalizedPower(q1a, q2a, coefficients.0, count)
        let b = normalizedPower(q1b, q2b, coefficients.1, count)
        let c = normalizedPower(q1c, q2c, coefficients.2, count)
        let d = normalizedPower(q1d, q2d, coefficients.3, count)
        let e = normalizedPower(q1e, q2e, coefficients.4, count)
        let packed = Self.pack(a, b, c, d, e)
        _ = bandLock.withLockIfAvailable { $0 = packed }
    }

    private func coefficient(for requestedFrequency: Double) -> Double {
        let nyquist = sampleRate / 2
        let frequency = min(requestedFrequency, nyquist * 0.9)
        let bin = max(1, min(windowSize / 2 - 1, Int((frequency * Double(windowSize) / sampleRate).rounded())))
        return 2 * cos(2 * .pi * Double(bin) / Double(windowSize))
    }

    private func sampleValue(_ data: UnsafeMutableRawPointer?, index: Int) -> Double {
        guard let data else { return 0 }
        if isFloat {
            return Double(data.assumingMemoryBound(to: Float.self)[index])
        }
        if bitsPerChannel == 16 {
            return Double(data.assumingMemoryBound(to: Int16.self)[index]) / 32_768
        }
        return Double(data.assumingMemoryBound(to: Int32.self)[index]) / 2_147_483_648
    }

    private func normalizedPower(_ q1: Double, _ q2: Double, _ coefficient: Double, _ count: Double) -> Double {
        let power = max(0, q1 * q1 + q2 * q2 - coefficient * q1 * q2)
        return min(1, max(0, sqrt(power) / count * 2 * 2.2))
    }

    private static func pack(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double) -> UInt64 {
        let qa = UInt64(min(255, max(0, Int(a * 255))) )
        let qb = UInt64(min(255, max(0, Int(b * 255))) )
        let qc = UInt64(min(255, max(0, Int(c * 255))) )
        let qd = UInt64(min(255, max(0, Int(d * 255))) )
        let qe = UInt64(min(255, max(0, Int(e * 255))) )
        return qa | (qb << 8) | (qc << 16) | (qd << 24) | (qe << 32)
    }
}

private func audioTapInit(
    _ tap: MTAudioProcessingTap,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ storageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    storageOut.pointee = clientInfo
}

private func audioTapFinalize(_ tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<AudioBandMeter>.fromOpaque(storage).release()
}

private func audioTapPrepare(
    _ tap: MTAudioProcessingTap,
    _ maxFrames: CMItemCount,
    _ format: UnsafePointer<AudioStreamBasicDescription>
) {
    let meter = Unmanaged<AudioBandMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    meter.configure(format: format.pointee, maxFrames: Int(maxFrames))
}

private func audioTapUnprepare(_ tap: MTAudioProcessingTap) {}

private func audioTapProcess(
    _ tap: MTAudioProcessingTap,
    _ frames: CMItemCount,
    _ flags: MTAudioProcessingTapFlags,
    _ buffers: UnsafeMutablePointer<AudioBufferList>,
    _ framesOut: UnsafeMutablePointer<CMItemCount>,
    _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut)
    guard status == noErr, framesOut.pointee > 0 else { return }
    let meter = Unmanaged<AudioBandMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    meter.analyze(buffers, frameCount: Int(framesOut.pointee))
}

/// 循环模式（对应 player.RepeatMode）
public enum RepeatMode: Int, Codable, CaseIterable, Sendable {
    case off = 0
    case all = 1
    case one = 2

    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// 会话持久化数据（对应 internal/app/session.go）
public struct SavedPlaybackSession: Codable, Sendable {
    public var queue: [Track]
    public var currentIndex: Int
    public var positionSeconds: TimeInterval
    public var shuffle: Bool
    public var repeatMode: RepeatMode

    public init(
        queue: [Track],
        currentIndex: Int,
        positionSeconds: TimeInterval,
        shuffle: Bool,
        repeatMode: RepeatMode
    ) {
        self.queue = queue
        self.currentIndex = currentIndex
        self.positionSeconds = positionSeconds
        self.shuffle = shuffle
        self.repeatMode = repeatMode
    }
}

/// 音频缓存条目元数据
public struct AudioCacheMetadata: Codable, Sendable {
    public var key: String
    public var audioFileName: String
    public var contentType: String?
    public var contentLength: Int64
    public var lastAccessedAt: TimeInterval
}

/// 音频磁盘缓存管理器（对应 internal/player/cache.go，支持按键读写、访问时间更新及 LRU 自动淘汰）
public final class AudioDiskCache: @unchecked Sendable {
    public let cacheDir: URL
    private let lock = NSLock()
    public var limitMB: Int = 2048

    public init(cacheDir: URL) {
        self.cacheDir = cacheDir
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    public static func cacheKey(sourceID: String, trackID: String, quality: String) -> String {
        let raw = "\(sourceID)|\(trackID)|\(quality)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func metaURL(forKey key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).meta.json")
    }

    /// 命中的本地缓存文件（同时刷新 LRU 访问时间）
    public func cachedFileURL(forKey key: String) -> (fileURL: URL, meta: AudioCacheMetadata)? {
        lock.lock()
        defer { lock.unlock() }

        let mURL = metaURL(forKey: key)
        guard let mData = try? Data(contentsOf: mURL),
              var meta = try? JSONDecoder().decode(AudioCacheMetadata.self, from: mData) else {
            return nil
        }

        let audioURL = cacheDir.appendingPathComponent(meta.audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path),
              let fileSize = (attrs[.size] as? NSNumber)?.int64Value,
              fileSize > 0 else {
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: mURL)
            return nil
        }

        if meta.contentLength > 0 && fileSize < meta.contentLength {
            // 残留不完整缓存文件直接清理
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: mURL)
            return nil
        }

        meta.lastAccessedAt = Date().timeIntervalSince1970
        if let updated = try? JSONEncoder().encode(meta) {
            try? updated.write(to: mURL, options: .atomic)
        }
        return (audioURL, meta)
    }

    /// 将完整音频数据落盘并按 limitMB 执行 LRU 淘汰
    @discardableResult
    public func store(
        data: Data,
        key: String,
        fileExtension: String = "dat",
        contentType: String? = nil
    ) throws -> URL {
        let ext = Self.sanitizedExtension(fileExtension)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygo-cache-tmp-\(UUID().uuidString).\(ext)")
        try data.write(to: tmp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try store(tempFileURL: tmp, key: key, fileExtension: ext, contentType: contentType)
    }

    /// 将临时音频文件移动/写入缓存目录并触发 LRU 淘汰
    @discardableResult
    public func store(
        tempFileURL: URL,
        key: String,
        fileExtension: String = "dat",
        contentType: String? = nil
    ) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        guard limitMB > 0 else { return tempFileURL }

        let attrs = try FileManager.default.attributesOfItem(atPath: tempFileURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw SourceError.message("Cannot store empty audio cache entry")
        }

        let ext = Self.sanitizedExtension(fileExtension)
        let fileName = "\(key).\(ext)"
        let destURL = cacheDir.appendingPathComponent(fileName)
        let mURL = metaURL(forKey: key)

        // 若旧版本存在不同扩展名则顺手移除
        if let existingMetaData = try? Data(contentsOf: mURL),
           let existingMeta = try? JSONDecoder().decode(AudioCacheMetadata.self, from: existingMetaData),
           existingMeta.audioFileName != fileName {
            try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(existingMeta.audioFileName))
        }
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: tempFileURL, to: destURL)

        let meta = AudioCacheMetadata(
            key: key,
            audioFileName: fileName,
            contentType: contentType,
            contentLength: fileSize,
            lastAccessedAt: Date().timeIntervalSince1970
        )
        let metaData = try JSONEncoder().encode(meta)
        try metaData.write(to: mURL, options: .atomic)

        evictIfNeededLocked()
        return destURL
    }

    public func evictIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        evictIfNeededLocked()
    }

    private func evictIfNeededLocked() {
        guard limitMB > 0 else { return }
        let maxBytes = Int64(limitMB) * 1024 * 1024
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        struct EntryInfo {
            let key: String
            let audioURL: URL
            let metaURL: URL
            let size: Int64
            let lastAccessedAt: TimeInterval
        }

        var totalBytes: Int64 = 0
        var entries: [EntryInfo] = []
        let decoder = JSONDecoder()

        for file in files {
            guard file.lastPathComponent.hasSuffix(".meta.json"),
                  let data = try? Data(contentsOf: file),
                  let meta = try? decoder.decode(AudioCacheMetadata.self, from: data) else {
                continue
            }
            let audioURL = cacheDir.appendingPathComponent(meta.audioFileName)
            let audioSize = Int64((try? audioURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let metaSize = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let combined = audioSize + metaSize
            totalBytes += combined
            entries.append(EntryInfo(
                key: meta.key,
                audioURL: audioURL,
                metaURL: file,
                size: combined,
                lastAccessedAt: meta.lastAccessedAt
            ))
        }

        // 同时清理无 meta 关联的孤立零散文件
        let trackedAudioNames = Set(entries.map { $0.audioURL.lastPathComponent })
        for file in files {
            let name = file.lastPathComponent
            if !name.hasSuffix(".meta.json") && !trackedAudioNames.contains(name) {
                if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    totalBytes += Int64(size)
                }
            }
        }

        guard totalBytes > maxBytes else { return }
        // 按最近访问时间升序（最久未访问先删）
        entries.sort { $0.lastAccessedAt < $1.lastAccessedAt }
        for entry in entries {
            guard totalBytes > maxBytes else { break }
            try? fm.removeItem(at: entry.audioURL)
            try? fm.removeItem(at: entry.metaURL)
            totalBytes -= entry.size
        }
    }

    public func usedBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for file in files {
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for f in files {
            try? fm.removeItem(at: f)
        }
    }

    private static func sanitizedExtension(_ ext: String) -> String {
        let cleaned = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? "dat" : cleaned
    }
}

/// 音视频流代理（通过 AVAssetResourceLoaderDelegate 解决 B 站 .m4s、防盗链头跨域重定向丢弃及边播边缓）
public final class AudioStreamProxy: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    public static let proxyScheme = "mygostream"

    public let remoteURL: URL
    public let headers: [String: String]
    public let streamTypeHint: String?
    public let cacheKey: String?
    public let diskCache: AudioDiskCache?
    public let delegateQueue: DispatchQueue

    private var urlSession: URLSession?
    private let lock = NSLock()
    private var activeTasks: [Int: TransferContext] = [:]
    private var isInvalidated = false

    private final class TransferContext {
        let lock = NSLock()
        let loadingRequest: AVAssetResourceLoadingRequest
        let requestedOffset: Int64
        let requestedLength: Int64
        let requestsAllToEnd: Bool
        let isInfoOnlyProbe: Bool

        var statusCode: Int = 200
        var streamStartOffset: Int64 = 0
        var totalContentLength: Int64 = -1
        var receivedBytesFromStreamStart: Int64 = 0
        var resolvedContentType: String = AVFileType.mp4.rawValue
        var resolvedExtension: String = "m4a"
        var respondedUpToOffset: Int64

        // 全量顺序读取时开启边下载边写临时文件，完成后原子转存磁盘缓存
        var cacheTempURL: URL?
        var cacheFileHandle: FileHandle?
        var cacheWrittenBytes: Int64 = 0
        var shouldWriteCache: Bool = false
        var finishedLoading = false

        init(loadingRequest: AVAssetResourceLoadingRequest, canCache: Bool) {
            self.loadingRequest = loadingRequest
            if let dataReq = loadingRequest.dataRequest {
                let reqOffset = dataReq.requestedOffset
                let curOffset = max(reqOffset, dataReq.currentOffset)
                let reqEnd = reqOffset + Int64(max(0, dataReq.requestedLength))
                self.requestedOffset = curOffset
                self.requestedLength = max(0, reqEnd - curOffset)
                self.requestsAllToEnd = dataReq.requestsAllDataToEndOfResource
                self.isInfoOnlyProbe = false
                self.respondedUpToOffset = curOffset
                self.shouldWriteCache = canCache && curOffset == 0 && (self.requestsAllToEnd || self.requestedLength > 65536)
            } else {
                self.requestedOffset = 0
                self.requestedLength = 0
                self.requestsAllToEnd = false
                self.isInfoOnlyProbe = (loadingRequest.contentInformationRequest != nil)
                self.respondedUpToOffset = 0
                self.shouldWriteCache = false
            }
        }
    }

    public init(
        remoteURL: URL,
        headers: [String: String],
        streamTypeHint: String?,
        cacheKey: String?,
        diskCache: AudioDiskCache?,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.remoteURL = remoteURL
        self.headers = headers
        self.streamTypeHint = streamTypeHint
        self.cacheKey = cacheKey
        self.diskCache = diskCache
        self.delegateQueue = DispatchQueue(label: "mygo.audio.stream.proxy", qos: .userInitiated)
        super.init()

        let config = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit {
        invalidate()
    }

    /// 构造带推荐扩展名的代理 Asset URL（仅在明确已知音频格式时附带扩展名，避免无后缀 MP3/FLAC 被提前错判为 .mp4）
    public func makeProxyAssetURL() -> URL {
        if let ext = Self.knownFileExtension(streamType: streamTypeHint, url: remoteURL) {
            return URL(string: "\(Self.proxyScheme)://track/\(UUID().uuidString).\(ext)")!
        }
        return URL(string: "\(Self.proxyScheme)://track/\(UUID().uuidString)")!
    }

    private static func knownFileExtension(streamType: String?, url: URL) -> String? {
        let hint = streamType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let pathExt = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !hint.isEmpty {
            if hint.contains("flac") { return "flac" }
            if hint.contains("mpeg") || hint.contains("mp3") { return "mp3" }
            if hint.contains("wav") { return "wav" }
            if hint.contains("aacp") || hint.contains("m4a") { return "m4a" }
            if hint.contains("aac") { return "aac" }
            if hint.contains("m4s") || hint.contains("mp4") { return "mp4" }
        }
        switch pathExt {
        case "flac", "mp3", "wav", "aac", "m4a", "mp4":
            return pathExt
        case "m4s":
            return "mp4"
        default:
            return nil
        }
    }

    /// 根据插件声明 type、HTTP 响应 Content-Type 与 URL 后缀精准映射到 Apple UTI（解决 B 站 .m4s 与无后缀 CDN）
    public static func resolveAudioUTType(streamType: String?, responseMIMEType: String?, url: URL) -> String {
        let candidates = [
            streamType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            responseMIMEType?.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        ].compactMap { s -> String? in
            guard let s, !s.isEmpty else { return nil }
            return s
        }

        let pathExt = url.pathExtension.lowercased()

        for hint in candidates {
            if hint.contains("flac") { return "org.xiph.flac" }
            if hint.contains("mpeg") || hint.contains("mp3") { return UTType.mp3.identifier }
            if hint.contains("wav") { return UTType.wav.identifier }
            if hint.contains("aacp") || hint.contains("x-m4a") || hint.contains("audio/m4a") { return "com.apple.m4a-audio" }
            if hint.contains("aac") { return "public.aac-audio" }
            if hint.contains("m4s") || hint.contains("mp4") { return AVFileType.mp4.rawValue }
        }

        switch pathExt {
        case "flac": return "org.xiph.flac"
        case "mp3": return UTType.mp3.identifier
        case "wav": return UTType.wav.identifier
        case "aac": return "public.aac-audio"
        case "m4a": return "com.apple.m4a-audio"
        case "m4s", "mp4": return AVFileType.mp4.rawValue
        default: break
        }

        for hint in candidates {
            if let ut = UTType(mimeType: hint), ut.conforms(to: .audio) || ut.conforms(to: .audiovisualContent) {
                return ut.identifier
            }
        }
        return AVFileType.mp4.rawValue
    }

    public static func preferredFileExtension(streamType: String?, responseMIMEType: String?, url: URL) -> String {
        let uti = resolveAudioUTType(streamType: streamType, responseMIMEType: responseMIMEType, url: url)
        switch uti {
        case "org.xiph.flac": return "flac"
        case UTType.mp3.identifier: return "mp3"
        case UTType.wav.identifier: return "wav"
        case "public.aac-audio": return "aac"
        case "com.apple.m4a-audio": return "m4a"
        case AVFileType.mp4.rawValue:
            // fMP4 / .m4s 在代理路径后缀和本地缓存里用 m4a 或 mp4 均可被 AVURLAsset 原生解析
            let ext = url.pathExtension.lowercased()
            return ext == "m4a" ? "m4a" : "mp4"
        default:
            let ext = url.pathExtension.lowercased()
            return ext.isEmpty || ext == "m4s" ? "mp4" : ext
        }
    }

    public func invalidate() {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }
        isInvalidated = true
        let contexts = Array(activeTasks.values)
        activeTasks.removeAll()
        let session = urlSession
        urlSession = nil
        lock.unlock()

        for ctx in contexts {
            var shouldFinish = false
            ctx.lock.lock()
            cleanupCacheHandleLocked(ctx, removeTemp: true)
            if !ctx.finishedLoading && !ctx.loadingRequest.isFinished && !ctx.loadingRequest.isCancelled {
                ctx.finishedLoading = true
                shouldFinish = true
            }
            ctx.lock.unlock()
            if shouldFinish {
                ctx.loadingRequest.finishLoading(with: CancellationError())
            }
        }
        session?.invalidateAndCancel()
    }

    // MARK: - AVAssetResourceLoaderDelegate

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        lock.lock()
        guard !isInvalidated, let session = urlSession else {
            lock.unlock()
            return false
        }
        lock.unlock()

        var request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        for (k, v) in headers {
            if k.caseInsensitiveCompare("host") == .orderedSame || k.caseInsensitiveCompare("content-length") == .orderedSame {
                continue
            }
            request.setValue(v, forHTTPHeaderField: k)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) mygo-music/0.1",
                forHTTPHeaderField: "User-Agent"
            )
        }

        let canCache = (cacheKey != nil) && ((diskCache?.limitMB ?? 0) > 0)
        let ctx = TransferContext(loadingRequest: loadingRequest, canCache: canCache)

        if let dataRequest = loadingRequest.dataRequest {
            let offset = max(0, ctx.requestedOffset)
            if dataRequest.requestsAllDataToEndOfResource || ctx.requestedLength <= 0 || ctx.requestedLength > 20_000_000 {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            } else {
                let end = offset + ctx.requestedLength - 1
                request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            }
        } else if ctx.isInfoOnlyProbe {
            // 纯元数据探测请求：只拉 2 字节探测响应头后立即结束，避免下载完整歌曲
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }

        let task = session.dataTask(with: request)
        lock.lock()
        if isInvalidated {
            lock.unlock()
            task.cancel()
            return false
        }
        activeTasks[task.taskIdentifier] = ctx
        lock.unlock()

        task.resume()
        return true
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        lock.lock()
        let match = activeTasks.first { $0.value.loadingRequest === loadingRequest }
        let removedCtx = match.flatMap { activeTasks.removeValue(forKey: $0.key) }
        let session = urlSession
        lock.unlock()

        if let match {
            session?.getAllTasks { tasks in
                tasks.first { $0.taskIdentifier == match.key }?.cancel()
            }
        }
        if let removedCtx {
            removedCtx.lock.lock()
            removedCtx.finishedLoading = true
            cleanupCacheHandleLocked(removedCtx, removeTemp: true)
            removedCtx.lock.unlock()
        }
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // CDN 跨节点跳转时保留 Referer/User-Agent/Origin/Range，但出于安全剥离 Cookie 和 Authorization
        var forwarded = request
        forwarded.httpShouldHandleCookies = false
        let oldHost = task.originalRequest?.url?.host?.lowercased()
        let newHost = request.url?.host?.lowercased()
        let sameHost = (oldHost != nil && oldHost == newHost)

        for (k, v) in headers {
            let lower = k.lowercased()
            if lower == "host" || lower == "content-length" { continue }
            if !sameHost && (lower == "cookie" || lower == "authorization") { continue }
            if forwarded.value(forHTTPHeaderField: k) == nil {
                forwarded.setValue(v, forHTTPHeaderField: k)
            }
        }
        if let rangeHeader = task.originalRequest?.value(forHTTPHeaderField: "Range"),
           forwarded.value(forHTTPHeaderField: "Range") == nil {
            forwarded.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }
        completionHandler(forwarded)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        guard let ctx = activeTasks[dataTask.taskIdentifier], !isInvalidated else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        lock.unlock()

        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(taskID: dataTask.taskIdentifier, error: SourceError.message("Invalid audio stream response"))
            return
        }

        let contentRangeInfo = Self.parseContentRange(http.value(forHTTPHeaderField: "Content-Range"))

        // 若探测流尾返回 416 且偏移 >= 总长度，视作合法 EOF
        if http.statusCode == 416, let cr = contentRangeInfo, cr.total > 0, ctx.requestedOffset >= cr.total {
            completionHandler(.cancel)
            finish(taskID: dataTask.taskIdentifier, error: nil)
            return
        }

        guard (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(taskID: dataTask.taskIdentifier, error: SourceError.message("Audio HTTP \(http.statusCode)"))
            return
        }

        let mime = http.value(forHTTPHeaderField: "Content-Type") ?? http.mimeType
        let resolvedType = Self.resolveAudioUTType(streamType: streamTypeHint, responseMIMEType: mime, url: remoteURL)
        let resolvedExt = Self.preferredFileExtension(streamType: streamTypeHint, responseMIMEType: mime, url: remoteURL)

        var streamStart: Int64 = 0
        var totalLen: Int64 = -1
        if http.statusCode == 206, let cr = contentRangeInfo {
            streamStart = cr.start
            totalLen = cr.total
        } else {
            streamStart = 0
            if let lenStr = http.value(forHTTPHeaderField: "Content-Length"), let len = Int64(lenStr), len > 0 {
                totalLen = len
            } else if response.expectedContentLength > 0 {
                totalLen = response.expectedContentLength
            }
        }

        let acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sentRangeHeader = dataTask.originalRequest?.value(forHTTPHeaderField: "Range") != nil
        let rangeSupported: Bool
        if http.statusCode == 206 {
            rangeSupported = true
        } else if sentRangeHeader && http.statusCode == 200 {
            // 发送了 Range 仍收到 200，说明上游忽略分片，切勿谎报支持 Range 避免 AVPlayer 反复跳尾重传卡死
            rangeSupported = false
        } else {
            rangeSupported = (acceptRanges == "bytes")
        }

        ctx.lock.lock()
        if ctx.finishedLoading || ctx.loadingRequest.isCancelled {
            ctx.lock.unlock()
            completionHandler(.cancel)
            return
        }
        ctx.statusCode = http.statusCode
        ctx.streamStartOffset = streamStart
        ctx.totalContentLength = totalLen
        ctx.resolvedContentType = resolvedType
        ctx.resolvedExtension = resolvedExt

        if let infoReq = ctx.loadingRequest.contentInformationRequest {
            infoReq.contentType = resolvedType
            infoReq.isByteRangeAccessSupported = rangeSupported
            if totalLen > 0 {
                infoReq.contentLength = totalLen
            }
        }

        // 纯信息探测请求拿到响应头后立刻完成并取消后续字节下载
        if ctx.isInfoOnlyProbe {
            ctx.finishedLoading = true
            ctx.lock.unlock()
            lock.lock()
            activeTasks.removeValue(forKey: dataTask.taskIdentifier)
            lock.unlock()
            ctx.loadingRequest.finishLoading()
            completionHandler(.cancel)
            return
        }

        // 若从 offset 0 开始读取全量流且允许缓存，则准备临时写入句柄
        if ctx.shouldWriteCache && streamStart == 0 {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mygo-stream-cache-\(UUID().uuidString).\(resolvedExt)")
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: tmp) {
                ctx.cacheTempURL = tmp
                ctx.cacheFileHandle = handle
            }
        } else {
            ctx.shouldWriteCache = false
        }
        ctx.lock.unlock()

        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let ctx = activeTasks[dataTask.taskIdentifier], !isInvalidated else {
            lock.unlock()
            dataTask.cancel()
            return
        }
        lock.unlock()

        ctx.lock.lock()
        guard !ctx.finishedLoading, !ctx.loadingRequest.isCancelled else {
            ctx.lock.unlock()
            dataTask.cancel()
            return
        }

        let chunkStartOffset = ctx.streamStartOffset + ctx.receivedBytesFromStreamStart
        let chunkEndOffset = chunkStartOffset + Int64(data.count)
        ctx.receivedBytesFromStreamStart += Int64(data.count)

        if ctx.shouldWriteCache, let handle = ctx.cacheFileHandle {
            try? handle.write(contentsOf: data)
            ctx.cacheWrittenBytes += Int64(data.count)
        }

        var sliceToRespond: Data?
        var shouldFinishNow = false

        if ctx.loadingRequest.dataRequest != nil {
            let reqLower = ctx.respondedUpToOffset
            let reqUpper: Int64 = (!ctx.requestsAllToEnd && ctx.requestedLength > 0)
                ? (ctx.requestedOffset + ctx.requestedLength)
                : Int64.max

            let overlapStart = max(chunkStartOffset, reqLower)
            let overlapEnd = min(chunkEndOffset, reqUpper)
            if overlapEnd > overlapStart {
                let startInChunk = Int(overlapStart - chunkStartOffset)
                let endInChunk = Int(overlapEnd - chunkStartOffset)
                sliceToRespond = data.subdata(in: startInChunk..<endInChunk)
                ctx.respondedUpToOffset = overlapEnd
            }

            if !ctx.requestsAllToEnd && ctx.requestedLength > 0 && ctx.respondedUpToOffset >= reqUpper {
                ctx.finishedLoading = true
                cleanupCacheHandleLocked(ctx, removeTemp: true)
                shouldFinishNow = true
            }
        }
        ctx.lock.unlock()

        if let slice = sliceToRespond, let dataRequest = ctx.loadingRequest.dataRequest {
            dataRequest.respond(with: slice)
        }

        if shouldFinishNow {
            lock.lock()
            activeTasks.removeValue(forKey: dataTask.taskIdentifier)
            lock.unlock()
            ctx.loadingRequest.finishLoading()
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 如果已在 didReceive data 阶段作为有界分块或探测请求完成，则忽略由主动 cancel 引起的回调
        if let nsErr = error as NSError?, nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
            lock.lock()
            let stillActive = activeTasks[task.taskIdentifier] != nil
            lock.unlock()
            if !stillActive { return }
        }
        finish(taskID: task.taskIdentifier, error: error)
    }

    private func finish(taskID: Int, error: Error?) {
        lock.lock()
        guard let ctx = activeTasks.removeValue(forKey: taskID) else {
            lock.unlock()
            return
        }
        lock.unlock()

        if let error {
            var shouldNotify = false
            ctx.lock.lock()
            cleanupCacheHandleLocked(ctx, removeTemp: true)
            if !ctx.finishedLoading && !ctx.loadingRequest.isCancelled {
                ctx.finishedLoading = true
                shouldNotify = true
            }
            ctx.lock.unlock()
            if shouldNotify {
                ctx.loadingRequest.finishLoading(with: error)
            }
            return
        }

        // 成功读到流 EOF，若缓存文件完整则落盘
        var cacheReady: (tmpURL: URL, key: String, diskCache: AudioDiskCache, ext: String, type: String)?
        var shouldNotifySuccess = false

        ctx.lock.lock()
        if ctx.shouldWriteCache,
           let tmpURL = ctx.cacheTempURL,
           let cacheKey = cacheKey,
           let diskCache = diskCache,
           ctx.cacheWrittenBytes > 0,
           (ctx.totalContentLength <= 0 || ctx.cacheWrittenBytes >= ctx.totalContentLength) {
            try? ctx.cacheFileHandle?.close()
            ctx.cacheFileHandle = nil
            ctx.cacheTempURL = nil
            cacheReady = (tmpURL, cacheKey, diskCache, ctx.resolvedExtension, ctx.resolvedContentType)
        } else {
            cleanupCacheHandleLocked(ctx, removeTemp: true)
        }

        if !ctx.finishedLoading && !ctx.loadingRequest.isCancelled {
            ctx.finishedLoading = true
            shouldNotifySuccess = true
        }
        ctx.lock.unlock()

        if let cacheReady {
            _ = try? cacheReady.diskCache.store(
                tempFileURL: cacheReady.tmpURL,
                key: cacheReady.key,
                fileExtension: cacheReady.ext,
                contentType: cacheReady.type
            )
            try? FileManager.default.removeItem(at: cacheReady.tmpURL)
        }

        if shouldNotifySuccess {
            ctx.loadingRequest.finishLoading()
        }
    }

    private func cleanupCacheHandleLocked(_ ctx: TransferContext, removeTemp: Bool) {
        try? ctx.cacheFileHandle?.close()
        ctx.cacheFileHandle = nil
        if removeTemp, let tmp = ctx.cacheTempURL {
            try? FileManager.default.removeItem(at: tmp)
            ctx.cacheTempURL = nil
        }
    }

    private static func parseContentRange(_ header: String?) -> (start: Int64, total: Int64)? {
        guard let header else { return nil }
        // 形如: bytes 0-1023/54321 或 bytes 0-1023/*
        let lower = header.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.hasPrefix("bytes ") else { return nil }
        let body = String(lower.dropFirst("bytes ".count))
        let parts = body.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let rangePart = parts[0].split(separator: "-")
        guard let start = Int64(rangePart.first ?? "") else { return nil }
        let total = Int64(parts[1]) ?? -1
        return (start, total)
    }
}

/// 核心播放器引擎（1:1 移植自 internal/player/player.go）
@MainActor
public final class PlayerEngine: ObservableObject {
    public static let bandCount = 5

    @Published public private(set) var queue: [Track] = []
    @Published public private(set) var order: [Int] = []
    @Published public private(set) var currentOrderIndex: Int = -1
    @Published public private(set) var currentTrack: Track? = nil
    @Published public private(set) var currentStream: StreamInfo? = nil
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var position: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var shuffle: Bool = false
    @Published public private(set) var repeatMode: RepeatMode = .off
    @Published public var volume: Double = 0.8 {
        didSet {
            applyPlayerVolume()
        }
    }
    @Published public private(set) var radioName: String? = nil
    @Published public private(set) var lyrics: [LyricLine] = []
    @Published public private(set) var lyricsLoaded: Bool = false
    @Published public private(set) var errorMessage: String? = nil
    @Published public private(set) var audioBands: [Float] = [0.15, 0.15, 0.15, 0.15, 0.15]
    @Published public private(set) var isSeeking: Bool = false
    @Published public private(set) var seekRevision: Int = 0

    public struct NowPlayingDisplayMetadata: Equatable, Sendable {
        public let title: String
        public let artist: String
        public let albumTitle: String
        public let lyricIndex: Int?
    }

    public var sourceResolver: ((String) -> MusicSource?)?
    public var qualityProvider: (() -> String)?
    public var normalizeProvider: (() -> Bool)?
    public var fadeEnabledProvider: (() -> Bool)?
    public var lockScreenLyricsProvider: (() -> Bool)?
    public var onSourceFailure: ((String, SourceError) -> Void)?
    public var onSessionChanged: (() -> Void)?

    public let diskCache: AudioDiskCache

    private var avPlayer: AVPlayer?
    private var activeStreamProxy: AudioStreamProxy?
    private var timeObserver: Any?
    private var boundaryTimeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var loadGeneration: Int = 0
    private var currentGainLinear: Float = 1.0
    private var currentFadeMultiplier: Float = 1.0
    private var fadeTask: Task<Void, Never>?
    private var prefetchedStream: (trackKey: String, quality: String, stream: StreamInfo, fetchedAt: Date)?
    private var prefetchAttemptedKey: String?
    private var radioFeed: (() async -> [Track])? = nil
    private var isFetchingRadio: Bool = false
    private var recordedTrackKey: String? = nil
    private var bandTimer: Timer?
    private var audioBandMeter: AudioBandMeter?
    private var syntheticBandPhase: Double = 0
    private var lockScreenArtwork: MPMediaItemArtwork?
    private var lastPublishedNowPlayingMeta: NowPlayingDisplayMetadata?

    public init(cacheDir: URL? = nil) {
        let dir = cacheDir ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyGoMusicAudioCache", isDirectory: true)
        self.diskCache = AudioDiskCache(cacheDir: dir)
        configureAudioSession()
        configureRemoteCommands()
        startBandUpdateTimer()
    }

    // MARK: - 队列与播放控制（对应 PlayQueue / PlayTrack / PlayShuffled）

    /// 按顺序替换播放队列并从 start 开始播放
    public func playQueue(_ tracks: [Track], start: Int = 0) {
        guard !tracks.isEmpty else { return }
        endRadio()
        let clampedStart = min(max(start, 0), tracks.count - 1)
        self.queue = tracks
        self.order = Array(0..<tracks.count)
        if shuffle {
            shuffleOrder(keepingFirstQueueIndex: clampedStart)
            loadTrack(atOrderIndex: 0, autoPlay: true)
        } else {
            loadTrack(atOrderIndex: clampedStart, autoPlay: true)
        }
    }

    /// 播放列表中用户点选的单曲
    public func playTrack(_ tracks: [Track], at index: Int) {
        playQueue(tracks, start: index)
    }

    /// 随机打乱并开始播放
    public func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        shuffle = true
        endRadio()
        self.queue = tracks
        self.order = Array(0..<tracks.count)
        shuffleOrder(keepingFirstQueueIndex: -1)
        loadTrack(atOrderIndex: 0, autoPlay: true)
    }

    /// 开启无限电台模式（对应 PlayRadio）
    public func playRadio(name: String, initialTracks: [Track], feed: @escaping () async -> [Track]) {
        guard !initialTracks.isEmpty else { return }
        self.shuffle = false
        self.radioName = name
        self.radioFeed = feed
        self.queue = initialTracks
        self.order = Array(0..<initialTracks.count)
        loadTrack(atOrderIndex: 0, autoPlay: true)
    }

    /// 退出电台模式但继续播放当前歌曲（对应 ExitRadio）
    public func exitRadio() {
        endRadio()
    }

    private func endRadio() {
        radioName = nil
        radioFeed = nil
        isFetchingRadio = false
    }

    /// 播放 / 暂停切换（对应 TogglePlay）
    public func togglePlay() {
        guard currentTrack != nil else { return }
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    public func pause() {
        isPlaying = false
        fadeTask?.cancel()
        if let player = avPlayer, fadeEnabledProvider?() == true, player.timeControlStatus == .playing {
            let gen = loadGeneration
            fadeTask = Task { [weak self] in
                await self?.animateFade(from: self?.currentFadeMultiplier ?? 1.0, to: 0.0, durationMs: 160, gen: gen)
                guard let self, !Task.isCancelled, self.loadGeneration == gen, !self.isPlaying else { return }
                self.avPlayer?.pause()
                self.currentFadeMultiplier = 1.0
                self.applyPlayerVolume()
            }
        } else {
            avPlayer?.pause()
            currentFadeMultiplier = 1.0
            applyPlayerVolume()
        }
        if let tr = currentTrack,
           let src = sourceForTrack(tr),
           src.info().playback == .remote {
            Task { try? await src.remotePause() }
        }
        updateNowPlayingCenter()
        onSessionChanged?()
    }

    public func resume() {
        guard currentTrack != nil else { return }
        ensureAudioSessionActive()
        isPlaying = true
        fadeTask?.cancel()
        if let player = avPlayer {
            if fadeEnabledProvider?() == true {
                currentFadeMultiplier = 0.0
                applyPlayerVolume()
                player.play()
                let gen = loadGeneration
                fadeTask = Task { [weak self] in
                    await self?.animateFade(from: 0.0, to: 1.0, durationMs: 200, gen: gen)
                }
            } else {
                currentFadeMultiplier = 1.0
                applyPlayerVolume()
                player.play()
            }
        } else if !isLoading {
            retryCurrentTrack()
        }
        if let tr = currentTrack,
           let src = sourceForTrack(tr),
           src.info().playback == .remote {
            Task { try? await src.remoteResume() }
        }
        updateNowPlayingCenter()
        onSessionChanged?()
    }

    /// 下一首（对应 Next）
    public func next() {
        guard !order.isEmpty else { return }
        let nextIdx = currentOrderIndex + 1
        if nextIdx < order.count {
            loadTrack(atOrderIndex: nextIdx, autoPlay: true)
            maybePrefetchRadio()
        } else if radioFeed != nil {
            Task {
                await appendRadioTracksAndAdvance()
            }
        } else {
            loadTrack(atOrderIndex: 0, autoPlay: true)
        }
    }

    /// 上一首（对应 Prev：超过 3 秒回到开头，否则切上一首）
    public func previous() {
        guard !order.isEmpty else { return }
        if position > 3.0 {
            seek(to: 0)
            return
        }
        let prevIdx = currentOrderIndex - 1
        if prevIdx >= 0 {
            loadTrack(atOrderIndex: prevIdx, autoPlay: true)
        } else if repeatMode == .all {
            loadTrack(atOrderIndex: order.count - 1, autoPlay: true)
        } else {
            seek(to: 0)
        }
    }

    /// 跳转到指定秒数（对应 Seek）
    public func seek(to seconds: TimeInterval) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        self.position = clamped
        self.isSeeking = true
        self.seekRevision &+= 1

        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        let revision = seekRevision
        if let avPlayer {
            avPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor in
                    guard let self, self.seekRevision == revision else { return }
                    if finished {
                        self.position = clamped
                    }
                    self.isSeeking = false
                    self.seekRevision &+= 1
                    self.updateNowPlayingCenter()
                }
            }
        } else {
            isSeeking = false
            self.seekRevision &+= 1
        }
        if let tr = currentTrack,
           let src = sourceForTrack(tr),
           src.info().playback == .remote {
            Task { try? await src.remoteSeek(position: Int64(clamped * 1000)) }
        }
        updateNowPlayingCenter()
        onSessionChanged?()
    }

    /// 切换随机模式（对应 ToggleShuffle）
    public func toggleShuffle() {
        guard radioName == nil else { return }
        shuffle.toggle()
        guard !queue.isEmpty else { return }
        let currentQueueIdx = (currentOrderIndex >= 0 && currentOrderIndex < order.count) ? order[currentOrderIndex] : 0
        if shuffle {
            shuffleOrder(keepingFirstQueueIndex: currentQueueIdx)
            currentOrderIndex = 0
        } else {
            order = Array(0..<queue.count)
            currentOrderIndex = currentQueueIdx
        }
        onSessionChanged?()
    }

    /// 切换循环模式（对应 CycleRepeat）
    public func cycleRepeat() {
        repeatMode = repeatMode.next
        onSessionChanged?()
    }

    /// 获取按当前播放顺序排列的队列（对应 UpNext / Queue）
    public var orderedQueue: [Track] {
        order.compactMap { idx in
            (idx >= 0 && idx < queue.count) ? queue[idx] : nil
        }
    }

    /// 跳到播放队列中的指定位置（对应 JumpTo）
    public func jumpToOrderIndex(_ orderIndex: Int) {
        guard orderIndex >= 0 && orderIndex < order.count else { return }
        loadTrack(atOrderIndex: orderIndex, autoPlay: true)
    }

    /// 从播放队列中移除指定项
    public func removeFromQueue(atOrderIndex idx: Int) {
        guard idx >= 0 && idx < order.count else { return }
        let removedQueueIdx = order.remove(at: idx)
        queue.remove(at: removedQueueIdx)
        for i in order.indices {
            if order[i] > removedQueueIdx {
                order[i] -= 1
            }
        }
        if order.isEmpty {
            stopAndClear()
            return
        }
        if idx < currentOrderIndex {
            currentOrderIndex -= 1
        } else if idx == currentOrderIndex {
            let nextIdx = min(currentOrderIndex, order.count - 1)
            loadTrack(atOrderIndex: nextIdx, autoPlay: isPlaying)
        }
        onSessionChanged?()
    }

    public func stopAndClear() {
        cleanupAVPlayer()
        queue = []
        order = []
        currentOrderIndex = -1
        currentTrack = nil
        currentStream = nil
        isPlaying = false
        isLoading = false
        position = 0
        duration = 0
        lyrics = []
        lyricsLoaded = false
        lastPublishedNowPlayingMeta = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - 会话恢复（Session Restore）

    public func exportSession() -> SavedPlaybackSession? {
        guard !queue.isEmpty, currentOrderIndex >= 0, currentOrderIndex < order.count else {
            return nil
        }
        return SavedPlaybackSession(
            queue: orderedQueue,
            currentIndex: currentOrderIndex,
            positionSeconds: position,
            shuffle: shuffle,
            repeatMode: repeatMode
        )
    }

    public func restoreSession(_ session: SavedPlaybackSession) {
        guard !session.queue.isEmpty else { return }
        self.queue = session.queue
        self.order = Array(0..<session.queue.count)
        self.shuffle = session.shuffle
        self.repeatMode = session.repeatMode
        let idx = min(max(session.currentIndex, 0), session.queue.count - 1)
        loadTrack(atOrderIndex: idx, autoPlay: false, initialSeek: session.positionSeconds)
    }

    // MARK: - 内部加载与流处理

    private func shuffleOrder(keepingFirstQueueIndex firstIdx: Int) {
        var indices = Array(0..<queue.count)
        if firstIdx >= 0, let pos = indices.firstIndex(of: firstIdx) {
            indices.remove(at: pos)
            indices.shuffle()
            indices.insert(firstIdx, at: 0)
        } else {
            indices.shuffle()
        }
        self.order = indices
    }

    private func sourceForTrack(_ track: Track) -> MusicSource? {
        let srcID = track.source ?? LocalMusicSource.sourceID
        return sourceResolver?(srcID)
    }

    private func loadTrack(atOrderIndex orderIndex: Int, autoPlay: Bool, initialSeek: TimeInterval = 0) {
        guard orderIndex >= 0 && orderIndex < order.count else { return }
        let queueIdx = order[orderIndex]
        let track = queue[queueIdx]

        loadGeneration += 1
        let gen = loadGeneration

        cleanupAVPlayer()
        currentOrderIndex = orderIndex
        currentTrack = track
        lockScreenArtwork = nil
        currentStream = nil
        position = initialSeek
        duration = track.durationSeconds
        isLoading = true
        isPlaying = autoPlay
        errorMessage = nil
        lyrics = []
        lyricsLoaded = false
        lastPublishedNowPlayingMeta = nil
        currentGainLinear = 1.0

        updateNowPlayingCenter()
        onSessionChanged?()

        guard let src = sourceForTrack(track) else {
            isLoading = false
            isPlaying = false
            errorMessage = I18n.t("The plugin of this song is gone")
            return
        }

        // 异步加载歌词
        if src.can("lyrics") && !track.isEpisode {
            let trackID = track.id
            Task {
                if let rawLyrics = try? await src.lyrics(id: trackID) {
                    let parsed = LyricsEngine.fromSource(rawLyrics)
                    if self.loadGeneration == gen {
                        self.lyrics = parsed
                        self.lyricsLoaded = true
                        self.rebuildLyricBoundaryObserver()
                        self.updateNowPlayingCenter()
                    }
                } else if self.loadGeneration == gen {
                    self.lyricsLoaded = true
                }
            }
        } else {
            lyricsLoaded = true
        }

        // 记录播放历史
        let key = track.compositeKey
        if recordedTrackKey != key {
            recordedTrackKey = key
            Task {
                await src.played(track: track)
            }
        }

        // 远程播放源处理
        if src.info().playback == .remote {
            let ids = orderedQueue.map(\.id)
            let posMs = Int64(initialSeek * 1000)
            Task {
                do {
                    try await src.remotePlay(ids: ids, start: orderIndex, position: posMs)
                    if !autoPlay {
                        try? await src.remotePause()
                    }
                    if self.loadGeneration == gen {
                        self.isLoading = false
                    }
                } catch let err as SourceError {
                    if self.loadGeneration == gen {
                        self.handleStreamError(err, sourceID: src.info().id)
                    }
                } catch {
                    if self.loadGeneration == gen {
                        self.handleStreamError(.message(error.localizedDescription), sourceID: src.info().id)
                    }
                }
            }
            return
        }

        // 流媒体/本地文件播放处理（优先使用下一首流地址预取缓存）
        let quality = qualityProvider?() ?? "high"
        let trackID = track.id
        let cachedPre = (prefetchedStream?.trackKey == key && prefetchedStream?.quality == quality
            && Date().timeIntervalSince(prefetchedStream!.fetchedAt) < 120)
            ? prefetchedStream?.stream
            : nil
        prefetchedStream = nil
        prefetchAttemptedKey = nil

        Task {
            do {
                let streamInfo: StreamInfo
                if let cachedPre {
                    streamInfo = cachedPre
                } else {
                    streamInfo = try await src.stream(id: trackID, quality: quality)
                }
                guard self.loadGeneration == gen else { return }
                self.currentStream = streamInfo
                self.computeLoudnessGain(streamInfo)
                await self.startAVPlayer(
                    with: streamInfo,
                    track: track,
                    quality: quality,
                    autoPlay: autoPlay,
                    initialSeek: initialSeek,
                    gen: gen
                )
            } catch let err as SourceError {
                guard self.loadGeneration == gen else { return }
                self.handleStreamError(err, sourceID: src.info().id)
            } catch {
                guard self.loadGeneration == gen else { return }
                self.handleStreamError(.message(error.localizedDescription), sourceID: src.info().id)
            }
        }
    }

    private func computeLoudnessGain(_ stream: StreamInfo) {
        guard normalizeProvider?() == true else {
            currentGainLinear = 1.0
            return
        }
        var gainLinear: Double = 1.0
        if let gainDB = stream.gain, gainDB != 0 {
            gainLinear = pow(10.0, gainDB / 20.0)
        }
        if let peak = stream.peak, peak > 0, gainLinear * peak > 1.0 {
            gainLinear = 1.0 / peak
        }
        currentGainLinear = Float(min(max(gainLinear, 0.1), 2.0))
    }

    private func applyPlayerVolume() {
        let effective = Float(volume) * min(currentGainLinear, 1.0) * min(max(currentFadeMultiplier, 0.0), 1.0)
        avPlayer?.volume = min(max(effective, 0.0), 1.0)
    }

    private func animateFade(from start: Float, to end: Float, durationMs: Int, gen: Int) async {
        let steps = max(4, durationMs / 16)
        let sleepNs = UInt64(max(1, durationMs / steps)) * 1_000_000
        for step in 1...steps {
            guard !Task.isCancelled, loadGeneration == gen else { return }
            let progress = Double(step) / Double(steps)
            let eased = Float(0.5 - 0.5 * cos(.pi * progress))
            currentFadeMultiplier = start + (end - start) * eased
            applyPlayerVolume()
            try? await Task.sleep(nanoseconds: sleepNs)
        }
        if !Task.isCancelled, loadGeneration == gen {
            currentFadeMultiplier = end
            applyPlayerVolume()
        }
    }

    /// 重新加载并播放当前曲目
    public func retryCurrentTrack() {
        guard currentOrderIndex >= 0 && currentOrderIndex < order.count else { return }
        loadTrack(atOrderIndex: currentOrderIndex, autoPlay: true, initialSeek: position)
    }

    /// 判断是否必须经由 AudioStreamProxy 代理：仅针对 .m4s 容器或携带自定义请求头的流，其余标准 HTTP/HTTPS 直链优先交给原生 AVURLAsset
    nonisolated public static func shouldUseStreamProxy(url: URL, stream: StreamInfo) -> Bool {
        guard !url.isFileURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        let isHLS = url.pathExtension.lowercased() == "m3u8"
            || (stream.type?.lowercased().contains("mpegurl") == true)
            || url.absoluteString.lowercased().contains(".m3u8")
        if isHLS { return false }

        let isM4S = url.pathExtension.lowercased() == "m4s"
            || (stream.type?.lowercased().contains("m4s") == true)
        if isM4S { return true }

        if let headers = stream.headers {
            for (k, v) in headers {
                let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
                let val = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty && !val.isEmpty {
                    return true
                }
            }
        }
        return false
    }

    private func startAVPlayer(
        with stream: StreamInfo,
        track: Track?,
        quality: String,
        autoPlay: Bool,
        initialSeek: TimeInterval,
        gen: Int,
        forceProxy: Bool = false
    ) async {
        ensureAudioSessionActive()

        let assetURL: URL?
        let rawURL = stream.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawURL.hasPrefix("file://") {
            let stripped = String(rawURL.dropFirst("file://".count))
            let decoded = stripped.removingPercentEncoding ?? stripped
            assetURL = URL(fileURLWithPath: decoded)
        } else if rawURL.hasPrefix("/") {
            assetURL = URL(fileURLWithPath: rawURL)
        } else if let direct = URL(string: rawURL) {
            assetURL = direct
        } else if let encoded = rawURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let fallback = URL(string: encoded) {
            assetURL = fallback
        } else {
            assetURL = nil
        }

        guard let url = assetURL else {
            isLoading = false
            isPlaying = false
            errorMessage = I18n.t("Couldn't play this song")
            return
        }

        let sourceID = track?.source ?? LocalMusicSource.sourceID
        let cacheKey: String? = (!url.isFileURL && track != nil)
            ? AudioDiskCache.cacheKey(sourceID: sourceID, trackID: track!.id, quality: quality)
            : nil
        let isHLS = url.pathExtension.lowercased() == "m3u8"
            || (stream.type?.lowercased().contains("mpegurl") == true)
            || url.absoluteString.lowercased().contains(".m3u8")

        let asset: AVURLAsset
        var usedProxy = false
        if !url.isFileURL, let cacheKey, let cached = diskCache.cachedFileURL(forKey: cacheKey) {
            // 优先从磁盘缓存秒开，零网络延迟并支持原生高精度 Seek
            asset = AVURLAsset(url: cached.fileURL)
        } else if !url.isFileURL && !isHLS && (url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https") && (forceProxy || Self.shouldUseStreamProxy(url: url, stream: stream)) {
            // 对 .m4s、带自定义请求头或直连回退流使用 AudioStreamProxy（保留跨域头与边播边缓）
            usedProxy = true
            var mergedHeaders = stream.headers ?? [:]
            if !mergedHeaders.keys.contains(where: { $0.lowercased() == "user-agent" }) {
                mergedHeaders["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) mygo-music/0.1"
            }
            let proxy = AudioStreamProxy(
                remoteURL: url,
                headers: mergedHeaders,
                streamTypeHint: stream.type,
                cacheKey: cacheKey,
                diskCache: diskCache
            )
            self.activeStreamProxy = proxy
            let proxyAsset = AVURLAsset(url: proxy.makeProxyAssetURL())
            proxyAsset.resourceLoader.setDelegate(proxy, queue: proxy.delegateQueue)
            asset = proxyAsset
        } else {
            asset = AVURLAsset(url: url)
        }

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 10
        let player = AVPlayer(playerItem: item)
        self.avPlayer = player

        if autoPlay && fadeEnabledProvider?() == true {
            currentFadeMultiplier = 0.0
        } else {
            currentFadeMultiplier = 1.0
        }
        applyPlayerVolume()

        // 仅对安全本地非 FLAC 文件挂载 MTAudioProcessingTap，避免远程流媒体/代理流因异步篡改 audioMix 阻塞底层管线
        let isLocalSafeTapTarget = url.isFileURL && url.pathExtension.lowercased() != "flac"
        if isLocalSafeTapTarget {
            let meter = AudioBandMeter()
            Task { [weak self, weak item] in
                guard let item, let tracks = try? await asset.load(.tracks),
                      let audioTrack = tracks.first(where: { $0.mediaType == .audio }),
                      let self, self.loadGeneration == gen,
                      let tap = self.makeAudioTap(for: meter) else {
                    return
                }
                let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
                parameters.audioTapProcessor = tap
                let mix = AVMutableAudioMix()
                mix.inputParameters = [parameters]
                item.audioMix = mix
                self.audioBandMeter = meter
            }
        }

        guard loadGeneration == gen else { return }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard let self, self.loadGeneration == gen else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.errorMessage = nil
                    let durSec = CMTimeGetSeconds(observedItem.duration)
                    if durSec.isFinite && durSec > 0 {
                        self.duration = durSec
                    }
                    if !self.isPlaying {
                        self.isLoading = false
                    } else if self.avPlayer?.timeControlStatus == .playing {
                        self.isLoading = false
                    }
                    if self.isPlaying {
                        self.avPlayer?.play()
                        if self.fadeEnabledProvider?() == true && self.currentFadeMultiplier < 0.99 {
                            self.fadeTask?.cancel()
                            self.fadeTask = Task { [weak self] in
                                await self?.animateFade(from: self?.currentFadeMultiplier ?? 0.0, to: 1.0, durationMs: 220, gen: gen)
                            }
                        }
                    }
                    self.updateNowPlayingCenter()
                case .failed:
                    // 若直连 AVURLAsset 失败且尚未回退代理，自动用带桌面 UA 的 AudioStreamProxy 重试一次
                    if !usedProxy && !forceProxy && !url.isFileURL && !isHLS {
                        self.cleanupAVPlayer()
                        await self.startAVPlayer(
                            with: stream,
                            track: track,
                            quality: quality,
                            autoPlay: autoPlay,
                            initialSeek: initialSeek,
                            gen: gen,
                            forceProxy: true
                        )
                        return
                    }
                    self.isLoading = false
                    self.isPlaying = false
                    let comment = observedItem.errorLog()?.events.last?.errorComment
                    let baseMsg = observedItem.error?.localizedDescription ?? I18n.t("Couldn't play this song")
                    self.errorMessage = (comment?.isEmpty == false && !baseMsg.contains(comment!))
                        ? "\(baseMsg) (\(comment!))"
                        : baseMsg
                    self.updateNowPlayingCenter()
                default:
                    break
                }
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] observedPlayer, _ in
            Task { @MainActor in
                guard let self, self.loadGeneration == gen else { return }
                switch observedPlayer.timeControlStatus {
                case .playing:
                    self.isLoading = false
                case .paused:
                    if !self.isPlaying {
                        self.isLoading = false
                    }
                case .waitingToPlayAtSpecifiedRate:
                    if self.isPlaying {
                        self.isLoading = true
                    }
                @unknown default:
                    break
                }
            }
        }

        // 桌面舞台按约 30fps 绘制；iOS 也以 30fps 提供连续的逐字动画时间。
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == gen, !self.isSeeking else { return }
                let sec = CMTimeGetSeconds(time)
                if sec.isFinite && sec >= 0 {
                    self.position = sec
                    self.syncNowPlayingLyricsIfNeeded(at: sec)
                }
                if let itemDur = self.avPlayer?.currentItem?.duration {
                    let durSec = CMTimeGetSeconds(itemDur)
                    if durSec.isFinite && durSec > 0 {
                        self.duration = durSec
                    }
                }
                if self.isLoading && (sec > 0.05 || self.avPlayer?.timeControlStatus == .playing || !self.isPlaying) {
                    self.isLoading = false
                }
                if self.duration > 0 && (self.duration - sec <= 35 || sec >= 5 && self.duration <= 25) {
                    self.maybePrefetchNextTrack()
                }
            }
        }
        rebuildLyricBoundaryObserver()

        stalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.loadGeneration == gen else { return }
                if self.isPlaying {
                    self.isLoading = true
                    self.avPlayer?.play()
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleTrackEnded()
            }
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, self.loadGeneration == gen else { return }
                if !usedProxy && !forceProxy && !url.isFileURL && !isHLS {
                    self.cleanupAVPlayer()
                    await self.startAVPlayer(
                        with: stream,
                        track: track,
                        quality: quality,
                        autoPlay: autoPlay,
                        initialSeek: initialSeek,
                        gen: gen,
                        forceProxy: true
                    )
                    return
                }
                self.isLoading = false
                self.isPlaying = false
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self.errorMessage = err?.localizedDescription ?? I18n.t("Couldn't play this song")
            }
        }

        if initialSeek > 0 {
            let cm = CMTime(seconds: initialSeek, preferredTimescale: 600)
            player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        }

        if autoPlay || isPlaying {
            player.play()
            isPlaying = true
            isLoading = player.timeControlStatus != .playing
            if fadeEnabledProvider?() == true && currentFadeMultiplier < 0.99 {
                fadeTask?.cancel()
                fadeTask = Task { [weak self] in
                    await self?.animateFade(from: self?.currentFadeMultiplier ?? 0.0, to: 1.0, durationMs: 220, gen: gen)
                }
            }
        } else {
            isLoading = false
        }
        updateNowPlayingCenter()
        maybePrefetchRadio()
    }

    /// 当当前曲目即将结束时提前解析下一首流地址，实现无缝切歌
    private func maybePrefetchNextTrack() {
        guard !order.isEmpty, currentOrderIndex >= 0 else { return }
        let nextOrderIdx: Int
        if currentOrderIndex + 1 < order.count {
            nextOrderIdx = currentOrderIndex + 1
        } else if repeatMode == .all, order.count > 1 {
            nextOrderIdx = 0
        } else {
            return
        }

        let queueIdx = order[nextOrderIdx]
        guard queueIdx >= 0 && queueIdx < queue.count else { return }
        let nextTrack = queue[queueIdx]
        let nextKey = nextTrack.compositeKey
        guard prefetchAttemptedKey != nextKey else { return }
        prefetchAttemptedKey = nextKey

        guard let nextSrc = sourceForTrack(nextTrack), nextSrc.info().playback != .remote else { return }
        let quality = qualityProvider?() ?? "high"
        let trackID = nextTrack.id
        Task { [weak self] in
            guard let nextStream = try? await nextSrc.stream(id: trackID, quality: quality) else { return }
            await MainActor.run {
                guard let self, self.currentTrack?.compositeKey != nextKey else { return }
                self.prefetchedStream = (nextKey, quality, nextStream, Date())
            }
        }
    }

    private func handleTrackEnded() {
        if repeatMode == .one {
            seek(to: 0)
            resume()
            return
        }
        if currentOrderIndex + 1 >= order.count {
            if radioFeed != nil {
                Task { await appendRadioTracksAndAdvance() }
                return
            }
            if repeatMode == .off {
                isPlaying = false
                updateNowPlayingCenter()
                return
            }
        }
        next()
    }

    private func handleStreamError(_ err: SourceError, sourceID: String) {
        isLoading = false
        isPlaying = false
        errorMessage = err.localizedDescription
        switch err {
        case .signIn, .setup:
            onSourceFailure?(sourceID, err)
        default:
            break
        }
    }

    private func maybePrefetchRadio() {
        guard let feed = radioFeed, !isFetchingRadio, order.count - currentOrderIndex <= 2 else { return }
        isFetchingRadio = true
        Task {
            let more = await feed()
            self.isFetchingRadio = false
            guard self.radioFeed != nil, !more.isEmpty else { return }
            let startIdx = self.queue.count
            self.queue.append(contentsOf: more)
            for i in 0..<more.count {
                self.order.append(startIdx + i)
            }
        }
    }

    private func appendRadioTracksAndAdvance() async {
        guard let feed = radioFeed, !isFetchingRadio else { return }
        isFetchingRadio = true
        let more = await feed()
        isFetchingRadio = false
        guard !more.isEmpty else {
            isPlaying = false
            errorMessage = I18n.t("The station has nothing more right now")
            return
        }
        let startIdx = queue.count
        queue.append(contentsOf: more)
        for i in 0..<more.count {
            order.append(startIdx + i)
        }
        loadTrack(atOrderIndex: currentOrderIndex + 1, autoPlay: true)
    }

    private func cleanupAVPlayer() {
        isSeeking = false
        fadeTask?.cancel()
        fadeTask = nil
        currentFadeMultiplier = 1.0
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let obs = timeObserver {
            avPlayer?.removeTimeObserver(obs)
            timeObserver = nil
        }
        if let bObs = boundaryTimeObserver {
            avPlayer?.removeTimeObserver(bObs)
            boundaryTimeObserver = nil
        }
        if let stalledObs = stalledObserver {
            NotificationCenter.default.removeObserver(stalledObs)
            stalledObserver = nil
        }
        if let endObs = endObserver {
            NotificationCenter.default.removeObserver(endObs)
            endObserver = nil
        }
        if let failObs = failObserver {
            NotificationCenter.default.removeObserver(failObs)
            failObserver = nil
        }
        avPlayer?.pause()
        avPlayer = nil
        activeStreamProxy?.invalidate()
        activeStreamProxy = nil
        audioBandMeter = nil
        audioBands = [0.12, 0.12, 0.12, 0.12, 0.12]
    }

    private func makeAudioTap(for meter: AudioBandMeter) -> MTAudioProcessingTap? {
        let retainedMeter = Unmanaged.passRetained(meter).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retainedMeter,
            init: audioTapInit,
            finalize: audioTapFinalize,
            prepare: audioTapPrepare,
            unprepare: audioTapUnprepare,
            process: audioTapProcess
        )
        var unmanagedTap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &unmanagedTap
        )
        guard status == noErr, let unmanagedTap else {
            Unmanaged<AudioBandMeter>.fromOpaque(retainedMeter).release()
            return nil
        }
        return unmanagedTap.takeRetainedValue()
    }

    // MARK: - iOS 系统音频会话与锁屏控制中心

    private func configureAudioSession() {
        ensureAudioSessionActive()
    }

    private func ensureAudioSessionActive() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("AVAudioSession configuration failed: \(error)")
        }
        #endif
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: posEvent.positionTime) }
            return .success
        }
    }

    /// 供设置切换后外部主动刷新锁屏媒体栏信息
    public func refreshNowPlayingInfo() {
        updateNowPlayingCenter()
    }

    /// 生成锁屏 / 控制中心展示元数据：开启锁屏歌词且命中非空歌词行时，将主标题替换为当前歌词并保留歌名
    nonisolated public static func buildNowPlayingDisplayMetadata(
        track: Track,
        lyrics: [LyricLine],
        position: Double,
        lockScreenLyricsEnabled: Bool
    ) -> NowPlayingDisplayMetadata {
        let fallback = NowPlayingDisplayMetadata(
            title: track.name,
            artist: track.artistNames,
            albumTitle: track.album.name,
            lyricIndex: nil
        )
        guard lockScreenLyricsEnabled, !lyrics.isEmpty else {
            return fallback
        }
        let idx = LyricsEngine.index(in: lyrics, at: position)
        guard idx >= 0, idx < lyrics.count else {
            return fallback
        }
        let line = lyrics[idx]
        let lyricText = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lyricText.isEmpty else {
            return fallback
        }
        let translation = line.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle: String
        if !translation.isEmpty {
            subtitle = "\(translation) · \(track.name)"
        } else if track.artistNames.isEmpty {
            subtitle = track.name
        } else {
            subtitle = "\(track.name) - \(track.artistNames)"
        }
        return NowPlayingDisplayMetadata(
            title: lyricText,
            artist: subtitle,
            albumTitle: track.album.name,
            lyricIndex: idx
        )
    }

    /// 为每句歌词时间点注册 CoreMedia 边界观察者，保证后台锁屏休眠期间切句也能及时触发刷新
    private func rebuildLyricBoundaryObserver() {
        if let existing = boundaryTimeObserver {
            avPlayer?.removeTimeObserver(existing)
            boundaryTimeObserver = nil
        }
        guard let player = avPlayer, !lyrics.isEmpty else { return }

        var boundaryTimes: [NSValue] = []
        boundaryTimes.reserveCapacity(min(lyrics.count, 1500))
        var lastTimestamp = -1.0
        for line in lyrics {
            // 延后 20ms 踩点，确保 CoreMedia 读取 currentTime() 稳定跨越该句边界
            let triggerTime = max(0.02, line.at + 0.02)
            if triggerTime - lastTimestamp >= 0.05 {
                let cm = CMTime(seconds: triggerTime, preferredTimescale: 600)
                boundaryTimes.append(NSValue(time: cm))
                lastTimestamp = triggerTime
                if boundaryTimes.count >= 1500 { break }
            }
        }
        guard !boundaryTimes.isEmpty else { return }

        let gen = loadGeneration
        boundaryTimeObserver = player.addBoundaryTimeObserver(forTimes: boundaryTimes, queue: .main) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.loadGeneration == gen,
                      !self.isSeeking,
                      let currentPlayer = self.avPlayer else { return }
                let sec = CMTimeGetSeconds(currentPlayer.currentTime())
                if sec.isFinite && sec >= 0 {
                    self.position = sec
                    self.syncNowPlayingLyricsIfNeeded(at: sec)
                }
            }
        }
    }

    /// 仅当锁屏歌词行或曲目展示元数据确实变化时刷新 MPNowPlayingInfoCenter，避免高频写入被系统限流
    private func syncNowPlayingLyricsIfNeeded(at sec: TimeInterval) {
        guard let tr = currentTrack else { return }
        let enabled = lockScreenLyricsProvider?() ?? true
        let nextMeta = Self.buildNowPlayingDisplayMetadata(
            track: tr,
            lyrics: lyrics,
            position: sec,
            lockScreenLyricsEnabled: enabled
        )
        if nextMeta != lastPublishedNowPlayingMeta {
            updateNowPlayingCenter()
        }
    }

    private func updateNowPlayingCenter() {
        guard let tr = currentTrack else {
            lockScreenArtwork = nil
            lastPublishedNowPlayingMeta = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let enabled = lockScreenLyricsProvider?() ?? true
        let meta = Self.buildNowPlayingDisplayMetadata(
            track: tr,
            lyrics: lyrics,
            position: position,
            lockScreenLyricsEnabled: enabled
        )
        lastPublishedNowPlayingMeta = meta

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: meta.title,
            MPMediaItemPropertyArtist: meta.artist,
            MPMediaItemPropertyAlbumTitle: meta.albumTitle,
            MPMediaItemPropertyMediaType: MPMediaType.music.rawValue,
            MPMediaItemPropertyPlaybackDuration: duration > 0 ? duration : tr.durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if let lockScreenArtwork {
            info[MPMediaItemPropertyArtwork] = lockScreenArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    #if canImport(UIKit)
    public func setNowPlayingArtwork(data: Data?) {
        if let data, let image = UIImage(data: data) {
            lockScreenArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        } else {
            lockScreenArtwork = nil
        }
        updateNowPlayingCenter()
    }
    #endif

    private func startBandUpdateTimer() {
        bandTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickAudioBands()
            }
        }
    }

    private func tickAudioBands() {
        let idleBands: [Float] = [0.12, 0.12, 0.12, 0.12, 0.12]
        guard isPlaying, !isLoading else {
            if audioBands != idleBands { audioBands = idleBands }
            return
        }
        let target: [Float]
        if let meter = audioBandMeter {
            target = meter.readBands()
        } else {
            // 在线流未挂载 MTAudioProcessingTap 时使用平滑律动估计，避免阻塞 CoreMedia 音频管线
            syntheticBandPhase += 0.35
            let p = syntheticBandPhase
            var synthetic: [Float] = []
            synthetic.reserveCapacity(Self.bandCount)
            for idx in 0..<Self.bandCount {
                let freq = 1.0 + Double(idx) * 0.27
                let wave = 0.5 + 0.5 * sin(p * freq + Double(idx) * 1.1)
                synthetic.append(Float(0.18 + 0.55 * wave))
            }
            target = synthetic
        }
        audioBands = zip(audioBands, target).map { current, next in
            current + (next - current) * 0.42
        }
    }
}

// PlayerEngine.swift
// 对应原项目 internal/player/player.go, remote.go, cache.go 的播放队列与音频引擎

import AVFoundation
import Combine
import Foundation
import MediaPlayer
import MediaToolbox
import Darwin
#if canImport(UIKit)
import UIKit
#endif


private final class AudioBandMeter: @unchecked Sendable {
    private var packedLowBands: Int32 = 0x1F1F1F1F
    private var packedHighBand: Int32 = 0x1F
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
        let low = UInt32(bitPattern: OSAtomicAdd32Barrier(0, &packedLowBands))
        let high = UInt32(bitPattern: OSAtomicAdd32Barrier(0, &packedHighBand))
        return [
            Float(low & 0xFF) / 255,
            Float((low >> 8) & 0xFF) / 255,
            Float((low >> 16) & 0xFF) / 255,
            Float((low >> 24) & 0xFF) / 255,
            Float(high & 0xFF) / 255
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
        Self.atomicStore(Int32(bitPattern: UInt32(truncatingIfNeeded: packed)), to: &packedLowBands)
        Self.atomicStore(Int32(bitPattern: UInt32(truncatingIfNeeded: packed >> 32)), to: &packedHighBand)
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

    private static func atomicStore(_ newValue: Int32, to storage: inout Int32) {
        while true {
            let oldValue = OSAtomicAdd32Barrier(0, &storage)
            if OSAtomicCompareAndSwap32Barrier(oldValue, newValue, &storage) { return }
        }
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

/// 音频磁盘缓存管理器（对应 internal/player/cache.go）
public final class AudioDiskCache: @unchecked Sendable {
    public let cacheDir: URL
    private let lock = NSLock()
    public var limitMB: Int = 2048

    public init(cacheDir: URL) {
        self.cacheDir = cacheDir
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    public func usedBytes() -> Int64 {
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
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for f in files {
            try? fm.removeItem(at: f)
        }
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

    public var sourceResolver: ((String) -> MusicSource?)?
    public var qualityProvider: (() -> String)?
    public var normalizeProvider: (() -> Bool)?
    public var onSourceFailure: ((String, SourceError) -> Void)?
    public var onSessionChanged: (() -> Void)?

    public let diskCache: AudioDiskCache

    private var avPlayer: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var loadGeneration: Int = 0
    private var currentGainLinear: Float = 1.0
    private var radioFeed: (() async -> [Track])? = nil
    private var isFetchingRadio: Bool = false
    private var recordedTrackKey: String? = nil
    private var bandTimer: Timer?
    private var audioBandMeter: AudioBandMeter?
    private var lockScreenArtwork: MPMediaItemArtwork?

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
        avPlayer?.pause()
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
        isPlaying = true
        if let player = avPlayer {
            player.play()
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

        // 流媒体/本地文件播放处理
        let quality = qualityProvider?() ?? "high"
        let trackID = track.id
        Task {
            do {
                let streamInfo = try await src.stream(id: trackID, quality: quality)
                guard self.loadGeneration == gen else { return }
                self.currentStream = streamInfo
                self.computeLoudnessGain(streamInfo)
                await self.startAVPlayer(with: streamInfo, autoPlay: autoPlay, initialSeek: initialSeek, gen: gen)
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
        let effective = Float(volume) * min(currentGainLinear, 1.0)
        avPlayer?.volume = min(max(effective, 0.0), 1.0)
    }

    /// 重新加载并播放当前曲目
    public func retryCurrentTrack() {
        guard currentOrderIndex >= 0 && currentOrderIndex < order.count else { return }
        loadTrack(atOrderIndex: currentOrderIndex, autoPlay: true, initialSeek: position)
    }

    private func startAVPlayer(with stream: StreamInfo, autoPlay: Bool, initialSeek: TimeInterval, gen: Int) async {
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

        var options: [String: Any] = [:]
        if !url.isFileURL {
            var mergedHeaders = stream.headers ?? [:]
            if !mergedHeaders.keys.contains(where: { $0.lowercased() == "user-agent" }) {
                mergedHeaders["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) mygo-music/0.1"
            }
            options["AVURLAssetHTTPHeaderFieldsKey"] = mergedHeaders
        }

        let asset = AVURLAsset(url: url, options: options.isEmpty ? nil : options)
        let item = AVPlayerItem(asset: asset)
        let meter = AudioBandMeter()
        if let tracks = try? await asset.load(.tracks),
           let audioTrack = tracks.first(where: { $0.mediaType == .audio }),
           loadGeneration == gen,
           let tap = makeAudioTap(for: meter) {
            let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
            audioBandMeter = meter
        }
        guard loadGeneration == gen else { return }

        let player = AVPlayer(playerItem: item)
        self.avPlayer = player
        applyPlayerVolume()

        if initialSeek > 0 {
            let cm = CMTime(seconds: initialSeek, preferredTimescale: 600)
            _ = await player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard let self, self.loadGeneration == gen else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.isLoading = false
                    self.errorMessage = nil
                    let durSec = CMTimeGetSeconds(observedItem.duration)
                    if durSec.isFinite && durSec > 0 {
                        self.duration = durSec
                    }
                    if self.isPlaying {
                        self.avPlayer?.play()
                    }
                    self.updateNowPlayingCenter()
                case .failed:
                    self.isLoading = false
                    self.isPlaying = false
                    self.errorMessage = observedItem.error?.localizedDescription ?? I18n.t("Couldn't play this song")
                    self.updateNowPlayingCenter()
                default:
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
                }
                if let itemDur = self.avPlayer?.currentItem?.duration {
                    let durSec = CMTimeGetSeconds(itemDur)
                    if durSec.isFinite && durSec > 0 {
                        self.duration = durSec
                    }
                }
                if self.isLoading && (self.avPlayer?.timeControlStatus == .playing || !autoPlay) {
                    self.isLoading = false
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
                self.isLoading = false
                self.isPlaying = false
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self.errorMessage = err?.localizedDescription ?? I18n.t("Couldn't play this song")
            }
        }

        isLoading = false
        if autoPlay || isPlaying {
            player.play()
            isPlaying = true
        }
        updateNowPlayingCenter()
        maybePrefetchRadio()
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
        statusObservation?.invalidate()
        statusObservation = nil
        if let obs = timeObserver {
            avPlayer?.removeTimeObserver(obs)
            timeObserver = nil
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

    private func updateNowPlayingCenter() {
        guard let tr = currentTrack else {
            lockScreenArtwork = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: tr.name,
            MPMediaItemPropertyArtist: tr.artistNames,
            MPMediaItemPropertyAlbumTitle: tr.album.name,
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
        let idleBands: [Float] = [0.12, 0.12, 0.12, 0.12, 0.12]
        bandTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isPlaying, !self.isLoading, let meter = self.audioBandMeter else {
                    if self.audioBands != idleBands { self.audioBands = idleBands }
                    return
                }
                let target = meter.readBands()
                self.audioBands = zip(self.audioBands, target).map { current, next in
                    current + (next - current) * 0.42
                }
            }
        }
    }
}

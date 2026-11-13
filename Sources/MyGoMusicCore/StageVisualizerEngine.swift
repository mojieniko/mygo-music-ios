// StageVisualizerEngine.swift
// 对照桌面原版 internal/app/ui_stage.go, ui_stage_styles.go, ui_quiet.go 的高标准律动引擎与音律状态模型

import CoreGraphics
import Foundation

/// 实时音频节拍与五频段频谱快照（供 60fps 律动舞台、烟雾进度条与极光背景同步消费）
public struct AudioRhythmState: Equatable, Sendable {
    /// 5 个对数音阶频段能量（0...1）：超低底鼓、低中贝斯、中频人声、中高泛音、高频空气感
    public var bands: [Float]
    /// 低频鼓点与贝斯驱动能量（0...1）
    public var bass: Double
    /// 中频人声主线共振能量（0...1）
    public var vocal: Double
    /// 高频闪烁与齿音泛音能量（0...1）
    public var treble: Double
    /// 综合听感响度（0...1）
    public var energy: Double
    /// 重音瞬态脉冲（0...1，踩中底鼓或强拍瞬间跃升并弹性回落）
    public var beatPulse: Double
    /// true 表示来自真实音频 FFT 解码/实时 Tap 采样；false 表示歌词音节与拍速智能推演
    public var isRealAudio: Bool

    public init(
        bands: [Float],
        bass: Double,
        vocal: Double,
        treble: Double,
        energy: Double,
        beatPulse: Double,
        isRealAudio: Bool
    ) {
        self.bands = bands
        self.bass = bass
        self.vocal = vocal
        self.treble = treble
        self.energy = energy
        self.beatPulse = beatPulse
        self.isRealAudio = isRealAudio
    }

    public static let idle = AudioRhythmState(
        bands: [0.12, 0.12, 0.12, 0.12, 0.12],
        bass: 0.12,
        vocal: 0.12,
        treble: 0.12,
        energy: 0.12,
        beatPulse: 0.0,
        isRealAudio: false
    )

    /// 面向 60fps 渲染的平滑攻击/衰减包络滤波器（快起落不拖泥带水）
    public func smoothed(from previous: AudioRhythmState, dt: TimeInterval) -> AudioRhythmState {
        let clampedDt = min(max(dt, 1.0 / 240.0), 0.12)
        func follow(_ cur: Double, _ target: Double, attackRate: Double, decayRate: Double) -> Double {
            let rate = target >= cur ? attackRate : decayRate
            let alpha = 1.0 - exp(-clampedDt * rate)
            return cur + (target - cur) * alpha
        }
        var nextBands = [Float](repeating: 0.12, count: 5)
        for i in 0..<5 {
            let cur = i < previous.bands.count ? Double(previous.bands[i]) : 0.12
            let tgt = i < bands.count ? Double(bands[i]) : 0.12
            nextBands[i] = Float(follow(cur, tgt, attackRate: 30.0, decayRate: 9.5))
        }
        return AudioRhythmState(
            bands: nextBands,
            bass: follow(previous.bass, bass, attackRate: 34.0, decayRate: 8.8),
            vocal: follow(previous.vocal, vocal, attackRate: 26.0, decayRate: 10.5),
            treble: follow(previous.treble, treble, attackRate: 32.0, decayRate: 12.0),
            energy: follow(previous.energy, energy, attackRate: 28.0, decayRate: 9.5),
            beatPulse: follow(previous.beatPulse, beatPulse, attackRate: 48.0, decayRate: 11.5),
            isRealAudio: isRealAudio
        )
    }
}

/// Flow（流光）模式行级舞台落位（对齐桌面 ui_stage.go:214-215）
public struct StageFlowPlacement: Equatable, Sendable {
    public enum HorizontalAlignment: Int, Sendable {
        case leading = 0
        case center = 1
        case trailing = 2
    }

    public var alignment: HorizontalAlignment
    public var verticalShiftRatio: Double
}

/// Steps（云阶）模式单排导标状态与运动参数
public struct StagePartitaRowMotion: Equatable, Sendable {
    public enum GuideState: Sendable {
        case upcoming
        case singing
        case past
    }

    public var offsetX: Double
    public var offsetY: Double
    public var scale: Double
    public var opacity: Double
    public var guideProgress: Double
    public var guideState: GuideState
    public var guideAlpha: Double
}

/// Tilt（倾诉）模式单段文本的排版与缩放结果
public struct StageTiltLayout: Equatable, Sendable {
    public var parts: [TiltPart]
    public var fontSize: Double
    public var fittedLineRatio: Double
}

/// Tilt（倾诉）模式单个字符的实时形变与火花触发状态
public struct StageTiltCharMotion: Equatable, Sendable {
    public var opacity: Double
    public var scale: Double
    public var waveOffsetY: Double
    public var highlightStrength: Double
}

/// Tilt（倾诉）模式单段整体进场运动参数
public struct StageTiltPartMotion: Equatable, Sendable {
    public var opacity: Double
    public var riseOffsetY: Double
    public var scale: Double
    public var fontSize: Double
    public var isLightWeight: Bool
    public var isItalic: Bool
    public var tracking: Double
    public var spaceWidth: Double
    public var useAccentColor: Bool
}

/// 放射光束火花粒子的单帧几何轨迹（桌面 stageSparks 1:1 线段光束还原 + 音律爆发强化）
public struct StageSparkStreak: Equatable, Sendable {
    public var startX: Double
    public var startY: Double
    public var endX: Double
    public var endY: Double
    public var lineWidth: Double
    public var whiteMix: Double
    public var alpha: Double
}

/// 静音期热评匹配状态（对齐桌面 ui_quiet.go）
public struct StageQuietCommentResult: Equatable, Sendable {
    public var comment: Comment
    public var slotIndex: Int
    public var quietIndex: Int
}

/// 间奏三圆点呼吸与节拍状态
public struct StageInterludeDotsState: Equatable, Sendable {
    public var progress: Double
    public var dotLit: [Double]
    public var breathScale: Double
    public var preCuePulse: Double
}

public extension StageMath {
    /// Flow / Steps 模式单字预入场引线（对应 ui_stage.go lookahead = 80ms）
    static let wordLookahead: TimeInterval = 0.08
    /// 旧行叠化退场时长（对应 ui_stage.go 0.4s）
    static let lineExitDuration: TimeInterval = 0.40

    /// 统一舞台歌词同步时间计算（直接接管高精度播放时钟与拖动预览时钟）
    static func stagePosition(
        playbackPosition: TimeInterval,
        scrubbingPosition: TimeInterval?,
        syncLead: TimeInterval = 0.025
    ) -> TimeInterval {
        if let scrubbingPosition {
            return max(0, scrubbingPosition)
        }
        return max(0, playbackPosition + syncLead)
    }

    /// 当真实音频尚未完成缓存扫谱前，基于歌词音节与句间节拍推断的乐感节奏包络
    static func lyricRhythm(
        at pos: TimeInterval,
        lines: [LyricLine],
        isPlaying: Bool
    ) -> AudioRhythmState {
        guard isPlaying else { return .idle }

        let curIdx = LyricsEngine.index(in: lines, at: pos)
        var beatPeriod: Double = 0.50
        var onsetImpulse: Double = 0.0
        var activePhraseEnergy: Double = 0.22
        var isVocalActive = false

        if curIdx >= 0, curIdx < lines.count {
            let line = lines[curIdx]
            // 由当前行平均逐字间隔推导自然节拍周期，钳制在常见音乐 88~142 BPM 之间
            if line.words.count >= 3 {
                let firstAt = line.words.first!.start
                let lastAt = line.words.last!.start
                let avgWord = max(0.14, (lastAt - firstAt) / Double(line.words.count - 1))
                let estBeat = avgWord * 2.0
                beatPeriod = min(0.68, max(0.42, estBeat))
            }

            if pos <= line.end + 0.15 {
                isVocalActive = true
                // 查找刚刚起唱或正在演唱的字，提取起唱瞬间爆发脉冲
                for word in line.words {
                    let wordEnd = max(word.end, word.start + 0.15)
                    let since = pos - word.start
                    if since >= -0.02 && pos <= wordEnd + 0.25 {
                        if since >= -0.02 {
                            onsetImpulse = max(onsetImpulse, exp(-max(0, since) * 9.5))
                        }
                        let dur = max(0.12, wordEnd - word.start)
                        let sustain = 1.0 - clamp01(max(0, since) / dur) * 0.35
                        activePhraseEnergy = max(activePhraseEnergy, 0.44 + 0.38 * sustain)
                    }
                }
            } else {
                activePhraseEnergy = 0.18
            }
        }

        // 节拍鼓点周期包络（主鼓在整拍 0.0 处脉冲，次重拍在 0.5 处轻起）
        let beatPhase = (pos / beatPeriod).truncatingRemainder(dividingBy: 1.0)
        let normPhase = beatPhase < 0 ? beatPhase + 1.0 : beatPhase
        let kickDecay = exp(-normPhase * 6.8)
        let halfBeatPhase = normPhase >= 0.5 ? (normPhase - 0.5) : (normPhase + 0.5)
        let snareDecay = exp(-halfBeatPhase * 9.2) * (isVocalActive ? 0.65 : 0.35)

        let bass = min(1.0, (isVocalActive ? 0.24 : 0.15) + 0.48 * kickDecay + 0.18 * onsetImpulse)
        let subBass = min(1.0, (isVocalActive ? 0.22 : 0.14) + 0.54 * kickDecay)
        let vocal = min(1.0, activePhraseEnergy + 0.32 * onsetImpulse)
        let highMid = min(1.0, (isVocalActive ? 0.26 : 0.14) + 0.38 * snareDecay + 0.22 * onsetImpulse)
        let treble = min(1.0, (isVocalActive ? 0.20 : 0.12) + 0.35 * snareDecay + 0.12 * sin(pos * 4.2))
        let energy = min(1.0, bass * 0.42 + vocal * 0.40 + treble * 0.18)
        let beatPulse = min(1.0, max(kickDecay * (isVocalActive ? 0.82 : 0.45), onsetImpulse * 0.88))

        return AudioRhythmState(
            bands: [Float(subBass), Float(bass), Float(vocal), Float(highMid), Float(treble)],
            bass: bass,
            vocal: vocal,
            treble: treble,
            energy: energy,
            beatPulse: beatPulse,
            isRealAudio: false
        )
    }

    /// Flow（流光）行级对齐与垂直层次偏移（对标桌面 ui_stage.go，混洗消除整数秒节拍锁死同角的问题）
    static func flowPlacement(for line: LyricLine, containerWidth: Double) -> StageFlowPlacement {
        let ms = UInt64(max(0, Int((line.at * 1000.0).rounded())))
        let charCount = wordsLength(line.words[...])

        // SplitMix 混洗时间戳与字数，避免每 3 秒一句时 (at*1000)%3 恒为 0 锁死在左上角
        var h1 = ms &* 0x9E3779B97F4A7C15
        h1 ^= UInt64(max(1, charCount)) &* 0xBF58476D1CE4E5B9
        h1 = (h1 ^ (h1 >> 30)) &* 0xBF58476D1CE4E5B9
        h1 ^= (h1 >> 27)
        let firstScalar = UInt64(line.text.unicodeScalars.first?.value ?? 0)
        var h2 = (h1 &* 0x94D049BB133111EB) ^ firstScalar
        h2 ^= (h2 >> 31)

        let rawAlign = Int(h1 % 3)
        let align: StageFlowPlacement.HorizontalAlignment
        if containerWidth < 360 && charCount > 16 {
            align = .center
        } else {
            align = StageFlowPlacement.HorizontalAlignment(rawValue: rawAlign) ?? .center
        }

        let verticalOptions = [-0.11, 0.0, 0.09]
        let vIdx = Int(h2 % UInt64(verticalOptions.count))
        return StageFlowPlacement(alignment: align, verticalShiftRatio: verticalOptions[vIdx])
    }

    /// 旧行叠化退场不透明度（对应 ui_stage.go:138-140: 0.4s easeOutCubic）
    static func lineExitOpacity(nextLineStart: TimeInterval, at pos: TimeInterval) -> Double {
        let gone = (pos - nextLineStart) / lineExitDuration
        guard gone >= 0, gone < 1 else { return 0 }
        return max(0, 1.0 - easeOutCubic(gone))
    }

    /// 升级版 Flow/Steps 单字物理渲染状态（完全还原桌面散落/旋转/缩放/余韵，且融入音律能量脉冲）
    /// 注：保留未唱字微弱预显（opacity >= 0.24），确保手机竖屏下整句可预先辨认而不缺字
    static func stageWordState(
        word: LyricWord,
        shape: WordShape,
        pos: TimeInterval,
        rhythm: AudioRhythmState = .idle,
        horizontalSpreadScale: Double = 0.65
    ) -> WordRenderState {
        let start = word.start - wordLookahead
        let end = max(word.end, word.start + 0.15)
        let since = pos - start
        let after = pos - end
        let singing = max(0.08, end - word.start)

        // 待唱初始偏移（对标桌面 ui_stage.go:237-238 的 sin/cos 散落，再适配竖屏安全幅度）
        let spread = max(0.35, horizontalSpreadScale)
        let waitX = shape.x * spread + sin(shape.y) * 46.0 * spread
        let waitY = shape.y * spread + cos(shape.x) * 24.0 * spread

        var x = waitX
        var y = waitY
        var scale = 0.72
        var rotate = shape.rotate + 14.0
        var opacity = 0.24
        var blur = 3.0
        var brightness = 0.56
        var glow = 0.0

        // 实时音律增益（低频踩拍与中频人声协同调制，节制峰值放大倍率防相邻汉字互相挤压碰撞）
        let vocalBoost = rhythm.vocal
        let pulseBoost = rhythm.beatPulse
        let bassBoost = rhythm.bass
        let peakScale = shape.scale * (1.18 + 0.06 * vocalBoost + 0.05 * pulseBoost)

        if since > 0 {
            let e = springStep(since)
            x = lerp(waitX, shape.x * spread, e)
            y = lerp(waitY, shape.y * spread, e)
            scale = lerp(0.72, peakScale, e)
            rotate = lerp(shape.rotate + 14.0, shape.rotate, e)
            opacity = lerp(0.24, 1.0, clamp01(since / 0.09))
            blur = 3.0 * (1.0 - clamp01(since / 0.16))
            brightness = lerp(0.56, 1.0, clamp01(since / singing))
            glow = clamp01(since / max(0.08, 0.28 * singing)) * (0.72 + 0.34 * vocalBoost + 0.24 * bassBoost)
        }

        if after > 0 {
            let q = easeOutCubic(after / 0.5)
            scale = lerp(peakScale, shape.scale, q)
            opacity = lerp(1.0, 0.80, q)
            rotate = shape.rotate + shape.drift * clamp01(after / 5.0)
            brightness = lerp(1.0, 0.54, easeOutCubic(after / 0.8))
            glow = max(0, (1.0 - clamp01(after / 0.9)) * (0.72 + 0.28 * bassBoost))
        }

        return WordRenderState(
            x: x,
            y: y,
            scale: scale,
            rotate: rotate,
            opacity: opacity,
            blur: blur,
            brightness: brightness,
            glow: glow,
            sparkSince: pos - word.start
        )
    }

    /// Steps（云阶 / Partita）整排运动与直角导标状态（1:1 对标 ui_stage_styles.go:194-268）
    static func partitaRowMotion(
        words: ArraySlice<LyricWord>,
        row: PartitaRow,
        pos: TimeInterval,
        rhythm: AudioRhythmState = .idle
    ) -> StagePartitaRowMotion {
        guard let first = words.first, let last = words.last else {
            return StagePartitaRowMotion(
                offsetX: row.x,
                offsetY: row.y,
                scale: 1,
                opacity: 1,
                guideProgress: 0,
                guideState: .upcoming,
                guideAlpha: 0.14
            )
        }

        let since = pos - (first.start - wordLookahead)
        let lastEnd = max(last.end, last.start + 0.15)
        let endAfter = pos - lastEnd
        let side = row.left ? -36.0 : 36.0

        var x = row.x * 0.45 + side
        var scale = 0.86
        var opacity = 0.16

        if since > 0 {
            let e = springStep(since)
            x = lerp(row.x * 0.45 + side, row.x * 0.45, e)
            scale = lerp(0.86, 1.0, e)
            opacity = lerp(0.16, 1.0, clamp01(since / 0.10))
        }

        let guideProgress = since > 0 ? easeOutCubic(since / 0.40) : 0.0
        let guideState: StagePartitaRowMotion.GuideState
        let guideAlpha: Double
        if endAfter > 0 {
            guideState = .past
            guideAlpha = 0.24
        } else if since > 0 {
            guideState = .singing
            guideAlpha = min(1.0, 0.85 + 0.15 * rhythm.vocal + 0.15 * rhythm.beatPulse)
        } else {
            guideState = .upcoming
            guideAlpha = 0.14
        }

        let bassLift = (guideState == .singing) ? (-3.0 * rhythm.beatPulse) : 0.0
        return StagePartitaRowMotion(
            offsetX: x,
            offsetY: row.y + bassLift,
            scale: scale,
            opacity: opacity,
            guideProgress: guideProgress,
            guideState: guideState,
            guideAlpha: guideAlpha
        )
    }

    /// Tilt（倾诉）自适应拆段与防折行字号缩放（1:1 对标 ui_stage_styles.go:286-390）
    static func fitTiltLayout(
        for line: LyricLine,
        maxWidth: Double,
        baseFontSize: Double
    ) -> StageTiltLayout {
        let units = stageUnits(line.words)
        guard !units.isEmpty else {
            return StageTiltLayout(parts: [], fontSize: baseFontSize, fittedLineRatio: 1.0)
        }

        let seed = (line.at * 1000.0).rounded() / 1000.0
        let chars = wordsLength(line.words[...])
        let score = log(Double(chars) + 4.0) / log(24.0) * (lineRandom(seed: seed, offset: 1) * 0.6 + 0.7) * 0.75

        var n = 4
        for (i, at) in [0.45, 1.05, 1.7].enumerated() {
            if score < at {
                n = i + 1
                break
            }
        }

        func estimatePartWidth(_ part: TiltPart, size: Double) -> Double {
            guard part.from < part.to, part.to <= line.words.count else { return 0 }
            let joined = line.words[part.from..<part.to].map(\.text).joined().trimmingCharacters(in: .whitespaces)
            let runeCount = Double(joined.count)
            let spacing = part.lean ? 0.13 : 0.06
            let tailMul = part.tail ? 1.18 : 1.0
            let effectiveSize = size * tailMul
            return wordWidth(joined, fontSize: effectiveSize) + runeCount * effectiveSize * spacing + effectiveSize * 0.4
        }

        func buildParts(count: Int) -> [TiltPart] {
            var parts = splitTiltParts(words: line.words, units: units, count: min(count, units.count))
            var leanCandidates: [Int] = []
            for i in parts.indices {
                if lineRandom(seed: seed, offset: 100 + Double(i)) < 0.35 {
                    leanCandidates.append(i)
                }
            }
            if !leanCandidates.isEmpty {
                let pickIdx = min(
                    leanCandidates.count - 1,
                    max(0, Int(lineRandom(seed: seed, offset: 200) * Double(leanCandidates.count)))
                )
                parts[leanCandidates[pickIdx]].lean = true
            }
            if parts.count > 1, let lastPart = parts.last, !lastPart.lean {
                let lastLen = wordsLength(line.words[lastPart.from..<lastPart.to])
                let prevPart = parts[parts.count - 2]
                let prevLen = wordsLength(line.words[prevPart.from..<prevPart.to])
                if lastLen <= 2 && lastLen * 2 <= prevLen {
                    parts[parts.count - 1].tail = true
                }
            }
            return parts
        }

        let safeWidth = max(140.0, maxWidth)
        var chosenParts = buildParts(count: n)
        while true {
            let widest = chosenParts.map { estimatePartWidth($0, size: baseFontSize) }.max() ?? 0
            if n >= 4 || n >= units.count || widest <= safeWidth {
                break
            }
            n += 1
            chosenParts = buildParts(count: n)
        }

        let widest = chosenParts.map { estimatePartWidth($0, size: baseFontSize) }.max() ?? 0
        let ratio = widest > safeWidth && widest > 0 ? max(0.48, safeWidth / widest) : 1.0
        return StageTiltLayout(
            parts: chosenParts,
            fontSize: baseFontSize * ratio,
            fittedLineRatio: ratio
        )
    }

    /// Tilt（倾诉）单段整体运动与排版样式参数
    static func tiltPartMotion(
        words: ArraySlice<LyricWord>,
        part: TiltPart,
        pos: TimeInterval,
        size: Double,
        rhythm: AudioRhythmState = .idle
    ) -> StageTiltPartMotion {
        guard let first = words.first else {
            return StageTiltPartMotion(
                opacity: 1,
                riseOffsetY: 0,
                scale: 1,
                fontSize: size,
                isLightWeight: part.lean,
                isItalic: part.lean,
                tracking: size * (part.lean ? 0.13 : 0.06),
                spaceWidth: size * (part.lean ? 0.34 : 0.25),
                useAccentColor: part.lean
            )
        }

        let since = pos - (first.start - tiltLead)
        @inline(__always) func easeQuadOut(_ v: Double) -> Double {
            let c = clamp01(v)
            return 1.0 - (1.0 - c) * (1.0 - c)
        }

        let duration = part.lean ? 0.60 : 0.55
        let progress = easeQuadOut(since / duration)
        // 保持微弱未唱预见性，但临近前 0.25s 时丝滑升入
        let opacity = since < 0 ? 0.18 : lerp(0.18, 1.0, progress)
        let rise = (part.lean ? 24.0 : 20.0) * (1.0 - progress)
        let baseScale = part.lean ? (0.92 + 0.08 * progress) : 1.0
        let beatScale = (part.tail && since > 0) ? (1.0 + 0.03 * rhythm.beatPulse) : 1.0
        let effectiveFont = (!part.lean && part.tail) ? (size * 1.18) : size

        return StageTiltPartMotion(
            opacity: opacity,
            riseOffsetY: rise,
            scale: baseScale * beatScale,
            fontSize: effectiveFont,
            isLightWeight: part.lean,
            isItalic: part.lean,
            tracking: effectiveFont * (part.lean ? 0.13 : 0.06),
            spaceWidth: effectiveFont * (part.lean ? 0.34 : 0.25),
            useAccentColor: part.lean
        )
    }

    /// Tilt（倾诉）单字符逐字波浪形变计算（1:1 对标 ui_stage_styles.go:428-455）
    static func tiltCharMotion(
        partSince: TimeInterval,
        charDuration: TimeInterval,
        charStart: TimeInterval,
        charOrderIndex: Int,
        part: TiltPart,
        size: Double,
        pos: TimeInterval,
        rhythm: AudioRhythmState = .idle
    ) -> StageTiltCharMotion {
        @inline(__always) func easeQuadOut(_ v: Double) -> Double {
            let c = clamp01(v)
            return 1.0 - (1.0 - c) * (1.0 - c)
        }

        let stagger = part.lean ? 0.05 : 0.04
        let shown = partSince < 0 ? 0.0 : easeQuadOut((partSince - Double(charOrderIndex) * stagger) / 0.50)

        let d = min(max(charDuration, 0.20), 0.90)
        let t = pos - charStart
        let swell: Double
        if t < 0 {
            swell = 0
        } else if t <= d {
            swell = sin((t / d) * .pi)
        } else {
            swell = 0.25 * clamp01((t - d) / (d * 1.2))
        }

        let basePulse = part.lean ? 0.18 : 0.15
        let audioMod = 1.0 + 0.40 * rhythm.vocal + 0.28 * rhythm.beatPulse
        let scale = 1.0 + swell * basePulse * audioMod

        // 斜体倾诉句逐字一高一低交替浮动
        let waveOffsetY: Double
        if part.lean {
            let amp = (size / 6.5) * (2.0 - shown)
            let audioRipple = size * 0.04 * rhythm.vocal * sin(pos * 6.0 + Double(charOrderIndex) * 0.8)
            waveOffsetY = (charOrderIndex % 2 == 0 ? -amp : amp) + audioRipple
        } else {
            waveOffsetY = 0
        }

        let highlight = t >= 0 && t <= d ? sin((t / d) * .pi) : 0.0
        return StageTiltCharMotion(
            opacity: lerp(0.18, 1.0, shown),
            scale: scale,
            waveOffsetY: waveOffsetY,
            highlightStrength: highlight
        )
    }

    /// 光束火花粒子帧几何生成（1:1 对标 ui_stage_styles.go stageSparks + 音律鼓点增强）
    static func sparkStreaks(
        size: CGSize,
        since: TimeInterval,
        seed: Double,
        isLastWord: Bool,
        rhythm: AudioRhythmState = .idle
    ) -> [StageSparkStreak] {
        guard since >= 0, since < sparkTime, size.width > 1, size.height > 1 else {
            return []
        }

        let t = since / sparkTime
        let count = isLastWord ? 16 : 9
        let baseReach = max(Double(size.width), Double(size.height)) * (isLastWord ? 1.20 : 0.78)
        let audioReachBoost = 1.0 + 0.30 * rhythm.beatPulse + 0.18 * rhythm.bass
        let reach = baseReach * audioReachBoost

        let oneMinusT = 1.0 - t
        let out = 1.0 - oneMinusT * oneMinusT * oneMinusT
        let fade = oneMinusT * oneMinusT
        let cx = Double(size.width) * 0.5
        let cy = Double(size.height) * 0.5
        let lineWidth = 1.0 + 1.8 * oneMinusT * (1.0 + 0.25 * rhythm.beatPulse)
        let whiteMix = 0.65 * oneMinusT

        var streaks: [StageSparkStreak] = []
        streaks.reserveCapacity(count)

        for i in 0..<count {
            let jitter = lineRandom(seed: seed, offset: Double(i))
            let angle = 2.0 * .pi * (Double(i) + jitter * 0.7) / Double(count)
            let dx = cos(angle)
            let dy = sin(angle)

            let edge = Double(size.width) * 0.5 * 0.72 * abs(dx) + Double(size.height) * 0.5 * 0.72 * abs(dy)
            let speed = 0.55 + 0.45 * lineRandom(seed: seed, offset: Double(i) + 50.0)
            let head = edge + reach * speed * out
            let tail = max(edge, head - reach * 0.34 * oneMinusT)

            streaks.append(
                StageSparkStreak(
                    startX: cx + dx * tail,
                    startY: cy + dy * tail,
                    endX: cx + dx * head,
                    endY: cy + dy * head,
                    lineWidth: lineWidth,
                    whiteMix: whiteMix,
                    alpha: min(1.0, (0.90 + 0.10 * rhythm.beatPulse) * fade)
                )
            )
        }
        return streaks
    }

    /// Quiet 静音期热门评论调度计算（1:1 对标桌面 ui_quiet.go）
    static func activeQuietComment(
        lines: [LyricLine],
        trackDuration: TimeInterval,
        lyricsLoaded: Bool,
        hotCommentsEnabled: Bool,
        comments: [Comment],
        at pos: TimeInterval
    ) -> StageQuietCommentResult? {
        guard hotCommentsEnabled else { return nil }
        let quietLeast: TimeInterval = 8.0
        let quietLead: TimeInterval = 1.2
        let quietTail: TimeInterval = 1.0
        let quietSlot: TimeInterval = 10.0
        let maxRunes = 140

        let hot = comments.filter {
            let len = $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count
            return len > 0 && len <= maxRunes
        }
        guard !hot.isEmpty else { return nil }

        var quiets = LyricsEngine.quiets(in: lines, trackLength: trackDuration, least: quietLeast)
        if lines.isEmpty && lyricsLoaded && trackDuration >= quietLeast {
            quiets = [LyricQuiet(from: 0, to: trackDuration)]
        }
        guard !quiets.isEmpty else { return nil }

        var shown = 0
        for (qIdx, q) in quiets.enumerated() {
            let from = q.from + quietLead
            let to = q.to - quietTail
            guard to > from else { continue }
            if pos < from {
                return nil
            }
            let slots = max(1, Int((to - from + quietSlot * 0.5) / quietSlot))
            let each = (to - from) / Double(slots)
            if pos < to {
                let slot = min(Int((pos - from) / each), slots - 1)
                let chosen = hot[(shown + slot) % hot.count]
                return StageQuietCommentResult(comment: chosen, slotIndex: shown + slot, quietIndex: qIdx)
            }
            shown += slots
        }
        return nil
    }

    /// 间奏三圆点呼吸充能状态（结合实时节奏脉冲与起唱预提醒）
    static func interludeDotsState(
        pos: TimeInterval,
        from: TimeInterval,
        to: TimeInterval,
        rhythm: AudioRhythmState = .idle
    ) -> StageInterludeDotsState {
        let span = max(0.1, to - from)
        let progress = clamp01((pos - from) / span)
        let lit = (0..<3).map { i in
            clamp01(progress * 3.0 - Double(i))
        }
        let wave = 0.06 * sin(pos * 2.4)
        let rhythmScale = 1.0 + wave + 0.14 * rhythm.bass + 0.10 * rhythm.beatPulse
        let remaining = max(0, to - pos)
        let preCue = remaining <= 1.2 ? clamp01(1.0 - remaining / 1.2) : 0.0
        return StageInterludeDotsState(
            progress: progress,
            dotLit: lit,
            breathScale: rhythmScale,
            preCuePulse: preCue
        )
    }

    /// 内部复用 Tilt 均分片段（与 StageMath.tiltParts 保持统一算法）
    private static func splitTiltParts(
        words: [LyricWord],
        units: [(Int, Int)],
        count n: Int
    ) -> [TiltPart] {
        guard n > 1, !units.isEmpty else {
            return [TiltPart(from: 0, to: words.count)]
        }
        let total = Double(wordsLength(words[...]))
        var before = [Double](repeating: 0, count: units.count + 1)
        for (i, u) in units.enumerated() {
            before[i + 1] = before[i] + Double(wordsLength(words[u.0..<u.1]))
        }
        var parts: [TiltPart] = []
        parts.reserveCapacity(n)
        var from = 0
        for k in 1..<n {
            var bestCut = -1
            var bestDist = 0.0
            let maxCut = units.count - (n - k)
            if from + 1 <= maxCut {
                for cut in (from + 1)...maxCut {
                    var dist = abs(before[cut] - total * Double(k) / Double(n))
                    let prevLastText = words[units[cut - 1].1 - 1].text.trimmingCharacters(in: .whitespaces)
                    if let lastScalar = prevLastText.unicodeScalars.last,
                       CharacterSet.punctuationCharacters.contains(lastScalar) {
                        dist -= total * 0.15
                    }
                    if bestCut < 0 || dist < bestDist {
                        bestCut = cut
                        bestDist = dist
                    }
                }
            }
            let safeCut = max(from + 1, bestCut)
            parts.append(TiltPart(from: units[from].0, to: units[safeCut - 1].1))
            from = safeCut
        }
        parts.append(TiltPart(from: units[from].0, to: units[units.count - 1].1))
        return parts
    }
}

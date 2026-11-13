// StageMath.swift
// 对应原项目 internal/app/ui_stage.go 与 ui_stage_styles.go 的律动歌词物理与排版计算

import Foundation

/// 律动视觉风格（对应 stageStyles）
public enum StageStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case flow = ""          // 流光（Folia 经典弹性散落）
    case partita = "partita"// 云阶（错落阶梯式入场）
    case tilt = "tilt"      // 倾诉（多层错落与斜体脉冲）

    public var id: String { rawValue }

    public var labelKey: String {
        switch self {
        case .flow: return "Flow"
        case .partita: return "Steps"
        case .tilt: return "Tilt"
        }
    }
}

/// 单词在舞台上的几何姿态（对应 wordShape）
public struct WordShape: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var rotate: Double
    public var scale: Double
    public var drift: Double
    public var margin: Double
    public var last: Bool

    public init(
        x: Double = 0,
        y: Double = 0,
        rotate: Double = 0,
        scale: Double = 1,
        drift: Double = 0,
        margin: Double = 0,
        last: Bool = false
    ) {
        self.x = x
        self.y = y
        self.rotate = rotate
        self.scale = scale
        self.drift = drift
        self.margin = margin
        self.last = last
    }
}

/// 云阶（Partita）行结构（对应 partitaRow）
public struct PartitaRow: Hashable, Sendable {
    public var from: Int
    public var to: Int
    public var x: Double
    public var y: Double
    public var scale: Double
    public var left: Bool

    public init(from: Int, to: Int, x: Double, y: Double, scale: Double, left: Bool) {
        self.from = from
        self.to = to
        self.x = x
        self.y = y
        self.scale = scale
        self.left = left
    }
}

/// 倾诉（Tilt）分段结构（对应 tiltPart）
public struct TiltPart: Hashable, Sendable {
    public var from: Int
    public var to: Int
    public var lean: Bool
    public var tail: Bool

    public init(from: Int, to: Int, lean: Bool = false, tail: Bool = false) {
        self.from = from
        self.to = to
        self.lean = lean
        self.tail = tail
    }
}

/// 单词在某一时刻的实时渲染状态
public struct WordRenderState: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var scale: Double
    public var rotate: Double
    public var opacity: Double
    public var blur: Double
    public var brightness: Double
    public var glow: Double
    public var sparkSince: Double
}

/// 律动舞台核心算法（1:1 移植自 ui_stage.go 与 ui_stage_styles.go）
public enum StageMath {
    public static let sparkTime: Double = 0.6
    public static let tiltLead: TimeInterval = 0.25

    /// 确定性伪随机数（确保同一行歌词每次渲染位置一致，对应 lineRandom）
    public static func lineRandom(seed: Double, offset: Double) -> Double {
        let x = sin(seed + offset) * 10000.0
        return x - floor(x)
    }

    /// 弹簧阶跃响应（stiffness 200, damping 20，对应 springStep）
    public static func springStep(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        let e = exp(-10.0 * t)
        return 1.0 - e * (cos(10.0 * t) + sin(10.0 * t))
    }

    public static func clamp01(_ v: Double) -> Double {
        return min(1.0, max(0.0, v))
    }

    public static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        return a + (b - a) * t
    }

    public static func easeOutCubic(_ t: Double) -> Double {
        let c = clamp01(t)
        let inv = 1.0 - c
        return 1.0 - inv * inv * inv
    }

    /// 计算单词在指定播放位置的实时动画状态（对应 stageWord）
    public static func wordState(word: LyricWord, shape: WordShape, pos: TimeInterval) -> WordRenderState {
        let lookahead: TimeInterval = 0.08
        let start = word.start - lookahead
        let end = max(word.end, word.start + 0.15)
        let since = pos - start
        let after = pos - end
        let singing = max(0.08, end - word.start)

        // 手机屏幕较窄：未唱到的字仍保留低亮度，避免整句看起来缺字；入场位移也收敛到字距范围。
        var x = shape.x + sin(shape.y) * 28.0
        var y = shape.y + cos(shape.x) * 12.0
        var scale = 0.88
        var rotate = shape.rotate + 4.0
        var opacity = 0.28
        var blur = 0.5
        var brightness = 0.58
        var glow = 0.0

        if since > 0 {
            let e = springStep(since)
            x = lerp(x, shape.x, e)
            y = lerp(y, shape.y, e)
            scale = lerp(0.88, shape.scale * 1.12, e)
            rotate = lerp(shape.rotate + 4.0, shape.rotate, e)
            opacity = lerp(0.28, 1.0, clamp01(since / 0.1))
            blur = 0.5 * (1.0 - clamp01(since / 0.16))
            brightness = lerp(0.5, 1.0, clamp01(since / singing))
            glow = clamp01(since / max(0.08, 0.3 * singing))
        }

        if after > 0 {
            let q = easeOutCubic(after / 0.5)
            scale = lerp(shape.scale * 1.12, shape.scale, q)
            opacity = lerp(1.0, 0.82, q)
            rotate = shape.rotate + shape.drift * clamp01(after / 5.0)
            brightness = lerp(1.0, 0.5, easeOutCubic(after / 0.8))
            glow = 1.0 - clamp01(after / 0.9)
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

    /// 计算流光（Flow）模式下整行每个词的姿态（对应 stageShapes）
    public static func stageShapes(for line: LyricLine, fontSize: Double, spreadScale: Double = 1.0) -> [WordShape] {
        let seed = floor(line.at * 1000.0)
        var shapes: [WordShape] = []
        var widths: [Double] = []
        shapes.reserveCapacity(line.words.count)
        widths.reserveCapacity(line.words.count)

        for (i, w) in line.words.enumerated() {
            widths.append(wordWidth(w.text, fontSize: fontSize))
            let ws = seed + Double(i)
            shapes.append(WordShape(
                x: (lineRandom(seed: ws, offset: 1) - 0.5) * 36.0,
                y: (lineRandom(seed: ws, offset: 2) - 0.5) * 36.0,
                rotate: (lineRandom(seed: ws, offset: 3) - 0.5) * 10.0,
                scale: 1.06 + lineRandom(seed: ws, offset: 4) * 0.14,
                drift: (lineRandom(seed: ws, offset: 5) - 0.5) * 10.0
            ))
        }
        spaceWords(&shapes, widths: widths, gap: fontSize * 0.08, spreadScale: spreadScale)
        if !shapes.isEmpty {
            shapes[shapes.count - 1].last = true
        }
        return shapes
    }

    /// 按手机可用宽度预排词行，避免每帧让 SwiftUI 重测所有字形，并自动消除单字孤行。
    public static func flowRows(
        for line: LyricLine,
        shapes: [WordShape],
        fontSize: Double,
        availableWidth: Double,
        marginScale: Double = 1.0
    ) -> [[Int]] {
        guard !line.words.isEmpty else { return [] }
        let limit = max(availableWidth, fontSize)
        var rows: [[Int]] = []
        var row: [Int] = []
        var rowWidth = 0.0

        for index in line.words.indices {
            let shape = index < shapes.count ? shapes[index] : WordShape()
            let baseWidth = wordWidth(line.words[index].text, fontSize: fontSize)
            if !row.isEmpty && rowWidth + baseWidth > limit {
                rows.append(row)
                row = []
                rowWidth = 0
            }
            row.append(index)
            rowWidth += baseWidth + shape.margin * marginScale
        }
        if !row.isEmpty { rows.append(row) }

        // 当折成 2 行且尾行出现极短孤词/单字孤行时，均衡从上一行匀 1~2 词保持视觉重心平稳
        if rows.count == 2 && rows[0].count >= 4 && rows[1].count <= 2 {
            let targetSecond = max(2, min(rows[0].count / 2, (rows[0].count + rows[1].count) / 2))
            let moveCount = max(0, targetSecond - rows[1].count)
            if moveCount > 0 && rows[0].count - moveCount >= 2 {
                let moved = rows[0].suffix(moveCount)
                rows[0].removeLast(moveCount)
                rows[1].insert(contentsOf: moved, at: 0)
            }
        }
        return rows
    }

    public static func wordWidth(_ text: String, fontSize: Double) -> Double {
        let isCJK = text.unicodeScalars.contains { scalar in
            let value = Int(scalar.value)
            return (0x2E80...0xA4CF).contains(value) ||
                (0xAC00...0xD7AF).contains(value) ||
                (0xF900...0xFAFF).contains(value) ||
                (0x20000...0x3134F).contains(value)
        }
        return Double(max(1, text.count)) * fontSize * (isCJK ? 1.0 : 0.56)
    }

    /// 词间距补偿（防止放大时重叠，对应 spaceWords，支持按屏幕缩放系数匹配实际散落位移）
    public static func spaceWords(_ shapes: inout [WordShape], widths: [Double], gap: Double, spreadScale: Double = 1.0) {
        let clampedSpread = max(0.25, spreadScale)
        for i in shapes.indices {
            let grow = widths[i] * (shapes[i].scale * 1.12 - 1.0) / 2.0
            var next = 0.0
            var toward = 0.0
            if i + 1 < shapes.count {
                next = widths[i + 1] * (shapes[i + 1].scale * 1.12 - 1.0) / 2.0
                toward = (shapes[i].x - shapes[i + 1].x) * clampedSpread
            }
            let effectiveMargin = max(1.6 * gap, grow + next + toward + gap)
            shapes[i].margin = i == shapes.count - 1 ? 0.0 : min(gap * 4.5, effectiveMargin)
        }
    }

    /// 将歌词行按语义与标点切分为短语单元（对应 stageUnits）
    public static func stageUnits(_ words: [LyricWord]) -> [(Int, Int)] {
        var units: [(Int, Int)] = []
        let phrase: (Int, Int) -> Void = { from, to in
            var n = (to - from + 3) / 4
            if to - from <= 6 {
                n = 1
            }
            for k in 0..<n {
                let start = from + (to - from) * k / n
                let end = from + (to - from) * (k + 1) / n
                units.append((start, end))
            }
        }

        var from = 0
        for (i, w) in words.enumerated() {
            let trimmed = w.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if i == from && !units.isEmpty && trimmed.isEmpty {
                units[units.count - 1].1 = i + 1
                from = i + 1
                continue
            }
            let lastScalar = w.text.unicodeScalars.last
            let isBreak: Bool
            if let s = lastScalar {
                let isMark = CharacterSet.whitespacesAndNewlines.contains(s) || CharacterSet.punctuationCharacters.contains(s)
                let isJoiner = s == "'" || s == "’" || s == "-"
                isBreak = isMark && !isJoiner
            } else {
                isBreak = false
            }
            if i + 1 == words.count || isBreak {
                phrase(from, i + 1)
                from = i + 1
            }
        }
        return units
    }

    /// 统计不含空白字符的总字数（对应 wordsLength）
    public static func wordsLength(_ words: ArraySlice<LyricWord>) -> Int {
        var count = 0
        for w in words {
            count += w.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        return count
    }

    /// 云阶（Partita）分行算法（对应 partitaRows）
    public static func partitaRows(for line: LyricLine, height: Double) -> [PartitaRow] {
        let units = stageUnits(line.words)
        guard !units.isEmpty else { return [] }

        let seed = floor(line.at * 1000.0) / 1000.0
        var k = 0.0
        let random: () -> Double = {
            k += 1.0
            return lineRandom(seed: seed, offset: k)
        }

        let count = min(units.count, max(1, Int(height * 0.65 / 100.0)))
        var rows: [PartitaRow] = []
        rows.reserveCapacity(count)

        var left = units.count
        var unit = 0
        for i in 0..<count {
            var n = left
            if i < count - 1 {
                let avg = Double(left) / Double(count - i)
                let jitter = avg + (random() - 0.5) * avg
                n = min(Int(ceil(avg * 1.5)), max(1, Int( jitter.rounded() )))
            }
            n = max(1, min(n, left - (count - i - 1)))
            let stagger = 20.0 + random() * 80.0
            let isLeft = (i % 2 == 0)
            let row = PartitaRow(
                from: units[unit].0,
                to: units[unit + n - 1].1,
                x: isLeft ? -stagger : stagger,
                y: (Double(i) - Double(count - 1) / 2.0) * 2.5,
                scale: 0.8 + random() * 0.9,
                left: isLeft
            )
            rows.append(row)
            unit += n
            left -= n
        }
        return rows
    }

    /// 倾诉（Tilt）分段算法（对应 tiltParts）
    public static func tiltParts(for line: LyricLine) -> [TiltPart] {
        let units = stageUnits(line.words)
        guard !units.isEmpty else { return [] }

        let seed = floor(line.at * 1000.0) / 1000.0
        let chars = wordsLength(line.words[...])
        let score = log(Double(chars) + 4.0) / log(24.0) * (lineRandom(seed: seed, offset: 1) * 0.6 + 0.7) * 0.75
        var n = 4
        let thresholds = [0.45, 1.05, 1.7]
        for (i, at) in thresholds.enumerated() {
            if score < at {
                n = i + 1
                break
            }
        }

        var parts = splitTiltParts(words: line.words, units: units, n: min(n, units.count))
        var leanCandidates: [Int] = []
        for i in parts.indices {
            if lineRandom(seed: seed, offset: 100.0 + Double(i)) < 0.35 {
                leanCandidates.append(i)
            }
        }
        if !leanCandidates.isEmpty {
            let chosen = leanCandidates[Int(lineRandom(seed: seed, offset: 200.0) * Double(leanCandidates.count)) % leanCandidates.count]
            parts[chosen].lean = true
        }
        if parts.count > 1 && !parts[parts.count - 1].lean {
            let lastLen = wordsLength(line.words[parts[parts.count - 1].from..<parts[parts.count - 1].to])
            let prevLen = wordsLength(line.words[parts[parts.count - 2].from..<parts[parts.count - 2].to])
            parts[parts.count - 1].tail = (lastLen <= 2 && lastLen * 2 <= prevLen)
        }
        return parts
    }

    private static func splitTiltParts(words: [LyricWord], units: [(Int, Int)], n: Int) -> [TiltPart] {
        let total = Double(wordsLength(words[...]))
        var before = Array(repeating: 0.0, count: units.count + 1)
        for (i, u) in units.enumerated() {
            before[i + 1] = before[i] + Double(wordsLength(words[u.0..<u.1]))
        }
        var parts: [TiltPart] = []
        var from = 0
        if n > 1 {
            for k in 1..<n {
                var at = -1
                var best = 0.0
                let upper = units.count - (n - k)
                if from + 1 <= upper {
                    for cut in (from + 1)...upper {
                        var d = abs(before[cut] - total * Double(k) / Double(n))
                        let lastWord = words[units[cut - 1].1 - 1].text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let lastScalar = lastWord.unicodeScalars.last,
                           CharacterSet.punctuationCharacters.contains(lastScalar) {
                            d -= total * 0.15
                        }
                        if at < 0 || d < best {
                            at = cut
                            best = d
                        }
                    }
                }
                if at < 0 {
                    at = min(from + 1, units.count)
                }
                parts.append(TiltPart(from: units[from].0, to: units[at - 1].1))
                from = at
            }
        }
        parts.append(TiltPart(from: units[from].0, to: units[units.count - 1].1))
        return parts
    }
}

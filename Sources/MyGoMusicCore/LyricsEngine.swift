// LyricsEngine.swift
// 对应原项目 internal/lyrics/lyrics.go 的歌词解析、逐字均摊、翻译对齐与间奏检测

import Foundation

/// 解析后的单行歌词（对应 lyrics.Line）
public struct LyricLine: Identifiable, Hashable, Sendable {
    public var id: String { "\(Int64(at * 1000))-\(text)" }
    public var at: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var translation: String
    public var words: [LyricWord]

    public init(
        at: TimeInterval,
        end: TimeInterval = 0,
        text: String,
        translation: String = "",
        words: [LyricWord] = []
    ) {
        self.at = at
        self.end = end
        self.text = text
        self.translation = translation
        self.words = words
    }
}

/// 解析后的单个词或中日韩字符（对应 lyrics.Word）
public struct LyricWord: Hashable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// 间奏或无人声片段（对应 lyrics.Quiet）
public struct LyricQuiet: Hashable, Sendable {
    public var from: TimeInterval
    public var to: TimeInterval

    public init(from: TimeInterval, to: TimeInterval) {
        self.from = from
        self.to = to
    }
}

/// 歌词解析与计算引擎（1:1 移植自 internal/lyrics/lyrics.go）
public enum LyricsEngine {
    private static let lrcTimeRegex = try! NSRegularExpression(pattern: #"\[(\d+):(\d+)(?:[.:](\d+))?\]"#)
    private static let lrcOffsetRegex = try! NSRegularExpression(pattern: #"\[offset:\s*([+-]?\d+)\]"#, options: .caseInsensitive)

    /// 演职员信息前缀（不视为演唱部分）
    public static let creditNames: [String] = [
        "作词", "作曲", "编曲", "制作", "监制", "混音", "录音", "母带", "和声",
        "吉他", "贝斯", "鼓", "键盘", "弦乐", "出品", "发行", "OP", "SP", "词", "曲",
        "Lyrics", "Music", "Composer", "Arranger", "Producer"
    ]

    /// 解析 LRC 文本，支持一行携带多个时间标签与全局 [offset:+/-ms] 偏移量
    public static func parseLRC(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let nsLRC = lrc as NSString
        let lines = nsLRC.components(separatedBy: "\n")

        // 提取全局 offset 偏移量（毫秒）
        var offsetSec: TimeInterval = 0
        for raw in lines {
            let nsRaw = raw as NSString
            if let match = lrcOffsetRegex.firstMatch(in: raw, range: NSRange(location: 0, length: nsRaw.length)),
               match.numberOfRanges > 1 {
                let offStr = nsRaw.substring(with: match.range(at: 1))
                if let ms = Double(offStr) {
                    offsetSec = ms / 1000.0
                }
                break
            }
        }

        for raw in lines {
            let nsRaw = raw as NSString
            let matches = lrcTimeRegex.matches(in: raw, range: NSRange(location: 0, length: nsRaw.length))
            guard let lastMatch = matches.last else { continue }

            let textStart = lastMatch.range.location + lastMatch.range.length
            let text = nsRaw.substring(from: textStart).trimmingCharacters(in: .whitespacesAndNewlines)

            for match in matches {
                let minStr = nsRaw.substring(with: match.range(at: 1))
                let secStr = nsRaw.substring(with: match.range(at: 2))
                let minutes = Double(minStr) ?? 0
                let seconds = Double(secStr) ?? 0
                var frac: Double = 0
                let fracRange = match.range(at: 3)
                if fracRange.location != NSNotFound {
                    let fracStr = nsRaw.substring(with: fracRange)
                    if let n = Double(fracStr) {
                        frac = n / pow(10.0, Double(fracStr.count))
                    }
                }
                let rawAt = minutes * 60.0 + seconds + frac
                let at = max(0, rawAt + offsetSec)
                out.append(LyricLine(at: at, text: text))
            }
        }
        // 稳定排序
        return out.enumerated().sorted { a, b in
            if a.element.at == b.element.at {
                return a.offset < b.offset
            }
            return a.element.at < b.element.at
        }.map(\.element)
    }

    /// 从音乐源返回的 RawLyrics 构建可渲染歌词行（对应 lyrics.FromSource）
    public static func fromSource(_ raw: RawLyrics?) -> [LyricLine] {
        guard let raw else { return [] }
        guard let rawLines = raw.lines, !rawLines.isEmpty else {
            return build(lrc: raw.lrc ?? "", translation: raw.translation ?? "")
        }

        let msToSec: (Int64) -> TimeInterval = { TimeInterval($0) / 1000.0 }
        var out: [LyricLine] = []
        out.reserveCapacity(rawLines.count)

        for sl in rawLines {
            var line = LyricLine(
                at: msToSec(sl.start),
                end: msToSec(sl.end ?? 0),
                text: (sl.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                translation: sl.translation ?? ""
            )
            if let rawWords = sl.words {
                for w in rawWords {
                    line.words.append(LyricWord(text: w.text, start: msToSec(w.start), end: msToSec(w.end)))
                }
            }
            if line.text.isEmpty {
                let joined = line.words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                line.text = joined
            }
            if line.text.isEmpty {
                continue
            }
            out.append(line)
        }

        out = out.enumerated().sorted { a, b in
            if a.element.at == b.element.at {
                return a.offset < b.offset
            }
            return a.element.at < b.element.at
        }.map(\.element)

        for i in out.indices {
            if out[i].end <= out[i].at {
                var end = out[i].at + 6.0
                if i + 1 < out.count {
                    end = min(end, out[i + 1].at)
                }
                out[i].end = end
            }
            if out[i].words.isEmpty {
                out[i].words = spreadWords(text: out[i].text, start: out[i].at, end: out[i].end)
            }
        }
        return out
    }

    /// 由 LRC 与翻译构建歌词行（对应 lyrics.Build）
    public static func build(lrc: String, translation: String = "") -> [LyricLine] {
        var lines = parseLRC(lrc).filter { !$0.text.isEmpty }
        for i in lines.indices {
            var end = lines[i].at + 6.0
            if i + 1 < lines.count {
                end = min(end, lines[i + 1].at)
            }
            lines[i].end = end
            lines[i].words = spreadWords(text: lines[i].text, start: lines[i].at, end: end)
        }

        // 将翻译匹配到时间差在 1500ms 内最近的一行
        for tr in parseLRC(translation) where !tr.text.isEmpty {
            var best = -1
            var bestGap: TimeInterval = 1.5
            for i in lines.indices {
                let gap = abs(lines[i].at - tr.at)
                if gap < bestGap {
                    best = i
                    bestGap = gap
                }
            }
            if best >= 0 && lines[best].translation.isEmpty {
                lines[best].translation = tr.text
            }
        }
        return lines
    }

    /// 将无逐字时间戳的文本切分为单词或 CJK 单字，并按 85% 演唱跨度均摊时长（对应 lyrics.SpreadWords）
    public static func spreadWords(text: String, start: TimeInterval, end: TimeInterval) -> [LyricWord] {
        var words: [String] = []
        var cur = ""
        let flush = {
            if !cur.isEmpty {
                words.append(cur)
                cur = ""
            }
        }

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !cur.isEmpty {
                    cur.append(" ")
                    flush()
                }
            } else if isCJK(scalar) {
                flush()
                words.append(String(scalar))
            } else {
                cur.unicodeScalars.append(scalar)
            }
        }
        flush()

        guard !words.isEmpty else { return [] }
        var total = 0
        for w in words {
            total += w.trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        let span = max(0, (end - start) * 0.85)
        var out: [LyricWord] = []
        out.reserveCapacity(words.count)
        var at = start
        let denom = Double(max(total, 1))
        for w in words {
            let charCount = Double(w.trimmingCharacters(in: .whitespacesAndNewlines).count)
            let d = span * charCount / denom
            out.append(LyricWord(text: w, start: at, end: at + d))
            at += d
        }
        return out
    }

    /// 判断是否为中日韩字符（对应 isCJK）
    public static func isCJK(_ s: UnicodeScalar) -> Bool {
        let v = s.value
        // Han (CJK Unified Ideographs + Extensions), Hiragana, Katakana, Hangul
        return (0x4E00...0x9FFF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0x20000...0x2A6DF).contains(v)
            || (0x3040...0x309F).contains(v)
            || (0x30A0...0x30FF).contains(v)
            || (0xAC00...0xD7AF).contains(v)
            || (0x1100...0x11FF).contains(v)
            || (0x3130...0x318F).contains(v)
    }

    /// 检测是否为日语歌词（包含假名，对应 lyrics.Lang）
    public static func lang(of lines: [LyricLine]) -> String {
        for line in lines {
            for s in line.text.unicodeScalars {
                let v = s.value
                let isKana = (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v)
                if isKana && s != "ー" && s != "・" {
                    return "ja"
                }
            }
        }
        return ""
    }

    /// 二分查找当前播放位置对应的歌词行索引（对应 lyrics.Index）
    public static func index(in lines: [LyricLine], at pos: TimeInterval) -> Int {
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].at > pos {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low - 1
    }

    /// 判断是否为作词/作曲等演职员行（对应 lyrics.IsCredit）
    public static func isCredit(_ text: String) -> Bool {
        guard let colonIdx = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return false
        }
        let prefix = String(text[..<colonIdx])
        if prefix.isEmpty || prefix.count > 12 {
            return false
        }
        let head = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        for name in creditNames {
            if head == name || (name.count > 1 && head.hasPrefix(name)) {
                return true
            }
        }
        return false
    }

    /// 提取歌曲中时长至少为 least 的间奏/前奏/尾奏片段（用于显示热评，对应 lyrics.Quiets）
    public static func quiets(in lines: [LyricLine], trackLength: TimeInterval, least: TimeInterval) -> [LyricQuiet] {
        var out: [LyricQuiet] = []
        let add: (TimeInterval, TimeInterval) -> Void = { from, to in
            if to - from >= least {
                out.append(LyricQuiet(from: from, to: to))
            }
        }
        var at: TimeInterval = 0
        var sung = false
        for line in lines {
            if isCredit(line.text) {
                continue
            }
            add(at, line.at)
            at = max(at, line.end)
            sung = true
        }
        if sung && trackLength > 0 {
            add(at, trackLength)
        }
        return out
    }
}

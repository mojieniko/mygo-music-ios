// StageVisualizerViews.swift
// 高标准 60fps 音律同步律动歌词舞台视图（完全对照桌面端 internal/app/ui_stage.go, ui_stage_styles.go, ui_quiet.go 并强化音画与节奏驱动）

#if canImport(MyGoMusicCore)
import MyGoMusicCore
#endif
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 律动歌词主舞台宿主（独立接收高精度时钟、拖动预览进度与音频频谱信号）
public struct StageVisualizerHostView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject public var player: PlayerEngine
    @StateObject private var coverColorLoader = ArtworkImageLoader()

    public let track: Track
    public let scrubbingPosition: TimeInterval?
    public let onOpenComments: () -> Void

    public init(
        player: PlayerEngine,
        track: Track,
        scrubbingPosition: TimeInterval?,
        onOpenComments: @escaping () -> Void
    ) {
        self.player = player
        self.track = track
        self.scrubbingPosition = scrubbingPosition
        self.onOpenComments = onOpenComments
    }

    public var body: some View {
        let stageAccent = resolvedStageAccent()

        // 将 GeometryReader 置于 TimelineView 之外，并把 timeline.date 作为显式值传入帧视图，
        // 确保 SwiftUI 不会跳过未引用 context 的惰性重绘，同时直接订阅 PlayerEngine 实现零漏帧 60fps 驱动。
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !player.isPlaying && scrubbingPosition == nil)) { timeline in
                StageVisualizerFrameView(
                    frameDate: timeline.date,
                    player: player,
                    track: track,
                    scrubbingPosition: scrubbingPosition,
                    stageAccent: stageAccent,
                    canvasSize: geo.size,
                    hotCommentsEnabled: app.settings.hotComments,
                    comments: app.currentTrackComments,
                    stageStyle: app.settings.stageStyle,
                    stageSparks: app.settings.stageSparks,
                    onOpenComments: onOpenComments
                )
            }
        }
        .task(id: track.album.imageUrl ?? track.id) {
            await coverColorLoader.load(
                rawURLString: track.album.imageUrl,
                pixelSize: 200,
                extractDominantColor: true,
                headersProvider: { url in app.imageHeaders(for: url) }
            )
        }
    }

    /// 调制高可读性、明亮通透的专辑专属舞台主色（避免灰暗脏色，在深雾背板上发光清晰）
    private func resolvedStageAccent() -> Color {
        guard let dominant = coverColorLoader.dominantColor else {
            return MyGoTheme.accent
        }
        return MyGoTheme.brightenAccentColor(dominant)
    }
}

/// 律动歌词单帧渲染容器（接收 timeline.date 与 ObservedObject player，每帧精确重算播放位置与逐字物理状态）
private struct StageVisualizerFrameView: View {
    let frameDate: Date
    @ObservedObject var player: PlayerEngine
    let track: Track
    let scrubbingPosition: TimeInterval?
    let stageAccent: Color
    let canvasSize: CGSize
    let hotCommentsEnabled: Bool
    let comments: [Comment]
    let stageStyle: StageStyle
    let stageSparks: Bool
    let onOpenComments: () -> Void

    var body: some View {
        let _ = frameDate
        let lines = player.lyrics
        let loaded = player.lyricsLoaded
        let rawPos = scrubbingPosition ?? player.livePlaybackPosition()
        let pos = StageMath.stagePosition(
            playbackPosition: rawPos,
            scrubbingPosition: scrubbingPosition
        )
        let rhythm = player.sampleAudioRhythm(
            at: rawPos,
            lines: lines,
            isScrubbing: scrubbingPosition != nil
        )
        let width = Double(canvasSize.width)
        let height = Double(canvasSize.height)
        let isJapanese = LyricsEngine.lang(of: lines) == "ja"
        let trackDur = player.duration > 0 ? player.duration : track.durationSeconds
        let quietResult = StageMath.activeQuietComment(
            lines: lines,
            trackDuration: trackDur,
            lyricsLoaded: loaded,
            hotCommentsEnabled: hotCommentsEnabled,
            comments: comments,
            at: pos
        )
        let dimAmount: Double = (quietResult != nil) ? 0.94 : 0.0
        let curIdx = LyricsEngine.index(in: lines, at: pos)
        let baseFontSize = min(40.0, max(24.0, min(width * 0.078, height * 0.068)))

        ZStack {
            // 1. 随音乐重低音与人声脉动的极光氛围底光（与背景烟雾浑然一体）
            StageAudioAtmosphereView(
                accent: stageAccent,
                rhythm: rhythm
            )
            .allowsHitTesting(false)

            // 2. 主歌词演艺层（在静音热评激活时优雅淡沉至 6% 背景对比度）
            Group {
                if lines.isEmpty {
                    stageEmptyState(loaded: loaded, width: width, accent: stageAccent)
                } else {
                    stageActiveLyricsLayer(
                        lines: lines,
                        curIdx: curIdx,
                        pos: pos,
                        width: width,
                        height: height,
                        baseFontSize: baseFontSize,
                        accent: stageAccent,
                        rhythm: rhythm
                    )
                }
            }
            .opacity(1.0 - dimAmount)
            .scaleEffect(quietResult != nil ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.55), value: quietResult != nil)
            .environment(\.locale, isJapanese ? Locale(identifier: "ja") : Locale.current)

            // 3. 静音 / 间奏热门评论卡片层（对照桌面 ui_quiet.go 舞台居中卡片）
            if let quietResult {
                StageQuietCommentCard(
                    comment: quietResult.comment,
                    accent: stageAccent,
                    rhythm: rhythm,
                    onTap: onOpenComments
                )
                .id("\(quietResult.comment.id)-\(quietResult.slotIndex)")
                .padding(.horizontal, 26)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 16)).combined(with: .scale(scale: 0.97)),
                        removal: .opacity.combined(with: .offset(y: -10))
                    )
                )
            }
        }
        .animation(.spring(response: 0.62, dampingFraction: 0.86), value: quietResult?.comment.id)
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    @ViewBuilder
    private func stageEmptyState(loaded: Bool, width: Double, accent: Color) -> some View {
        VStack(spacing: 14) {
            Spacer()
            if !loaded {
                StageSkeletonView(accent: accent, maxWidth: min(280, width * 0.72))
            } else {
                Text(I18n.t("No lyrics. Enjoy the music."))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private func stageActiveLyricsLayer(
        lines: [LyricLine],
        curIdx: Int,
        pos: TimeInterval,
        width: Double,
        height: Double,
        baseFontSize: Double,
        accent: Color,
        rhythm: AudioRhythmState
    ) -> some View {
        let stageContentWidth = max(200.0, width - 48.0)

        ZStack {
            // 中央演艺舞台区域（为底部译文与下一句预留底部安全高度，保持构图呼吸感）
            ZStack {
                // 桌面端精髓：旧行 0.4s 叠化退场（仅在非间奏的正常演唱过渡期触发）
                if curIdx > 0 {
                    let exitOpacity = StageMath.lineExitOpacity(nextLineStart: lines[curIdx].at, at: pos)
                    if exitOpacity > 0.01 {
                        stageLineView(
                            line: lines[curIdx - 1],
                            pos: pos,
                            style: stageStyle,
                            fade: exitOpacity,
                            width: stageContentWidth,
                            height: height * 0.72,
                            fontSize: baseFontSize,
                            accent: accent,
                            sparks: false,
                            rhythm: rhythm
                        )
                        .id("exit-\(curIdx - 1)-\(lines[curIdx - 1].id)")
                        .allowsHitTesting(false)
                    }
                }

                // 当前句 / 间奏呼吸三圆点
                if curIdx < 0 {
                    if lines[0].at > 0.35 {
                        StageRhythmInterludeView(
                            pos: pos,
                            from: 0,
                            to: lines[0].at,
                            accent: accent,
                            rhythm: rhythm
                        )
                    } else {
                        stageLineView(
                            line: lines[0],
                            pos: pos,
                            style: stageStyle,
                            fade: 1.0,
                            width: stageContentWidth,
                            height: height * 0.72,
                            fontSize: baseFontSize,
                            accent: accent,
                            sparks: stageSparks,
                            rhythm: rhythm
                        )
                        .id("active-0-\(lines[0].id)")
                    }
                } else if curIdx + 1 < lines.count,
                          pos > lines[curIdx].end + 1.0,
                          lines[curIdx + 1].at - lines[curIdx].end > 4.0 {
                    StageRhythmInterludeView(
                        pos: pos,
                        from: lines[curIdx].end,
                        to: lines[curIdx + 1].at,
                        accent: accent,
                        rhythm: rhythm
                    )
                } else {
                    stageLineView(
                        line: lines[curIdx],
                        pos: pos,
                        style: stageStyle,
                        fade: 1.0,
                        width: stageContentWidth,
                        height: height * 0.72,
                        fontSize: baseFontSize,
                        accent: accent,
                        sparks: stageSparks,
                        rhythm: rhythm
                    )
                    .id("active-\(curIdx)-\(lines[curIdx].id)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 42)

            // 底部常驻翻译与下一行预告带（瞬间移除旧行防叠字残影，再轻柔淡入新行）
            let previewIdx = curIdx >= 0 ? curIdx : (lines[0].at <= 0.35 ? 0 : -1)
            VStack(spacing: 6) {
                Spacer()
                if previewIdx >= 0 && previewIdx < lines.count && !lines[previewIdx].translation.isEmpty {
                    Text(lines[previewIdx].translation)
                        .id("trans-\(previewIdx)")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 4)), removal: .identity))
                }
                if previewIdx + 1 < lines.count {
                    Text(lines[previewIdx + 1].text)
                        .id("next-\(previewIdx)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.36))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 4)), removal: .identity))
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 12)
            .animation(.easeOut(duration: 0.24), value: previewIdx)
        }
    }

    @ViewBuilder
    private func stageLineView(
        line: LyricLine,
        pos: TimeInterval,
        style: StageStyle,
        fade: Double,
        width: Double,
        height: Double,
        fontSize: Double,
        accent: Color,
        sparks: Bool,
        rhythm: AudioRhythmState
    ) -> some View {
        switch style {
        case .flow:
            StageFlowLineView(
                line: line,
                pos: pos,
                fade: fade,
                availableWidth: width,
                availableHeight: height,
                fontSize: fontSize,
                accent: accent,
                sparks: sparks,
                rhythm: rhythm
            )
        case .partita:
            StagePartitaLineView(
                line: line,
                pos: pos,
                fade: fade,
                availableWidth: width,
                availableHeight: height,
                fontSize: fontSize,
                accent: accent,
                sparks: sparks,
                rhythm: rhythm
            )
        case .tilt:
            StageTiltLineView(
                line: line,
                pos: pos,
                fade: fade,
                availableWidth: width,
                accent: accent,
                sparks: sparks,
                rhythm: rhythm
            )
        }
    }
}

// MARK: - 1. 音律极光舞台底光层（克制而充满生机的音乐脉冲底光）

private struct StageAudioAtmosphereView: View {
    let accent: Color
    let rhythm: AudioRhythmState

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let vocalOpacity = 0.08 + 0.14 * rhythm.vocal + 0.07 * rhythm.beatPulse
            let bassScale = 0.88 + 0.24 * rhythm.bass + 0.16 * rhythm.beatPulse
            let bassOpacity = 0.06 + 0.15 * rhythm.bass + 0.09 * rhythm.beatPulse

            ZStack {
                // 中央人声感应柔光
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [accent.opacity(vocalOpacity), .clear],
                            center: .center,
                            startRadius: 4,
                            endRadius: max(w, h) * 0.42
                        )
                    )
                    .frame(width: w * 0.92, height: h * 0.56)
                    .scaleEffect(0.95 + 0.08 * rhythm.vocal)
                    .position(x: w * 0.5, y: h * 0.42)
                    .blendMode(.screen)

                // 低频踩鼓脉冲光浪
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                accent.opacity(bassOpacity),
                                Color.white.opacity(0.035 * rhythm.beatPulse),
                                .clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: w * 0.48
                        )
                    )
                    .frame(width: w * 0.85, height: w * 0.85)
                    .scaleEffect(bassScale)
                    .position(x: w * 0.5, y: h * 0.58)
                    .blendMode(.screen)
            }
        }
    }
}

// MARK: - 2. Flow（流光）模式：随机左右落位 + 散落飞入 + 音律光晕 + 余韵漂移

private struct StageFlowLineView: View {
    let line: LyricLine
    let pos: TimeInterval
    let fade: Double
    let availableWidth: Double
    let availableHeight: Double
    let fontSize: Double
    let accent: Color
    let sparks: Bool
    let rhythm: AudioRhythmState

    var body: some View {
        let charLen = StageMath.wordsLength(line.words[...])
        let adaptiveFontSize: Double = {
            if charLen > 22 { return fontSize * 0.78 }
            if charLen > 12 { return fontSize * 0.88 }
            return fontSize * 0.94
        }()
        let spreadScale = 0.42
        let marginScale = 0.92
        let shapes = StageMath.stageShapes(for: line, fontSize: adaptiveFontSize, spreadScale: spreadScale)
        let rows = StageMath.flowRows(
            for: line,
            shapes: shapes,
            fontSize: adaptiveFontSize,
            availableWidth: max(180, availableWidth),
            marginScale: marginScale
        )
        let placement = StageMath.flowPlacement(for: line, containerWidth: availableWidth)
        let isCompactWidth = availableWidth < 460
        let rowAlignment: HorizontalAlignment = {
            if isCompactWidth { return .center }
            switch placement.alignment {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }()
        let frameAlignment: Alignment = {
            if isCompactWidth { return .center }
            switch placement.alignment {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }()
        let horizontalSway: Double = {
            guard isCompactWidth else { return 0 }
            switch placement.alignment {
            case .leading: return -14.0
            case .center: return 0.0
            case .trailing: return 14.0
            }
        }()
        let verticalShift = placement.verticalShiftRatio * availableHeight * (isCompactWidth ? 0.55 : 1.0)
        let exitLift = (1.0 - fade) * -14.0
        let exitScale = 1.0 - (1.0 - fade) * 0.04

        VStack(alignment: rowAlignment, spacing: max(18, adaptiveFontSize * 0.62)) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, wordIndices in
                HStack(spacing: 0) {
                    ForEach(wordIndices, id: \.self) { idx in
                        if idx < line.words.count, idx < shapes.count {
                            let rawState = StageMath.stageWordState(
                                word: line.words[idx],
                                shape: shapes[idx],
                                pos: pos,
                                rhythm: rhythm,
                                horizontalSpreadScale: 0.42
                            )
                            let safeState: WordRenderState = {
                                var st = rawState
                                // 控制单字竖直散落幅度，防止上下行发生字母碰撞
                                st.y = min(10.0, max(-10.0, st.y))
                                if idx == wordIndices.first {
                                    st.x = max(-10.0, st.x)
                                }
                                if idx == wordIndices.last {
                                    st.x = min(10.0, st.x)
                                }
                                return st
                            }()
                            StageWordNodeView(
                                word: line.words[idx],
                                shape: shapes[idx],
                                state: safeState,
                                fontSize: adaptiveFontSize,
                                accent: accent,
                                sparks: sparks,
                                rhythm: rhythm,
                                trailingMargin: shapes[idx].margin * marginScale
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: availableWidth, alignment: frameAlignment)
        .offset(x: horizontalSway, y: verticalShift + exitLift)
        .scaleEffect(exitScale)
        .opacity(fade)
    }
}

// MARK: - 3. Steps（云阶 / Partita）模式：不规则阶梯 + L型直角动态导标 + 逐词弹簧

private struct StagePartitaLineView: View {
    let line: LyricLine
    let pos: TimeInterval
    let fade: Double
    let availableWidth: Double
    let availableHeight: Double
    let fontSize: Double
    let accent: Color
    let sparks: Bool
    let rhythm: AudioRhythmState

    var body: some View {
        let rows = StageMath.partitaRows(for: line, height: max(280, availableHeight))
        let totalChars = StageMath.wordsLength(line.words[...])
        let rowFontSize = (totalChars > 40 ? fontSize * 0.78 : fontSize) * 0.80
        let grow = 1.0 + 0.05 * (1.0 - fade)

        VStack(spacing: max(14, rowFontSize * 0.56)) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                if row.from < row.to, row.to <= line.words.count {
                    partitaRowView(
                        row: row,
                        isLastRow: rIdx == rows.count - 1,
                        rowFontSize: rowFontSize
                    )
                }
            }
        }
        .padding(.horizontal, 8)
        .scaleEffect(grow)
        .opacity(fade)
    }

    @ViewBuilder
    private func partitaRowView(
        row: PartitaRow,
        isLastRow: Bool,
        rowFontSize: Double
    ) -> some View {
        let rowWords = line.words[row.from..<row.to]
        let rowMotion = StageMath.partitaRowMotion(
            words: rowWords,
            row: row,
            pos: pos,
            rhythm: rhythm
        )
        let seed = (rowWords[row.from].start * 1000.0).rounded() / 1000.0
        let rowShapes = buildRowWordShapes(
            words: rowWords,
            rowScale: row.scale,
            seed: seed,
            fontSize: rowFontSize,
            isLastRow: isLastRow
        )

        HStack(spacing: 0) {
            ForEach(Array(rowWords.enumerated()), id: \.offset) { localIdx, word in
                partitaWordNodeView(word: word, shape: rowShapes[localIdx], rowFontSize: rowFontSize)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background {
            // 对照桌面 ui_stage_styles.go:248-261 实时绘制的 L 型直角引导角标
            PartitaGuideCornerOverlay(
                isLeft: row.left,
                motion: rowMotion,
                accent: accent
            )
        }
        .offset(
            x: min(max(rowMotion.offsetX, -availableWidth * 0.14), availableWidth * 0.14),
            y: rowMotion.offsetY
        )
        .scaleEffect(rowMotion.scale)
        .opacity(rowMotion.opacity)
    }

    private func partitaWordNodeView(word: LyricWord, shape: WordShape, rowFontSize: Double) -> some View {
        var state = StageMath.stageWordState(
            word: word,
            shape: shape,
            pos: pos,
            rhythm: rhythm,
            horizontalSpreadScale: 0.44
        )
        state.y = min(8.0, max(-8.0, state.y))
        return StageWordNodeView(
            word: word,
            shape: shape,
            state: state,
            fontSize: rowFontSize,
            accent: accent,
            sparks: sparks,
            rhythm: rhythm,
            trailingMargin: shape.margin * 0.72
        )
    }

    private func buildRowWordShapes(
        words: ArraySlice<LyricWord>,
        rowScale: Double,
        seed: Double,
        fontSize: Double,
        isLastRow: Bool
    ) -> [WordShape] {
        var shapes: [WordShape] = []
        var widths: [Double] = []
        shapes.reserveCapacity(words.count)
        widths.reserveCapacity(words.count)
        let boundedRowScale = min(1.38, max(0.86, rowScale * 0.86))

        for (i, word) in words.enumerated() {
            let ws = seed + Double(i) * 7.13
            widths.append(StageMath.wordWidth(word.text, fontSize: fontSize))
            shapes.append(
                WordShape(
                    x: (StageMath.lineRandom(seed: ws, offset: 1) - 0.5) * 12,
                    y: (StageMath.lineRandom(seed: ws, offset: 2) - 0.5) * 12,
                    rotate: (StageMath.lineRandom(seed: ws, offset: 3) - 0.5) * 6,
                    scale: boundedRowScale,
                    drift: (StageMath.lineRandom(seed: ws, offset: 8) - 0.5) * 18,
                    margin: 0,
                    last: false
                )
            )
        }
        StageMath.spaceWords(&shapes, widths: widths, gap: fontSize * 0.1)
        if !shapes.isEmpty {
            shapes[shapes.count - 1].margin = 0
            shapes[shapes.count - 1].last = isLastRow
        }
        return shapes
    }
}

/// 云阶 L 型直角矢量引导标（随歌唱阶段从拐角展开、亮显主题色并轻泛音律霓虹）
private struct PartitaGuideCornerOverlay: View {
    let isLeft: Bool
    let motion: StagePartitaRowMotion
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let g = motion.guideProgress
            guard g > 0.01, size.width > 4, size.height > 4 else { return }

            let baseColor: Color = (motion.guideState == .singing) ? accent : .white
            let strokeColor = baseColor.opacity(motion.guideAlpha)
            let bottom = size.height
            let vertLen = min(30.0, size.height + 14.0) * g
            let horizLen = (size.width + 26.0) * g
            let lineWidth: CGFloat = (motion.guideState == .singing) ? 1.5 : 1.0

            var path = Path()
            if isLeft {
                let x = -6.0
                path.move(to: CGPoint(x: x, y: bottom + 12.0))
                path.addLine(to: CGPoint(x: x, y: bottom + 12.0 - vertLen))
                path.move(to: CGPoint(x: -12.0, y: bottom + 5.0))
                path.addLine(to: CGPoint(x: -12.0 + horizLen, y: bottom + 5.0))
            } else {
                let x = size.width + 6.0
                path.move(to: CGPoint(x: x, y: bottom + 12.0))
                path.addLine(to: CGPoint(x: x, y: bottom + 12.0 - vertLen))
                path.move(to: CGPoint(x: size.width + 12.0, y: bottom + 5.0))
                path.addLine(to: CGPoint(x: size.width + 12.0 - horizLen, y: bottom + 5.0))
            }

            if motion.guideState == .singing {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: accent.opacity(0.65), radius: 5))
                    layer.stroke(path, with: .color(strokeColor), lineWidth: lineWidth)
                }
            } else {
                context.stroke(path, with: .color(strokeColor), lineWidth: lineWidth)
            }
        }
        .padding(-16)
        .allowsHitTesting(false)
    }
}

// MARK: - 4. Tilt（倾诉）模式：标点切段 + 防折行动态缩放 + 斜体波浪字符 + 逐字正弦脉冲

private struct StageTiltLineView: View {
    let line: LyricLine
    let pos: TimeInterval
    let fade: Double
    let availableWidth: Double
    let accent: Color
    let sparks: Bool
    let rhythm: AudioRhythmState

    var body: some View {
        let rawBase = min(availableWidth * 0.115, 42.0)
        let layout = StageMath.fitTiltLayout(
            for: line,
            maxWidth: max(200.0, availableWidth - 16.0),
            baseFontSize: rawBase
        )
        let exitRise = -12.0 * (1.0 - fade)

        VStack(spacing: max(10, layout.fontSize * 0.34)) {
            ForEach(Array(layout.parts.enumerated()), id: \.offset) { pIdx, part in
                if part.from < part.to, part.to <= line.words.count {
                    StageTiltPartRowView(
                        words: line.words[part.from..<part.to],
                        part: part,
                        pos: pos,
                        size: layout.fontSize,
                        accent: accent,
                        sparks: sparks,
                        isLastPart: pIdx == layout.parts.count - 1,
                        rhythm: rhythm
                    )
                }
            }
        }
        .padding(.horizontal, 20)
        .offset(y: exitRise)
        .opacity(fade)
    }
}

private struct StageTiltPartRowView: View {
    let words: ArraySlice<LyricWord>
    let part: TiltPart
    let pos: TimeInterval
    let size: Double
    let accent: Color
    let sparks: Bool
    let isLastPart: Bool
    let rhythm: AudioRhythmState

    private struct CharToken: Identifiable {
        let id: String
        let text: String
        let isSpace: Bool
        let charStart: TimeInterval
        let charDuration: TimeInterval
        let charOrderIndex: Int
        let sparkWordStart: TimeInterval?
        let isFinalWord: Bool
    }

    var body: some View {
        let motion = StageMath.tiltPartMotion(
            words: words,
            part: part,
            pos: pos,
            size: size,
            rhythm: rhythm
        )
        let firstWordStart = words.first?.start ?? pos
        let partSince = pos - (firstWordStart - StageMath.tiltLead)
        let tokens = buildTokens()
        let baseColor: Color = motion.useAccentColor ? accent : .white

        HStack(spacing: 0) {
            ForEach(tokens) { token in
                if token.isSpace {
                    Color.clear
                        .frame(width: motion.spaceWidth, height: 1)
                } else {
                    let chMotion = StageMath.tiltCharMotion(
                        partSince: partSince,
                        charDuration: token.charDuration,
                        charStart: token.charStart,
                        charOrderIndex: token.charOrderIndex,
                        part: part,
                        size: motion.fontSize,
                        pos: pos,
                        rhythm: rhythm
                    )
                    let seed = ((token.sparkWordStart ?? 0) * 1000.0).rounded()
                    let sparkSince = token.sparkWordStart.map { pos - $0 } ?? -1

                    let charView = Text(token.text)
                        .font(.system(
                            size: motion.fontSize,
                            weight: motion.isLightWeight ? .light : .semibold
                        ))
                        .italic(motion.isItalic)
                        .foregroundStyle(baseColor.opacity(chMotion.opacity))
                        .shadow(
                            color: motion.useAccentColor
                                ? accent.opacity(0.45 * chMotion.highlightStrength)
                                : accent.opacity(0.55 * chMotion.highlightStrength),
                            radius: 6 + 6 * chMotion.highlightStrength
                        )
                        .padding(.trailing, motion.tracking * 0.65)
                        .scaleEffect(chMotion.scale)
                        .offset(y: chMotion.waveOffsetY)

                    if sparks, token.sparkWordStart != nil {
                        charView.overlay {
                            StageSparkCanvasOverlay(
                                since: sparkSince,
                                seed: seed,
                                accent: accent,
                                isLastWord: token.isFinalWord,
                                rhythm: rhythm
                            )
                        }
                    } else {
                        charView
                    }
                }
            }
        }
        .offset(y: motion.riseOffsetY)
        .scaleEffect(motion.scale)
        .opacity(motion.opacity)
    }

    private func buildTokens() -> [CharToken] {
        var result: [CharToken] = []
        var orderIdx = 0
        let allWords = Array(words)
        for (wIdx, word) in allWords.enumerated() {
            var trimmedRight = word.text
            while let last = trimmedRight.last, last.isWhitespace {
                trimmedRight.removeLast()
            }
            let hadTrailingSpace = trimmedRight.count < word.text.count
            let charCount = max(1, trimmedRight.count)
            let eachDur = max(0.05, (word.end - word.start) / Double(charCount))
            var localIdx = 0

            for ch in trimmedRight {
                let s = String(ch)
                if ch.isWhitespace {
                    result.append(
                        CharToken(
                            id: "\(wIdx)-\(localIdx)-sp",
                            text: " ",
                            isSpace: true,
                            charStart: word.start + Double(localIdx) * eachDur,
                            charDuration: eachDur,
                            charOrderIndex: orderIdx,
                            sparkWordStart: nil,
                            isFinalWord: false
                        )
                    )
                } else {
                    let isSparkAnchor = (localIdx == 0)
                    result.append(
                        CharToken(
                            id: "\(wIdx)-\(localIdx)-\(s)",
                            text: s,
                            isSpace: false,
                            charStart: word.start + Double(localIdx) * eachDur,
                            charDuration: eachDur,
                            charOrderIndex: orderIdx,
                            sparkWordStart: isSparkAnchor ? word.start : nil,
                            isFinalWord: isLastPart && wIdx == allWords.count - 1
                        )
                    )
                    orderIdx += 1
                }
                localIdx += 1
            }
            if hadTrailingSpace && wIdx < allWords.count - 1 {
                result.append(
                    CharToken(
                        id: "\(wIdx)-tail-sp",
                        text: " ",
                        isSpace: true,
                        charStart: word.end,
                        charDuration: 0.05,
                        charOrderIndex: orderIdx,
                        sparkWordStart: nil,
                        isFinalWord: false
                    )
                )
            }
        }
        return result
    }
}

// MARK: - 5. 单词渲染单元与真实光束轨迹火花

private struct StageWordNodeView: View {
    let word: LyricWord
    let shape: WordShape
    let state: WordRenderState
    let fontSize: Double
    let accent: Color
    let sparks: Bool
    let rhythm: AudioRhythmState
    let trailingMargin: Double

    var body: some View {
        let glowBlur = fontSize * (0.18 + 0.08 * rhythm.bass)

        ZStack {
            if state.glow > 0.015 {
                Text(word.text)
                    .font(.system(size: fontSize, weight: .heavy))
                    .foregroundStyle(accent.opacity(min(1.0, 0.88 * state.glow)))
                    .blur(radius: glowBlur)
            }
            Text(word.text)
                .font(.system(size: fontSize, weight: .heavy))
                .foregroundStyle(.white.opacity(state.brightness))
                .blur(radius: state.blur * 0.42)
        }
        .fixedSize(horizontal: true, vertical: true)
        .overlay {
            if sparks && state.sparkSince >= 0 && state.sparkSince < StageMath.sparkTime {
                StageSparkCanvasOverlay(
                    since: state.sparkSince,
                    seed: (word.start * 1000.0).rounded(),
                    accent: accent,
                    isLastWord: shape.last,
                    rhythm: rhythm
                )
            }
        }
        .scaleEffect(state.scale)
        .rotationEffect(.degrees(state.rotate))
        .offset(x: state.x, y: state.y)
        .opacity(state.opacity)
        .padding(.trailing, trailingMargin)
    }
}

/// 真实桌面端放射光束轨迹火花（Canvas 高速飞驰线段，外扩叠层绝不剪裁边界）
private struct StageSparkCanvasOverlay: View {
    let since: TimeInterval
    let seed: Double
    let accent: Color
    let isLastWord: Bool
    let rhythm: AudioRhythmState

    private static let bleedPadding: CGFloat = 56

    var body: some View {
        Canvas { context, canvasSize in
            let targetSize = CGSize(
                width: max(4, canvasSize.width - Self.bleedPadding * 2),
                height: max(4, canvasSize.height - Self.bleedPadding * 2)
            )
            let streaks = StageMath.sparkStreaks(
                size: targetSize,
                since: since,
                seed: seed,
                isLastWord: isLastWord,
                rhythm: rhythm
            )
            guard !streaks.isEmpty else { return }

            let ox = Double(Self.bleedPadding)
            let oy = Double(Self.bleedPadding)

            for streak in streaks {
                let p0 = CGPoint(x: ox + streak.startX, y: oy + streak.startY)
                let p1 = CGPoint(x: ox + streak.endX, y: oy + streak.endY)

                var path = Path()
                path.move(to: p0)
                path.addLine(to: p1)

                // 外圈主题色柔和光晕
                context.stroke(
                    path,
                    with: .color(accent.opacity(streak.alpha * 0.45)),
                    style: StrokeStyle(lineWidth: streak.lineWidth * 2.2, lineCap: .round)
                )

                // 核心白热渐变高亮射线（头部近白、尾部显主题色）
                let gradient = Gradient(stops: [
                    .init(color: accent.opacity(streak.alpha * 0.85), location: 0),
                    .init(color: .white.opacity(streak.alpha * (0.45 + 0.55 * streak.whiteMix)), location: 1)
                ])
                context.stroke(
                    path,
                    with: .linearGradient(gradient, startPoint: p0, endPoint: p1),
                    style: StrokeStyle(lineWidth: streak.lineWidth, lineCap: .round)
                )
            }
        }
        .padding(-Self.bleedPadding)
        .allowsHitTesting(false)
    }
}

// MARK: - 6. 间奏三圆点（与音乐节拍共鸣并蓄能预告下一行）

private struct StageRhythmInterludeView: View {
    let pos: TimeInterval
    let from: TimeInterval
    let to: TimeInterval
    let accent: Color
    let rhythm: AudioRhythmState

    var body: some View {
        let state = StageMath.interludeDotsState(
            pos: pos,
            from: from,
            to: to,
            rhythm: rhythm
        )

        HStack(spacing: 20) {
            ForEach(0..<3, id: \.self) { idx in
                let lit = state.dotLit[idx]
                let phaseScale = 1.0 + 0.14 * lit * rhythm.beatPulse
                let preCueGlow = (idx == 2 ? state.preCuePulse : 0.0)

                ZStack {
                    if lit > 0.08 {
                        Circle()
                            .fill(accent.opacity(0.38 * lit + 0.25 * rhythm.bass))
                            .frame(width: 22, height: 22)
                            .blur(radius: 6 + 4 * rhythm.beatPulse)
                    }
                    Circle()
                        .fill(
                            Color.white.opacity(0.20 + 0.72 * lit + 0.08 * preCueGlow)
                        )
                        .frame(width: 14, height: 14)
                }
                .scaleEffect(state.breathScale * phaseScale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 7. 静音 / 间奏热门评论卡片与无歌词骨架

private struct StageQuietCommentCard: View {
    let comment: Comment
    let accent: Color
    let rhythm: AudioRhythmState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.95))
                    Text(I18n.t("Top Comment"))
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.58))
                    Spacer()
                }

                Text(comment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 20, weight: .semibold))
                    .lineSpacing(6)
                    .foregroundStyle(.white.opacity(0.94))
                    .multilineTextAlignment(.leading)
                    .lineLimit(6)

                HStack(spacing: 8) {
                    ArtworkView(
                        urlString: comment.avatarUrl,
                        pixelSize: 80,
                        size: 22,
                        cornerRadius: 11,
                        systemIcon: "person.crop.circle.fill"
                    )
                    Text(comment.author)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                    if let likes = comment.likes, likes > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "hand.thumbsup")
                                .font(.system(size: 11))
                            Text("\(likes)")
                                .font(.system(size: 11.5).monospacedDigit())
                        }
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.leading, 4)
                    }
                    Spacer()
                }
            }
            .padding(18)
            .frame(maxWidth: 440, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.065 + 0.02 * rhythm.bass))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.11 + 0.08 * rhythm.vocal), lineWidth: 0.75)
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct StageSkeletonView: View {
    let accent: Color
    let maxWidth: Double
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(pulse ? 0.14 : 0.07))
                .frame(width: maxWidth, height: 24)
            RoundedRectangle(cornerRadius: 8)
                .fill(accent.opacity(pulse ? 0.18 : 0.08))
                .frame(width: maxWidth * 0.72, height: 24)
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(pulse ? 0.12 : 0.06))
                .frame(width: maxWidth * 0.56, height: 20)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

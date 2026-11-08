// NowPlayingView.swift
// 对应原项目 internal/app/ui_nowplaying.go, ui_stage.go, ui_stage_styles.go, ui_wall.go, ui_comments.go, ui_quiet.go

#if canImport(MyGoMusicCore)
import MyGoMusicCore
#endif
import SwiftUI

public struct NowPlayingView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var newCommentText = ""
    @State private var scrubbingPosition: TimeInterval? = nil

    public init() {}

    public var body: some View {
        let track = app.player.currentTrack
        ZStack {
            if let track {
                VStack(spacing: 14) {
                    // 2. 顶部下拉关闭指示器与面板切换标签栏
                    topHeaderBar(for: track)

                    // 3. 主内容区（根据选中的标签页切换）
                    Group {
                        switch app.activeNowPlayingPane {
                        case .lyrics:
                            lyricsMainView(for: track, scrubbingPosition: scrubbingPosition)
                        case .stage:
                            StageVisualizerPaneView(track: track)
                        case .queue:
                            queuePaneView
                        case .wall:
                            CoverWallPaneView()
                        case .comments:
                            commentsPaneView(for: track)
                        case .show:
                            podcastEpisodeAboutPane(for: track)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                    // 4. 底部播放进度与传输控制区（单独抽离子视图，隔离高频 position 重绘）
                    NowPlayingBottomControlsView(
                        player: app.player,
                        track: track,
                        smoke: app.settings.smoke,
                        volume: $app.settings.volume,
                        scrubbingPosition: $scrubbingPosition
                    )
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 20)
            } else {
                Text(I18n.t("Not Playing"))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 沉浸式背景放在 background 中，不参与布局计算，避免把正文撑出屏幕
        .background {
            NowPlayingBackdropView(imageURL: track?.album.imageUrl, player: app.player, fogEnabled: app.settings.fog)
                .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 顶部面板切换栏（对应 npTabs / stageStyleButton）

    private func topHeaderBar(for track: Track) -> some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(.white.opacity(0.28))
                .frame(width: 40, height: 5)
                .onTapGesture {
                    dismiss()
                }

            HStack(spacing: 6) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(availablePanes(for: track)) { pane in
                            let selected = (app.activeNowPlayingPane == pane)
                            Button {
                                withAnimation(.snappy(duration: 0.22)) {
                                    app.activeNowPlayingPane = pane
                                    if pane == .lyrics || pane == .stage {
                                        app.settings.lyricsStage = (pane == .stage)
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(I18n.t(pane.labelKey))
                                        .font(.system(size: 13, weight: .semibold))
                                    if pane == .comments && app.currentTrackCommentTotal > 0 {
                                        Text("\(app.currentTrackCommentTotal)")
                                            .font(.system(size: 11, weight: .bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(.white.opacity(0.18), in: Capsule())
                                    }
                                }
                                .foregroundStyle(selected ? .white : .white.opacity(0.55))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 6)
                                .background(selected ? .white.opacity(0.16) : .clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if app.activeNowPlayingPane == .stage {
                    stageStyleMenuButton
                }
            }
        }
    }

    private func availablePanes(for track: Track) -> [NowPlayingPane] {
        var panes: [NowPlayingPane]
        if track.isEpisode {
            panes = [.show, .queue]
        } else {
            panes = [.lyrics, .stage, .queue, .wall]
        }
        let sid = track.source ?? app.activeSourceID
        if let src = app.source(forID: sid), src.can("comments") {
            panes.append(.comments)
        }
        return panes
    }

    private var stageStyleMenuButton: some View {
        Menu {
            ForEach(StageStyle.allCases) { style in
                Button {
                    app.settings.stageStyle = style
                } label: {
                    HStack {
                        Text(I18n.t(style.labelKey))
                        if app.settings.stageStyle == style {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Toggle(I18n.t("Sparks"), isOn: $app.settings.stageSparks)
        } label: {
            HStack(spacing: 4) {
                Text(I18n.t(app.settings.stageStyle.labelKey))
                    .font(.system(size: 12.5, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(.white.opacity(0.12), in: Capsule())
        }
    }

    // MARK: - 封面与滚动歌词主视图（对应 nowPlayingBody / lyricsPane）

    private func lyricsMainView(for track: Track, scrubbingPosition: TimeInterval?) -> some View {
        VStack(spacing: 16) {
            // 顶部可 3D 倾斜与滑动切歌的封面卡片（单独封装，避免手势与动画触碰下层歌词）
            NowPlayingCoverHeaderView(
                track: track,
                isPlaying: app.player.isPlaying,
                radioName: app.player.radioName,
                isLiked: app.isTrackLiked(track),
                onLike: {
                    Task { await app.toggleLike(track) }
                },
                onNext: {
                    app.player.next()
                },
                onPrev: {
                    app.player.previous()
                },
                onExitRadio: {
                    app.player.exitRadio()
                }
            )

            // 滚动歌词区（直接传入 player 与 scrubbingPosition，实现拖动实时跟随与精准回弹）
            LyricsScrollView(
                player: app.player,
                scrubbingPosition: scrubbingPosition,
                hotCommentsEnabled: app.settings.hotComments,
                comments: app.currentTrackComments,
                onSeek: { sec in
                    app.player.seek(to: sec)
                }
            )
        }
    }

    // MARK: - 待播清单（Up Next）与评论页

    private var queuePaneView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                let ordered = app.player.orderedQueue
                ForEach(Array(ordered.enumerated()), id: \.offset) { orderIdx, tr in
                    let isCurrent = (orderIdx == app.player.currentOrderIndex)
                    HStack(spacing: 12) {
                        ArtworkView(urlString: tr.album.imageUrl, pixelSize: 120, size: 42, cornerRadius: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr.name)
                                .font(.system(size: 14.5, weight: isCurrent ? .bold : .medium))
                                .foregroundStyle(isCurrent ? MyGoTheme.accent : .white)
                                .lineLimit(1)
                            Text(tr.artistNames)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        Spacer()
                        if isCurrent {
                            EqualizerBarsView(bands: app.player.audioBands, isPlaying: app.player.isPlaying, color: MyGoTheme.accent)
                        }
                        Button {
                            app.player.removeFromQueue(atOrderIndex: orderIdx)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(isCurrent ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        app.player.jumpToOrderIndex(orderIdx)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func commentsPaneView(for track: Track) -> some View {
        VStack(spacing: 12) {
            ScrollView {
                if app.isLoadingComments && app.currentTrackComments.isEmpty {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if app.currentTrackComments.isEmpty {
                    Text(I18n.t("No comments yet"))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(app.currentTrackComments) { comment in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(comment.author)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.85))
                                    Spacer()
                                    Text(I18n.relativeTime(from: comment.time))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.4))
                                    if let likes = comment.likes, likes > 0 {
                                        HStack(spacing: 3) {
                                            Image(systemName: comment.liked == true ? "heart.fill" : "heart")
                                                .font(.system(size: 11))
                                            Text("\(likes)")
                                                .font(.system(size: 11))
                                        }
                                        .foregroundStyle(.white.opacity(0.55))
                                    }
                                }
                                Text(comment.text)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                            .padding(12)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }

            let sid = track.source ?? app.activeSourceID
            if let src = app.source(forID: sid), src.can("postComment") {
                HStack(spacing: 10) {
                    TextField(I18n.t("Write a comment…"), text: $newCommentText)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.1), in: Capsule())

                    Button(I18n.t("Post")) {
                        let text = newCommentText
                        newCommentText = ""
                        Task { await app.postComment(text: text) }
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(MyGoTheme.accent, in: Capsule())
                    .disabled(newCommentText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func podcastEpisodeAboutPane(for track: Track) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(I18n.t("About This Episode"))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)

                if let pub = track.published, !pub.isEmpty {
                    Text(pub)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.55))
                }

                Text(track.description?.isEmpty == false ? track.description! : I18n.t("This episode has no description"))
                    .font(.system(size: 14.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - 封面卡片头部组件（独立封装以隔离手势与局部动画）

private struct NowPlayingCoverHeaderView: View {
    let track: Track
    let isPlaying: Bool
    let radioName: String?
    let isLiked: Bool
    let onLike: () -> Void
    let onNext: () -> Void
    let onPrev: () -> Void
    let onExitRadio: () -> Void

    @State private var coverTilt: CGSize = .zero

    var body: some View {
        HStack(spacing: 16) {
            ArtworkView(
                urlString: track.album.imageUrl,
                pixelSize: 600,
                size: 96,
                cornerRadius: 16
            )
            .shadow(color: .black.opacity(0.42), radius: 18, x: 0, y: 10)
            .rotation3DEffect(
                .degrees(Double(coverTilt.width / 8)),
                axis: (x: -coverTilt.height / 20, y: coverTilt.width / 20, z: 0)
            )
            .scaleEffect(isPlaying ? 1.0 : 0.92)
            .animation(.spring(duration: 0.45, bounce: 0.25), value: isPlaying)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        coverTilt = value.translation
                    }
                    .onEnded { value in
                        withAnimation(.spring()) {
                            coverTilt = .zero
                        }
                        if value.translation.width < -65 {
                            onNext()
                        } else if value.translation.width > 65 {
                            onPrev()
                        }
                    }
            )

            VStack(alignment: .leading, spacing: 5) {
                if let radio = radioName, !radio.isEmpty {
                    Button {
                        onExitRadio()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 11))
                            Text(radio)
                                .font(.system(size: 11, weight: .bold))
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Text(track.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(track.artistNames)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer()

            Button {
                onLike()
            } label: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 21))
                    .foregroundStyle(isLiked ? MyGoTheme.accent : .white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 底部播放控制与进度条（独立订阅 player，隔离高频 position 触发整屏重绘）

private struct NowPlayingBottomControlsView: View {
    @ObservedObject var player: PlayerEngine
    let track: Track
    let smoke: Bool
    @Binding var volume: Double
    @Binding var scrubbingPosition: TimeInterval?

    var body: some View {
        let totalDuration = max(player.duration, track.durationSeconds, 1)
        let currentPos = scrubbingPosition ?? player.position

        VStack(spacing: 12) {
            if let errMsg = player.errorMessage, !errMsg.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.yellow)
                    Text(errMsg)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        player.retryCurrentTrack()
                    } label: {
                        Text("重试")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(MyGoTheme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // 进度滑块与无损音质徽章
            VStack(spacing: 4) {
                ZStack {
                    ProgressSeekBar(
                        value: Binding(
                            get: { min(max(currentPos, 0), totalDuration) },
                            set: { newVal in
                                scrubbingPosition = newVal
                            }
                        ),
                        duration: totalDuration,
                        onEditingChanged: { editing in
                            if !editing {
                                let target = scrubbingPosition ?? player.position
                                scrubbingPosition = nil
                                player.seek(to: target)
                            }
                        }
                    )
                    .tint(smoke ? MyGoTheme.accent : .white)

                    if smoke && player.isPlaying && !player.isLoading && scrubbingPosition == nil {
                        ProgressSmokeView(
                            progress: CGFloat(min(max(currentPos / totalDuration, 0), 1)),
                            level: CGFloat(player.audioBands.first ?? 0.15)
                        )
                        .frame(height: 44)
                        .offset(y: -7)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .frame(height: 30)

                HStack {
                    Text(MyGoTheme.formatClock(currentPos))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))

                    Spacer()

                    if let st = player.currentStream,
                       (st.quality == "lossless" || st.type == "flac" || st.type == "wav") {
                        Text(I18n.t("Lossless"))
                            .font(.system(size: 9.5, weight: .heavy))
                            .foregroundStyle(MyGoTheme.losslessGold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(MyGoTheme.losslessGold.opacity(0.6), lineWidth: 1)
                            )
                    }

                    Spacer()

                    let rightLabel = player.isLoading
                        ? I18n.t("Buffering…")
                        : "-" + MyGoTheme.formatClock(max(0, totalDuration - currentPos))
                    Text(rightLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            // 播放控制按钮（随机、上一首、播放/暂停、下一首、循环）
            HStack(spacing: 28) {
                Button {
                    player.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(player.shuffle ? MyGoTheme.accent : .white.opacity(0.5))
                }
                .buttonStyle(.plain)

                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    player.togglePlay()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.white.opacity(0.16))
                            .frame(width: 62, height: 62)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: player.isPlaying ? 0 : 2)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    player.cycleRepeat()
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(player.repeatMode != .off ? MyGoTheme.accent : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            // 音量滑块
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                Slider(value: $volume, in: 0...1)
                    .tint(.white.opacity(0.75))
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct ProgressSeekBar: View {
    @Binding var value: Double
    let duration: Double
    let onEditingChanged: (Bool) -> Void
    @State private var isEditing = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - 12, 1)
            let fraction = min(max(value / max(duration, 1), 0), 1)
            let x = 6 + width * fraction

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: 3)
                Capsule().fill(MyGoTheme.accent).frame(width: max(3, width * fraction), height: 3)
                Circle()
                    .fill(Color(red: 1, green: 0.48, blue: 0.38))
                    .frame(width: 7, height: 7)
                    .shadow(color: MyGoTheme.accent.opacity(0.5), radius: 4)
                    .offset(x: x - 3.5)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isEditing {
                            isEditing = true
                            onEditingChanged(true)
                        }
                        value = duration * min(max((gesture.location.x - 6) / width, 0), 1)
                    }
                    .onEnded { gesture in
                        value = duration * min(max((gesture.location.x - 6) / width, 0), 1)
                        isEditing = false
                        onEditingChanged(false)
                    }
            )
            .accessibilityElement()
            .accessibilityRepresentation {
                Slider(value: $value, in: 0...max(duration, 1), onEditingChanged: onEditingChanged)
                    .accessibilityLabel(I18n.t("Playback progress"))
            }
        }
        .frame(height: 44)
    }
}

struct ProgressSmokeView: View {
    let progress: CGFloat
    let level: CGFloat

    // 桌面端约 1.4 秒、36 条粒子；手机端减少数量但提高单条可见度。
    private let life = 1.25
    private let wispCount = 24

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            Canvas { context, size in
                drawSmoke(
                    in: &context,
                    size: size,
                    now: timeline.date.timeIntervalSinceReferenceDate
                )
            }
        }
    }

    private func drawSmoke(in context: inout GraphicsContext, size: CGSize, now: Double) {
        let headX = 12 + (size.width - 24) * progress
        let centerY = size.height / 2
        let strength = min(max(level, 0.05), 1)
        let step = life / Double(wispCount)
        let latestBirth = floor(now / step)

        for index in 0..<wispCount {
            let birth = latestBirth - Double(index)
            let age = now - birth * step
            guard age >= 0, age < life else { continue }
            drawWisp(in: &context, headX: headX, centerY: centerY, birth: birth, age: age, strength: strength)
        }

        // 不绘制独立圆形光点，烟迹直接从细小的播放头后方连续散开。
    }

    private func drawWisp(
        in context: inout GraphicsContext,
        headX: CGFloat,
        centerY: CGFloat,
        birth: Double,
        age: Double,
        strength: CGFloat
    ) {
        let f = CGFloat(age / life)
        let a = Self.noise(birth * 1.37 + 1)
        let b = Self.noise(birth * 2.11 + 2)
        let c = Self.noise(birth * 3.19 + 3)
        let driftX = CGFloat(age * (18 + 22 * a))
        let driftY = CGFloat(age * (10 + 15 * b))
        let curl = CGFloat(sin(age * (2.5 + 2 * c) + b * .pi * 2)) * 7 * f
        let center = CGPoint(x: headX - driftX, y: centerY - driftY + curl)
        let origin = CGPoint(x: headX - driftX * 0.18, y: centerY - driftY * 0.06)
        let control = CGPoint(
            x: (origin.x + center.x) / 2 + curl * 1.4,
            y: (origin.y + center.y) / 2 - CGFloat(3 + 5 * b)
        )
        var wisp = Path()
        wisp.move(to: origin)
        wisp.addQuadCurve(to: center, control: control)
        let alpha = 0.48 * pow(Double(1 - f), 1.35) * (0.55 + 0.45 * Double(strength))
        context.stroke(
            wisp,
            with: .linearGradient(
                Gradient(colors: [MyGoTheme.accent.opacity(alpha), MyGoTheme.accent.opacity(alpha * 0.65), .clear]),
                startPoint: origin,
                endPoint: center
            ),
            style: StrokeStyle(lineWidth: 2.2 - 1.35 * f, lineCap: .round)
        )
    }

    private static func noise(_ seed: Double) -> Double {
        let value = sin(seed * 127.1) * 43_758.5453
        return value - floor(value)
    }
}

// MARK: - 歌词高亮离散层级与单行缓存渲染（极大缩减 Diff 范围与避免级联刷新）

private enum LyricHighlightTier: Equatable {
    case current
    case near1
    case near2
    case far
}

private struct LyricRowView: View, Equatable {
    let index: Int
    let line: LyricLine
    let tier: LyricHighlightTier
    let onSeek: (TimeInterval) -> Void

    static func == (lhs: LyricRowView, rhs: LyricRowView) -> Bool {
        lhs.index == rhs.index &&
        lhs.tier == rhs.tier &&
        lhs.line.text == rhs.line.text &&
        lhs.line.translation == rhs.line.translation
    }

    var body: some View {
        let isCurrent = (tier == .current)
        let opacity: Double = {
            switch tier {
            case .current: return 1.0
            case .near1: return 0.58
            case .near2: return 0.42
            case .far: return 0.24
            }
        }()

        VStack(alignment: .leading, spacing: 4) {
            Text(line.text)
                .font(.system(size: isCurrent ? 23 : 18, weight: isCurrent ? .bold : .semibold))
                .foregroundStyle(isCurrent ? .white : .white.opacity(opacity))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if !line.translation.isEmpty {
                Text(line.translation)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isCurrent ? .white.opacity(0.80) : .white.opacity(opacity * 0.75))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onSeek(line.at)
        }
    }
}

// MARK: - 滚动歌词组件（含间奏热评浮层，高性能实时驱动版）

private struct LyricsScrollView: View {
    @ObservedObject var player: PlayerEngine
    let scrubbingPosition: TimeInterval?
    let hotCommentsEnabled: Bool
    let comments: [Comment]
    let onSeek: (TimeInterval) -> Void

    // 缓存间奏检测结果，避免在每次 body 评估时重复对所有行做遍历和正则匹配
    @State private var cachedQuiets: [LyricQuiet] = []

    // 用户手动拖拽/浏览歌词状态
    @State private var isUserScrolling: Bool = false
    @State private var autoSnapTask: Task<Void, Never>? = nil
    @State private var seekAlignmentTask: Task<Void, Never>? = nil

    /// 对标桌面端黄金分割视线焦点（视口由顶向下的 32% 位置，下方留足接下来演唱的 3~5 行预览）
    private let lyricAnchor = UnitPoint(x: 0.5, y: 0.32)

    init(
        player: PlayerEngine,
        scrubbingPosition: TimeInterval? = nil,
        hotCommentsEnabled: Bool,
        comments: [Comment],
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.player = player
        self.scrubbingPosition = scrubbingPosition
        self.hotCommentsEnabled = hotCommentsEnabled
        self.comments = comments
        self.onSeek = onSeek
    }

    private var effectivePosition: TimeInterval {
        scrubbingPosition ?? player.position
    }

    /// 加入 0.08 秒视听前瞻补偿（消除音频解码至耳机的延迟，歌手开唱瞬间歌词正正好好高亮）
    private var currentIndex: Int {
        guard !player.lyrics.isEmpty else { return -1 }
        let pos = effectivePosition + 0.08
        return LyricsEngine.index(in: player.lyrics, at: pos)
    }

    /// 检测当前是否处于长间奏以显示热评
    private var activeQuietComment: Comment? {
        guard hotCommentsEnabled, !comments.isEmpty, !cachedQuiets.isEmpty else { return nil }
        let pos = effectivePosition
        for (idx, q) in cachedQuiets.enumerated() {
            if pos >= q.from + 1.0 && pos <= q.to - 1.5 {
                return comments[idx % comments.count]
            }
        }
        return nil
    }

    private func tier(for index: Int, current: Int) -> LyricHighlightTier {
        if current < 0 {
            return .far
        }
        let diff = abs(index - current)
        if diff == 0 {
            return .current
        } else if diff == 1 {
            return .near1
        } else if diff == 2 {
            return .near2
        } else {
            return .far
        }
    }

    private func refreshQuiets() {
        if hotCommentsEnabled && !player.lyrics.isEmpty {
            cachedQuiets = LyricsEngine.quiets(in: player.lyrics, trackLength: player.duration, least: 8.0)
        } else {
            cachedQuiets = []
        }
    }

    private func scrollToLine(index: Int, proxy: ScrollViewProxy, animated: Bool = true) {
        guard index >= 0 && index < player.lyrics.count else { return }
        if animated {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                proxy.scrollTo(index, anchor: lyricAnchor)
            }
        } else {
            proxy.scrollTo(index, anchor: lyricAnchor)
        }
    }

    private func scheduleAutoSnap(proxy: ScrollViewProxy) {
        autoSnapTask?.cancel()
        autoSnapTask = Task {
            // 松手后等待 2.5 秒，若用户无新动作，自动平滑弹回当前播放行！
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isUserScrolling = false
                let target = currentIndex
                if target >= 0 {
                    scrollToLine(index: target, proxy: proxy, animated: true)
                }
            }
        }
    }

    var body: some View {
        let lines = player.lyrics
        let loaded = player.lyricsLoaded
        let curIdx = currentIndex

        ZStack {
            if !loaded {
                ProgressView()
                    .tint(.white)
            } else if lines.isEmpty {
                Text(I18n.t("No lyrics. Enjoy the music."))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                GeometryReader { geo in
                    let topPad = max(geo.size.height * 0.32, 100)
                    let bottomPad = max(geo.size.height * 0.58, 160)

                    ScrollViewReader { proxy in
                        ZStack(alignment: .bottomTrailing) {
                            ScrollView(showsIndicators: false) {
                                // 使用标准 VStack 保证所有歌词行坐标绝对精确，无论如何拖拽/跳转均 100% 居中对齐，杜绝 Lazy 虚拟化偏移
                                VStack(alignment: .leading, spacing: 18) {
                                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                                        LyricRowView(
                                            index: idx,
                                            line: line,
                                            tier: tier(for: idx, current: curIdx),
                                            onSeek: { targetTime in
                                                autoSnapTask?.cancel()
                                                isUserScrolling = false
                                                onSeek(targetTime)
                                                scrollToLine(index: idx, proxy: proxy, animated: true)
                                            }
                                        )
                                        .id(idx)
                                    }
                                }
                                .padding(.top, topPad)
                                .padding(.bottom, bottomPad)
                            }
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 12)
                                    .onChanged { _ in
                                        autoSnapTask?.cancel()
                                        seekAlignmentTask?.cancel()
                                        if !isUserScrolling {
                                            withAnimation(.easeInOut(duration: 0.18)) {
                                                isUserScrolling = true
                                            }
                                        }
                                    }
                                    .onEnded { _ in
                                        scheduleAutoSnap(proxy: proxy)
                                    }
                            )
                            // 自然播放推进换行
                            .onChange(of: curIdx) { _, newIdx in
                                if scrubbingPosition == nil && !isUserScrolling && newIdx >= 0 {
                                    scrollToLine(index: newIdx, proxy: proxy, animated: true)
                                }
                            }
                            // 用户在底栏进度条拖拽时：歌词实时丝滑跟随手指高亮与滚动！
                            .onChange(of: scrubbingPosition) { _, newScrub in
                                guard newScrub != nil else { return }
                                autoSnapTask?.cancel()
                                seekAlignmentTask?.cancel()
                                isUserScrolling = false
                                let target = currentIndex
                                if target >= 0 {
                                    scrollToLine(index: target, proxy: proxy, animated: false)
                                }
                            }
                            // 拖拽松手（Seek）或外部跳转时：强制退出手动浏览状态，100% 精准无条件重定位目标行！
                            .onChange(of: player.seekRevision) { _, revision in
                                autoSnapTask?.cancel()
                                seekAlignmentTask?.cancel()
                                isUserScrolling = false
                                seekAlignmentTask = Task { @MainActor in
                                    await Task.yield()
                                    guard !Task.isCancelled, player.seekRevision == revision else { return }
                                    var target = currentIndex
                                    guard target >= 0 else { return }
                                    scrollToLine(index: target, proxy: proxy, animated: true)

                                    try? await Task.sleep(nanoseconds: 50_000_000)
                                    guard !Task.isCancelled, player.seekRevision == revision else { return }
                                    isUserScrolling = false
                                    target = currentIndex
                                    scrollToLine(index: target, proxy: proxy, animated: false)
                                }
                            }
                            .onAppear {
                                refreshQuiets()
                                let target = curIdx >= 0 ? curIdx : 0
                                DispatchQueue.main.async {
                                    scrollToLine(index: target, proxy: proxy, animated: false)
                                }
                            }
                            .onChange(of: player.currentTrack?.id) { _, _ in
                                refreshQuiets()
                                autoSnapTask?.cancel()
                                seekAlignmentTask?.cancel()
                                isUserScrolling = false
                                let target = curIdx >= 0 ? curIdx : 0
                                DispatchQueue.main.async {
                                    scrollToLine(index: target, proxy: proxy, animated: false)
                                }
                            }
                            .onChange(of: lines.count) { _, _ in
                                refreshQuiets()
                                let target = curIdx >= 0 ? curIdx : 0
                                DispatchQueue.main.async {
                                    scrollToLine(index: target, proxy: proxy, animated: false)
                                }
                            }

                            // 用户手动滑动浏览时，右下角优雅浮现一键回到当前播放胶囊按钮
                            if isUserScrolling {
                                Button {
                                    autoSnapTask?.cancel()
                                    isUserScrolling = false
                                    let target = currentIndex
                                    if target >= 0 {
                                        scrollToLine(index: target, proxy: proxy, animated: true)
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "scope")
                                            .font(.system(size: 11, weight: .bold))
                                        Text("回位")
                                            .font(.system(size: 12, weight: .bold))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .overlay(
                                        Capsule().stroke(Color.white.opacity(0.3), lineWidth: 0.8)
                                    )
                                    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 16)
                                .padding(.bottom, 24)
                                .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }
                }
                // 上下边缘渐隐，避免歌词被生硬截断
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.08),
                            .init(color: .black, location: 0.92),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(activeQuietComment != nil ? 0.15 : 1.0)
            }

            // 间奏热评浮层（对应 ui_quiet.go）
            if let hot = activeQuietComment {
                VStack(alignment: .leading, spacing: 10) {
                    Text(I18n.t("Top Comment").uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(MyGoTheme.accent)
                        .tracking(1.0)

                    Text("“\(hot.text)”")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .lineSpacing(4)

                    Text("— \(hot.author)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }
}

// MARK: - 律动舞台全屏视觉器（1:1 移植自 ui_stage.go 与 ui_stage_styles.go）

public struct StageVisualizerPaneView: View {
    @EnvironmentObject private var app: AppModel
    public let track: Track

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !app.player.isPlaying)) { timeline in
            GeometryReader { geo in
                let lines = app.player.lyrics
                let pos = app.player.position
                let curIdx = LyricsEngine.index(in: lines, at: pos)
                let width = Double(geo.size.width)
                let height = Double(geo.size.height)

                ZStack {
                    if !app.player.lyricsLoaded {
                        ProgressView()
                            .tint(.white)
                    } else if lines.isEmpty {
                        Text(I18n.t("No lyrics. Enjoy the music."))
                            .font(.system(size: 24, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.4))
                    } else if curIdx < 0 {
                        StageInterludeDotsView(
                            position: pos,
                            from: 0,
                            to: lines[0].at,
                            now: timeline.date
                        )
                    } else if curIdx + 1 < lines.count,
                              pos > lines[curIdx].end + 1.0,
                              lines[curIdx + 1].at - lines[curIdx].end > 4.0 {
                        StageInterludeDotsView(
                            position: pos,
                            from: lines[curIdx].end,
                            to: lines[curIdx + 1].at,
                            now: timeline.date
                        )
                    } else {
                        let currentLine = lines[curIdx]
                        switch app.settings.stageStyle {
                        case .flow:
                            StageFlowLineView(
                                line: currentLine,
                                position: pos,
                                width: width,
                                height: height,
                                sparks: app.settings.stageSparks
                            )
                        case .partita:
                            StagePartitaLineView(
                                line: currentLine,
                                position: pos,
                                width: width,
                                height: height,
                                sparks: app.settings.stageSparks
                            )
                        case .tilt:
                            StageTiltLineView(
                                line: currentLine,
                                position: pos,
                                width: width,
                                sparks: app.settings.stageSparks
                            )
                        }

                        // 底部翻译与下一行预告
                        VStack(spacing: 6) {
                            Spacer()
                            if !currentLine.translation.isEmpty {
                                Text(currentLine.translation)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .multilineTextAlignment(.center)
                            }
                            if curIdx + 1 < lines.count {
                                Text(lines[curIdx + 1].text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.32))
                                    .lineLimit(1)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

/// 流光（Flow）模式歌词渲染（对应 ui_stage.go 中的 stageLine + stageWord）
private struct StageFlowLineView: View {
    let line: LyricLine
    let position: TimeInterval
    let width: Double
    let height: Double
    let sparks: Bool

    var body: some View {
        let fontSize = min(42.0, max(24.0, width * 0.068))
        let shapes = StageMath.stageShapes(for: line, fontSize: fontSize)

        VStack(spacing: 12) {
            FlowLayoutWordsView(
                line: line,
                shapes: shapes,
                position: position,
                fontSize: fontSize,
                availableWidth: width - 32,
                sparks: sparks
            )
        }
        .padding(.horizontal, 16)
    }
}

/// 云阶（Steps / Partita）模式歌词渲染（对应 partitaLine）
private struct StagePartitaLineView: View {
    let line: LyricLine
    let position: TimeInterval
    let width: Double
    let height: Double
    let sparks: Bool

    var body: some View {
        let baseFontSize = min(34.0, max(20.0, width * 0.056))
        let rows = StageMath.partitaRows(for: line, height: height)

        VStack(spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                let slice = Array(line.words[row.from..<row.to])
                let firstStart = slice.first?.start ?? line.at
                let since = position - (firstStart - 0.08)
                let e = StageMath.springStep(since)
                let sideOffset = row.left ? -32.0 : 32.0
                let x = since > 0 ? StageMath.lerp(row.x + sideOffset, row.x * 0.35, e) : (row.x + sideOffset)
                let scale = since > 0 ? StageMath.lerp(0.85, 1.0, e) : 0.85
                let opacity = since > 0 ? StageMath.clamp01(since / 0.12) : 0.0

                HStack(spacing: 4) {
                    ForEach(Array(slice.enumerated()), id: \.offset) { wIdx, word in
                        let shape = WordShape(scale: row.scale, last: rIdx == rows.count - 1 && wIdx == slice.count - 1)
                        let st = StageMath.wordState(word: word, shape: shape, pos: position)
                        StageWordItemView(
                            word: word,
                            state: st,
                            fontSize: baseFontSize,
                            sparks: sparks,
                            isLast: shape.last
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(alignment: row.left ? .bottomLeading : .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(since > 0 ? MyGoTheme.accent : .white.opacity(0.22))
                        .frame(width: 48 * StageMath.easeOutCubic(since / 0.4), height: 2)
                }
                .offset(x: x, y: row.y)
                .scaleEffect(scale)
                .opacity(opacity)
            }
        }
    }
}

/// 倾诉（Tilt）模式歌词渲染（对应 tiltLine）
private struct StageTiltLineView: View {
    let line: LyricLine
    let position: TimeInterval
    let width: Double
    let sparks: Bool

    var body: some View {
        let parts = StageMath.tiltParts(for: line)
        let fontSize = min(38.0, max(22.0, width * 0.072))

        VStack(spacing: 14) {
            ForEach(Array(parts.enumerated()), id: \.offset) { pIdx, part in
                let words = Array(line.words[part.from..<part.to])
                let firstStart = words.first?.start ?? line.at
                let since = position - (firstStart - StageMath.tiltLead)
                let easeIn = StageMath.clamp01(1.0 - pow(1.0 - StageMath.clamp01(since / 0.55), 2))

                HStack(spacing: part.lean ? 4 : 2) {
                    ForEach(Array(words.enumerated()), id: \.offset) { wIdx, w in
                        let elapsed = position - w.start
                        let dur = max(0.2, min(0.9, w.end - w.start))
                        let swell = (elapsed >= 0 && elapsed <= dur) ? sin(elapsed / dur * .pi) : 0.0
                        let scale = 1.0 + swell * (part.lean ? 0.18 : 0.14)

                        Text(w.text)
                            .font(.system(size: part.tail ? fontSize * 1.15 : fontSize, weight: part.lean ? .light : .semibold))
                            .italic(part.lean)
                            .foregroundStyle(part.lean ? MyGoTheme.accent : .white)
                            .scaleEffect(scale)
                            .offset(y: part.lean ? (wIdx % 2 == 0 ? -4 : 4) * (1.5 - easeIn) : 0)
                            .overlay {
                                if sparks && elapsed >= 0 && elapsed < StageMath.sparkTime {
                                    SparkBurstOverlay(
                                        since: elapsed,
                                        seed: floor(w.start * 1000),
                                        isLast: pIdx == parts.count - 1 && wIdx == words.count - 1,
                                        originSize: CGSize(width: StageMath.wordWidth(w.text, fontSize: fontSize), height: fontSize)
                                    )
                                }
                            }
                    }
                }
                .offset(y: 20.0 * (1.0 - easeIn))
                .opacity(easeIn)
            }
        }
    }
}

private struct FlowLayoutWordsView: View {
    let line: LyricLine
    let shapes: [WordShape]
    let position: TimeInterval
    let fontSize: Double
    let availableWidth: Double
    let sparks: Bool

    var body: some View {
        let rows = StageMath.flowRows(for: line, shapes: shapes, fontSize: fontSize, availableWidth: availableWidth)
        VStack(spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(row, id: \.self) { idx in
                        let word = line.words[idx]
                        let shape = idx < shapes.count ? shapes[idx] : WordShape()
                        let state = StageMath.wordState(word: word, shape: shape, pos: position)
                        StageWordItemView(
                            word: word,
                            state: state,
                            fontSize: fontSize,
                            sparks: sparks,
                            isLast: shape.last
                        )
                        .padding(.trailing, CGFloat(shape.margin))
                    }
                }
            }
        }
    }
}

private struct StageWordItemView: View {
    let word: LyricWord
    let state: WordRenderState
    let fontSize: Double
    let sparks: Bool
    let isLast: Bool

    var body: some View {
        ZStack {
            if state.glow > 0.02 {
                Text(word.text)
                    .font(.system(size: fontSize, weight: .heavy))
                    .foregroundStyle(MyGoTheme.accent.opacity(0.85 * state.glow))
                    .blur(radius: fontSize * 0.18)
            }
            Text(word.text)
                .font(.system(size: fontSize, weight: .heavy))
                .foregroundStyle(.white.opacity(state.brightness))
                .blur(radius: state.blur * 0.4)
        }
        .fixedSize(horizontal: true, vertical: true)
        .overlay {
            if sparks && state.sparkSince >= 0 && state.sparkSince < StageMath.sparkTime {
                SparkBurstOverlay(
                    since: state.sparkSince,
                    seed: floor(word.start * 1000),
                    isLast: isLast,
                    originSize: CGSize(width: StageMath.wordWidth(word.text, fontSize: fontSize), height: fontSize)
                )
            }
        }
        .scaleEffect(state.scale)
        .rotationEffect(.degrees(state.rotate))
        .offset(x: state.x * 0.35, y: state.y * 0.35)
        .opacity(state.opacity)
    }
}

/// 火花粒子飞溅绘制器（对应 ui_stage_styles.go 中的 stageSparks）
private struct SparkBurstOverlay: View {
    let since: Double
    let seed: Double
    let isLast: Bool
    let originSize: CGSize

    private var canvasExtent: CGFloat {
        max(72, max(originSize.width, originSize.height) * (isLast ? 3.2 : 2.4))
    }

    var body: some View {
        Canvas { context, size in
            let t = since / StageMath.sparkTime
            guard t >= 0 && t < 1 else { return }
            let cx = size.width / 2
            let cy = size.height / 2
            let count = isLast ? 16 : 9
            let sourceWidth = Double(originSize.width)
            let sourceHeight = Double(originSize.height)
            let reach = Double(max(originSize.width, originSize.height)) * 0.75 * (isLast ? 1.6 : 1.0)
            let out = 1.0 - pow(1.0 - t, 3)
            let fade = pow(1.0 - t, 2)

            for i in 0..<count {
                let randAngle = StageMath.lineRandom(seed: seed, offset: Double(i)) * 0.7
                let angle = 2.0 * .pi * (Double(i) + randAngle) / Double(count)
                let dx = cos(angle)
                let dy = sin(angle)
                let edge = sourceWidth * 0.35 * abs(dx) + sourceHeight * 0.35 * abs(dy)
                let speed = 0.55 + 0.45 * StageMath.lineRandom(seed: seed, offset: Double(i) + 50.0)
                let head = edge + reach * speed * out
                let tail = max(edge, head - reach * 0.3 * (1.0 - t))

                var path = Path()
                path.move(to: CGPoint(x: cx + dx * tail, y: cy + dy * tail))
                path.addLine(to: CGPoint(x: cx + dx * head, y: cy + dy * head))
                context.stroke(
                    path,
                    with: .color(MyGoTheme.accent.opacity(0.9 * fade)),
                    lineWidth: CGFloat(0.8 + 1.6 * (1.0 - t))
                )
            }
        }
        .frame(width: canvasExtent, height: canvasExtent)
        .allowsHitTesting(false)
    }
}

/// 间奏三圆点呼吸动画（对应 interlude）
private struct StageInterludeDotsView: View {
    let position: TimeInterval
    let from: TimeInterval
    let to: TimeInterval
    let now: Date

    var body: some View {
        let progress = StageMath.clamp01((position - from) / max(0.1, to - from))
        let breath = 1.0 + 0.12 * sin(now.timeIntervalSince1970 * 1000.0 / 420.0)

        HStack(spacing: 18) {
            ForEach(0..<3, id: \.self) { i in
                let lit = StageMath.clamp01(progress * 3.0 - Double(i))
                Circle()
                    .fill(.white.opacity(0.2 + 0.7 * lit))
                    .frame(width: 16, height: 16)
                    .scaleEffect(breath)
            }
        }
    }
}

// MARK: - 选歌封面墙（移植自 internal/app/ui_wall.go）

public struct CoverWallPaneView: View {
    @EnvironmentObject private var app: AppModel

    public var body: some View {
        let queue = app.player.orderedQueue
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            let cols = max(3, min(5, Int(sqrt(Double(max(queue.count, 9))))))
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(116), spacing: 14), count: cols),
                spacing: 14
            ) {
                ForEach(Array(queue.enumerated()), id: \.offset) { orderIdx, tr in
                    let isCurrent = (orderIdx == app.player.currentOrderIndex)
                    Button {
                        app.player.jumpToOrderIndex(orderIdx)
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                ArtworkView(
                                    urlString: tr.album.imageUrl,
                                    pixelSize: 300,
                                    size: 112,
                                    cornerRadius: 14
                                )
                                if isCurrent {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(MyGoTheme.accent, lineWidth: 3)
                                        .frame(width: 112, height: 112)
                                }
                            }
                            Text(tr.name)
                                .font(.system(size: 12, weight: isCurrent ? .bold : .medium))
                                .foregroundStyle(isCurrent ? MyGoTheme.accent : .white.opacity(0.85))
                                .lineLimit(1)
                                .frame(width: 112)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - 正在播放动态烟雾与流光背景（对应 backdrop.go）

struct NowPlayingBackdropView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var artworkLoader = ArtworkImageLoader()
    let imageURL: String?
    @ObservedObject var player: PlayerEngine
    let fogEnabled: Bool
    var preview: Bool = false

    var body: some View {
        ZStack {
            MyGoTheme.nowPlayingBg

            if let image = artworkLoader.image {
                GeometryReader { geo in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 65)
                        .opacity(0.30)
                }
                .clipped()
            }

            if fogEnabled {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: (!player.isPlaying && !preview) || reduceMotion)) { timeline in
                    Canvas { context, size in
                        drawFog(
                            in: &context,
                            size: size,
                            time: timeline.date.timeIntervalSinceReferenceDate,
                            tint: artworkLoader.dominantColor ?? MyGoTheme.accent,
                            bass: CGFloat(player.audioBands.first ?? 0.15)
                        )
                    }
                }
            }

            LinearGradient(
                colors: [.black.opacity(fogEnabled ? 0.10 : 0.18), .black.opacity(fogEnabled ? 0.34 : 0.48)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .task(id: "\(imageURL ?? "")|\(fogEnabled)") {
            await artworkLoader.load(rawURLString: imageURL, pixelSize: 200, extractDominantColor: fogEnabled) { url in
                app.imageHeaders(for: url)
            }
        }
    }

    private func drawFog(in context: inout GraphicsContext, size: CGSize, time: Double, tint: Color, bass: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        let phase = time * 0.16
        let beat = min(max(bass, 0), 1)

        for layerIndex in 0..<3 {
            let layer = CGFloat(layerIndex)
            let baseline = size.height * (0.34 + layer * 0.14 + 0.018 * sin(phase + Double(layer)))
            let thickness = size.height * (0.12 + beat * 0.025)
            let amplitude = min(size.height * (0.038 + beat * 0.016), 28) * (1 + layer * 0.12)
            var bank = Path()
            bank.move(to: CGPoint(x: 0, y: baseline))

            let segments = 12
            for step in 0..<segments {
                let x0 = size.width * CGFloat(step) / CGFloat(segments)
                let x1 = size.width * CGFloat(step + 1) / CGFloat(segments)
                let wave0 = sin(Double(step) * 0.72 + phase * (1.1 + Double(layer) * 0.12) + Double(layer) * 1.7)
                let wave1 = sin(Double(step + 1) * 0.72 + phase * (1.1 + Double(layer) * 0.12) + Double(layer) * 1.7)
                let y0 = baseline + amplitude * CGFloat(wave0)
                let y1 = baseline + amplitude * CGFloat(wave1)
                bank.addQuadCurve(
                    to: CGPoint(x: x1, y: y1),
                    control: CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2 - amplitude * 0.35)
                )
            }

            for step in (0..<segments).reversed() {
                let x0 = size.width * CGFloat(step + 1) / CGFloat(segments)
                let x1 = size.width * CGFloat(step) / CGFloat(segments)
                let wave0 = sin(Double(step + 1) * 0.58 + phase * 0.72 + Double(layer) * 2.1)
                let wave1 = sin(Double(step) * 0.58 + phase * 0.72 + Double(layer) * 2.1)
                let y0 = baseline + thickness + amplitude * 0.62 * CGFloat(wave0)
                let y1 = baseline + thickness + amplitude * 0.62 * CGFloat(wave1)
                bank.addQuadCurve(
                    to: CGPoint(x: x1, y: y1),
                    control: CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2 + amplitude * 0.2)
                )
            }
            bank.closeSubpath()

            let top = CGPoint(x: size.width * 0.5, y: baseline - amplitude)
            let bottom = CGPoint(x: size.width * 0.5, y: baseline + thickness + amplitude)
            context.drawLayer { fog in
                fog.addFilter(.blur(radius: min(size.width, size.height) * 0.055))
                fog.fill(
                    bank,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: tint.opacity(0.04), location: 0),
                            .init(color: tint.opacity(0.42 + Double(beat) * 0.10 - Double(layerIndex) * 0.035), location: 0.48),
                            .init(color: tint.opacity(0.09), location: 1)
                        ]),
                        startPoint: top,
                        endPoint: bottom
                    )
                )
            }
        }
    }
}

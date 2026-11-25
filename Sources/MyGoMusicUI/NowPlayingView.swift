// NowPlayingView.swift
// 对应原项目 internal/app/ui_nowplaying.go, ui_stage.go, ui_stage_styles.go, ui_wall.go, ui_comments.go, ui_quiet.go

#if canImport(MyGoMusicCore)
import MyGoMusicCore
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(MetalKit)
import MetalKit
#endif
import SwiftUI
#if canImport(QuartzCore)
import QuartzCore
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// 全局与阶段过渡共享的封面锚点信息（.cover 大封面 / .lyrics 左上封面 / UIKit 飞入飞出）
struct NowPlayingHeroArtworkSnapshot: Equatable {
    var globalRect: CGRect = .zero
    var cornerRadius: CGFloat = 12
    var isVisibleInCurrentPane: Bool = false
}

/// 跨 UIKit 外壳（NowPlayingModalContainer）与 SwiftUI 播放内页的 0 延迟桥接对象
@MainActor
final class NowPlayingModalBridge: ObservableObject {
    @Published var hideInnerHeroArtwork: Bool = false
    /// 展开或回弹结束解锁快照时递增，主动驱动 SwiftUI 上报静止全屏的真实封面坐标
    @Published var snapshotRefreshTick: Int = 0
    /// 宿主隐藏时置 true，暂停后台歌词滚动、舞台频谱等周期性动效实现零开销常驻复用
    @Published var isHostHidden: Bool = false
    /// 正在执行进出转场时置 true，减少并发重绘抢占 120Hz 转场帧率
    @Published var isTransitioning: Bool = false
    var currentHeroSnapshot: NowPlayingHeroArtworkSnapshot = .init()
    /// 在卡片外框正缩在底部或处于动画变形期间冻结快照写入，避免用缩放后的脏坐标污染全屏基准
    var freezeHeroSnapshotUpdates: Bool = false
    var canInteractiveDismiss: Bool = true
    var onRequestDismiss: (() -> Void)?
    /// 当前曲目专辑主色调（由 NowPlayingBackdropView 实时同步，供 UIKit 收拢底卡实心承接，杜绝退场透字）
    var currentBackdropTint: BackdropRGBColor = .defaultTint
    #if DEBUG
    var onDebugRunLyricsMorph: (() -> Void)?
    #endif

    /// 仅在全屏未缩放、坐标位于安全范围且未冻结时写入封面快照，从源头阻断缩放态 / y<0 脏坐标污染
    func updateHeroSnapshotIfValid(
        globalFrame: CGRect,
        cornerRadius: CGFloat,
        isHidden: Bool = false,
        widthRange: ClosedRange<CGFloat>,
        minXRange: ClosedRange<CGFloat> = 10...CGFloat.greatestFiniteMagnitude,
        minYRange: ClosedRange<CGFloat> = 36...240
    ) {
        guard !isHidden,
              !freezeHeroSnapshotUpdates,
              widthRange.contains(globalFrame.width),
              minXRange.contains(globalFrame.minX),
              minYRange.contains(globalFrame.minY) else {
            return
        }
        currentHeroSnapshot = NowPlayingHeroArtworkSnapshot(
            globalRect: globalFrame,
            cornerRadius: cornerRadius,
            isVisibleInCurrentPane: true
        )
    }
}

private struct MyGoNowPlayingModalBridgeKey: EnvironmentKey {
    static let defaultValue: NowPlayingModalBridge? = nil
}

private struct MyGoDismissNowPlayingKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private struct MyGoNowPlayingCanDismissChangedKey: EnvironmentKey {
    static let defaultValue: ((Bool) -> Void)? = nil
}

extension EnvironmentValues {
    var mygoNowPlayingModalBridge: NowPlayingModalBridge? {
        get { self[MyGoNowPlayingModalBridgeKey.self] }
        set { self[MyGoNowPlayingModalBridgeKey.self] = newValue }
    }

    var mygoDismissNowPlaying: (() -> Void)? {
        get { self[MyGoDismissNowPlayingKey.self] }
        set { self[MyGoDismissNowPlayingKey.self] = newValue }
    }

    var mygoOnNowPlayingCanDismissChanged: ((Bool) -> Void)? {
        get { self[MyGoNowPlayingCanDismissChangedKey.self] }
        set { self[MyGoNowPlayingCanDismissChangedKey.self] = newValue }
    }
}

private struct CoverHeroStageRectKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 10 && next.height > 10 {
            value = next
        }
    }
}

private struct LyricsHeroStageRectKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 10 && next.height > 10 {
            value = next
        }
    }
}

/// 仅订阅 hideInnerHeroArtwork 局部隐藏封面，避免整棵 NowPlayingView 因外层接棒刷新
private struct HeroArtworkOuterVisibilityGate<Content: View>: View {
    @ObservedObject var bridge: NowPlayingModalBridge
    let localForceHidden: Bool
    let content: Content

    init(bridge: NowPlayingModalBridge, localForceHidden: Bool, @ViewBuilder content: () -> Content) {
        self.bridge = bridge
        self.localForceHidden = localForceHidden
        self.content = content()
    }

    var body: some View {
        content.opacity((bridge.hideInnerHeroArtwork || localForceHidden) ? 0 : 1)
    }
}

/// 将宿主显隐态映射为子树的 `mygoIsViewVisible` 环境键，保证常驻隐藏时后台零 GPU/CPU 消耗
private struct NowPlayingVisibilityScope<Content: View>: View {
    @ObservedObject var bridge: NowPlayingModalBridge
    let content: Content

    init(bridge: NowPlayingModalBridge, @ViewBuilder content: () -> Content) {
        self.bridge = bridge
        self.content = content()
    }

    var body: some View {
        content.environment(\.mygoIsViewVisible, !bridge.isHostHidden)
    }
}

/// 仅订阅快照刷新与解锁事件，在展开/回弹静止后主动同步真实全屏封面坐标，零开销隔离重绘
private struct HeroSnapshotObserverOverlay: View {
    @ObservedObject var bridge: NowPlayingModalBridge
    let globalFrame: CGRect
    let cornerRadius: CGFloat
    let isHidden: Bool
    let widthRange: ClosedRange<CGFloat>
    var minXRange: ClosedRange<CGFloat> = 10...CGFloat.greatestFiniteMagnitude

    var body: some View {
        Color.clear
            .onAppear {
                publish(globalFrame)
            }
            .mygoOnChange(of: globalFrame) { _, newFrame in
                publish(newFrame)
            }
            .mygoOnChange(of: bridge.snapshotRefreshTick) { _, _ in
                publish(globalFrame)
            }
            .mygoOnChange(of: bridge.hideInnerHeroArtwork) { _, hidden in
                if !hidden {
                    publish(globalFrame)
                }
            }
    }

    private func publish(_ frame: CGRect) {
        bridge.updateHeroSnapshotIfValid(
            globalFrame: frame,
            cornerRadius: cornerRadius,
            isHidden: isHidden,
            widthRange: widthRange,
            minXRange: minXRange
        )
    }
}

public struct NowPlayingView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mygoNowPlayingModalBridge) private var externalModalBridge
    @Environment(\.mygoDismissNowPlaying) private var externalDismissNowPlaying
    @Environment(\.mygoOnNowPlayingCanDismissChanged) private var onCanDismissChanged

    @Namespace private var coverHeroNamespace
    @StateObject private var fallbackModalBridge = NowPlayingModalBridge()
    @State private var newCommentText = ""
    @State private var scrubbingPosition: TimeInterval? = nil
    @State private var containerSize: CGSize = CGSize(width: 393, height: 852)
    @State private var navPath = NavigationPath()
    @State private var showSaveQueueAlert = false
    @State private var saveQueuePlaylistName = ""

    // 「封面 ↔ 歌词」同源实体直飞与错峰文字过渡状态
    @State private var coverStageRect: CGRect = .zero
    @State private var lyricsStageRect: CGRect = .zero
    @State private var isPaneArtworkFlying: Bool = false
    @State private var transitioningFromPane: NowPlayingPane? = nil
    @State private var flyingArtworkRect: CGRect = .zero
    @State private var flyingArtworkCornerRadius: CGFloat = 12
    @State private var awaitingFlightTarget: NowPlayingPane? = nil
    @State private var paneFlightToken: Int = 0
    @State private var coverChromeOpacity: Double = 1.0
    @State private var lyricsChromeOpacity: Double = 1.0
    @State private var lyricsContentOffsetY: CGFloat = 0

    private static let stageCoordinateSpaceName = "NowPlayingStageSpace"

    private static let paneTransitionSpring = Animation.spring(
        response: 0.44,
        dampingFraction: 0.74,
        blendDuration: 0.04
    )

    private var activeBridge: NowPlayingModalBridge {
        externalModalBridge ?? fallbackModalBridge
    }

    public init() {}

    public var body: some View {
        NowPlayingVisibilityScope(bridge: activeBridge) {
            NavigationStack(path: $navPath) {
                ZStack(alignment: .top) {
                    NowPlayingBackdropView(
                        imageURL: app.player.currentTrack?.album.imageUrl,
                        player: app.player,
                        fogEnabled: app.settings.fog
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.all)

                    playerMainContent
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: app.activeNowPlayingPane == .cover ? .bottom : [])
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
                .navigationDestination(for: NavigationTarget.self) { target in
                    HomeView.buildDestination(for: target)
                }
                .environment(\.mygoNavigate) { target in
                    navPath.append(target)
                }
            }
            .preferredColorScheme(.dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { containerSize = proxy.size }
                    .mygoOnChange(of: proxy.size) { _, newSize in
                        containerSize = newSize
                    }
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            onCanDismissChanged?(navPath.isEmpty)
            activeBridge.canInteractiveDismiss = navPath.isEmpty
            #if DEBUG
            activeBridge.onDebugRunLyricsMorph = { [self] in
                Task { @MainActor in
                    await runDebugLyricsMorphSequence()
                }
            }
            #endif
            syncIdleTimerState()
        }
        .onDisappear {
            setIdleTimerDisabled(false)
            onCanDismissChanged?(true)
            activeBridge.canInteractiveDismiss = true
            isPaneArtworkFlying = false
            awaitingFlightTarget = nil
        }
        .mygoOnChange(of: navPath.count) { _, newCount in
            let canDismiss = (newCount == 0)
            onCanDismissChanged?(canDismiss)
            activeBridge.canInteractiveDismiss = canDismiss
        }
        .mygoOnChange(of: app.activeNowPlayingPane) { _, _ in
            syncIdleTimerState()
        }
        .mygoOnChange(of: app.player.isPlaying) { _, _ in
            syncIdleTimerState()
        }
        .mygoOnChange(of: scenePhase) { _, _ in
            syncIdleTimerState()
        }
        .mygoOnChange(of: app.isNowPlayingPresented) { _, _ in
            syncIdleTimerState()
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .mygoDebugDemoLyricsMorph)) { _ in
            Task { @MainActor in
                await runDebugLyricsMorphSequence()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mygoDebugSwitchPane)) { note in
            guard let sp = note.object as? String else { return }
            switch sp {
            case "lyrics": switchNowPlayingPane(to: .lyrics)
            case "cover": switchNowPlayingPane(to: .cover)
            default: break
            }
        }
        #endif
        .alert(I18n.t("Save Queue"), isPresented: $showSaveQueueAlert) {
            TextField(I18n.t("New Playlist Name"), text: $saveQueuePlaylistName)
            Button(I18n.t("Cancel"), role: .cancel) {}
            Button(I18n.t("Create")) {
                let targetName = saveQueuePlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !targetName.isEmpty else { return }
                Task {
                    await app.saveQueueAsNewPlaylist(name: targetName)
                }
            }
        } message: {
            Text(I18n.t("Enter a name for the new playlist"))
        }
    }

    private func syncIdleTimerState() {
        let shouldKeepScreenAwake = (scenePhase == .active)
            && app.isNowPlayingPresented
            && (app.activeNowPlayingPane == .stage || app.activeNowPlayingPane == .lyrics)
            && app.player.isPlaying
        setIdleTimerDisabled(shouldKeepScreenAwake)
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS) && canImport(UIKit)
        if UIApplication.shared.isIdleTimerDisabled != disabled {
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
        #endif
    }

    /// 平滑退出播放页：接入外层硬件级 UIKit 容器向底部迷你条缩融退场。
    private func performInteractiveDismiss() {
        MyGoHaptics.impact(.soft)
        if let externalDismissNowPlaying {
            externalDismissNowPlaying()
        } else {
            withAnimation(.spring(response: 0.44, dampingFraction: 0.78)) {
                app.isNowPlayingPresented = false
            }
        }
    }

    /// 统一驱动播放页子面板切换；`.cover <-> .lyrics` 采用 Apple Music 同源实体封面斜飞与错峰文字过渡。
    private func switchNowPlayingPane(to targetPane: NowPlayingPane) {
        let current = app.activeNowPlayingPane
        guard current != targetPane else { return }
        if targetPane == .lyrics || targetPane == .stage {
            app.settings.lyricsStage = (targetPane == .stage)
        }

        // 若是封面与歌词之间互切，保留退场页播完淡出并零延迟实体封面直飞 + 错峰显影
        if (current == .cover && targetPane == .lyrics) || (current == .lyrics && targetPane == .cover) {
            paneFlightToken += 1
            let token = paneFlightToken

            let goingToLyrics = (targetPane == .lyrics)
            let fallbackCover = estimatedCoverStageRect()
            let fallbackLyrics = estimatedLyricsStageRect()

            let startRect = goingToLyrics
                ? (coverStageRect.width > 20 ? coverStageRect : fallbackCover)
                : (lyricsStageRect.width > 20 ? lyricsStageRect : fallbackLyrics)
            let targetRect = goingToLyrics
                ? (lyricsStageRect.width > 20 ? lyricsStageRect : fallbackLyrics)
                : (coverStageRect.width > 20 ? coverStageRect : fallbackCover)
            let startRadius: CGFloat = goingToLyrics ? 12 : 16

            // 第 1 拍：先将顶层实体封面稳稳摆在起点，同时在 ZStack 中保留旧面板以播放真正平滑的文字淡出
            flyingArtworkRect = startRect
            flyingArtworkCornerRadius = startRadius
            isPaneArtworkFlying = true
            transitioningFromPane = current
            awaitingFlightTarget = targetPane

            if goingToLyrics {
                lyricsChromeOpacity = 0
                lyricsContentOffsetY = 18
            } else {
                coverChromeOpacity = 0
            }

            // 切换到目标面板
            app.activeNowPlayingPane = targetPane

            // 旧页文案平滑淡出（因 transitioningFromPane 留在 ZStack 里，不再瞬间被销毁）
            withAnimation(.easeOut(duration: 0.11)) {
                if goingToLyrics {
                    coverChromeOpacity = 0
                } else {
                    lyricsChromeOpacity = 0
                    lyricsContentOffsetY = 12
                }
            }

            // 紧接下一个 Render Tick 零停顿直飞，不再白白卡停一两帧
            DispatchQueue.main.async {
                guard self.paneFlightToken == token else { return }
                let resolvedTarget: CGRect
                if goingToLyrics {
                    resolvedTarget = self.lyricsStageRect.width > 20 ? self.lyricsStageRect : targetRect
                } else {
                    resolvedTarget = self.coverStageRect.width > 20 ? self.coverStageRect : targetRect
                }
                self.launchPaneArtworkFlight(to: targetPane, targetRect: resolvedTarget, token: token)
            }
            return
        }

        // 切换到其他面板（队列/舞台/评论/专辑墙）：取消飞行并恢复清晰透明度
        paneFlightToken += 1
        isPaneArtworkFlying = false
        transitioningFromPane = nil
        awaitingFlightTarget = nil
        coverChromeOpacity = 1.0
        lyricsChromeOpacity = 1.0
        lyricsContentOffsetY = 0
        activeBridge.currentHeroSnapshot.isVisibleInCurrentPane = false
        withAnimation(Self.paneTransitionSpring) {
            app.activeNowPlayingPane = targetPane
        }
    }

    private func launchPaneArtworkFlight(to targetPane: NowPlayingPane, targetRect: CGRect, token: Int) {
        guard paneFlightToken == token else { return }
        // 若同一次切换期间 onPreferenceChange 回传微调更精确槽位，直接随同一弹簧跟进终点
        let targetRadius: CGFloat = (targetPane == .lyrics) ? 16 : 12
        let flightSpring: Animation = (targetPane == .lyrics)
            ? .spring(response: 0.40, dampingFraction: 0.84)
            : .spring(response: 0.44, dampingFraction: 0.76)
        let isCorrection = (awaitingFlightTarget == nil)
        awaitingFlightTarget = nil

        if isCorrection {
            let delta = hypot(flyingArtworkRect.midX - targetRect.midX, flyingArtworkRect.midY - targetRect.midY)
                + abs(flyingArtworkRect.width - targetRect.width)
            guard delta > 2.5 else { return }
            withAnimation(flightSpring) {
                self.flyingArtworkRect = targetRect
                self.flyingArtworkCornerRadius = targetRadius
            }
            return
        }

        // 第 2 拍：100% 不透明实体封面沿斜线带着苹果 Q 弹感直飞落位
        withAnimation(flightSpring) {
            self.flyingArtworkRect = targetRect
            self.flyingArtworkCornerRadius = targetRadius
        }

        // 错峰文字上浮渐显（等封面缩窄腾出左侧栏后再稳步托出标题与歌词，彻底避免叠压遮字）
        let chromeDelayNs: UInt64 = (targetPane == .lyrics) ? 175_000_000 : 130_000_000
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: chromeDelayNs)
            guard paneFlightToken == token else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                if targetPane == .lyrics {
                    lyricsChromeOpacity = 1.0
                    lyricsContentOffsetY = 0
                } else {
                    coverChromeOpacity = 1.0
                }
            }
        }

        // 动画落地后清除退场保留层并交还槽位原生 Artwork
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard paneFlightToken == token else { return }
            transitioningFromPane = nil
            isPaneArtworkFlying = false
            coverChromeOpacity = 1.0
            lyricsChromeOpacity = 1.0
            lyricsContentOffsetY = 0
        }
    }

    private func estimatedCoverStageRect() -> CGRect {
        let h = max(667, containerSize.height)
        let baseSide = max(210, min(containerSize.width - 36, round(h * 0.419)))
        let x = (containerSize.width - baseSide) * 0.5
        let gapTop = round(h * 0.021)
        return CGRect(x: x, y: 16 + gapTop, width: baseSide, height: baseSide)
    }

    private func estimatedLyricsStageRect() -> CGRect {
        let isRadio = app.player.radioName?.isEmpty == false
        let topPad: CGFloat = isRadio ? 12 : 8
        let scale: CGFloat = app.player.isPlaying ? 1.0 : 0.92
        let baseSide: CGFloat = 96
        let effSide = baseSide * scale
        let inset = (baseSide - effSide) / 2
        // topHeaderBar (~45pt) + VStack spacing (10pt) = ~55pt；左 padding = 22pt
        return CGRect(x: 22 + inset, y: topPad + 55 + inset, width: effSide, height: effSide)
    }

    #if DEBUG
    private func runDebugLyricsMorphSequence() async {
        if app.activeNowPlayingPane != .cover {
            switchNowPlayingPane(to: .cover)
            try? await Task.sleep(nanoseconds: 650_000_000)
        }
        // 大封面静止展示 0.55s
        try? await Task.sleep(nanoseconds: 550_000_000)
        // 斜飞切入歌词页
        switchNowPlayingPane(to: .lyrics)
        try? await Task.sleep(nanoseconds: 1_550_000_000)
        // 弹回大封面页
        switchNowPlayingPane(to: .cover)
    }
    #endif

    private var playerMainContent: some View {
        let track = app.player.currentTrack
        let isRadio = app.player.radioName?.isEmpty == false
        let smokeAccentColor = Color.white
        return ZStack(alignment: .topLeading) {
            if let track {
                let isCover = app.activeNowPlayingPane == .cover
                let showCoverPane = (app.activeNowPlayingPane == .cover) || (transitioningFromPane == .cover)
                let showLyricsPane = (app.activeNowPlayingPane == .lyrics) || (transitioningFromPane == .lyrics)
                VStack(spacing: isCover ? 0 : 10) {
                    // 2+3. 独立分层锁定大封面与歌词/非封面面板几何坐标系，消除顶栏切换导致的 41pt 跳变
                    ZStack(alignment: .top) {
                        if showCoverPane {
                            VStack(spacing: isCover ? 0 : 10) {
                                HStack {
                                    Spacer()
                                    Capsule()
                                        .fill(.white.opacity(0.34))
                                        .frame(width: 36, height: 5)
                                    Spacer()
                                }
                                .padding(.top, isCover ? 0 : 4)
                                .padding(.bottom, isCover ? 0 : 6)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    performInteractiveDismiss()
                                }
                                .opacity(coverChromeOpacity)

                                coverMainView(for: track)
                            }
                            .frame(maxWidth: .infinity, maxHeight: isCover ? nil : .infinity, alignment: .top)
                            .allowsHitTesting(app.activeNowPlayingPane == .cover)
                            .zIndex(app.activeNowPlayingPane == .cover ? 3 : 2)
                        }

                        if !isCover || showLyricsPane {
                            VStack(spacing: isRadio ? 14 : 10) {
                                topHeaderBar(for: track)
                                    .padding(.horizontal, 21)
                                    .opacity(showLyricsPane && app.activeNowPlayingPane != .stage ? lyricsChromeOpacity : (isCover ? 0 : 1))

                                ZStack {
                                    if showLyricsPane {
                                        lyricsMainView(for: track, scrubbingPosition: scrubbingPosition)
                                            .allowsHitTesting(app.activeNowPlayingPane == .lyrics)
                                    } else if app.activeNowPlayingPane == .stage {
                                        StageVisualizerHostView(
                                            player: app.player,
                                            track: track,
                                            scrubbingPosition: scrubbingPosition,
                                            onOpenComments: {
                                                switchNowPlayingPane(to: .comments)
                                            }
                                        )
                                        .transition(.opacity)
                                    } else if app.activeNowPlayingPane == .queue {
                                        queuePaneView
                                            .padding(.horizontal, 21)
                                            .clipped()
                                            .transition(.opacity)
                                    } else if app.activeNowPlayingPane == .wall {
                                        CoverWallPaneView()
                                            .padding(.horizontal, 21)
                                            .clipped()
                                            .transition(.opacity)
                                    } else if app.activeNowPlayingPane == .comments {
                                        commentsPaneView(for: track)
                                            .padding(.horizontal, 21)
                                            .clipped()
                                            .transition(.opacity)
                                    } else if app.activeNowPlayingPane == .show {
                                        podcastEpisodeAboutPane(for: track)
                                            .padding(.horizontal, 21)
                                            .clipped()
                                            .transition(.opacity)
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: isCover ? 0 : .infinity, alignment: .top)
                            }
                            .frame(maxWidth: .infinity, maxHeight: isCover ? 0 : .infinity, alignment: .top)
                            .allowsHitTesting(app.activeNowPlayingPane != .cover)
                            .zIndex(app.activeNowPlayingPane != .cover ? 3 : 2)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: isCover ? nil : .infinity)

                    // 4. 底部播放进度与传输控制区
                    NowPlayingBottomControlsView(
                        player: app.player,
                        track: track,
                        smoke: false,
                        smokeAccent: smokeAccentColor,
                        isCoverMode: isCover,
                        triBarOpacity: isCover ? coverChromeOpacity : 1.0,
                        availableHeight: max(667, containerSize.height),
                        volume: $app.settings.volume,
                        scrubbingPosition: $scrubbingPosition,
                        onSelectPane: { targetPane in
                            MyGoHaptics.selection()
                            switchNowPlayingPane(to: targetPane)
                        }
                    )
                    .animation(.easeInOut(duration: 0.22), value: isCover)
                    .padding(.horizontal, isCover ? 32 : 21)

                    if isCover {
                        Spacer(minLength: 0)
                    }
                }
                .padding(.top, isCover ? 11 : (isRadio ? 12 : 8))
                .padding(.bottom, isCover ? 0 : max(28, round(max(667, containerSize.height) * 0.042)))
                .ignoresSafeArea(.container, edges: isCover ? .bottom : [])

                // 顶层实体共享直飞封面（100% 不透明度跨状态飞跃于大封面正中 <-> 歌词左上角 96x96）
                if isPaneArtworkFlying && flyingArtworkRect.width > 10 && flyingArtworkRect.height > 10 {
                    HeroArtworkOuterVisibilityGate(bridge: activeBridge, localForceHidden: false) {
                        Group {
                            if let cached = ArtworkImageLoader.cachedSwiftUIImage(rawURLString: track.album.imageUrl, pixelSize: 960)
                                ?? ArtworkImageLoader.cachedSwiftUIImage(rawURLString: track.album.imageUrl, pixelSize: 160) {
                                cached
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 0).fill(MyGoTheme.placeholderFill)
                                    Image(systemName: "music.note")
                                        .font(.system(size: 42, weight: .semibold))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                }
                            }
                        }
                        .frame(width: flyingArtworkRect.width, height: flyingArtworkRect.height)
                        .clipShape(RoundedRectangle(cornerRadius: flyingArtworkCornerRadius, style: .continuous))
                    }
                    .background(
                        GeometryReader { proxy in
                            let globalFrame = proxy.frame(in: .global)
                            Color.clear
                                .onAppear {
                                    activeBridge.updateHeroSnapshotIfValid(
                                        globalFrame: globalFrame,
                                        cornerRadius: flyingArtworkCornerRadius,
                                        widthRange: 12.01...CGFloat.greatestFiniteMagnitude
                                    )
                                }
                                .mygoOnChange(of: globalFrame) { _, newFrame in
                                    activeBridge.updateHeroSnapshotIfValid(
                                        globalFrame: newFrame,
                                        cornerRadius: flyingArtworkCornerRadius,
                                        widthRange: 12.01...CGFloat.greatestFiniteMagnitude
                                    )
                                }
                        }
                    )
                    .shadow(
                        color: .black.opacity(app.player.isPlaying ? 0.36 : 0.24),
                        radius: flyingArtworkCornerRadius > 14 ? 16 : 24,
                        y: flyingArtworkCornerRadius > 14 ? 8 : 13
                    )
                    .position(x: flyingArtworkRect.midX, y: flyingArtworkRect.midY)
                    .allowsHitTesting(false)
                    .zIndex(99)
                }
            } else {
                Text(I18n.t("Not Playing"))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: app.activeNowPlayingPane == .cover ? .bottom : [])
        .coordinateSpace(name: Self.stageCoordinateSpaceName)
        .onPreferenceChange(CoverHeroStageRectKey.self) { rect in
            if rect.width > 10 && app.activeNowPlayingPane == .cover {
                coverStageRect = rect
                if awaitingFlightTarget == .cover {
                    let token = paneFlightToken
                    launchPaneArtworkFlight(to: .cover, targetRect: rect, token: token)
                }
            }
        }
        .onPreferenceChange(LyricsHeroStageRectKey.self) { rect in
            if rect.width > 10 && app.activeNowPlayingPane == .lyrics {
                lyricsStageRect = rect
                if awaitingFlightTarget == .lyrics {
                    let token = paneFlightToken
                    launchPaneArtworkFlight(to: .lyrics, targetRect: rect, token: token)
                }
            }
        }
    }

    // MARK: - 顶部面板切换栏（对应 npTabs / stageStyleButton）

    private func topHeaderBar(for track: Track) -> some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(.white.opacity(0.28))
                .frame(width: 40, height: 5)
                .onTapGesture {
                    performInteractiveDismiss()
                }

            HStack(spacing: 6) {
                Button {
                    performInteractiveDismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(I18n.t("Dismiss Now Playing"))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(availablePanes(for: track)) { pane in
                            let selected = (app.activeNowPlayingPane == pane)
                            Button {
                                MyGoHaptics.selection()
                                switchNowPlayingPane(to: pane)
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
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selected ? .white.opacity(0.16) : .clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.trailing, 12)
                }
                .mask {
                    HStack(spacing: 0) {
                        Rectangle().fill(.black)
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 14)
                    }
                }

                if app.activeNowPlayingPane == .stage {
                    stageStyleMenuButton
                }

                nowPlayingMoreMenuButton(for: track)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func nowPlayingMoreMenuButton(for track: Track) -> some View {
        let timerActive = app.player.sleepTimerStopsAfterCurrentTrack || (app.player.sleepTimerRemainingSeconds ?? 0) > 0
        Menu {
            Menu {
                ForEach(availablePanes(for: track)) { pane in
                    Button {
                        MyGoHaptics.selection()
                        switchNowPlayingPane(to: pane)
                    } label: {
                        HStack {
                            Text(I18n.t(pane.labelKey))
                            if app.activeNowPlayingPane == pane {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label(I18n.t("View Mode"), systemImage: "rectangle.stack")
            }

            Button {
                MyGoHaptics.selection()
                app.player.toggleShuffle()
            } label: {
                Label(I18n.t("Toggle Shuffle"), systemImage: app.player.shuffle ? "checkmark.circle.fill" : "shuffle")
            }

            Button {
                MyGoHaptics.selection()
                app.player.cycleRepeat()
            } label: {
                Label(
                    I18n.t("Cycle Repeat Mode"),
                    systemImage: app.player.repeatMode == .one ? "repeat.1" : (app.player.repeatMode == .all ? "repeat.circle.fill" : "repeat")
                )
            }

            Divider()

            let shareSummary = MyGoShareHelper.shareText(for: track)
            ShareLink(item: shareSummary, subject: Text(track.name), message: Text(shareSummary)) {
                Label(I18n.t("Share Track"), systemImage: "square.and.arrow.up")
            }

            Menu {
                sleepTimerMenuButton(titleKey: "Turn Off Timer", option: .off, isSelected: !timerActive) {
                    app.showToast(I18n.t("Sleep timer turned off"))
                }
                sleepTimerMenuButton(
                    titleKey: "After Current Track",
                    option: .afterCurrentTrack,
                    isSelected: app.player.sleepTimerStopsAfterCurrentTrack
                ) {
                    app.showToast(I18n.t("Playback will stop after current track"))
                }
                Divider()
                ForEach([15, 30, 45, 60], id: \.self) { mins in
                    sleepTimerMenuButton(
                        title: I18n.t("\(mins) Minutes"),
                        option: .minutes(mins),
                        isSelected: false
                    ) {
                        app.showToast(String(format: I18n.t("Sleep timer set for %d minutes"), mins))
                    }
                }
            } label: {
                if let sec = app.player.sleepTimerRemainingSeconds, sec > 0 {
                    Label("\(I18n.t("Sleep Timer")) · \(MyGoTheme.formatClock(TimeInterval(sec)))", systemImage: "moon.zzz.fill")
                } else if app.player.sleepTimerStopsAfterCurrentTrack {
                    Label("\(I18n.t("Sleep Timer")) · \(I18n.t("After Current Track"))", systemImage: "moon.zzz.fill")
                } else {
                    Label(I18n.t("Sleep Timer"), systemImage: "moon.zzz")
                }
            }

            Divider()

            if app.activeSource.can("like") {
                let liked = app.isTrackLiked(track)
                Button {
                    MyGoHaptics.impact(liked ? .light : .medium)
                    Task { await app.toggleLike(track) }
                } label: {
                    Label(liked ? I18n.t("Unlike") : I18n.t("Like"), systemImage: liked ? "heart.slash" : "heart")
                }
            }

            if app.activeSource.can("addToPlaylist"), app.myPlaylists.contains(where: { $0.fixed != true }) {
                Button {
                    app.pendingAddToPlaylistTrack = track
                } label: {
                    Label(I18n.t("Add to Playlist"), systemImage: "text.badge.plus")
                }
            }

            if !track.album.id.isEmpty {
                Button {
                    navPath.append(NavigationTarget.album(id: track.album.id, name: track.album.name, sourceID: track.source))
                } label: {
                    Label(I18n.t("Go to Album"), systemImage: "square.stack")
                }
            }

            let artists = track.resolvedArtistsForNavigation
            if artists.count == 1, let artist = artists.first {
                Button {
                    navPath.append(NavigationTarget.artist(id: artist.id, name: artist.name, sourceID: track.source))
                } label: {
                    Label(I18n.tf("Go to Artist: %s", artist.name), systemImage: "person.wave.2")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: timerActive ? "moon.zzz.fill" : "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                if let sec = app.player.sleepTimerRemainingSeconds, sec > 0 {
                    Text(MyGoTheme.formatClock(TimeInterval(sec)))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
            }
            .foregroundStyle(timerActive ? MyGoTheme.accent : .white.opacity(0.86))
            .padding(.horizontal, timerActive && app.player.sleepTimerRemainingSeconds != nil ? 9 : 0)
            .frame(minWidth: 34, minHeight: 34)
            .background(.white.opacity(0.14), in: Capsule())
        }
        .accessibilityLabel(I18n.t("More Actions"))
    }

    @ViewBuilder
    private func sleepTimerMenuButton(
        titleKey: String? = nil,
        title: String? = nil,
        option: PlayerEngine.SleepTimerOption,
        isSelected: Bool,
        onApplied: @escaping () -> Void
    ) -> some View {
        Button {
            MyGoHaptics.selection()
            app.player.setSleepTimer(option)
            onApplied()
        } label: {
            HStack {
                Text(title ?? I18n.t(titleKey ?? ""))
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func availablePanes(for track: Track) -> [NowPlayingPane] {
        var panes: [NowPlayingPane]
        if track.isEpisode {
            panes = [.cover, .show, .queue]
        } else {
            panes = [.cover, .lyrics, .stage, .queue, .wall]
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

    // MARK: - Apple Music 经典大封面播放主视图（.cover 模式）

    private func coverMainView(for track: Track) -> some View {
        let artists = track.resolvedArtistsForNavigation
        let liked = app.isTrackLiked(track)
        let h = max(667, containerSize.height)
        // 严格对齐 1206×2622 Apple Music 原版真实全屏比例（左右封面 18pt、下方控件 32pt、底部留足小横条呼吸区）
        let maxSide = max(210, min(containerSize.width - 36, round(h * 0.419)))
        let gapTopToCover = round(h * 0.021)
        let gapCoverToTitle = round(h * 0.042)
        let gapTitleToProgress = round(h * 0.028)

        return VStack(spacing: 0) {
            Color.clear
                .frame(height: gapTopToCover)

            CoverPlayerArtworkHeroView(
                urlString: track.album.imageUrl,
                side: maxSide,
                isPlaying: app.player.isPlaying,
                heroNamespace: coverHeroNamespace,
                isMatchedSource: app.activeNowPlayingPane == .cover,
                modalBridge: activeBridge,
                isHiddenByPaneFlight: isPaneArtworkFlying,
                stageSpaceName: Self.stageCoordinateSpaceName,
                onNext: { app.player.next() },
                onPrev: { app.player.previous() }
            )

            Color.clear
                .frame(height: gapCoverToTitle)

            // 左对齐歌曲与歌手信息（严格按 32pt 左右边距收窄，显著小于上方主封面宽度）+ 右侧 34×34pt 毛玻璃圆形收藏与更多按钮
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: -1) {
                    MyGoMarqueeText(
                        track.name,
                        font: .custom("PingFangSC-Semibold", size: 19.5),
                        foregroundStyle: .white
                    )

                    if let firstArtist = artists.first {
                        Button {
                            navPath.append(NavigationTarget.artist(id: firstArtist.id, name: firstArtist.name, sourceID: track.source))
                        } label: {
                            MyGoMarqueeText(
                                track.artistNames,
                                font: .custom("PingFangSC-Medium", size: 18.5),
                                foregroundStyle: .white.opacity(0.66)
                            )
                        }
                        .buttonStyle(.plain)
                    } else if !track.artistNames.isEmpty {
                        MyGoMarqueeText(
                            track.artistNames,
                            font: .custom("PingFangSC-Medium", size: 18.5),
                            foregroundStyle: .white.opacity(0.66)
                        )
                    }
                }
                .frame(height: 49)
                .frame(maxWidth: .infinity, alignment: .leading)

                if app.activeSource.can("like") {
                    Button {
                        MyGoHaptics.impact(liked ? .light : .medium)
                        Task { await app.toggleLike(track) }
                    } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(liked ? MyGoTheme.accent : .white.opacity(0.86))
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(I18n.t(liked ? "Unlike" : "Like"))
                }

                nowPlayingMoreMenuButton(for: track)
            }
            .padding(.horizontal, 32)
            .opacity(coverChromeOpacity)

            Color.clear
                .frame(height: gapTitleToProgress)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 封面与滚动歌词主视图（对应 nowPlayingBody / lyricsPane）

    private func lyricsMainView(for track: Track, scrubbingPosition: TimeInterval?) -> some View {
        VStack(spacing: 12) {
            // 顶部可 3D 倾斜与滑动切歌的封面卡片（切页时实体封面斜飞左上角 96x96 坑位）
            NowPlayingCoverHeaderView(
                track: track,
                isPlaying: app.player.isPlaying,
                radioName: app.player.radioName,
                isLiked: app.isTrackLiked(track),
                heroNamespace: coverHeroNamespace,
                isMatchedSource: app.activeNowPlayingPane == .lyrics,
                modalBridge: activeBridge,
                isHiddenByPaneFlight: isPaneArtworkFlying,
                infoOpacity: lyricsChromeOpacity,
                stageSpaceName: Self.stageCoordinateSpaceName,
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
                },
                onSelectArtist: { artist in
                    navPath.append(NavigationTarget.artist(id: artist.id, name: artist.name, sourceID: track.source))
                }
            )
            .padding(.horizontal, 22)

            // 滚动歌词区（精准协调坐标渲染，紧凑铺到封面头下方，错峰柔和上浮显影）
            LyricsScrollView(
                player: app.player,
                activePane: app.activeNowPlayingPane,
                scrubbingPosition: scrubbingPosition,
                hotCommentsEnabled: app.settings.hotComments,
                comments: app.currentTrackComments,
                onSeek: { sec in
                    app.player.seek(to: sec)
                }
            )
            .padding(.horizontal, 12)
            .clipped()
            .opacity(lyricsChromeOpacity)
            .offset(y: lyricsContentOffsetY)
        }
    }

    // MARK: - 待播清单（Up Next）与评论页

    private var queuePaneView: some View {
        let ordered = app.player.orderedQueue
        let curOrder = app.player.currentOrderIndex

        return VStack(spacing: 10) {
            // 顶部控制栏：曲目数 · 定位当前 / 存为歌单 / 清空队列（纯圆形极简图标，不折行不挤占）
            HStack(spacing: 8) {
                Text(I18n.tf("%d Tracks", ordered.count))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))

                Spacer()

                if ordered.isEmpty == false {
                    Button {
                        MyGoHaptics.impact(.light)
                        if ordered.indices.contains(curOrder) {
                            NotificationCenter.default.post(name: .mygoLocateQueueCurrent, object: curOrder)
                        }
                    } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.14), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(I18n.t("Locate Current"))

                    Button {
                        MyGoHaptics.impact(.light)
                        let baseName = app.player.currentTrack?.name ?? I18n.t("Queue")
                        saveQueuePlaylistName = "\(I18n.t("Queue")) · \(baseName)"
                        showSaveQueueAlert = true
                    } label: {
                        Image(systemName: "text.badge.plus")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.14), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(I18n.t("Save as Playlist"))
                }

                if ordered.count > 1 {
                    Button {
                        MyGoHaptics.impact(.medium)
                        app.player.clearQueueKeepingCurrent()
                        app.showToast(I18n.t("Queue Cleared"))
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.12), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(I18n.t("Clear Queue"))
                }
            }
            .padding(.horizontal, 4)

            if ordered.isEmpty {
                Spacer()
                Text(I18n.t("Queue is empty"))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(ordered.enumerated()), id: \.offset) { orderIdx, tr in
                                let isCurrent = (orderIdx == curOrder)
                                HStack(spacing: 10) {
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
                                    if ordered.count > 1 {
                                        HStack(spacing: 2) {
                                            Button {
                                                MyGoHaptics.impact(.light)
                                                app.player.moveInQueue(fromOrderIndex: orderIdx, toOrderIndex: max(0, orderIdx - 1))
                                            } label: {
                                                Image(systemName: "chevron.up")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(orderIdx > 0 ? .white.opacity(0.65) : .white.opacity(0.2))
                                                    .frame(width: 24, height: 26)
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(orderIdx == 0)

                                            Button {
                                                MyGoHaptics.impact(.light)
                                                app.player.moveInQueue(fromOrderIndex: orderIdx, toOrderIndex: min(ordered.count - 1, orderIdx + 1))
                                            } label: {
                                                Image(systemName: "chevron.down")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(orderIdx < ordered.count - 1 ? .white.opacity(0.65) : .white.opacity(0.2))
                                                    .frame(width: 24, height: 26)
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(orderIdx >= ordered.count - 1)
                                        }
                                    }
                                    Button {
                                        MyGoHaptics.impact(.light)
                                        app.player.removeFromQueue(atOrderIndex: orderIdx)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.45))
                                            .frame(width: 24, height: 26)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(isCurrent ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                                .id(orderIdx)
                                .onTapGesture {
                                    app.player.jumpToOrderIndex(orderIdx)
                                }
                                .contextMenu {
                                    if !isCurrent && orderIdx != curOrder + 1 {
                                        Button {
                                            MyGoHaptics.impact(.light)
                                            let dest = orderIdx < curOrder ? curOrder : min(ordered.count - 1, curOrder + 1)
                                            app.player.moveInQueue(fromOrderIndex: orderIdx, toOrderIndex: dest)
                                        } label: {
                                            Label(I18n.t("Play Next"), systemImage: "text.insert")
                                        }
                                    }
                                    if orderIdx > 0 {
                                        Button {
                                            app.player.moveInQueue(fromOrderIndex: orderIdx, toOrderIndex: orderIdx - 1)
                                        } label: {
                                            Label(I18n.t("Move Up"), systemImage: "arrow.up")
                                        }
                                    }
                                    if orderIdx < ordered.count - 1 {
                                        Button {
                                            app.player.moveInQueue(fromOrderIndex: orderIdx, toOrderIndex: orderIdx + 1)
                                        } label: {
                                            Label(I18n.t("Move Down"), systemImage: "arrow.down")
                                        }
                                    }
                                    Button(role: .destructive) {
                                        app.player.removeFromQueue(atOrderIndex: orderIdx)
                                    } label: {
                                        Label(I18n.t("Remove"), systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onAppear {
                        let target = app.player.currentOrderIndex
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                    .mygoOnChange(of: app.activeNowPlayingPane) { _, pane in
                        if pane == .queue {
                            let target = app.player.currentOrderIndex
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    proxy.scrollTo(target, anchor: .center)
                                }
                            }
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .mygoLocateQueueCurrent)) { note in
                        if let idx = note.object as? Int {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    private func commentsPaneView(for track: Track) -> some View {
        let sid = track.source ?? app.activeSourceID
        let src = app.source(forID: sid)
        let canLike = src?.can("likeComment") == true
        let canPost = src?.can("postComment") == true

        return VStack(spacing: 12) {
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
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(app.currentTrackComments) { comment in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    ArtworkView(
                                        urlString: comment.avatarUrl,
                                        pixelSize: 96,
                                        size: 24,
                                        cornerRadius: 12,
                                        systemIcon: "person.crop.circle.fill"
                                    )
                                    Text(comment.author)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.88))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(I18n.relativeTime(from: comment.time))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.45))

                                    let likes = comment.likes ?? 0
                                    let liked = comment.liked == true
                                    if canLike || likes > 0 || liked {
                                        Button {
                                            Task { await app.toggleLikeComment(comment) }
                                        } label: {
                                            HStack(spacing: 3) {
                                                Image(systemName: liked ? "heart.fill" : "heart")
                                                    .font(.system(size: 12))
                                                if likes > 0 {
                                                    Text("\(likes)")
                                                        .font(.system(size: 11, weight: .semibold))
                                                }
                                            }
                                            .foregroundStyle(liked ? MyGoTheme.accent : .white.opacity(0.6))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(.white.opacity(liked ? 0.14 : 0.06), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(!canLike)
                                    }
                                }
                                Text(comment.text)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                            .padding(12)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        }

                        if app.commentsHasMore {
                            LoadMoreButton(isLoading: app.isLoadingMoreComments) {
                                Task { await app.loadMoreComments() }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }

            if canPost {
                let submitComment: () -> Void = {
                    let text = newCommentText
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    newCommentText = ""
                    MyGoKeyboard.dismiss()
                    Task { await app.postComment(text: text) }
                }
                HStack(spacing: 10) {
                    TextField(I18n.t("Write a comment…"), text: $newCommentText)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .submitLabel(.send)
                        .onSubmit {
                            submitComment()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.1), in: Capsule())

                    Button(I18n.t("Post"), action: submitComment)
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
        ScrollViewReader { capProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 实时语音识别字幕卡片（基于系统 Speech 框架，本地/离线文件支持）
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "captions.bubble.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(app.settings.captions ? MyGoTheme.accent : .white.opacity(0.6))
                            Text(I18n.t("Live Captions"))
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                            Spacer()
                            Toggle("", isOn: $app.settings.captions)
                                .labelsHidden()
                                .tint(MyGoTheme.accent)
                        }

                        if !app.liveCaptionsStatus.isEmpty {
                            HStack(spacing: 8) {
                                Text(app.liveCaptionsStatus)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.white.opacity(0.65))
                                Spacer()
                                if app.settings.captions && app.timedCaptions.isEmpty {
                                    Button(I18n.t("Turn On Captions")) {
                                        Task { await app.requestSpeechPermissionAndRefreshCaptions() }
                                    }
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(MyGoTheme.accent)
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if app.settings.captions && !app.timedCaptions.isEmpty {
                            let activeCapIdx = LyricsEngine.index(in: app.timedCaptions, at: app.player.position)
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(app.timedCaptions.enumerated()), id: \.offset) { idx, capLine in
                                    let isActive = (idx == activeCapIdx)
                                    Text(capLine.text)
                                        .font(.system(size: isActive ? 15.5 : 14, weight: isActive ? .bold : .regular))
                                        .foregroundStyle(isActive ? .white : .white.opacity(0.55))
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            app.player.seek(to: capLine.at)
                                        }
                                        .id("cap-\(idx)")
                                }
                            }
                            .mygoOnChange(of: activeCapIdx) { _, newIdx in
                                guard newIdx >= 0 else { return }
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    capProxy.scrollTo("cap-\(newIdx)", anchor: .center)
                                }
                            }
                        } else if !app.settings.captions {
                            Text(I18n.t("Captions are off"))
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .padding(14)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

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
}

private struct OptionalHeroMatchedArtworkModifier: ViewModifier {
    let id: String
    let namespace: Namespace.ID?
    var isSource: Bool = true

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: id, in: namespace, properties: .frame, isSource: isSource)
        } else {
            content
        }
    }
}

#if os(iOS) && canImport(UIKit)
/// 方向锁定横向滑动切歌识别器：仅在水平分量显著大于垂直分量时接管手势，
/// 垂直下拉手势 100% 直接让渡给外层卡片下拉退场控制器，彻底避免大封面区域吞噬下拉手势。
private struct HorizontalOnlyPanOverlay: UIViewRepresentable {
    let minVelocityRatio: CGFloat
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    init(
        minVelocityRatio: CGFloat = 1.25,
        onChanged: @escaping (CGFloat) -> Void,
        onEnded: @escaping (CGFloat, CGFloat) -> Void
    ) {
        self.minVelocityRatio = minVelocityRatio
        self.onChanged = onChanged
        self.onEnded = onEnded
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: HorizontalOnlyPanOverlay

        init(parent: HorizontalOnlyPanOverlay) {
            self.parent = parent
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let targetView = pan.view else {
                return false
            }
            let vel = pan.velocity(in: targetView)
            return abs(vel.x) > 12 && abs(vel.x) > abs(vel.y) * parent.minVelocityRatio
        }

        @objc func handlePan(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view else { return }
            let tx = pan.translation(in: view).x
            let vx = pan.velocity(in: view).x
            switch pan.state {
            case .began, .changed:
                parent.onChanged(tx)
            case .ended, .cancelled, .failed:
                parent.onEnded(tx, vx)
            default:
                break
            }
        }
    }
}
#endif

/// 独立封装大封面卡片组件，专注水平横滑切歌与 3D 倾角；上报精准舞台坐标与全局屏幕坐标以支撑零重影飞跃过渡。
private struct CoverPlayerArtworkHeroView: View {
    let urlString: String?
    let side: CGFloat
    let isPlaying: Bool
    let heroNamespace: Namespace.ID
    let isMatchedSource: Bool
    let modalBridge: NowPlayingModalBridge
    let isHiddenByPaneFlight: Bool
    let stageSpaceName: String
    let onNext: () -> Void
    let onPrev: () -> Void

    @State private var swipeOffsetX: CGFloat = 0

    var body: some View {
        HeroArtworkOuterVisibilityGate(bridge: modalBridge, localForceHidden: isHiddenByPaneFlight) {
            ArtworkView(
                urlString: urlString,
                pixelSize: 960,
                size: side,
                cornerRadius: 12
            )
            .shadow(
                color: .black.opacity(isPlaying ? 0.36 : 0.24),
                radius: isPlaying ? 26 : 16,
                y: isPlaying ? 14 : 9
            )
        }
        .background(
            GeometryReader { proxy in
                let stageFrame = proxy.frame(in: .named(stageSpaceName))
                let globalFrame = proxy.frame(in: .global)
                let expectedRange = (side - 1.99)...(side + 1.99)
                HeroSnapshotObserverOverlay(
                    bridge: modalBridge,
                    globalFrame: globalFrame,
                    cornerRadius: 12,
                    isHidden: isHiddenByPaneFlight,
                    widthRange: expectedRange
                )
                .preference(key: CoverHeroStageRectKey.self, value: stageFrame)
            }
        )
        .scaleEffect(1.0)
        .offset(x: swipeOffsetX * 0.42)
        .rotation3DEffect(
            .degrees(Double(swipeOffsetX) / 28.0),
            axis: (x: 0, y: 1, z: 0)
        )
        .animation(.spring(response: 0.44, dampingFraction: 0.76), value: isPlaying)
        #if os(iOS) && canImport(UIKit)
        .overlay {
            HorizontalOnlyPanOverlay(
                minVelocityRatio: 1.25,
                onChanged: { dx in
                    swipeOffsetX = dx
                },
                onEnded: { dx, vx in
                    withAnimation(.spring(response: 0.40, dampingFraction: 0.74)) {
                        swipeOffsetX = 0
                    }
                    if abs(dx) > 54 || abs(vx) > 260 {
                        MyGoHaptics.impact(.light)
                        if dx < 0 {
                            onNext()
                        } else {
                            onPrev()
                        }
                    }
                }
            )
        }
        #else
        .gesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > abs(dy) * 1.25 || abs(swipeOffsetX) > 2 else { return }
                    swipeOffsetX = dx
                }
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let predictedX = value.predictedEndTranslation.width
                    let wasHorizontal = abs(swipeOffsetX) > 2 || abs(dx) > abs(dy) * 1.25
                    withAnimation(.spring(response: 0.40, dampingFraction: 0.74)) {
                        swipeOffsetX = 0
                    }
                    if wasHorizontal && (abs(dx) > 54 || abs(predictedX) > 120) {
                        MyGoHaptics.impact(.light)
                        if dx < 0 {
                            onNext()
                        } else {
                            onPrev()
                        }
                    }
                }
        )
        #endif
    }
}

// MARK: - 封面卡片头部组件（独立封装以隔离手势与局部动画）

private struct NowPlayingCoverHeaderView: View {
    let track: Track
    let isPlaying: Bool
    let radioName: String?
    let isLiked: Bool
    var heroNamespace: Namespace.ID? = nil
    var isMatchedSource: Bool = false
    let modalBridge: NowPlayingModalBridge
    let isHiddenByPaneFlight: Bool
    let infoOpacity: Double
    let stageSpaceName: String
    let onLike: () -> Void
    let onNext: () -> Void
    let onPrev: () -> Void
    let onExitRadio: () -> Void
    let onSelectArtist: (Artist) -> Void

    @State private var coverTilt: CGSize = .zero

    var body: some View {
        HStack(spacing: 16) {
            HeroArtworkOuterVisibilityGate(bridge: modalBridge, localForceHidden: isHiddenByPaneFlight) {
                ArtworkView(
                    urlString: track.album.imageUrl,
                    pixelSize: 960,
                    size: 96,
                    cornerRadius: 16
                )
                .shadow(color: .black.opacity(0.36), radius: 16, x: 0, y: 8)
            }
            .background(
                GeometryReader { proxy in
                    let stageFrame = proxy.frame(in: .named(stageSpaceName))
                    let globalFrame = proxy.frame(in: .global)
                    HeroSnapshotObserverOverlay(
                        bridge: modalBridge,
                        globalFrame: globalFrame,
                        cornerRadius: 16,
                        isHidden: isHiddenByPaneFlight,
                        widthRange: 76...104,
                        minXRange: 10...80
                    )
                    .preference(key: LyricsHeroStageRectKey.self, value: stageFrame)
                }
            )
            .rotation3DEffect(
                .degrees(Double(coverTilt.width / 8)),
                axis: (x: -coverTilt.height / 20, y: coverTilt.width / 20, z: 0)
            )
            .scaleEffect(isPlaying ? 1.0 : 0.92)
            .animation(.spring(duration: 0.45, bounce: 0.25), value: isPlaying)
            #if os(iOS) && canImport(UIKit)
            .overlay {
                HorizontalOnlyPanOverlay(
                    minVelocityRatio: 1.2,
                    onChanged: { dx in
                        coverTilt = CGSize(width: dx, height: 0)
                    },
                    onEnded: { dx, vx in
                        withAnimation(.spring(response: 0.40, dampingFraction: 0.74)) {
                            coverTilt = .zero
                        }
                        if dx < -65 || vx < -280 {
                            onNext()
                        } else if dx > 65 || vx > 280 {
                            onPrev()
                        }
                    }
                )
            }
            #else
            .gesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .onChanged { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > abs(dy) * 1.2 || abs(coverTilt.width) > 2 else { return }
                        coverTilt = value.translation
                    }
                    .onEnded { value in
                        let hadTilt = abs(coverTilt.width) > 2
                        withAnimation(.spring(response: 0.40, dampingFraction: 0.74)) {
                            coverTilt = .zero
                        }
                        if hadTilt {
                            if value.translation.width < -65 {
                                onNext()
                            } else if value.translation.width > 65 {
                                onPrev()
                            }
                        }
                    }
            )
            #endif

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

                MyGoMarqueeText(
                    track.name,
                    font: .system(size: 20, weight: .bold),
                    foregroundStyle: .white
                )

                artistInteractiveButton
            }
            .opacity(infoOpacity)
            Spacer()

            Button {
                MyGoHaptics.impact(isLiked ? .light : .medium)
                onLike()
            } label: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 21))
                    .foregroundStyle(isLiked ? MyGoTheme.accent : .white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(I18n.t(isLiked ? "Unlike" : "Like"))
            .opacity(infoOpacity)
        }
    }

    @ViewBuilder
    private var artistInteractiveButton: some View {
        let artists = track.resolvedArtistsForNavigation
        if artists.isEmpty {
            Text(track.artistNames)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        } else if artists.count == 1 {
            Button {
                onSelectArtist(artists[0])
            } label: {
                artistLinkLabel
            }
            .buttonStyle(.plain)
            .accessibilityHint(I18n.tf("Go to Artist: %s", artists[0].name))
        } else {
            Menu {
                ForEach(Array(artists.enumerated()), id: \.offset) { _, artist in
                    Button {
                        onSelectArtist(artist)
                    } label: {
                        Label(artist.name, systemImage: "person.wave.2")
                    }
                }
            } label: {
                artistLinkLabel
            }
            .buttonStyle(.plain)
        }
    }

    private var artistLinkLabel: some View {
        HStack(spacing: 4) {
            Text(track.artistNames)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

// MARK: - 底部播放控制与进度条（独立订阅 player，隔离高频 position 触发整屏重绘）

private struct NowPlayingBottomControlsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var player: PlayerEngine
    let track: Track
    let smoke: Bool
    var smokeAccent: Color = .white
    var isCoverMode: Bool = false
    var triBarOpacity: Double = 1.0
    var availableHeight: CGFloat = 780
    @Binding var volume: Double
    @Binding var scrubbingPosition: TimeInterval?
    var onSelectPane: ((NowPlayingPane) -> Void)? = nil

    @State private var trailDrainUntil: Date = .distantPast
    @State private var wasActivelySmoking = false
    @State private var showSignalPathSheet = false
    @StateObject private var systemVolume = SystemVolumeObserver()

    private var activeDisplayVolume: Double {
        #if os(iOS)
        return systemVolume.volume
        #else
        return volume
        #endif
    }

    private var activeVolumeBinding: Binding<Double> {
        #if os(iOS)
        return Binding(
            get: { systemVolume.volume },
            set: { newValue in
                systemVolume.setUserVolume(newValue)
            }
        )
        #else
        return $volume
        #endif
    }

    private func speakerRightSymbol(for level: Double) -> String {
        if isCoverMode {
            return "speaker.wave.3.fill"
        }
        if level <= 0.005 {
            return "speaker.fill"
        } else if level < 0.34 {
            return "speaker.wave.1.fill"
        } else if level < 0.68 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        let totalDuration = (player.duration > 0) ? player.duration : max(track.durationSeconds, 1)
        let isActivelySmoking = false
        let timelinePaused = !player.isPlaying && scrubbingPosition == nil
        let h = max(667, availableHeight)
        let expandedGap = min(18, max(14, round(h * 0.020)))
        let gapProgressToTransport: CGFloat = isCoverMode ? round(h * 0.048) : expandedGap
        let gapTransportToVolume: CGFloat = isCoverMode ? round(h * 0.060) : expandedGap
        let gapVolumeToTriBar: CGFloat = isCoverMode ? round(h * 0.020) : 2

        VStack(spacing: 0) {
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
                .padding(.bottom, 10)
            }

            // 进度滑块与音频信号路径胶囊
            progressAndQualitySection(
                totalDuration: totalDuration,
                isActivelySmoking: isActivelySmoking,
                timelinePaused: timelinePaused
            )
            .mygoOnChange(of: isActivelySmoking) { _, active in
                if wasActivelySmoking && !active {
                    trailDrainUntil = Date().addingTimeInterval(1.6)
                }
                wasActivelySmoking = active
            }
            .onAppear {
                wasActivelySmoking = isActivelySmoking
            }

            if isCoverMode {
                Color.clear
                    .frame(height: gapProgressToTransport)
            } else {
                Spacer(minLength: 10)
                    .frame(maxHeight: gapProgressToTransport)
            }

            // 播放控制按钮：同一组实体按钮随大封面/歌词模式丝滑形变位移，避免双三角形交叉重影
            HStack(spacing: isCoverMode ? 62 : 28) {
                if !isCoverMode {
                    Button {
                        MyGoHaptics.selection()
                        player.toggleShuffle()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(player.shuffle ? MyGoTheme.accent : .white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(I18n.t("Toggle Shuffle"))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                Button {
                    MyGoHaptics.impact(.light)
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: isCoverMode ? 27.5 : 24, weight: isCoverMode ? .bold : .regular))
                        .foregroundStyle(.white)
                        .frame(width: isCoverMode ? 44 : 30, height: isCoverMode ? 44 : 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(I18n.t("Previous Track"))

                Button {
                    MyGoHaptics.impact(.soft)
                    player.togglePlay()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.white.opacity(isCoverMode ? 0.0 : 0.16))
                            .frame(width: isCoverMode ? 48 : 62, height: isCoverMode ? 48 : 62)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: isCoverMode ? 42 : 26, weight: isCoverMode ? .semibold : .bold))
                            .foregroundStyle(.white)
                            .offset(x: player.isPlaying ? 0 : 2)
                    }
                    .frame(width: isCoverMode ? 48 : 62, height: isCoverMode ? 48 : 62)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(I18n.t(player.isPlaying ? "Pause" : "Play"))

                Button {
                    MyGoHaptics.impact(.light)
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: isCoverMode ? 27.5 : 24, weight: isCoverMode ? .bold : .regular))
                        .foregroundStyle(.white)
                        .frame(width: isCoverMode ? 44 : 30, height: isCoverMode ? 44 : 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(I18n.t("Next Track"))

                if !isCoverMode {
                    Button {
                        MyGoHaptics.selection()
                        player.cycleRepeat()
                    } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(player.repeatMode != .off ? MyGoTheme.accent : .white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(I18n.t("Cycle Repeat Mode"))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(height: isCoverMode ? 48 : 66)

            if isCoverMode {
                Color.clear
                    .frame(height: gapTransportToVolume)
            } else {
                Spacer(minLength: 10)
                    .frame(maxHeight: gapTransportToVolume)
            }

            // 音量滑块：纤细磨砂无球轨（对照 Apple Music 质感，拖动时柔和加粗提亮）
            HStack(spacing: 12) {
                Button {
                    #if os(iOS)
                    systemVolume.toggleMute()
                    #else
                    volume = volume <= 0.005 ? 0.5 : 0
                    #endif
                } label: {
                    Image(systemName: activeDisplayVolume <= 0.005 ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: isCoverMode ? 15 : 13, weight: .medium))
                        .foregroundStyle(.white.opacity(activeDisplayVolume <= 0.005 ? 0.84 : 0.56))
                        .frame(width: isCoverMode ? 14 : 18, height: 22, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                SleekVolumeBarView(
                    value: activeVolumeBinding,
                    isDraggingExternal: {
                        #if os(iOS)
                        return systemVolume.isDragging
                        #else
                        return false
                        #endif
                    }(),
                    onEditingChanged: { editing in
                        #if os(iOS)
                        if editing {
                            systemVolume.beginDragging()
                        } else {
                            systemVolume.endDragging()
                        }
                        #endif
                    }
                )

                Image(systemName: speakerRightSymbol(for: activeDisplayVolume))
                    .font(.system(size: isCoverMode ? 15.5 : 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.56))
                    .frame(width: isCoverMode ? 24 : 18, height: 22, alignment: .trailing)

                if !isCoverMode {
                    AirPlayRoutePickerView(tintColor: .white.opacity(0.8))
                        .frame(width: 28, height: 28)
                }
            }
            .padding(.horizontal, isCoverMode ? 2 : 16)

            // 大封面模式专属极简底部 Tri-Bar：歌词气泡 · 隔空播放设备图标 · 待播清单（纯洁三图标对齐 Apple Music）
            if isCoverMode {
                Color.clear
                    .frame(height: gapVolumeToTriBar)

                HStack {
                    Button {
                        onSelectPane?(track.isEpisode ? .show : .lyrics)
                    } label: {
                        Image(systemName: "quote.bubble")
                            .font(.system(size: 19.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.76))
                            .frame(width: 40, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(I18n.t(track.isEpisode ? "About" : "Lyrics"))

                    Spacer()

                    AirPlayRoutePickerView(tintColor: .white.opacity(0.76))
                        .frame(width: 40, height: 28)

                    Spacer()

                    Button {
                        onSelectPane?(.queue)
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 19.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.76))
                                .frame(width: 40, height: 28)

                            if player.repeatMode != .off || player.shuffle {
                                Image(systemName: player.repeatMode == .one ? "repeat.1" : (player.repeatMode == .all ? "repeat" : "shuffle"))
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(3)
                                    .background(MyGoTheme.accent, in: Circle())
                                    .offset(x: -2, y: 2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(I18n.t("Up Next"))
                }
                .padding(.horizontal, 34)
                .opacity(triBarOpacity)
            }
        }
        #if os(iOS) && canImport(UIKit) && canImport(MediaPlayer)
        .background {
            SystemVolumeHardwareHostView(observer: systemVolume)
                .frame(width: 1, height: 1)
                .opacity(0.011)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            systemVolume.startObserving()
        }
        .onDisappear {
            systemVolume.stopObserving()
        }
        #endif
        .sheet(isPresented: $showSignalPathSheet) {
            let sid = track.source ?? app.activeSourceID
            let srcName = (app.source(forID: sid) ?? app.activeSource).info().name
            let pathInfo = player.currentAudioSignalPath(sourceDisplayName: srcName)
            AudioSignalPathSheetView(track: track, info: pathInfo)
        }
    }

    @ViewBuilder
    private func progressAndQualitySection(
        totalDuration: Double,
        isActivelySmoking: Bool,
        timelinePaused: Bool
    ) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: timelinePaused)) { timeline in
            let _ = timeline.date
            let rawPos = scrubbingPosition ?? (player.isPlaying ? player.livePlaybackPosition() : player.position)
            let currentPos = min(max(rawPos, 0), totalDuration)
            let rhythm = player.sampleAudioRhythm(
                at: currentPos,
                lines: player.lyrics,
                isScrubbing: scrubbingPosition != nil
            )
            let bandLevel = Float(min(1.0, rhythm.bass * 0.65 + rhythm.beatPulse * 0.45))

            VStack(spacing: isCoverMode ? 3 : 2) {
                ProgressSeekBar(
                    value: Binding(
                        get: { currentPos },
                        set: { newVal in
                            scrubbingPosition = newVal
                        }
                    ),
                    duration: totalDuration,
                    smokeEnabled: false,
                    smokeAccent: smokeAccent,
                    showCometStyle: false,
                    waveform: player.currentTrackWaveform,
                    showWaveform: false,
                    activeBandLevel: bandLevel,
                    onEditingChanged: { editing in
                        if !editing {
                            let target = scrubbingPosition ?? player.position
                            // 先将底层时钟推进到目标值，再清除预览状态，避免松手一帧回跳闪烁
                            player.seek(to: target)
                            scrubbingPosition = nil
                        }
                    }
                )
                .frame(height: isCoverMode ? 20 : 24)

                ZStack {
                    HStack(spacing: 8) {
                        Text(MyGoTheme.formatClock(currentPos))
                            .font(.custom("PingFangSC-Semibold", size: 12.0))
                            .monospacedDigit()
                            .foregroundStyle(scrubbingPosition != nil ? .white.opacity(0.95) : .white.opacity(0.55))
                            .lineLimit(1)

                        Spacer(minLength: 96)

                        let rightLabel = player.isLoading
                            ? I18n.t("Buffering…")
                            : "-" + MyGoTheme.formatClock(max(0, totalDuration - currentPos))
                        Text(rightLabel)
                            .font(.custom("PingFangSC-Semibold", size: 12.0))
                            .monospacedDigit()
                            .foregroundStyle(scrubbingPosition != nil ? .white.opacity(0.95) : .white.opacity(0.55))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }

                    qualityBadgeButton()
                }
                .frame(height: 18)
            }
        }
    }

    @ViewBuilder
    private func qualityBadgeButton() -> some View {
        let st = player.currentStream
        let resolvedURL = st.flatMap { URL(string: $0.url) }
        let fallbackCodec = st.map { PlayerEngine.resolvedCodecLabel(streamType: $0.type, url: resolvedURL) } ?? ""
        let activeCodec = player.activeSignalCodec
        // 严格对应「音源与解码 -> 音频容器」（如 FLAC / MP3 / WAV (PCM) / AAC / M4A）
        let qualityTitle: String = {
            if activeCodec != "Audio" && !activeCodec.isEmpty {
                return activeCodec
            }
            if !fallbackCodec.isEmpty && fallbackCodec != "Audio" {
                return fallbackCodec
            }
            let effectiveQuality = AppModel.resolveEffectiveStreamingQuality(
                isCellular: app.isOnCellularNetwork,
                wifiQuality: app.settings.wifiQuality,
                cellularQuality: app.settings.cellularQuality
            )
            return I18n.t(effectiveQuality.labelKey)
        }()
        let fgColor: Color = Color.white.opacity(0.78)
        let bgColor: Color = Color.white.opacity(0.13)

        Button {
            MyGoHaptics.impact(.light)
            showSignalPathSheet = true
        } label: {
            HStack(spacing: 4.5) {
                AppleMusicLosslessGlyphView(color: fgColor)
                    .frame(width: 16.5, height: 10.0)
                Text(qualityTitle)
                    .font(.custom("PingFangSC-Semibold", size: 11.0))
                    .foregroundStyle(fgColor)
            }
            .padding(.horizontal, 8.5)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(bgColor)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(I18n.t("Audio Signal Path"))
    }
}

/// 100% 原生 Apple Music 官方无损矢量图标（直接采用 CoreGlyphsPrivate `apple.music.lossless` Semibold 42 段三次贝塞尔闭合轮廓，全机型真机一致）
private struct AppleMusicLosslessGlyphView: View {
    let color: Color

    var body: some View {
        AppleOfficialLosslessShape()
            .fill(color)
            .accessibilityHidden(true)
    }
}

private struct AppleOfficialLosslessShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let bw: CGFloat = 38.553
        let bh: CGFloat = 20.3166
        @inline(__always) func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x / bw) * w, y: rect.minY + (y / bh) * h)
        }

        var p = Path()
        p.move(to: pt(17.4265, 20.3166))
        p.addCurve(to: pt(20.3736, 18.9226), control1: pt(18.7106, 20.3166), control2: pt(19.6537, 19.6949))
        p.addLine(to: pt(19.4400, 17.5569))
        p.addCurve(to: pt(17.9373, 18.2647), control1: pt(18.9825, 18.0158), control2: pt(18.4782, 18.2647))
        p.addCurve(to: pt(6.4345, 0.0000), control1: pt(13.9187, 18.2647), control2: pt(13.4054, 0.0000))
        p.addCurve(to: pt(0.0667, 11.3153), control1: pt(2.5454, 0.0000), control2: pt(0.6523, 5.5869))
        p.addCurve(to: pt(0.8247, 12.3033), control1: pt(0.0000, 11.9590), control2: pt(0.2751, 12.3033))
        p.addCurve(to: pt(1.5550, 11.5762), control1: pt(1.2376, 12.3033), control2: pt(1.4989, 12.0639))
        p.addCurve(to: pt(5.8014, 2.0782), control1: pt(1.9151, 8.1912), control2: pt(3.2274, 2.0782))
        p.addCurve(to: pt(8.5462, 5.4584), control1: pt(7.2308, 2.0782), control2: pt(8.0552, 3.7081))
        p.addCurve(to: pt(7.3797, 11.3153), control1: pt(8.0665, 7.0166), control2: pt(7.6613, 8.7360))
        p.addCurve(to: pt(8.1377, 12.3033), control1: pt(7.3174, 11.9590), control2: pt(7.5838, 12.3033))
        p.addCurve(to: pt(8.8706, 11.5762), control1: pt(8.5619, 12.3033), control2: pt(8.8232, 12.0639))
        p.addCurve(to: pt(9.4831, 8.0118), control1: pt(8.9790, 10.6656), control2: pt(9.2170, 8.9324))
        p.addCurve(to: pt(17.4265, 20.3166), control1: pt(10.9590, 12.8857), control2: pt(13.0785, 20.3166))
        p.closeSubpath()

        p.move(to: pt(24.8399, 20.3166))
        p.addCurve(to: pt(27.6663, 19.0471), control1: pt(25.9926, 20.3166), control2: pt(26.9602, 19.7932))
        p.addLine(to: pt(26.7027, 17.6970))
        p.addCurve(to: pt(25.3570, 18.2647), control1: pt(26.3371, 18.0158), control2: pt(25.8804, 18.2647))
        p.addCurve(to: pt(13.8414, 0.0000), control1: pt(21.3716, 18.2647), control2: pt(20.8274, 0.0000))
        p.addCurve(to: pt(10.8135, 1.3941), control1: pt(12.5047, 0.0000), control2: pt(11.5246, 0.6217))
        p.addLine(to: pt(11.7603, 2.7773))
        p.addCurve(to: pt(13.2630, 2.0782), control1: pt(12.2284, 2.3271), control2: pt(12.7221, 2.0782))
        p.addCurve(to: pt(24.8399, 20.3166), control1: pt(17.0405, 2.0782), control2: pt(17.8761, 20.3166))
        p.closeSubpath()

        p.move(to: pt(32.1690, 20.3166))
        p.addCurve(to: pt(38.5456, 9.0013), control1: pt(36.0581, 20.3166), control2: pt(37.9600, 14.7297))
        p.addCurve(to: pt(37.7788, 8.0133), control1: pt(38.6035, 8.3576), control2: pt(38.3284, 8.0133))
        p.addCurve(to: pt(37.0485, 8.7404), control1: pt(37.3659, 8.0133), control2: pt(37.1046, 8.2527))
        p.addCurve(to: pt(32.8109, 18.2296), control1: pt(36.6885, 12.1254), control2: pt(35.3893, 18.2296))
        p.addCurve(to: pt(30.0661, 14.8495), control1: pt(31.3815, 18.2296), control2: pt(30.5483, 16.6086))
        p.addCurve(to: pt(31.2326, 9.0013), control1: pt(30.5370, 13.3000), control2: pt(30.9510, 11.5788))
        p.addCurve(to: pt(30.4746, 8.0133), control1: pt(31.2949, 8.3576), control2: pt(31.0234, 8.0133))
        p.addCurve(to: pt(29.7330, 8.7404), control1: pt(30.0416, 8.0133), control2: pt(29.7909, 8.2527))
        p.addCurve(to: pt(29.1292, 12.3048), control1: pt(29.6352, 9.6511), control2: pt(29.3865, 11.3755))
        p.addCurve(to: pt(21.1771, 0.0000), control1: pt(27.6533, 7.4310), control2: pt(25.5251, 0.0000))
        p.addCurve(to: pt(18.2387, 1.4028), control1: pt(19.8930, 0.0000), control2: pt(18.9498, 0.6217))
        p.addLine(to: pt(19.1723, 2.7598))
        p.addCurve(to: pt(20.6681, 2.0520), control1: pt(19.6229, 2.3008), control2: pt(20.1253, 2.0520))
        p.addCurve(to: pt(32.1690, 20.3166), control1: pt(24.6848, 2.0520), control2: pt(25.2069, 20.3166))
        p.closeSubpath()
        return p
    }
}

/// 对标 Apple Music 纤细磨砂无球音量滑轨（拖动时柔和膨胀提亮，消除系统 Slider 大白圆球违和感）
private struct SleekVolumeBarView: View {
    @Binding var value: Double
    var isDraggingExternal: Bool = false
    let onEditingChanged: (Bool) -> Void

    @State private var isEditing = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = CGFloat(min(max(value, 0), 1))
            let barHeight: CGFloat = isEditing ? 10.5 : 6.5

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: barHeight)

                Capsule()
                    .fill(.white.opacity(isEditing ? 0.96 : 0.78))
                    .frame(width: max(barHeight, width * fraction), height: barHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.26, dampingFraction: 0.78), value: isEditing)
            .animation(
                isDraggingExternal || isEditing ? nil : .interactiveSpring(response: 0.16, dampingFraction: 0.88),
                value: value
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isEditing {
                            isEditing = true
                            onEditingChanged(true)
                        }
                        let ratio = min(max(Double(drag.location.x / width), 0), 1)
                        value = ratio
                    }
                    .onEnded { drag in
                        let ratio = min(max(Double(drag.location.x / width), 0), 1)
                        value = ratio
                        isEditing = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 28)
    }
}

private struct ProgressSeekBar: View {
    @Binding var value: Double
    let duration: Double
    var smokeEnabled: Bool = false
    var smokeAccent: Color = .white
    var showCometStyle: Bool = false
    var waveform: [Float] = []
    var showWaveform: Bool = false
    var activeBandLevel: Float = 0
    let onEditingChanged: (Bool) -> Void
    @State private var isEditing = false

    private static let waveformBarCount = 56

    private func sampledHeights(count: Int) -> [CGFloat] {
        guard !waveform.isEmpty else {
            return (0..<count).map { idx in
                let progress = Double(idx) / Double(max(count - 1, 1))
                let arc = 0.24 + 0.42 * sin(progress * .pi)
                let micro = 0.24 * abs(sin(Double(idx) * 1.15)) + ((idx % 3 == 0) ? 0.12 : 0.0)
                return CGFloat(min(0.98, max(0.12, arc * 0.55 + micro)))
            }
        }
        if waveform.count == count {
            return waveform.map { CGFloat(min(max($0, 0.10), 1.0)) }
        }
        return (0..<count).map { idx in
            let srcPos = Double(idx) / Double(max(count - 1, 1)) * Double(waveform.count - 1)
            let lo = Int(floor(srcPos))
            let hi = min(waveform.count - 1, lo + 1)
            let t = Float(srcPos - Double(lo))
            let val = waveform[lo] * (1 - t) + waveform[hi] * t
            return CGFloat(min(max(val, 0.10), 1.0))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = min(max(value / max(duration, 1), 0), 1)
            let barHeight: CGFloat = isEditing ? 11.0 : 7.0

            ZStack(alignment: .leading) {
                if showWaveform {
                    let count = Self.waveformBarCount
                    let heights = sampledHeights(count: count)
                    let maxBarHeight: CGFloat = isEditing ? 28 : 25
                    let minBarHeight: CGFloat = 3.5
                    let activeColor = MyGoTheme.mix(.white, with: smokeAccent, ratio: 0.25)

                    Canvas { context, size in
                        let slotW = size.width / CGFloat(count)
                        let barW = max(2.2, slotW - 2.2)
                        for idx in 0..<count {
                            let posRatio = (Double(idx) + 0.5) / Double(count)
                            let isPlayed = posRatio <= fraction
                            let distToHead = abs(posRatio - fraction)
                            let isNearHead = distToHead < 0.036
                            let pulseBoost: CGFloat = isNearHead
                                ? CGFloat(activeBandLevel) * (1.0 - CGFloat(distToHead / 0.036)) * 0.30
                                : 0
                            let normalized = min(1.0, max(0.10, heights[idx] + pulseBoost))
                            let barH = minBarHeight + (maxBarHeight - minBarHeight) * normalized

                            let bx = CGFloat(idx) * slotW + (slotW - barW) * 0.5
                            let by = (size.height - barH) * 0.5
                            let barRect = CGRect(x: bx, y: by, width: barW, height: barH)
                            let path = Path(roundedRect: barRect, cornerRadius: barW * 0.5)

                            let color: Color = (isNearHead && isEditing)
                                ? .white
                                : (isPlayed ? activeColor.opacity(0.95) : .white.opacity(0.24))
                            context.fill(path, with: .color(color))
                        }
                    }
                    .frame(height: 30)

                    if isEditing {
                        Capsule()
                            .fill(.white)
                            .frame(width: 3, height: 28)
                            .shadow(color: .black.opacity(0.4), radius: 3)
                            .offset(x: width * fraction - 1.5)
                    }
                } else {
                    // 1:1 复刻 Apple Music 无圆球饱满圆角胶囊进度条（拖动时整体柔和膨胀变白）
                    Capsule(style: .continuous)
                        .fill(.white.opacity(isEditing ? 0.28 : 0.18))
                        .frame(height: barHeight)

                    Capsule(style: .continuous)
                        .fill(.white.opacity(isEditing ? 0.96 : 0.58))
                        .frame(width: max(barHeight, width * fraction), height: barHeight)
                }
            }
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isEditing)
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isEditing {
                            isEditing = true
                            onEditingChanged(true)
                        }
                        value = duration * min(max(gesture.location.x / width, 0), 1)
                    }
                    .onEnded { gesture in
                        value = duration * min(max(gesture.location.x / width, 0), 1)
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
        .frame(height: 32)
    }
}

/// 烟雾粒子出生轨道状态容器（记录火车前进过程中每一缕烟冒出时的真实水平轨道点，实现“顺着跑”的排烟轨迹）
private final class SmokeTrailTracker: ObservableObject {
    var spawns: [Int64: CGFloat] = [:]
    var lastHeadX: CGFloat?
    var lastFrameTime: Double?
    var emitterLevel: Double = 1.0
    var stoppedAfterBirth: Int64?
    var wasActive: Bool = true
}

struct SmokeWispGeometry: Equatable {
    let center: CGPoint
    let radiusX: CGFloat
    let radiusY: CGFloat
    let alpha: Double
}

struct ProgressSmokeView: View {
    let progress: CGFloat
    let level: CGFloat
    var horizontalInset: CGFloat = 0
    var scale: CGFloat = 1.0
    var useAdditiveBlend: Bool = true
    var tintColor: Color = .white
    var isActive: Bool = true
    var lightSurfaceMode: Bool = false
    var frameRate: Double = 60.0

    @StateObject private var tracker = SmokeTrailTracker()
    @State private var drainComplete: Bool = false

    static func anchorOffsetFromBottom(scale: CGFloat) -> CGFloat {
        10 * scale
    }

    // 对照桌面 ui_player.go，适当加大飘散半径与升腾行程，呈现饱满蓬松的白色小烟囱蒸汽
    static let smokeLife: Double = 1.65
    private let life: Double = ProgressSmokeView.smokeLife
    private let wispCount: Int = 56

    var body: some View {
        GeometryReader { geometry in
            let bleed = 88 * scale
            let interval = 1.0 / max(10.0, frameRate)
            TimelineView(.animation(minimumInterval: interval, paused: !isActive && drainComplete)) { timeline in
                Canvas { context, size in
                    drawSmoke(
                        in: &context,
                        trackWidth: geometry.size.width,
                        size: size,
                        bleedX: bleed,
                        now: timeline.date.timeIntervalSinceReferenceDate
                    )
                }
                .frame(width: geometry.size.width + bleed * 2, height: geometry.size.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .offset(x: -bleed)
        }
        .task(id: isActive) {
            if isActive {
                drainComplete = false
            } else {
                try? await Task.sleep(nanoseconds: 1_650_000_000)
                if !Task.isCancelled && !isActive {
                    drainComplete = true
                }
            }
        }
    }

    private func drawSmoke(
        in context: inout GraphicsContext,
        trackWidth: CGFloat,
        size: CGSize,
        bleedX: CGFloat,
        now: Double
    ) {
        let usableWidth = max(trackWidth - horizontalInset * 2, 1)
        let clampedProgress = min(max(progress, 0), 1)
        let headX = bleedX + horizontalInset + usableWidth * clampedProgress
        let anchorY = size.height - Self.anchorOffsetFromBottom(scale: scale)
        let strength = min(max(level, 0.08), 1.0)
        let step = life / Double(wispCount)
        let latestBirthInt = Int64(floor(now / step))

        // 更新发射包络与火车行驶轨迹记录
        let dt: Double
        if let prevTime = tracker.lastFrameTime {
            dt = min(max(now - prevTime, 1.0 / 240.0), 0.1)
        } else {
            dt = 1.0 / 60.0
            tracker.emitterLevel = isActive ? 1.0 : 0.0
            tracker.wasActive = isActive
        }
        tracker.lastFrameTime = now

        if let prevX = tracker.lastHeadX, abs(headX - prevX) > 22.0 * scale {
            tracker.spawns.removeAll(keepingCapacity: true)
        }
        tracker.lastHeadX = headX

        if isActive {
            if !tracker.wasActive {
                tracker.stoppedAfterBirth = nil
            }
            let rate = 1.0 - exp(-dt * 10.0)
            tracker.emitterLevel += (1.0 - tracker.emitterLevel) * rate
        } else {
            if tracker.wasActive {
                tracker.stoppedAfterBirth = latestBirthInt
            }
            let rate = 1.0 - exp(-dt * 5.2)
            tracker.emitterLevel += (0.0 - tracker.emitterLevel) * rate
        }
        tracker.wasActive = isActive

        let oldestKeep = latestBirthInt - Int64(wispCount) - 8
        if tracker.spawns.count > wispCount * 2 {
            tracker.spawns = tracker.spawns.filter { $0.key >= oldestKeep }
        }

        // 1. 火车小烟囱白色蒸汽羽流层（3.15pt 柔和融合：既保持喷口紧实清晰，又使稍大一点的白烟饱满蓬松）
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 3.15 * scale))
            if useAdditiveBlend && !lightSurfaceMode {
                layer.blendMode = .plusLighter
            }
            for index in 0..<wispCount {
                let birthIdx = latestBirthInt - Int64(index)
                if let cutoff = tracker.stoppedAfterBirth, birthIdx > cutoff {
                    continue
                }
                let birth = Double(birthIdx)
                let age = now - birth * step
                guard age >= 0, age < life else { continue }

                let spawnHeadX: CGFloat
                if let recorded = tracker.spawns[birthIdx] {
                    spawnHeadX = recorded
                } else if age < 0.14 && isActive {
                    tracker.spawns[birthIdx] = headX
                    spawnHeadX = headX
                } else if isActive {
                    // 刚打开页面时补全前置平滑连贯的初始尾气，避免突然突兀空缺
                    let seeded = headX - CGFloat(age) * 1.4 * scale
                    tracker.spawns[birthIdx] = seeded
                    spawnHeadX = seeded
                } else {
                    continue
                }

                drawWisp(
                    in: &layer,
                    spawnX: spawnHeadX,
                    anchorY: anchorY,
                    birth: birth,
                    age: age,
                    strength: strength
                )
            }
        }

        // 2. 火车烟囱口亮点：纯净白光晕 + 晶亮白点发射口
        let em = tracker.emitterLevel
        guard em > 0.01 else { return }

        let haloColor: Color = MyGoTheme.mix(.white, with: tintColor, ratio: 0.24)
        let glowRadius = (9.2 + 7.8 * strength) * scale
        let glowRect = CGRect(
            x: headX - glowRadius,
            y: anchorY - glowRadius,
            width: glowRadius * 2,
            height: glowRadius * 2
        )
        context.fill(
            Path(ellipseIn: glowRect),
            with: .radialGradient(
                Gradient(colors: [
                    haloColor.opacity((lightSurfaceMode ? 0.36 : 0.68) * em),
                    haloColor.opacity((lightSurfaceMode ? 0.14 : 0.26) * em),
                    .clear
                ]),
                center: CGPoint(x: headX, y: anchorY),
                startRadius: 0,
                endRadius: glowRadius
            )
        )

        let coreSize = (4.8 + 1.25 * strength) * scale
        let coreRect = CGRect(
            x: headX - coreSize * 0.5,
            y: anchorY - coreSize * 0.5,
            width: coreSize,
            height: coreSize
        )
        let coreColor: Color = lightSurfaceMode
            ? MyGoTheme.mix(Color(white: 0.88), with: tintColor, ratio: 0.25)
            : .white
        context.fill(
            Path(ellipseIn: coreRect),
            with: .color(coreColor.opacity(min(1.0, 0.96 * em)))
        )
    }

    static func wispGeometry(
        spawnX: CGFloat,
        anchorY: CGFloat,
        birth: Double,
        age: Double,
        life: Double = ProgressSmokeView.smokeLife,
        strength: CGFloat,
        scale: CGFloat = 1.0,
        lightSurfaceMode: Bool = false,
        useAdditiveBlend: Bool = true,
        respectQuietGate: Bool = true
    ) -> SmokeWispGeometry? {
        guard life > 0, age >= 0, age < life else { return nil }
        let f = CGFloat(age / life)
        let a = noise(birth * 1.37 + 1.1)
        let b = noise(birth * 2.11 + 2.3)
        let c = noise(birth * 3.19 + 3.7)
        let d = noise(birth * 4.71 + 5.3)

        // 安静段落仅在中远扩散段平滑减稀透明度（前 32% 紧贴小烟囱喷口始终保持 100% 满密度连续喷射，绝不断层）
        let quietGate = noise(birth * 5.23 + 7.1)
        let quietDensityScale = (f > 0.32 && quietGate > 0.66 + 0.34 * Double(strength)) ? 0.45 : 1.0
        if respectQuietGate && quietGate > 0.88 + 0.12 * Double(strength) && f > 0.36 {
            return nil
        }

        // 紧贴喷嘴向上偏左喷涌并呈现稍大一些、更加连绵蓬松的白色蒸汽卷曲
        let driftLeft = CGFloat(age) * (15.5 + 20.5 * CGFloat(a)) * scale
        let liftUp = CGFloat(age) * (20.0 + 23.5 * CGFloat(b)) * scale
        let sway = CGFloat(sin(age * (2.2 + 1.6 * c) + d * .pi * 2)) * (3.4 * pow(Double(f), 0.90)) * scale

        let center = CGPoint(
            x: spawnX - driftLeft + sway * 0.42,
            y: anchorY - 1.3 * scale - liftUp + sway * 0.26
        )

        // 刚喷出时保持紧凑口径，随后迅速舒展成饱满白雾
        let radius = (2.3 + f * (14.2 + 10.6 * CGFloat(d))) * scale
        let rx = radius * (1.30 + 0.15 * CGFloat(a))
        let ry = radius * (0.94 + 0.12 * CGFloat(b))

        // 零悬空断根：刚出生 3% 内立刻显形，紧贴光点口
        let fadeIn = min(Double(f) / 0.03, 1.0)
        let fadeOut = pow(1.0 - Double(f), 1.42)
        let levelGain = 0.76 + 0.56 * Double(strength)
        let baseOpacity = lightSurfaceMode ? 0.22 : (useAdditiveBlend ? 0.23 : 0.28)
        let alpha = fadeIn * fadeOut * baseOpacity * levelGain * quietDensityScale
        guard alpha > 0.004 else { return nil }

        return SmokeWispGeometry(center: center, radiusX: rx, radiusY: ry, alpha: alpha)
    }

    private func drawWisp(
        in context: inout GraphicsContext,
        spawnX: CGFloat,
        anchorY: CGFloat,
        birth: Double,
        age: Double,
        strength: CGFloat
    ) {
        guard let geo = Self.wispGeometry(
            spawnX: spawnX,
            anchorY: anchorY,
            birth: birth,
            age: age,
            life: life,
            strength: strength,
            scale: scale,
            lightSurfaceMode: lightSurfaceMode,
            useAdditiveBlend: useAdditiveBlend
        ) else {
            return
        }

        let smokeColor: Color
        let coreMixColor: Color
        if lightSurfaceMode {
            let smokyGrey = Color(red: 0.56, green: 0.58, blue: 0.63)
            smokeColor = MyGoTheme.mix(smokyGrey, with: tintColor, ratio: 0.16)
            coreMixColor = MyGoTheme.mix(Color(white: 0.74), with: tintColor, ratio: 0.18)
        } else {
            smokeColor = MyGoTheme.mix(.white, with: tintColor, ratio: 0.22)
            coreMixColor = MyGoTheme.mix(.white, with: tintColor, ratio: 0.12)
        }

        // 沿气流斜向 -39° 微微拉伸绘制，使连串粒子无缝接成一条飘逸蒸汽束
        var localCtx = context
        localCtx.translateBy(x: geo.center.x, y: geo.center.y)
        localCtx.rotate(by: .radians(-0.68))

        let localRect = CGRect(x: -geo.radiusX, y: -geo.radiusY, width: geo.radiusX * 2, height: geo.radiusY * 2)
        localCtx.fill(
            Path(ellipseIn: localRect),
            with: .radialGradient(
                Gradient(colors: [
                    coreMixColor.opacity(geo.alpha),
                    smokeColor.opacity(geo.alpha * 0.56),
                    smokeColor.opacity(geo.alpha * 0.14),
                    .clear
                ]),
                center: .zero,
                startRadius: 0,
                endRadius: max(geo.radiusX, geo.radiusY)
            )
        )
    }

    private static func noise(_ seed: Double) -> Double {
        let value = sin(seed * 127.1) * 43_758.5453
        return value - floor(value)
    }
}

// MARK: - 歌词高亮离散层级与单行缓存渲染（极大缩减 Diff 范围与避免级联刷新）

/// 歌词行按压圆角高光反馈样式（遵循 iOS HIG 触控卡片微缩与明暗衬底反馈）
private struct LyricRowButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.11 : 0.0))
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1.0, anchor: .leading)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// 标记词条结尾是否自带空白间隔，用于在单词边界精确换行且不因尾随空格误折行
private struct LyricWordTrailingSpaceKey: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// Apple Music 风格自适应词流布局：按行排布完整词条与单字，防止英文单词被拆分或切换焦点时重排抖动
private struct AppleMusicWordFlowLayout: Layout {
    var lineSpacing: CGFloat = 5

    func makeCache(subviews: Subviews) -> () { () }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = (proposal.width ?? .greatestFiniteMagnitude).isFinite
            ? max(40, proposal.width ?? 340)
            : CGFloat.greatestFiniteMagnitude
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        guard !rows.isEmpty else { return .zero }

        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0
        for (idx, row) in rows.enumerated() {
            totalHeight += row.height
            if idx + 1 < rows.count {
                totalHeight += lineSpacing
            }
            widest = max(widest, row.width)
        }
        let resultWidth = maxWidth.isFinite ? maxWidth : widest
        return CGSize(width: resultWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = max(40, bounds.width)
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let yOffset = (row.height - item.size.height) * 0.5
                let itemProposal = item.clampedToContainer
                    ? ProposedViewSize(width: maxWidth, height: nil)
                    : ProposedViewSize(width: item.size.width, height: item.size.height)
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + yOffset),
                    anchor: .topLeading,
                    proposal: itemProposal
                )
                x += item.size.width
            }
            y += row.height + lineSpacing
        }
    }

    private struct RowItem {
        let index: Int
        let size: CGSize
        let clampedToContainer: Bool
    }

    private struct ComputedRow {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [ComputedRow] {
        var rows: [ComputedRow] = []
        var current = ComputedRow()

        for index in subviews.indices {
            let subview = subviews[index]
            let natural = subview.sizeThatFits(.unspecified)
            let trailingTolerance = subview[LyricWordTrailingSpaceKey.self]
            let visibleAdvance = max(0, natural.width - trailingTolerance)

            if !current.items.isEmpty && current.width + visibleAdvance > maxWidth {
                rows.append(current)
                current = ComputedRow()
            }

            let needsClamp = current.items.isEmpty && natural.width > maxWidth && maxWidth.isFinite
            let measuredSize = needsClamp
                ? subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                : natural

            current.items.append(RowItem(index: index, size: measuredSize, clampedToContainer: needsClamp))
            current.width += measuredSize.width
            current.height = max(current.height, measuredSize.height)
        }
        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

/// 单个歌词词条视觉单元：支持基于连续线性渐变遮罩的流体扫光、柔性余韵辉光与音节轻抬
private struct AppleMusicWordItemView: View {
    let parts: (core: String, trailing: String)
    let motion: LyricWordMotion
    let isActiveHighlight: Bool
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let staticTintOpacity: Double
    let dimOpacity: Double

    private var glyphFont: Font {
        .system(size: fontSize, weight: fontWeight)
    }

    var body: some View {
        HStack(spacing: 0) {
            if !parts.core.isEmpty {
                coreGlyphView
            }
            if !parts.trailing.isEmpty {
                Text(parts.trailing)
                    .font(glyphFont)
                    .foregroundStyle(.clear)
            }
        }
        .layoutValue(
            key: LyricWordTrailingSpaceKey.self,
            value: parts.trailing.isEmpty ? 0 : fontSize * 0.25
        )
    }

    @ViewBuilder
    private var coreGlyphView: some View {
        if !isActiveHighlight {
            // 相邻预布局行（near1）：纯单色呈现以保证零重排开销
            Text(parts.core)
                .font(glyphFont)
                .foregroundStyle(Color.white.opacity(staticTintOpacity))
        } else {
            ZStack(alignment: .leading) {
                Text(parts.core)
                    .font(glyphFont)
                    .foregroundStyle(Color.white.opacity(dimOpacity))

                if motion.wipeProgress >= 0.999 {
                    Text(parts.core)
                        .font(glyphFont)
                        .foregroundStyle(.white)
                        .shadow(
                            color: .white.opacity(0.30 * motion.glowIntensity),
                            radius: 5,
                            x: 0,
                            y: 0
                        )
                } else if motion.wipeProgress > 0.001 {
                    let feather = 0.22
                    let lead = motion.wipeProgress * (1.0 + feather) - feather
                    let tail = lead + feather
                    Text(parts.core)
                        .font(glyphFont)
                        .foregroundStyle(.white)
                        .shadow(
                            color: .white.opacity(0.36 * motion.glowIntensity),
                            radius: 6,
                            x: 0,
                            y: 0
                        )
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0.0),
                                    .init(color: .black, location: min(max(lead, 0.0), 1.0)),
                                    .init(color: .clear, location: min(max(tail, 0.0), 1.0)),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        }
                }
            }
            .scaleEffect(motion.scale, anchor: .center)
            .offset(y: motion.liftY)
        }
    }
}

/// 隔离于单行内部的 60fps 硬件时钟驱动器：仅当该行处于当前聚焦演唱态时才唤醒逐字动画帧刷新
private struct ActiveLyricLineWordsHostView: View {
    let words: [LyricWord]
    let fallbackText: String
    let isCurrent: Bool
    let isPlaying: Bool
    let scrubbingPosition: TimeInterval?
    let staticPosition: TimeInterval
    let livePositionProvider: () -> TimeInterval
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let staticTintOpacity: Double
    let reduceMotion: Bool

    var body: some View {
        if isCurrent {
            // 仅在播放且非拖拽时启动 60fps 帧采样；暂停与拖拽时由外部状态按需精准刷新
            let timelinePaused = !isPlaying || scrubbingPosition != nil
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: timelinePaused)) { timeline in
                let _ = timeline.date
                let rawPos = scrubbingPosition ?? (isPlaying ? livePositionProvider() : staticPosition)
                // 与行切分保持一致的 0.08s 视听前瞻补偿，让歌词点亮时刻与耳中人声分毫不差
                let livePos = rawPos + 0.08
                wordsFlowContent(livePosition: livePos, active: true)
            }
        } else {
            wordsFlowContent(livePosition: nil, active: false)
        }
    }

    @ViewBuilder
    private func wordsFlowContent(livePosition: TimeInterval?, active: Bool) -> some View {
        if words.count > 120 {
            // 对极端超长文本兜底系统 Text 拼合，兼顾流体计算上限保护
            legacyConcatenatedText(livePosition: livePosition, active: active)
        } else {
            AppleMusicWordFlowLayout(lineSpacing: 5) {
                ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                    let parts = LyricsEngine.splitWordTrailingWhitespace(word.text)
                    let motion = active && livePosition != nil
                        ? LyricsEngine.wordMotion(for: word, at: livePosition ?? 0, reduceMotion: reduceMotion)
                        : LyricWordMotion(wipeProgress: 0, liftY: 0, scale: 1.0, glowIntensity: 0, isActive: false)
                    AppleMusicWordItemView(
                        parts: parts,
                        motion: motion,
                        isActiveHighlight: active,
                        fontSize: fontSize,
                        fontWeight: fontWeight,
                        staticTintOpacity: staticTintOpacity,
                        dimOpacity: 0.54
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legacyConcatenatedText(livePosition: TimeInterval?, active: Bool) -> some View {
        var combined = Text("")
        if active, let pos = livePosition {
            for word in words {
                let motion = LyricsEngine.wordMotion(for: word, at: pos, reduceMotion: reduceMotion)
                let opacity = 0.54 + 0.46 * motion.wipeProgress
                combined = combined + Text(word.text).foregroundColor(.white.opacity(opacity))
            }
        } else {
            combined = Text(fallbackText).foregroundColor(.white.opacity(staticTintOpacity))
        }
        return combined
            .font(.system(size: fontSize, weight: fontWeight))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 滚动歌词流中的 Apple Music 风格前奏/长间奏三圆点呼吸气泡
private struct AppleMusicInterludeDotsRowView: View {
    let window: LyricInterludeWindow?
    let isVisible: Bool
    let isPlaying: Bool
    let scrubbingPosition: TimeInterval?
    let staticPosition: TimeInterval
    let livePositionProvider: () -> TimeInterval
    let reduceMotion: Bool

    var body: some View {
        let timelinePaused = !isVisible || !isPlaying || scrubbingPosition != nil
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: timelinePaused)) { timeline in
            let now = timeline.date.timeIntervalSince1970
            let pos = scrubbingPosition ?? (isPlaying ? livePositionProvider() : staticPosition)
            let progress: Double = {
                guard let window else { return 0 }
                let span = max(0.1, window.to - window.from)
                return min(1.0, max(0.0, (pos - window.from) / span))
            }()
            // 在靠近下一句开唱前 0.45s 平滑收敛消隐，优雅让位给首字
            let tailScale: CGFloat = {
                guard let window, !reduceMotion else { return 1.0 }
                let rem = max(0.0, window.to - pos)
                return rem < 0.45 ? max(0.65, CGFloat(rem / 0.45)) : 1.0
            }()

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { idx in
                    let dotLit = min(1.0, max(0.0, progress * 3.0 - Double(idx)))
                    let pulse: CGFloat = reduceMotion
                        ? 1.0
                        : 0.90 + 0.22 * CGFloat(0.5 + 0.5 * sin(now * 3.6 - Double(idx) * 0.85))
                    Circle()
                        .fill(Color.white.opacity(0.28 + 0.68 * dotLit))
                        .frame(width: 10, height: 10)
                        .scaleEffect(pulse * tailScale)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: isVisible ? 30 : 0)
            .opacity(isVisible ? 1.0 : 0.0)
            .clipped()
            .animation(.easeOut(duration: 0.16), value: isVisible)
        }
    }
}

private struct LyricRowView: View, Equatable {
    let index: Int
    let line: LyricLine
    let presentation: LyricLinePresentation
    let allowsBlur: Bool
    let isUserScrolling: Bool
    let isCredit: Bool
    let isPlaying: Bool
    let scrubbingPosition: TimeInterval?
    let staticPosition: TimeInterval
    let livePositionProvider: () -> TimeInterval
    let reduceMotion: Bool
    let onSeek: (TimeInterval) -> Void

    private static let primaryFontSize: CGFloat = 24
    private static let translationFontSize: CGFloat = 15

    static func == (lhs: LyricRowView, rhs: LyricRowView) -> Bool {
        guard lhs.index == rhs.index &&
                lhs.presentation == rhs.presentation &&
                lhs.allowsBlur == rhs.allowsBlur &&
                lhs.isUserScrolling == rhs.isUserScrolling &&
                lhs.isCredit == rhs.isCredit &&
                lhs.isPlaying == rhs.isPlaying &&
                lhs.reduceMotion == rhs.reduceMotion &&
                lhs.line.at == rhs.line.at &&
                lhs.line.end == rhs.line.end &&
                lhs.line.text == rhs.line.text &&
                lhs.line.translation == rhs.line.translation &&
                lhs.line.words.count == rhs.line.words.count else {
            return false
        }
        // 非聚焦行完全屏蔽高频时间变更，保持 0% 额外重绘消耗
        guard lhs.presentation.tier == .current else { return true }
        if lhs.scrubbingPosition != rhs.scrubbingPosition {
            return false
        }
        // 仅在暂停非拖拽状态下比对静态位置（播放态由内部 60fps TimelineView 驱动）
        if !lhs.isPlaying && lhs.scrubbingPosition == nil {
            return abs(lhs.staticPosition - rhs.staticPosition) < 0.015
        }
        return true
    }

    private var rowTransitionAnimation: Animation {
        if isUserScrolling {
            return .easeOut(duration: 0.18)
        }
        if reduceMotion {
            return .easeInOut(duration: 0.22)
        }
        return .spring(response: 0.54, dampingFraction: 0.84, blendDuration: 0.14)
            .delay(presentation.staggerDelay)
    }

    var body: some View {
        let isCurrent = (presentation.tier == .current)
        let usesWordFlow = !line.words.isEmpty && (presentation.tier == .current || presentation.tier == .near1)

        Button {
            onSeek(line.at)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if usesWordFlow {
                    ActiveLyricLineWordsHostView(
                        words: line.words,
                        fallbackText: line.text,
                        isCurrent: isCurrent,
                        isPlaying: isPlaying,
                        scrubbingPosition: scrubbingPosition,
                        staticPosition: staticPosition,
                        livePositionProvider: livePositionProvider,
                        fontSize: Self.primaryFontSize,
                        fontWeight: isCredit ? .semibold : .bold,
                        staticTintOpacity: presentation.primaryOpacity,
                        reduceMotion: reduceMotion
                    )
                } else {
                    Text(line.text)
                        .font(.system(size: Self.primaryFontSize, weight: isCredit ? .semibold : .bold))
                        .foregroundStyle(.white.opacity(presentation.primaryOpacity))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !line.translation.isEmpty {
                    Text(line.translation)
                        .font(.system(size: Self.translationFontSize, weight: .medium))
                        .foregroundStyle(.white.opacity(presentation.translationOpacity))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(LyricRowButtonStyle(reduceMotion: reduceMotion))
        // 统一字号配合 GPU 左侧锚点缩放，仅对近景相邻几行应用模糊以消除全曲 80+ 离屏高斯模糊卡顿
        .scaleEffect(presentation.scale, anchor: .leading)
        .blur(radius: allowsBlur ? presentation.blurRadius : 0)
        .animation(rowTransitionAnimation, value: presentation)
        .animation(.easeOut(duration: 0.18), value: isUserScrolling)
        .accessibilityLabel(line.translation.isEmpty ? line.text : "\(line.text)，\(line.translation)")
    }
}

// MARK: - 滚动歌词组件（Apple Music 逐字扫光 + 景深柔焦 + 弹簧级联滚屏 + 间奏引导/热评浮层）

private struct LyricsScrollView: View {
    @ObservedObject var player: PlayerEngine
    let activePane: NowPlayingPane
    let scrubbingPosition: TimeInterval?
    let hotCommentsEnabled: Bool
    let comments: [Comment]
    let onSeek: (TimeInterval) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 缓存间奏与演职员行标识，避免高频评估重复正则匹配
    @State private var cachedQuiets: [LyricQuiet] = []
    @State private var cachedCreditFlags: [Bool] = []

    // 用户手动拖拽/浏览歌词状态与触觉反馈触发器
    @State private var isUserScrolling: Bool = false
    @State private var autoSnapTask: Task<Void, Never>? = nil
    @State private var seekAlignmentTask: Task<Void, Never>? = nil
    @State private var layoutAlignmentTask: Task<Void, Never>? = nil
    @State private var lastScrubTargetIndex: Int? = nil
    @State private var seekHapticTrigger: Int = 0
    @State private var hasAlignedInitialScroll: Bool = false

    /// 对标 Apple Music 视觉重心（贴紧上方封面底边展开，下方铺开充分预读歌词）
    private let lyricAnchor = UnitPoint(x: 0.5, y: 0.20)

    init(
        player: PlayerEngine,
        activePane: NowPlayingPane = .lyrics,
        scrubbingPosition: TimeInterval? = nil,
        hotCommentsEnabled: Bool,
        comments: [Comment],
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.player = player
        self.activePane = activePane
        self.scrubbingPosition = scrubbingPosition
        self.hotCommentsEnabled = hotCommentsEnabled
        self.comments = comments
        self.onSeek = onSeek
    }

    private var effectivePosition: TimeInterval {
        scrubbingPosition ?? player.acousticLyricPosition()
    }

    private func livePositionSample() -> TimeInterval {
        scrubbingPosition ?? player.acousticLyricPosition()
    }

    private var currentIndex: Int {
        guard !player.lyrics.isEmpty else { return -1 }
        return LyricsEngine.index(in: player.lyrics, at: effectivePosition)
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

    private func refreshCachedLineMetadata() {
        let lines = player.lyrics
        cachedCreditFlags = lines.map { LyricsEngine.isCredit($0.text) }
        if hotCommentsEnabled && !lines.isEmpty {
            cachedQuiets = LyricsEngine.quiets(in: lines, trackLength: player.duration, least: 8.0)
        } else {
            cachedQuiets = []
        }
    }

    private func scrollToFocus(index targetIndex: Int, proxy: ScrollViewProxy, animated: Bool = true) {
        guard !player.lyrics.isEmpty else { return }
        let applyScroll = {
            if targetIndex >= 0 && targetIndex < player.lyrics.count {
                proxy.scrollTo(targetIndex, anchor: lyricAnchor)
            } else if (player.lyrics.first?.at ?? 0) >= 2.2 {
                proxy.scrollTo("interlude-intro", anchor: lyricAnchor)
            } else {
                proxy.scrollTo(0, anchor: lyricAnchor)
            }
        }
        if animated {
            let curve: Animation = reduceMotion
                ? .easeInOut(duration: 0.22)
                : .spring(response: 0.54, dampingFraction: 0.84)
            withAnimation(curve) {
                applyScroll()
            }
        } else {
            applyScroll()
        }
    }

    private func scheduleAutoSnap(proxy: ScrollViewProxy) {
        autoSnapTask?.cancel()
        autoSnapTask = Task {
            // 松手后等待 2.5 秒，若用户无新动作，自动平滑弹回当前播放行或前奏引导！
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.22)) {
                    isUserScrolling = false
                }
                scrollToFocus(index: currentIndex, proxy: proxy, animated: true)
            }
        }
    }

    private func scheduleReliableAlignment(proxy: ScrollViewProxy, animated: Bool = false) {
        layoutAlignmentTask?.cancel()
        let sig = player.lyricsSignature
        layoutAlignmentTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, !isUserScrolling, scrubbingPosition == nil, player.lyricsSignature == sig else { return }
            scrollToFocus(index: currentIndex, proxy: proxy, animated: animated)

            // 切页错峰位移及换行文本排版彻底稳态后再复核一次锚点，消除初始定位偏差
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, !isUserScrolling, scrubbingPosition == nil, player.lyricsSignature == sig else { return }
            scrollToFocus(index: currentIndex, proxy: proxy, animated: false)
        }
    }

    var body: some View {
        let lines = player.lyrics
        let loaded = player.lyricsLoaded
        let curIdx = currentIndex
        let interlude = activeQuietComment == nil
            ? LyricsEngine.activeInterlude(in: lines, at: effectivePosition, currentIndex: curIdx)
            : nil

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
                    let topPad: CGFloat = 16
                    let bottomPad = max(geo.size.height * 0.58, 160)

                    ScrollViewReader { proxy in
                        ZStack(alignment: .bottomTrailing) {
                            ScrollView(showsIndicators: false) {
                                // 使用精确坐标 VStack（搭配 .equatable() 与近景 4 行模糊限流）保证所有歌词行位置 100% 精准不跳偏
                                VStack(alignment: .leading, spacing: 14) {
                                    // 歌曲前奏三圆点呼吸引导槽（仅当首句存在 >=2.2s 前奏时挂载）
                                    if let firstAt = lines.first?.at, firstAt >= 2.2 {
                                        let showIntro = (interlude?.insertAfterLineIndex == -1)
                                        AppleMusicInterludeDotsRowView(
                                            window: showIntro ? interlude : nil,
                                            isVisible: showIntro,
                                            isPlaying: player.isPlaying,
                                            scrubbingPosition: scrubbingPosition,
                                            staticPosition: effectivePosition,
                                            livePositionProvider: { livePositionSample() },
                                            reduceMotion: reduceMotion
                                        )
                                        .id("interlude-intro")
                                    }

                                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                                        let isCredit = idx < cachedCreditFlags.count ? cachedCreditFlags[idx] : false
                                        let pres = LyricsEngine.linePresentation(
                                            index: idx,
                                            currentIndex: curIdx,
                                            isUserScrolling: isUserScrolling,
                                            isCredit: isCredit,
                                            reduceMotion: reduceMotion
                                        )
                                        LyricRowView(
                                            index: idx,
                                            line: line,
                                            presentation: pres,
                                            allowsBlur: abs(idx - curIdx) <= 4 && !isUserScrolling,
                                            isUserScrolling: isUserScrolling,
                                            isCredit: isCredit,
                                            isPlaying: player.isPlaying,
                                            scrubbingPosition: scrubbingPosition,
                                            staticPosition: effectivePosition,
                                            livePositionProvider: { livePositionSample() },
                                            reduceMotion: reduceMotion,
                                            onSeek: { targetTime in
                                                autoSnapTask?.cancel()
                                                isUserScrolling = false
                                                seekHapticTrigger &+= 1
                                                onSeek(targetTime)
                                                scrollToFocus(index: idx, proxy: proxy, animated: true)
                                            }
                                        )
                                        .equatable()
                                        .id(idx)

                                        // 句间长间奏三圆点呼吸引导槽（仅挂载在 >=4s 真实间奏行后）
                                        if idx + 1 < lines.count, lines[idx + 1].at - line.end >= 4.0 {
                                            let showGapDots = (interlude?.insertAfterLineIndex == idx)
                                            AppleMusicInterludeDotsRowView(
                                                window: showGapDots ? interlude : nil,
                                                isVisible: showGapDots,
                                                isPlaying: player.isPlaying,
                                                scrubbingPosition: scrubbingPosition,
                                                staticPosition: effectivePosition,
                                                livePositionProvider: { livePositionSample() },
                                                reduceMotion: reduceMotion
                                            )
                                        }
                                    }
                                }
                                .padding(.top, topPad)
                                .padding(.bottom, bottomPad)
                            }
                            // 直接协同父面板切换同步显影，彻底取消二次延迟淡入造成的切页脱节
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 12)
                                    .onChanged { _ in
                                        autoSnapTask?.cancel()
                                        seekAlignmentTask?.cancel()
                                        if !isUserScrolling {
                                            withAnimation(.easeOut(duration: 0.18)) {
                                                isUserScrolling = true
                                            }
                                        }
                                    }
                                    .onEnded { _ in
                                        scheduleAutoSnap(proxy: proxy)
                                    }
                            )
                            // 自然播放推进换行（含从间奏或拖回前奏）
                            .mygoOnChange(of: curIdx) { _, newIdx in
                                if scrubbingPosition == nil && !isUserScrolling {
                                    scrollToFocus(index: newIdx, proxy: proxy, animated: true)
                                }
                            }
                            // 用户在底栏进度条拖拽时：仅当目标行索引发生变化才即时定位，避免手抖打断滚动状态机
                            .mygoOnChange(of: scrubbingPosition) { _, newScrub in
                                guard let newScrub else {
                                    lastScrubTargetIndex = nil
                                    return
                                }
                                autoSnapTask?.cancel()
                                seekAlignmentTask?.cancel()
                                layoutAlignmentTask?.cancel()
                                isUserScrolling = false
                                let targetIdx = LyricsEngine.index(in: player.lyrics, at: newScrub)
                                if targetIdx != lastScrubTargetIndex {
                                    lastScrubTargetIndex = targetIdx
                                    scrollToFocus(index: targetIdx, proxy: proxy, animated: false)
                                }
                            }
                            // 发起 Seek 与底层解码真落地两阶段对焦校准：确保“拖到哪就稳稳停在哪”
                            .mygoOnChange(of: player.seekRevision) { _, revision in
                                autoSnapTask?.cancel()
                                seekAlignmentTask?.cancel()
                                layoutAlignmentTask?.cancel()
                                isUserScrolling = false
                                seekAlignmentTask = Task { @MainActor in
                                    await Task.yield()
                                    guard !Task.isCancelled, player.seekRevision == revision else { return }
                                    scrollToFocus(index: currentIndex, proxy: proxy, animated: true)
                                }
                            }
                            .mygoOnChange(of: player.seekSettledRevision) { _, settledRev in
                                autoSnapTask?.cancel()
                                seekAlignmentTask?.cancel()
                                layoutAlignmentTask?.cancel()
                                isUserScrolling = false
                                seekAlignmentTask = Task { @MainActor in
                                    await Task.yield()
                                    guard !Task.isCancelled, player.seekSettledRevision == settledRev else { return }
                                    scrollToFocus(index: currentIndex, proxy: proxy, animated: false)
                                    try? await Task.sleep(nanoseconds: 90_000_000)
                                    guard !Task.isCancelled, player.seekSettledRevision == settledRev, !isUserScrolling else { return }
                                    scrollToFocus(index: currentIndex, proxy: proxy, animated: false)
                                }
                            }
                            .onAppear {
                                hasAlignedInitialScroll = true
                                refreshCachedLineMetadata()
                                scheduleReliableAlignment(proxy: proxy, animated: false)
                            }
                            .mygoOnChange(of: activePane) { _, pane in
                                guard pane == .lyrics else { return }
                                isUserScrolling = false
                                scheduleReliableAlignment(proxy: proxy, animated: false)
                            }
                            .mygoOnChange(of: player.currentTrack?.id) { _, _ in
                                refreshCachedLineMetadata()
                                autoSnapTask?.cancel()
                                seekAlignmentTask?.cancel()
                                layoutAlignmentTask?.cancel()
                                isUserScrolling = false
                                scheduleReliableAlignment(proxy: proxy, animated: false)
                            }
                            .mygoOnChange(of: player.lyricsSignature) { _, _ in
                                refreshCachedLineMetadata()
                                scheduleReliableAlignment(proxy: proxy, animated: false)
                            }

                            // 用户手动滑动浏览时，右下角优雅浮现 iOS 玻璃胶囊「回位」按钮
                            if isUserScrolling {
                                Button {
                                    autoSnapTask?.cancel()
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        isUserScrolling = false
                                    }
                                    seekHapticTrigger &+= 1
                                    scrollToFocus(index: currentIndex, proxy: proxy, animated: true)
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
                // 上下边缘渐变柔隐，契合 Apple Music 无边界液态沉浸质感
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.04),
                            .init(color: .black, location: 0.87),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(activeQuietComment != nil ? 0.0 : 1.0)
                .blur(radius: activeQuietComment != nil ? 12 : 0)
                .animation(.easeInOut(duration: 0.38), value: activeQuietComment != nil)
            }

            // 间奏热评浮层（对应 ui_quiet.go，背后歌词已完全淡出虚化以避免文字穿帮隔离感）
            if let hot = activeQuietComment {
                VStack(alignment: .leading, spacing: 12) {
                    Text(I18n.t("Top Comment").uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(MyGoTheme.accent)
                        .tracking(1.2)

                    Text("“\(hot.text)”")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineSpacing(5)

                    Text("— \(hot.author)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.75)
                )
                .padding(.horizontal, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeInOut(duration: 0.36), value: activeQuietComment != nil)
        .mygoOnChange(of: seekHapticTrigger) { _, _ in
            MyGoHaptics.impact(.light)
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
                let pos = app.player.acousticLyricPosition()
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

// MARK: - 正在播放动态烟雾与流光背景（1:1 移植桌面端 backdrop.go GPU Shader）

struct NowPlayingBackdropView: View {
    @Environment(\.mygoImageHeadersProvider) private var imageHeadersProvider
    @Environment(\.mygoIsViewVisible) private var isViewVisible
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mygoNowPlayingModalBridge) private var externalModalBridge
    @StateObject private var artworkLoader = ArtworkImageLoader()
    let imageURL: String?
    @ObservedObject var player: PlayerEngine
    let fogEnabled: Bool
    var preview: Bool = false

    private var resolvedTint: BackdropRGBColor {
        artworkLoader.dominantRGB ?? .defaultTint
    }

    var body: some View {
        let tint = resolvedTint
        // 统一升级为 Apple Music 同款纯洁专辑主色模糊漫射渐变背景（全面告别浊白烟雾层）
        stillBackdropView(tint: tint)
            .drawingGroup(opaque: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.all)
            .allowsHitTesting(false)
            .onAppear {
                externalModalBridge?.currentBackdropTint = tint
            }
            .mygoOnChange(of: tint) { _, newTint in
                externalModalBridge?.currentBackdropTint = newTint
            }
            .task(id: imageURL ?? "") {
                await artworkLoader.load(
                    rawURLString: imageURL,
                    pixelSize: 200,
                    extractDominantColor: true
                ) { url in
                    imageHeadersProvider(url)
                }
            }
    }

    /// Apple Music 同款专辑取色柔光背景（双色调温和渐变 + 超大半径主色光晕 + 底部沉稳暗角）
    @ViewBuilder
    private func stillBackdropView(tint: BackdropRGBColor) -> some View {
        let pair = BackdropFogMath.backdropColors(from: tint)
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: pair.top.r, green: pair.top.g, blue: pair.top.b),
                    Color(red: pair.foot.r, green: pair.foot.g, blue: pair.foot.b)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            if let image = artworkLoader.image {
                GeometryReader { geo in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 96)
                        .saturation(1.08)
                        .opacity(0.28)
                }
                .clipped()
            }

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.06), location: 0.0),
                    .init(color: .clear, location: 0.42),
                    .init(color: .black.opacity(0.26), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

#if canImport(Metal) && canImport(MetalKit)

private struct FogShaderUniforms {
    var deepColor: SIMD4<Float>
    var fogColor: SIMD4<Float>
    var beforeDeepColor: SIMD4<Float>
    var beforeFogColor: SIMD4<Float>
    var params: SIMD4<Float>       // x = drift, y = bass, z = width, w = height
    var beforeParams: SIMD4<Float> // x = beforeDrift, y = beforeBass, z = beforeAlpha, w = 0
}

private final class FogMetalPipeline: @unchecked Sendable {
    static let shared = FogMetalPipeline()

    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?
    let pipelineState: MTLRenderPipelineState?

    private static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct FogUniforms {
        float4 deepColor;
        float4 fogColor;
        float4 beforeDeepColor;
        float4 beforeFogColor;
        float4 params;
        float4 beforeParams;
    };

    vertex VertexOut mygoFogVertex(uint vid [[vertex_id]]) {
        constexpr float2 positions[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        constexpr float2 uvs[4] = {
            float2(0.0, 1.0),
            float2(1.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 0.0)
        };
        VertexOut out;
        out.position = float4(positions[vid], 0.0, 1.0);
        out.uv = uvs[vid];
        return out;
    }

    inline float fogHash(float2 p) {
        return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
    }

    inline float fogNoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = fogHash(i);
        float b = fogHash(i + float2(1.0, 0.0));
        float c = fogHash(i + float2(0.0, 1.0));
        float d = fogHash(i + float2(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    inline float fogFbm(float2 p) {
        float v = 0.0;
        float amp = 0.5;
        for (int i = 0; i < 5; i++) {
            v += amp * fogNoise(p);
            p = p * 2.03 + float2(1.7, 9.2);
            amp *= 0.5;
        }
        return v;
    }

    inline float3 evalFogPixel(float2 uv, float2 size, float t, float bass, float3 deepRGB, float3 fogRGB) {
        float2 pos = uv * size;
        float2 p = pos / size.y * 2.4;
        float2 rise = float2(0.0, t * 0.1);
        float2 q = float2(
            fogFbm(p + rise + float2(0.0, t * 0.04)),
            fogFbm(p + rise + float2(5.2, 1.3) - float2(t * 0.05, 0.0))
        );
        float f = fogFbm(p + rise + 0.9 * q);
        float bank = fogFbm(p * 0.45 + rise * 0.6 + float2(3.7, 0.0));
        float cloud = smoothstep(0.3 - 0.06 * bass, 0.78, f) * (0.45 + 0.75 * smoothstep(0.3, 0.65, bank));
        float m = smoothstep(-0.1, 0.4, uv.y) * (1.0 - 0.5 * smoothstep(0.65, 1.0, uv.y));
        float3 c = mix(deepRGB, fogRGB, min(cloud * m * (0.85 + 0.35 * bass), 1.0));
        float g = length((uv - float2(0.5, 0.42)) * float2(1.0, 1.25));
        c *= 1.08 - 0.45 * smoothstep(0.2, 0.85, g);

        float cell = size.y / 22.0;
        float2 sp = (pos + float2(0.0, t * cell * 0.9)) / cell;
        float2 id = floor(sp);
        float h = fogHash(id + float2(3.1, 7.7));
        if (h > 0.93) {
            float2 at = float2(fogHash(id + float2(1.3, 2.9)), fogHash(id + float2(8.1, 4.3))) * 0.8 + 0.1;
            float d = length((fract(sp) - at) * cell) / max(cell * 0.05, 0.7);
            float glint = 0.5 + 0.5 * sin(t * (1.5 + 2.0 * h) + h * 40.0);
            c += float3(0.75, 0.82, 1.0) * exp(-d * d) * glint * (0.25 + 0.3 * m);
        }
        return clamp(c, 0.0, 1.0);
    }

    fragment float4 mygoFogFragment(VertexOut in [[stage_in]], constant FogUniforms &u [[buffer(0)]]) {
        float2 size = max(u.params.zw, float2(64.0, 64.0));
        float3 col = evalFogPixel(in.uv, size, u.params.x, u.params.y, u.deepColor.rgb, u.fogColor.rgb);
        float beforeAlpha = u.beforeParams.z;
        if (beforeAlpha > 0.001) {
            float3 beforeCol = evalFogPixel(
                in.uv,
                size,
                u.beforeParams.x,
                u.beforeParams.y,
                u.beforeDeepColor.rgb,
                u.beforeFogColor.rgb
            );
            col = mix(col, beforeCol, clamp(beforeAlpha, 0.0, 1.0));
        }
        return float4(col, 1.0);
    }
    """

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let lib = try? device.makeLibrary(source: Self.metalSource, options: nil),
              let vfn = lib.makeFunction(name: "mygoFogVertex"),
              let ffn = lib.makeFunction(name: "mygoFogFragment") else {
            self.device = nil
            self.commandQueue = nil
            self.pipelineState = nil
            return
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.device = device
        self.commandQueue = queue
        self.pipelineState = try? device.makeRenderPipelineState(descriptor: desc)
    }
}

@MainActor
private final class FogMTKView: MTKView {
    var onLayoutChanged: (() -> Void)?

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutChanged?()
    }
    #else
    override func layout() {
        super.layout()
        onLayoutChanged?()
    }
    #endif
}

@MainActor
private final class FogMetalCoordinator: NSObject, MTKViewDelegate {
    weak var mtkView: MTKView?
    weak var player: PlayerEngine?

    private var motion = BackdropMotionState()
    private var hasInitializedTint = false
    private var currentTint: BackdropRGBColor = .defaultTint
    private var currentDeep: BackdropRGBColor
    private var currentFog: BackdropRGBColor

    private var beforeDeep: BackdropRGBColor = .defaultTint
    private var beforeFog: BackdropRGBColor = .defaultTint
    private var beforeDrift: Double = 0
    private var beforeBass: Double = 0
    private var fadeStart: TimeInterval? = nil

    private var previewMode: Bool = false
    private var isViewVisible: Bool = true
    private var isAppActive: Bool = true
    private var reduceMotion: Bool = false
    private var lastTintKey: String = ""

    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    private var appLifecycleObservers: [NSObjectProtocol] = []
    #else
    private var timer: Timer?
    #endif

    override init() {
        let initial = BackdropFogMath.fogColors(from: .defaultTint)
        self.currentDeep = initial.deep
        self.currentFog = initial.fog
        super.init()
        #if canImport(UIKit)
        registerAppLifecycleObservers()
        #endif
    }

    deinit {
        #if canImport(UIKit)
        for token in appLifecycleObservers {
            NotificationCenter.default.removeObserver(token)
        }
        #endif
    }

    #if canImport(UIKit)
    private func registerAppLifecycleObservers() {
        let resign = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isAppActive = false
                self?.setTickerActive(false)
            }
        }
        let active = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isAppActive = true
                self?.ensureTickerState(forceDraw: true)
            }
        }
        appLifecycleObservers = [resign, active]
    }
    #endif

    func stopTicker() {
        setTickerActive(false)
        #if canImport(UIKit)
        displayLink?.invalidate()
        displayLink = nil
        #endif
    }

    func update(
        tint: BackdropRGBColor,
        tintKey: String,
        player: PlayerEngine,
        preview: Bool,
        isViewVisible: Bool,
        reduceMotion: Bool
    ) {
        self.player = player
        self.previewMode = preview
        self.isViewVisible = isViewVisible
        self.reduceMotion = reduceMotion

        if !hasInitializedTint {
            hasInitializedTint = true
            currentTint = tint
            lastTintKey = tintKey
            let next = BackdropFogMath.fogColors(from: tint)
            currentDeep = next.deep
            currentFog = next.fog
        } else if tint != currentTint || tintKey != lastTintKey {
            if tint != currentTint {
                beforeDeep = currentDeep
                beforeFog = currentFog
                beforeDrift = motion.drift
                beforeBass = motion.bassLevel
                fadeStart = Date.timeIntervalSinceReferenceDate
            }
            currentTint = tint
            lastTintKey = tintKey
            let next = BackdropFogMath.fogColors(from: tint)
            currentDeep = next.deep
            currentFog = next.fog
        }

        ensureTickerState(forceDraw: true)
    }

    func attach(to view: FogMTKView) {
        self.mtkView = view
        view.onLayoutChanged = { [weak self] in
            self?.handleLayoutChange()
        }
        syncDrawableSize()
        ensureTickerState(forceDraw: true)
    }

    func handleLayoutChange() {
        syncDrawableSize()
        mtkView?.draw()
    }

    func syncDrawableSize() {
        guard let view = mtkView else { return }
        let b = view.bounds.size
        guard b.width > 1, b.height > 1 else { return }
        // 按桌面端 div = 2 等效半分辨率离屏渲染并 GPU 双线性柔化放大，兼顾奶油级柔雾观感与超低功耗
        let targetW = max(64.0, (b.width * 0.55).rounded())
        let targetH = max(64.0, (b.height * 0.55).rounded())
        if abs(view.drawableSize.width - targetW) > 1 || abs(view.drawableSize.height - targetH) > 1 {
            view.drawableSize = CGSize(width: targetW, height: targetH)
        }
    }

    private func ensureTickerState(forceDraw: Bool) {
        guard isViewVisible, isAppActive else {
            setTickerActive(false)
            return
        }
        let now = Date.timeIntervalSinceReferenceDate
        let isPlaying = (player?.isPlaying ?? false)
        let shouldMove = (isPlaying || previewMode) && !reduceMotion
        let isFading: Bool = {
            guard let start = fadeStart else { return false }
            return BackdropFogMath.beforeLayerOpacity(elapsedSinceFadeStart: now - start) > 0.001
        }()

        let needsTicker = shouldMove || isFading || motion.speed > 0.001 || motion.bassLevel > 0.004
        setTickerActive(needsTicker)

        if forceDraw {
            tickFrame(at: now)
        }
    }

    private func setTickerActive(_ active: Bool) {
        #if canImport(UIKit)
        if active {
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(onDisplayLink))
                if #available(iOS 15.0, *) {
                    link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
                }
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            displayLink?.isPaused = false
        } else {
            displayLink?.isPaused = true
        }
        #else
        if active {
            if timer == nil {
                let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.tickFrame(at: Date.timeIntervalSinceReferenceDate)
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
        #endif
    }

    #if canImport(UIKit)
    @objc private func onDisplayLink() {
        tickFrame(at: Date.timeIntervalSinceReferenceDate)
    }
    #endif

    private func tickFrame(at now: TimeInterval) {
        let isPlaying = (player?.isPlaying ?? false)
        let isLive = isPlaying && !(player?.isLoading ?? false)
        let moving = (isPlaying || previewMode) && !reduceMotion

        var liveLevels: [Float] = []
        if isLive, let player {
            let pos = player.livePlaybackPosition()
            let rhythm = player.sampleAudioRhythm(at: pos, lines: player.lyrics, isScrubbing: false)
            // 按低频主导加权铺满 24 格，使 group(0, 6) 准确反映真实底鼓/贝斯跃动
            let bassF = Float(rhythm.bass * 0.72 + rhythm.beatPulse * 0.38)
            liveLevels = Array(repeating: min(1.0, max(0.0, bassF)), count: 6)
            liveLevels.append(contentsOf: rhythm.bands.map { min(1.0, max(0.0, $0)) })
        }

        let stillMoving = motion.step(
            now: now,
            playing: moving,
            levels: liveLevels,
            live: isLive && !reduceMotion
        )
        let fading: Bool
        if let start = fadeStart {
            if BackdropFogMath.beforeLayerOpacity(elapsedSinceFadeStart: now - start) <= 0.001 {
                fadeStart = nil
                fading = false
            } else {
                fading = true
            }
        } else {
            fading = false
        }

        syncDrawableSize()
        mtkView?.draw()

        if !stillMoving && !fading && !moving {
            setTickerActive(false)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let gpu = FogMetalPipeline.shared
        guard let pipeline = gpu.pipelineState,
              let queue = gpu.commandQueue,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
            return
        }

        let now = Date.timeIntervalSinceReferenceDate
        let beforeAlpha: Double
        if let start = fadeStart {
            beforeAlpha = BackdropFogMath.beforeLayerOpacity(elapsedSinceFadeStart: now - start)
        } else {
            beforeAlpha = 0
        }

        let dSize = view.drawableSize
        let safeW = Float(max(64, dSize.width > 1 ? dSize.width : view.bounds.width * 0.55))
        let safeH = Float(max(64, dSize.height > 1 ? dSize.height : view.bounds.height * 0.55))

        var uniforms = FogShaderUniforms(
            deepColor: SIMD4<Float>(Float(currentDeep.r), Float(currentDeep.g), Float(currentDeep.b), 1),
            fogColor: SIMD4<Float>(Float(currentFog.r), Float(currentFog.g), Float(currentFog.b), 1),
            beforeDeepColor: SIMD4<Float>(Float(beforeDeep.r), Float(beforeDeep.g), Float(beforeDeep.b), 1),
            beforeFogColor: SIMD4<Float>(Float(beforeFog.r), Float(beforeFog.g), Float(beforeFog.b), 1),
            params: SIMD4<Float>(Float(motion.drift), Float(min(motion.bassLevel, 1.0)), safeW, safeH),
            beforeParams: SIMD4<Float>(Float(beforeDrift), Float(min(beforeBass, 1.0)), Float(beforeAlpha), 0)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FogShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

#if canImport(UIKit)
private struct FogShaderBackdropRepresentable: UIViewRepresentable {
    let tint: BackdropRGBColor
    let tintKey: String
    @ObservedObject var player: PlayerEngine
    let preview: Bool
    let isViewVisible: Bool
    let reduceMotion: Bool

    func makeCoordinator() -> FogMetalCoordinator {
        FogMetalCoordinator()
    }

    func makeUIView(context: Context) -> FogMTKView {
        let view = FogMTKView(frame: .zero, device: FogMetalPipeline.shared.device)
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = false
        view.isOpaque = true
        view.clearColor = MTLClearColor(red: tint.r * 0.3, green: tint.g * 0.3, blue: tint.b * 0.3, alpha: 1.0)
        view.delegate = context.coordinator
        context.coordinator.attach(to: view)
        context.coordinator.update(
            tint: tint,
            tintKey: tintKey,
            player: player,
            preview: preview,
            isViewVisible: isViewVisible,
            reduceMotion: reduceMotion
        )
        return view
    }

    func updateUIView(_ uiView: FogMTKView, context: Context) {
        context.coordinator.update(
            tint: tint,
            tintKey: tintKey,
            player: player,
            preview: preview,
            isViewVisible: isViewVisible,
            reduceMotion: reduceMotion
        )
    }

    static func dismantleUIView(_ uiView: FogMTKView, coordinator: FogMetalCoordinator) {
        uiView.onLayoutChanged = nil
        coordinator.stopTicker()
    }
}
#else
private struct FogShaderBackdropRepresentable: NSViewRepresentable {
    let tint: BackdropRGBColor
    let tintKey: String
    @ObservedObject var player: PlayerEngine
    let preview: Bool
    let isViewVisible: Bool
    let reduceMotion: Bool

    func makeCoordinator() -> FogMetalCoordinator {
        FogMetalCoordinator()
    }

    func makeNSView(context: Context) -> FogMTKView {
        let view = FogMTKView(frame: .zero, device: FogMetalPipeline.shared.device)
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = false
        view.delegate = context.coordinator
        context.coordinator.attach(to: view)
        context.coordinator.update(
            tint: tint,
            tintKey: tintKey,
            player: player,
            preview: preview,
            isViewVisible: isViewVisible,
            reduceMotion: reduceMotion
        )
        return view
    }

    func updateNSView(_ nsView: FogMTKView, context: Context) {
        context.coordinator.update(
            tint: tint,
            tintKey: tintKey,
            player: player,
            preview: preview,
            isViewVisible: isViewVisible,
            reduceMotion: reduceMotion
        )
    }

    static func dismantleNSView(_ nsView: FogMTKView, coordinator: FogMetalCoordinator) {
        nsView.onLayoutChanged = nil
        coordinator.stopTicker()
    }
}
#endif

#else

private struct FogShaderBackdropRepresentable: View {
    let tint: BackdropRGBColor
    let tintKey: String
    @ObservedObject var player: PlayerEngine
    let preview: Bool
    let isViewVisible: Bool
    let reduceMotion: Bool

    var body: some View {
        let pair = BackdropFogMath.fogColors(from: tint)
        LinearGradient(
            colors: [
                Color(red: pair.deep.r, green: pair.deep.g, blue: pair.deep.b),
                Color(red: pair.fog.r, green: pair.fog.g, blue: pair.fog.b),
                Color(red: pair.deep.r, green: pair.deep.g, blue: pair.deep.b)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

#endif

// MARK: - 音频信号路径详情浮层（#3）与队列定位通知

private extension Notification.Name {
    static let mygoLocateQueueCurrent = Notification.Name("mygoLocateQueueCurrent")
}

private struct AudioSignalPathSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let track: Track
    let info: AudioSignalPathInfo

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 顶部音质定性横幅
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill((info.isLossless ? MyGoTheme.losslessGold : .cyan).opacity(0.18))
                                .frame(width: 44, height: 44)
                            if info.isLossless {
                                AppleMusicLosslessGlyphView(color: MyGoTheme.losslessGold)
                                    .frame(width: 22, height: 12)
                            } else {
                                Image(systemName: "waveform")
                                    .font(.system(size: 19, weight: .bold))
                                    .foregroundStyle(.cyan)
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(info.isLossless ? I18n.t("Bit-Perfect Lossless") : I18n.t("Standard Audio"))
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                            Text("\(track.name) · \(track.artistNames)")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder((info.isLossless ? MyGoTheme.losslessGold : .white).opacity(0.25), lineWidth: 0.8)
                    )

                    // 两段式纯净音频直出信号路径
                    VStack(spacing: 0) {
                        let sampleRateSummary: String = {
                            if info.sampleRateHz > 0 {
                                return String(format: "%.1f kHz / %d-bit", Double(info.sampleRateHz) / 1000.0, info.bitDepth)
                            }
                            return "\(info.bitDepth)-bit"
                        }()

                        signalStageCard(
                            index: 1,
                            icon: "opticaldisc.fill",
                            tint: info.isLossless ? MyGoTheme.losslessGold : .cyan,
                            title: I18n.t("Source & Decoding"),
                            rows: [
                                (I18n.t("Delivery Mode"), "\(info.sourceName) · \(info.deliveryMode)"),
                                (I18n.t("Container Format"), "\(info.codecFormat) (\(info.qualityTier))"),
                                (I18n.t("Sample Rate & Bit Depth"), sampleRateSummary)
                            ]
                        )

                        signalFlowConnector()

                        signalStageCard(
                            index: 2,
                            icon: "hifispeaker.fill",
                            tint: .green,
                            title: I18n.t("Hardware Output"),
                            rows: [
                                (I18n.t("Output Device Name"), info.outputDeviceName),
                                (I18n.t("Transition"), info.transitionMode),
                                (I18n.t("Delivery Mode"), info.outputPortType)
                            ]
                        )
                    }
                }
                .padding(16)
            }
            .background(Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea())
            .navigationTitle(I18n.t("Audio Signal Path"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(I18n.t("Done")) { dismiss() }
                        .foregroundStyle(MyGoTheme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func signalFlowConnector() -> some View {
        HStack {
            Spacer().frame(width: 22)
            VStack(spacing: 2) {
                Rectangle()
                    .fill(.white.opacity(0.22))
                    .frame(width: 1.5, height: 12)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func signalStageCard(
        index: Int,
        icon: String,
        tint: Color,
        title: String,
        rows: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.18))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text("\(index). \(title)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
            }

            Divider().overlay(.white.opacity(0.1))

            VStack(spacing: 7) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.0)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        Text(row.1)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.94))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.6)
        )
    }
}

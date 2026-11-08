// SettingsAndMainViews.swift
// 对应原项目 internal/app/ui_settings.go, ui_player.go, ui_main.go 的设置、迷你播放条与根容器视图

#if canImport(MyGoMusicCore)
import MyGoMusicCore
#endif
import SwiftUI
import WebKit

// MARK: - 设置与插件管理页（对应 ui_settings.go / plugin_install.go）

public struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showInstallSheet = false
    @State private var githubRepoInput = ""
    @State private var cacheUsedBytes: Int64 = 0

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                // 1. 通用与外观
                SwiftUI.Section(I18n.t("General")) {
                    Picker(I18n.t("Language"), selection: $app.settings.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }

                    Picker(I18n.t("Appearance"), selection: $app.settings.appearance) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(I18n.t(mode.labelKey)).tag(mode)
                        }
                    }
                }

                // 2. 播放与音质
                SwiftUI.Section(I18n.t("Playback")) {
                    Picker(I18n.t("Quality"), selection: $app.settings.quality) {
                        ForEach(AudioQuality.allCases) { q in
                            Text(I18n.t(q.labelKey)).tag(q)
                        }
                    }

                    Toggle(isOn: $app.settings.normalize) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(I18n.t("Even Out Loudness"))
                            Text(I18n.t("Adjust each song's volume by what its plugin measured of it, for them to sound as loud as each other"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 3. 律动舞台与视觉实验（对应 Experiments / Stage）
                SwiftUI.Section(I18n.t("Experiments")) {
                    Picker(I18n.t("Stage Style"), selection: $app.settings.stageStyle) {
                        ForEach(StageStyle.allCases) { style in
                            Text(I18n.t(style.labelKey)).tag(style)
                        }
                    }

                    Toggle(I18n.t("Sparks"), isOn: $app.settings.stageSparks)
                    Toggle(isOn: $app.settings.fog) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(I18n.t("Fog Backdrop"))
                            Text(I18n.t("The album-colored fog drifts behind the Now Playing screen."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $app.settings.smoke) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(I18n.t("Smoke on the Progress Bar"))
                            Text(I18n.t("A glowing playhead trails smoke during playback; it pauses while seeking."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $app.settings.hotComments) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(I18n.t("Top Comments in Quiet Parts"))
                            Text(I18n.t("In intros, breaks and outros, a song's top comments show in place of the lyrics"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SwiftUI.Section(I18n.t("Effects Preview")) {
                    ZStack(alignment: .bottom) {
                        NowPlayingBackdropView(
                            imageURL: app.player.currentTrack?.album.imageUrl,
                            player: app.player,
                            fogEnabled: app.settings.fog,
                            preview: true
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            Text(app.player.currentTrack?.name ?? I18n.t("Now Playing"))
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text(app.player.currentTrack?.artistNames ?? I18n.t("Choose a song to preview its cover colors."))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                            GeometryReader { geometry in
                                let duration = max(app.player.duration, app.player.currentTrack?.durationSeconds ?? 0, 1)
                                let progress = min(max(app.player.position / duration, 0), 1)
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.25)).frame(height: 2)
                                    Capsule().fill(MyGoTheme.accent).frame(width: geometry.size.width * progress, height: 2)
                                    if app.settings.smoke {
                                        ProgressSmokeView(
                                            progress: CGFloat(progress),
                                            level: CGFloat(app.player.audioBands.first ?? 0.15)
                                        )
                                        .frame(height: 24)
                                        .offset(y: -11)
                                    }
                                }
                                .frame(height: geometry.size.height)
                            }
                            .frame(height: 3)
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                    }
                    .frame(height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .listRowInsets(EdgeInsets())
                }

                // 4. 插件管理（对应 Plugins）
                SwiftUI.Section {
                    // 内置本地文件源
                    PluginSourceRowView(
                        source: app.localSource,
                        isBuiltIn: true,
                        onRemove: nil
                    )

                    // 已安装的 JS/TS 插件列表
                    ForEach(app.pluginSources, id: \.manifest.id) { plugin in
                        PluginSourceRowView(
                            source: plugin,
                            isBuiltIn: false,
                            onRemove: {
                                app.removePlugin(id: plugin.manifest.id)
                            }
                        )
                    }

                    Button {
                        githubRepoInput = ""
                        app.installErrorMessage = nil
                        showInstallSheet = true
                    } label: {
                        Label(I18n.t("Install from GitHub"), systemImage: "plus.circle.fill")
                            .foregroundStyle(MyGoTheme.accent)
                    }
                } header: {
                    Text(I18n.t("Plugins"))
                } footer: {
                    Text(I18n.t("A repository with a plugin, as owner/repo or its address on GitHub"))
                }

                // 5. 本地音乐统计与重新扫描
                SwiftUI.Section(I18n.t("Local Files")) {
                    HStack {
                        Text(I18n.t("Songs"))
                        Spacer()
                        Text(I18n.songs(app.localSource.trackCount()))
                            .foregroundStyle(.secondary)
                    }
                    Button(I18n.t("Rescan")) {
                        app.localSource.rescan()
                        Task { await app.refreshActiveSource() }
                    }
                    .foregroundStyle(MyGoTheme.accent)
                }

                // 6. 歌曲缓存管理（对应 Song Cache）
                SwiftUI.Section(I18n.t("Song Cache")) {
                    Picker(I18n.t("Cache"), selection: $app.settings.cacheMB) {
                        Text(I18n.t("Off")).tag(0)
                        Text("1 GB").tag(1024)
                        Text("2 GB").tag(2048)
                        Text("5 GB").tag(5120)
                        Text("10 GB").tag(10240)
                    }

                    HStack {
                        Text(I18n.tf("%d MB used", Int(cacheUsedBytes / (1024 * 1024))))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(I18n.t("Clear the Cache"), role: .destructive) {
                            app.player.diskCache.clear()
                            cacheUsedBytes = app.player.diskCache.usedBytes()
                        }
                    }
                }
            }
            .navigationTitle(I18n.t("Settings"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear {
                cacheUsedBytes = app.player.diskCache.usedBytes()
            }
            .sheet(isPresented: $showInstallSheet) {
                installPluginSheet
            }
        }
    }

    private var installPluginSheet: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    TextField(I18n.t("owner/repo or URL"), text: $githubRepoInput)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif

                    if let err = app.installErrorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text(I18n.t("Install from GitHub"))
                } footer: {
                    Text("例如: egoist/mygo-music-youtube-music 或 AkinoKaede/mygo-music-netease-cloud-music")
                }

                SwiftUI.Section("推荐社区插件") {
                    ForEach([
                        ("egoist/mygo-music-youtube-music", "YouTube Music 官方插件"),
                        ("AkinoKaede/mygo-music-netease-cloud-music", "网易云音乐插件"),
                        ("xingkaixin/mygo-music-spotify", "Spotify 插件")
                    ], id: \.0) { repo, desc in
                        Button {
                            githubRepoInput = repo
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repo)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(desc)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(I18n.t("Install a Plugin"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(I18n.t("Cancel")) {
                        showInstallSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if app.isInstallingPlugin {
                        ProgressView()
                    } else {
                        Button(I18n.t("Install")) {
                            let repo = githubRepoInput
                            Task {
                                await app.installPluginFromGitHub(repoInput: repo)
                                if app.installErrorMessage == nil {
                                    showInstallSheet = false
                                }
                            }
                        }
                        .disabled(githubRepoInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }
}

private struct PluginSourceRowView: View {
    @EnvironmentObject private var app: AppModel
    let source: MusicSource
    let isBuiltIn: Bool
    let onRemove: (() -> Void)?

    var body: some View {
        let info = source.info()
        let enabled = app.isSourceEnabled(info.id)
        let signedAccount = app.accountsBySource[info.id]

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(info.name)
                            .font(.system(size: 15, weight: .semibold))
                        if isBuiltIn {
                            Text(I18n.t("Built-in"))
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        } else if let ver = info.version, !ver.isEmpty {
                            Text("v\(ver)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let jsPlugin = source as? JSPluginSource {
                        let nets = jsPlugin.manifest.permissions?.network ?? []
                        Text(nets.isEmpty ? I18n.t("Asks for no network") : I18n.tf("Can reach %s", nets.joined(separator: ", ")))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { enabled },
                    set: { app.setSourceEnabled(info.id, enabled: $0) }
                ))
                .labelsHidden()
                .tint(MyGoTheme.accent)
            }

            // 账号登录与状态管理（对应 internal/app/ui_account.go 中的 accountRow）
            if enabled && source.can("signIn") {
                HStack(spacing: 10) {
                    if let acc = signedAccount {
                        if let img = acc.imageUrl, !img.isEmpty {
                            ArtworkView(
                                urlString: img,
                                pixelSize: 120,
                                size: 30,
                                cornerRadius: 15,
                                systemIcon: "person.crop.circle.fill.badge.checkmark"
                            )
                        } else {
                            Image(systemName: "person.crop.circle.fill.badge.checkmark")
                                .font(.system(size: 22))
                                .foregroundStyle(MyGoTheme.accent)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(acc.name)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(I18n.tf("Signed in to %s", info.name))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if source.can("signOut") {
                            Button(I18n.t("Sign Out"), role: .destructive) {
                                Task { await app.signOut(ofSourceID: info.id) }
                            }
                            .font(.system(size: 12.5, weight: .semibold))
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.secondary)
                        Text(I18n.tf("Sign in to %s", info.name))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await app.signIn(toSourceID: info.id) }
                        } label: {
                            Text(I18n.t("Sign In"))
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(MyGoTheme.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            // 插件专属配置字段（对应 plugin.json 中的 settings）
            if enabled, let specs = info.settings, !specs.isEmpty {
                ForEach(specs) { spec in
                    PluginSettingFieldRow(source: source, spec: spec)
                }
            }

            if !isBuiltIn, let onRemove {
                HStack {
                    Spacer()
                    Button(role: .destructive, action: onRemove) {
                        Label(I18n.t("Remove"), systemImage: "trash")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PluginSettingFieldRow: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openURL) private var openURL
    let source: MusicSource
    let spec: PluginSettingSpec
    @State private var value: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(spec.label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let linkStr = spec.link, let url = URL(string: linkStr) {
                    Button(I18n.t("Help")) {
                        openURL(url)
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(MyGoTheme.accent)
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                TextField(spec.help ?? spec.label, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13.5))
                    .onSubmit {
                        saveValue()
                    }
                if value != source.setting(spec.key) {
                    Button(I18n.t("Save")) {
                        saveValue()
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MyGoTheme.accent)
                    .buttonStyle(.bordered)
                }
            }
        }
        .onAppear {
            value = source.setting(spec.key)
        }
    }

    private func saveValue() {
        try? source.setSetting(spec.key, value: value)
        Task { await app.refreshActiveSource() }
    }
}

// MARK: - 底部悬浮迷你播放条（对应 ui_player.go 中的 playerBar）

public struct MiniPlayerBarView: View {
    @EnvironmentObject private var app: AppModel

    public init() {}

    public var body: some View {
        if let track = app.player.currentTrack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ArtworkView(
                        urlString: track.album.imageUrl,
                        pixelSize: 160,
                        size: 44,
                        cornerRadius: 8
                    )
                    .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(track.name)
                                .font(.system(size: 14.5, weight: .semibold))
                                .lineLimit(1)
                            if let radio = app.player.radioName, !radio.isEmpty {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 11))
                                    .foregroundStyle(MyGoTheme.accent)
                            }
                        }
                        if let errMsg = app.player.errorMessage, !errMsg.isEmpty {
                            Text(errMsg)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        } else {
                            Text(track.artistNames)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    EqualizerBarsView(
                        bands: app.player.audioBands,
                        isPlaying: app.player.isPlaying
                    )

                    Button {
                        if app.player.errorMessage != nil {
                            app.player.retryCurrentTrack()
                        } else {
                            app.player.togglePlay()
                        }
                    } label: {
                        Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)

                    Button {
                        app.player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                // 迷你播放条底部的播放进度细线
                GeometryReader { geo in
                    let dur = max(app.player.duration, track.durationSeconds, 1)
                    let ratio = min(max(app.player.position / dur, 0), 1)
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                        Rectangle()
                            .fill(MyGoTheme.accent)
                            .frame(width: geo.size.width * ratio)
                    }
                    .overlay(alignment: .leading) {
                        if app.settings.smoke && app.player.isPlaying && !app.player.isLoading {
                            ProgressSmokeView(
                                progress: ratio,
                                level: CGFloat(app.player.audioBands.first ?? 0.15)
                            )
                            .frame(height: 22)
                            .offset(y: -9.75)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                }
                .frame(height: 2.5)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 4)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                app.isNowPlayingPresented = true
            }
        }
    }
}

// MARK: - 扫码与引导登录弹窗（对应 internal/app/ui_account.go 中的 openSignIn）

public struct SignInDialogSheetView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openURL) private var openURL

    private var targetSourceName: String {
        if let id = app.signInTargetSourceID, let src = app.source(forID: id) {
            return src.info().name
        }
        return app.activeSource.info().name
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer(minLength: 8)

                if let qrText = app.activeSignInPrompt?.qr, !qrText.isEmpty,
                   let qrImage = MyGoQRCodeGenerator.generate(from: qrText) {
                    VStack(spacing: 14) {
                        qrImage
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 210, height: 210)
                            .padding(16)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: .black.opacity(0.15), radius: 14, x: 0, y: 6)

                        if let url = URL(string: qrText),
                           let scheme = url.scheme?.lowercased(),
                           (scheme == "http" || scheme == "https") {
                            Button {
                                openURL(url)
                            } label: {
                                Label("在浏览器中打开登录链接", systemImage: "safari")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(MyGoTheme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else if app.isSigningIn {
                    ProgressView()
                        .controlSize(.large)
                        .padding(.vertical, 24)
                }

                if let promptText = app.activeSignInPrompt?.text, !promptText.isEmpty {
                    Text(promptText)
                        .font(.system(size: 15, weight: .medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                } else if app.isSigningIn {
                    Text(I18n.t("Finish signing in in your browser"))
                        .font(.system(size: 14.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                if let err = app.signInError, !err.isEmpty {
                    VStack(spacing: 12) {
                        Text(err)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        Button {
                            let targetID = app.signInTargetSourceID ?? app.activeSourceID
                            app.dismissSignInSheet()
                            Task { @MainActor in
                                await Task.yield()
                                await app.signIn(toSourceID: targetID)
                            }
                        } label: {
                            Label(I18n.t("Sign In"), systemImage: "arrow.clockwise")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(MyGoTheme.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()
            }
            .padding(20)
            .navigationTitle(I18n.tf("Sign in to %s", targetSourceName))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(I18n.t("Cancel")) {
                        app.dismissSignInSheet()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 内置无痕 WebView 登录窗口（对应 internal/app/websignin.go）

public struct WebSignInSheetView: View {
    @EnvironmentObject private var app: AppModel
    public let request: WebSignInRequest

    public var body: some View {
        NavigationStack {
            EphemeralSignInWebView(request: request) { cookieHeader in
                app.completeWebSignIn(cookieHeader: cookieHeader)
            }
            .navigationTitle(I18n.tf("Sign in to %s", request.pluginName ?? request.pluginId ?? "Plugin"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(I18n.t("Cancel")) {
                        app.cancelWebSignIn()
                    }
                }
            }
        }
    }
}

#if canImport(UIKit)
private struct EphemeralSignInWebView: UIViewRepresentable {
    let request: WebSignInRequest
    let onResolved: (String) -> Void

    func makeCoordinator() -> WebSignInCoordinator {
        WebSignInCoordinator(request: request, onResolved: onResolved)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView()
        context.coordinator.start()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: WebSignInCoordinator) {
        coordinator.stop()
    }
}
#elseif canImport(AppKit)
private struct EphemeralSignInWebView: NSViewRepresentable {
    let request: WebSignInRequest
    let onResolved: (String) -> Void

    func makeCoordinator() -> WebSignInCoordinator {
        WebSignInCoordinator(request: request, onResolved: onResolved)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView()
        context.coordinator.start()
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: WebSignInCoordinator) {
        coordinator.stop()
    }
}
#endif

@MainActor
private final class WebSignInCoordinator: NSObject {
    let request: WebSignInRequest
    let onResolved: (String) -> Void
    private var webView: WKWebView?
    private var pollTimer: Timer?
    private var finished = false

    init(request: WebSignInRequest, onResolved: @escaping (String) -> Void) {
        self.request = request
        self.onResolved = onResolved
    }

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: config)
        if let ua = request.userAgent, !ua.isEmpty {
            wv.customUserAgent = ua
        }
        self.webView = wv
        return wv
    }

    func start() {
        if let url = URL(string: request.url) {
            webView?.load(URLRequest(url: url))
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkCookies()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func checkCookies() {
        guard !finished, let wv = webView, let targetURL = URL(string: request.cookiesOf),
              let targetHost = targetURL.host?.lowercased() else { return }

        wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                let matching = cookies.filter { cookie in
                    let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return targetHost == domain || targetHost.hasSuffix("." + domain)
                }
                let byName = Dictionary(grouping: matching, by: \.name)
                for reqName in self.request.until {
                    let hasValid = byName[reqName]?.contains(where: { !$0.value.isEmpty }) ?? false
                    if !hasValid { return }
                }
                self.finished = true
                self.stop()
                let header = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                self.onResolved(header)
            }
        }
    }
}

// MARK: - iOS 应用根视图（对应 ui_main.go 中的 view）

public struct MainView: View {
    @EnvironmentObject private var app: AppModel
    @State private var selectedTab: Int = 0

    public init() {}

    private var preferredScheme: ColorScheme? {
        switch app.settings.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem {
                        Label(I18n.t("Home"), systemImage: "house.fill")
                    }
                    .tag(0)

                SearchView()
                    .tabItem {
                        Label(I18n.t("Search"), systemImage: "magnifyingglass")
                    }
                    .tag(1)

                LibraryView()
                    .tabItem {
                        Label(I18n.t("Library"), systemImage: "music.note.list")
                    }
                    .tag(2)

                SettingsView()
                    .tabItem {
                        Label(I18n.t("Settings"), systemImage: "gearshape.fill")
                    }
                    .tag(3)
            }
            .tint(MyGoTheme.accent)

            // 悬浮于底部标签栏上方的 Mini Player Bar
            MiniPlayerBarView()
                .padding(.bottom, 54)

            // 全局轻提示 Toast
            if let toast = app.toastMessage {
                Text(toast)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.82), in: Capsule())
                    .padding(.bottom, 118)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .preferredColorScheme(preferredScheme)
        #if os(iOS)
        // iOS 上全屏展示正在播放页（与原生音乐 App 一致）
        .fullScreenCover(isPresented: $app.isNowPlayingPresented) {
            NowPlayingView()
                .environmentObject(app)
        }
        #else
        .sheet(isPresented: $app.isNowPlayingPresented) {
            NowPlayingView()
                .environmentObject(app)
                .frame(minWidth: 420, minHeight: 640)
        }
        #endif
        .onAppear {
            // 调试用启动参数：直接打开正在播放页，便于在模拟器中截图检查布局
            if ProcessInfo.processInfo.arguments.contains("-MyGoOpenNowPlaying"), app.player.currentTrack != nil {
                app.activeNowPlayingPane = .lyrics
                app.isNowPlayingPresented = true
                if ProcessInfo.processInfo.arguments.contains("-MyGoAutoPlay") {
                    app.player.resume()
                }
                if let seekArg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-MyGoSeek:") }),
                   let secStr = seekArg.split(separator: ":").last,
                   let sec = Double(secStr) {
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        await MainActor.run {
                            app.player.seek(to: sec)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $app.isSignInSheetPresented) {
            SignInDialogSheetView()
                .environmentObject(app)
        }
        .sheet(item: $app.activeWebSignInRequest) { req in
            WebSignInSheetView(request: req)
                .environmentObject(app)
        }
        .onOpenURL { url in
            app.handleDeepLink(url)
        }
    }
}

// SettingsAndMainViews.swift
// 对应原项目 internal/app/ui_settings.go, ui_player.go, ui_main.go 的设置、迷你播放条与根容器视图

#if canImport(MyGoMusicCore)
import MyGoMusicCore
#endif
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers
import WebKit

// MARK: - 设置与插件管理页（对应 ui_settings.go / plugin_install.go）

public struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showInstallSheet = false
    @State private var showPluginImporter = false
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

                    Toggle(isOn: $app.settings.fade) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(I18n.t("Fade Between Songs"))
                            Text(I18n.t("Smoothly fade audio out and in when switching or pausing tracks"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $app.settings.lockScreenLyrics) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(I18n.t("Lock Screen Lyrics"))
                            Text(I18n.t("Show the active lyric line in the Lock Screen media title while playing"))
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

                    Toggle(isOn: $app.settings.growFromCover) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(I18n.t("Grow From the Cover"))
                            Text(I18n.t("Open Now Playing with a spring transition from the mini bar"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

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

                    Toggle(isOn: $app.settings.captions) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(I18n.t("Captions for Podcasts"))
                            Text(I18n.t("Automatically generate timed captions for local podcast episodes"))
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
                                    Capsule().fill(.white.opacity(0.22)).frame(height: 2.5)
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    .white.opacity(0.30),
                                                    .white.opacity(0.84),
                                                    .white.opacity(0.98)
                                                ],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: geometry.size.width * progress, height: 2.5)
                                    if app.settings.smoke {
                                        let previewSmokeHeight: CGFloat = 104
                                        ProgressSmokeView(
                                            progress: CGFloat(progress),
                                            level: CGFloat(app.player.audioBands.first ?? 0.25),
                                            horizontalInset: 0,
                                            scale: 0.78,
                                            useAdditiveBlend: true,
                                            tintColor: .white,
                                            isActive: true
                                        )
                                        .frame(height: previewSmokeHeight)
                                        .offset(y: -(previewSmokeHeight / 2 - ProgressSmokeView.anchorOffsetFromBottom(scale: 0.78)))
                                        .allowsHitTesting(false)
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
                        let pid = plugin.manifest.id
                        PluginSourceRowView(
                            source: plugin,
                            isBuiltIn: false,
                            pendingUpdateVersion: app.settings.pluginUpdates[pid],
                            origin: app.pluginOrigins[pid],
                            onUpdate: {
                                Task { await app.updatePlugin(id: pid) }
                            },
                            onRemove: {
                                app.removePlugin(id: pid)
                            }
                        )
                    }

                    // 加载失败诊断卡片（例如 minAppVersion 不满足或脚本语法错误）
                    if !app.pluginLoadFailures.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(I18n.t("Plugin Load Errors"))
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(.red)
                            ForEach(app.pluginLoadFailures) { failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failure.folderName)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(failure.reason)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Button {
                        githubRepoInput = ""
                        app.installErrorMessage = nil
                        showInstallSheet = true
                    } label: {
                        Label(I18n.t("Install from GitHub"), systemImage: "plus.circle.fill")
                            .foregroundStyle(MyGoTheme.accent)
                    }

                    Button {
                        showPluginImporter = true
                    } label: {
                        Label(I18n.t("Import Plugin (Folder / Zip)…"), systemImage: "folder.badge.plus")
                            .foregroundStyle(MyGoTheme.accent)
                    }

                    if !app.pluginOrigins.isEmpty {
                        Button {
                            Task { await app.checkForPluginUpdates(manual: true) }
                        } label: {
                            HStack(spacing: 8) {
                                if app.isCheckingUpdates {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(I18n.t("Checking for updates…"))
                                } else {
                                    Label(I18n.t("Check for Updates"), systemImage: "arrow.triangle.2.circlepath")
                                }
                            }
                            .foregroundStyle(MyGoTheme.accent)
                        }
                        .disabled(app.isCheckingUpdates)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(I18n.t("GitHub Token"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        SecureField(I18n.t("Optional token to avoid GitHub rate limits"), text: $app.settings.githubToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                    .padding(.vertical, 2)
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
            .mygoTrackVerticalScroll()
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
            .fileImporter(
                isPresented: $showPluginImporter,
                allowedContentTypes: [.folder, .zip],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task {
                        let secured = url.startAccessingSecurityScopedResource()
                        defer {
                            if secured { url.stopAccessingSecurityScopedResource() }
                        }
                        await app.importLocalPlugin(from: url)
                    }
                }
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
                    Text("例如: egoist/mygo-music-youtube-music 或 GentleM4dman/mygo-music-bilibili")
                }

                SwiftUI.Section("推荐社区插件") {
                    ForEach([
                        ("egoist/mygo-music-youtube-music", "YouTube Music 官方插件"),
                        ("GentleM4dman/mygo-music-bilibili", "哔哩哔哩音乐插件"),
                        ("AkinoKaede/mygo-music-netease-cloud-music", "网易云音乐插件"),
                        ("sogud/mygo-music-netease", "网易云音乐插件（社区分支）"),
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
    var pendingUpdateVersion: String? = nil
    var origin: PluginOrigin? = nil
    var onUpdate: (() -> Void)? = nil
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
                        if let pending = pendingUpdateVersion, !pending.isEmpty {
                            Text("→ v\(pending)")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MyGoTheme.accent, in: Capsule())
                        }
                    }
                    if let jsPlugin = source as? JSPluginSource {
                        let nets = jsPlugin.manifest.permissions?.network ?? []
                        Text(nets.isEmpty ? I18n.t("Asks for no network") : I18n.tf("Can reach %s", nets.joined(separator: ", ")))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        if let repo = origin?.repo, !repo.isEmpty {
                            Text(repo)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
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

            // 本地进程权限提示与一次性授权
            if let jsPlugin = source as? JSPluginSource, jsPlugin.hasProcessPermissionDeclaration {
                HStack(spacing: 8) {
                    if jsPlugin.isProcessGranted() {
                        Label(I18n.t("Process permission granted"), systemImage: "checkmark.shield")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    } else {
                        Label(I18n.t("Needs Process Permission"), systemImage: "exclamationmark.shield.fill")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button {
                            app.grantProcessPermission(for: info.id)
                        } label: {
                            Text(I18n.t("Grant Permission"))
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(MyGoTheme.accent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(MyGoTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.borderless)
                    }
                }
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
                            Button(role: .destructive) {
                                Task { await app.signOut(ofSourceID: info.id) }
                            } label: {
                                Text(I18n.t("Sign Out"))
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.borderless)
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

            if !isBuiltIn {
                HStack(spacing: 12) {
                    if let pending = pendingUpdateVersion, !pending.isEmpty, let onUpdate {
                        Button(action: onUpdate) {
                            Label(I18n.tf("Update to %s", "v\(pending)"), systemImage: "arrow.down.circle.fill")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(MyGoTheme.accent)
                        }
                        .buttonStyle(.borderless)
                        .disabled(app.isInstallingPlugin)
                    }
                    Spacer()
                    if let onRemove {
                        Button(role: .destructive, action: onRemove) {
                            Label(I18n.t("Remove"), systemImage: "trash")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                    }
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
    @State private var savedValue: String = ""

    private var fieldKind: String {
        (spec.type ?? "text").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if fieldKind == "boolean" {
                booleanRow
            } else {
                headerRow
                switch fieldKind {
                case "select":
                    selectInputRow
                case "password":
                    secretOrTextInputRow(isSecret: true)
                default:
                    secretOrTextInputRow(isSecret: false)
                }
            }
        }
        .onAppear {
            loadInitialValue()
        }
        .onChange(of: source.info().id) { _, _ in
            loadInitialValue()
        }
    }

    private var headerRow: some View {
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
    }

    private var booleanRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: Binding(
                get: { value.lowercased() == "true" || value == "1" },
                set: { newBool in
                    let str = newBool ? "true" : "false"
                    value = str
                    saveValue(str)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.label)
                        .font(.system(size: 13.5, weight: .medium))
                    if let help = spec.help, !help.isEmpty {
                        Text(help)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(MyGoTheme.accent)

            if let linkStr = spec.link, let url = URL(string: linkStr) {
                Button(I18n.t("Help")) {
                    openURL(url)
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MyGoTheme.accent)
                .buttonStyle(.plain)
            }
        }
    }

    private var selectInputRow: some View {
        let options = spec.options ?? []
        let hasUnknownValue = !value.isEmpty && !options.contains(where: { $0.value == value })
        return VStack(alignment: .leading, spacing: 3) {
            Picker(spec.label, selection: Binding(
                get: { value },
                set: { newVal in
                    value = newVal
                    saveValue(newVal)
                }
            )) {
                if options.isEmpty && value.isEmpty {
                    Text(I18n.t("Current value")).tag("")
                }
                if hasUnknownValue {
                    Text("\(I18n.t("Current value")): \(value)").tag(value)
                }
                ForEach(options, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if let help = spec.help, !help.isEmpty {
                Text(help)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func secretOrTextInputRow(isSecret: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if isSecret {
                    SecureField(spec.help ?? spec.label, text: $value)
                } else {
                    TextField(spec.help ?? spec.label, text: $value)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13.5))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit {
                MyGoKeyboard.dismiss()
                saveValue(value)
            }

            if value != savedValue {
                HStack(spacing: 8) {
                    Button {
                        MyGoKeyboard.dismiss()
                        saveValue(value)
                    } label: {
                        Text(I18n.t("Save changes"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(MyGoTheme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.borderless)

                    Button {
                        value = savedValue
                    } label: {
                        Text(I18n.t("Discard changes"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func loadInitialValue() {
        var current = source.setting(spec.key)
        if fieldKind == "select", current.isEmpty, let first = spec.options?.first {
            current = first.value
        }
        value = current
        savedValue = current
    }

    private func saveValue(_ newValue: String) {
        savedValue = newValue
        try? source.setSetting(spec.key, value: newValue)
        Task { await app.refreshActiveSource() }
    }
}

// MARK: - Liquid Glass 通透玻璃表面（对标 Apple Music iOS 26 悬浮胶囊光学质感）

private struct LiquidGlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let isHighlighted: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape
                        .fill(.ultraThinMaterial)
                    shape
                        .fill(tintOverlay)
                    shape
                        .fill(specularInnerSheen)
                }
            }
            .clipShape(shape)
            .overlay(
                shape
                    .strokeBorder(borderGradient, lineWidth: colorScheme == .dark ? 0.9 : 1.0)
            )
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.36 : 0.095),
                radius: 18,
                x: 0,
                y: 7
            )
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.16 : 0.04),
                radius: 3.5,
                x: 0,
                y: 1.5
            )
    }

    private var tintOverlay: Color {
        if colorScheme == .dark {
            return Color(white: 0.15).opacity(isHighlighted ? 0.32 : 0.24)
        }
        return Color.white.opacity(isHighlighted ? 0.36 : 0.22)
    }

    private var specularInnerSheen: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.14),
                    Color.white.opacity(0.015),
                    Color.clear,
                    Color.white.opacity(0.07)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [
                Color.white.opacity(0.48),
                Color.white.opacity(0.08),
                Color.clear,
                Color.white.opacity(0.26)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var borderGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.44),
                    Color.white.opacity(0.11),
                    Color.white.opacity(0.06),
                    Color.white.opacity(0.26)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [
                Color.white.opacity(0.95),
                Color.white.opacity(0.35),
                Color.white.opacity(0.20),
                Color.white.opacity(0.75)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private extension View {
    func mygoLiquidGlass<S: InsettableShape>(in shape: S, isHighlighted: Bool = false) -> some View {
        modifier(LiquidGlassSurfaceModifier(shape: shape, isHighlighted: isHighlighted))
    }
}

// MARK: - 底部悬浮迷你播放条（对应 ui_player.go 中的 playerBar，支持 iOS 26 随滚动嵌合形态）

public struct MiniPlayerBarView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var colorScheme

    public let isCompact: Bool

    public init(isCompact: Bool = false) {
        self.isCompact = isCompact
    }

    public var body: some View {
        if let track = app.player.currentTrack {
            let capsuleShape = Capsule(style: .continuous)
            let barHeight = isCompact
                ? FloatingTabBarMetrics.compactBarHeight
                : FloatingTabBarMetrics.miniExpandedHeight
            let artworkSize: CGFloat = isCompact ? 32 : 36
            let artworkRadius: CGFloat = isCompact ? 7 : 8

            ZStack(alignment: .bottom) {
                HStack(spacing: isCompact ? 9 : 11) {
                    ArtworkView(
                        urlString: track.album.imageUrl,
                        pixelSize: 160,
                        size: artworkSize,
                        cornerRadius: artworkRadius
                    )
                    .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 1.5)

                    VStack(alignment: .leading, spacing: isCompact ? 1 : 2) {
                        HStack(spacing: 5) {
                            Text(track.name)
                                .font(.system(size: isCompact ? 13.5 : 14.5, weight: .semibold))
                                .lineLimit(1)
                            if !isCompact, let radio = app.player.radioName, !radio.isEmpty {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 11))
                                    .foregroundStyle(MyGoTheme.accent)
                            }
                        }
                        if let errMsg = app.player.errorMessage, !errMsg.isEmpty {
                            Text(errMsg)
                                .font(.system(size: isCompact ? 10.5 : 11.5, weight: .medium))
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        } else {
                            Text(track.artistNames)
                                .font(.system(size: isCompact ? 11 : 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !isCompact {
                        EqualizerBarsView(
                            bands: app.player.audioBands,
                            isPlaying: app.player.isPlaying
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.72)))
                    }

                    Button {
                        if app.player.errorMessage != nil {
                            app.player.retryCurrentTrack()
                        } else {
                            app.player.togglePlay()
                        }
                    } label: {
                        Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: isCompact ? 17.5 : 19.5, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: isCompact ? 32 : 34, height: isCompact ? 32 : 34)
                    }
                    .buttonStyle(.plain)

                    if !isCompact {
                        Button {
                            app.player.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .scale(scale: 0.72)))
                    }
                }
                .padding(.leading, isCompact ? 10 : 12)
                .padding(.trailing, isCompact ? 10 : 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 贴合胶囊底缘平直区域的轻柔进度细线与白色拖尾烟雾
                miniProgressStrip(for: track)
                    .padding(.horizontal, isCompact ? 24 : 26)
                    .padding(.bottom, 1.5)
            }
            .frame(height: barHeight)
            .mygoLiquidGlass(in: capsuleShape)
            .contentShape(capsuleShape)
            .onTapGesture {
                if app.settings.growFromCover {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                        app.isNowPlayingPresented = true
                    }
                } else {
                    app.isNowPlayingPresented = true
                }
            }
        }
    }

    @ViewBuilder
    private func miniProgressStrip(for track: Track) -> some View {
        GeometryReader { geo in
            let dur = max(app.player.duration, track.durationSeconds, 1)
            let livePos = app.player.isPlaying ? app.player.livePlaybackPosition() : app.player.position
            let ratio = min(max(livePos / dur, 0), 1)
            let rhythm = app.player.sampleAudioRhythm(at: livePos, lines: app.player.lyrics, isScrubbing: false)
            let miniLevel = CGFloat(min(1.0, max(0.15, rhythm.bass * 0.7 + rhythm.beatPulse * 0.4)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(isCompact ? 0.045 : 0.06))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [.white.opacity(0.28), .white.opacity(isCompact ? 0.65 : 0.85)]
                                : [Color.primary.opacity(0.18), Color.primary.opacity(isCompact ? 0.36 : 0.46)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * ratio)
            }
            .overlay(alignment: .leading) {
                if !isCompact && app.settings.smoke && app.player.isPlaying && !app.player.isLoading {
                    let miniSmokeHeight: CGFloat = 74
                    ProgressSmokeView(
                        progress: ratio,
                        level: miniLevel,
                        horizontalInset: 0,
                        scale: 0.52,
                        useAdditiveBlend: colorScheme == .dark,
                        tintColor: .white,
                        isActive: true,
                        lightSurfaceMode: colorScheme == .light
                    )
                    .frame(height: miniSmokeHeight)
                    .mask {
                        HStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 14)
                            Rectangle().fill(.black)
                        }
                    }
                    .offset(y: -(miniSmokeHeight / 2 - ProgressSmokeView.anchorOffsetFromBottom(scale: 0.52)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(height: isCompact ? 1.5 : 2)
        .allowsHitTesting(false)
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
    @State private var reloadTrigger = 0

    public var body: some View {
        NavigationStack {
            EphemeralSignInWebView(request: request, reloadTrigger: reloadTrigger) { cookieHeader in
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        reloadTrigger += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(I18n.t("Reload Page"))
                }
            }
        }
    }
}

#if canImport(UIKit)
private struct EphemeralSignInWebView: UIViewRepresentable {
    let request: WebSignInRequest
    let reloadTrigger: Int
    let onResolved: (String) -> Void

    func makeCoordinator() -> WebSignInCoordinator {
        WebSignInCoordinator(request: request, onResolved: onResolved)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView()
        context.coordinator.lastReloadTrigger = reloadTrigger
        context.coordinator.start()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastReloadTrigger != reloadTrigger {
            context.coordinator.lastReloadTrigger = reloadTrigger
            uiView.reload()
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: WebSignInCoordinator) {
        coordinator.stop()
    }
}
#elseif canImport(AppKit)
private struct EphemeralSignInWebView: NSViewRepresentable {
    let request: WebSignInRequest
    let reloadTrigger: Int
    let onResolved: (String) -> Void

    func makeCoordinator() -> WebSignInCoordinator {
        WebSignInCoordinator(request: request, onResolved: onResolved)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView()
        context.coordinator.lastReloadTrigger = reloadTrigger
        context.coordinator.start()
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.lastReloadTrigger != reloadTrigger {
            context.coordinator.lastReloadTrigger = reloadTrigger
            nsView.reload()
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: WebSignInCoordinator) {
        coordinator.stop()
    }
}
#endif

@MainActor
private final class WebSignInCoordinator: NSObject, WKUIDelegate {
    let request: WebSignInRequest
    let onResolved: (String) -> Void
    var lastReloadTrigger = 0
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
        wv.uiDelegate = self
        if let ua = request.userAgent, !ua.isEmpty {
            wv.customUserAgent = ua
        }
        self.webView = wv
        return wv
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // 第三方 OAuth 登录常以 target="_blank" 弹窗跳转，在当前内置无痕 WebView 直接接管加载
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
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
                    return !domain.isEmpty && (targetHost == domain || targetHost.hasSuffix("." + domain))
                }
                // 按 Cookie 名称去重，优先保留非空值及域名更精确的匹配项
                var resolved: [String: HTTPCookie] = [:]
                for cookie in matching where !cookie.value.isEmpty {
                    if let prev = resolved[cookie.name] {
                        if cookie.domain.count >= prev.domain.count {
                            resolved[cookie.name] = cookie
                        }
                    } else {
                        resolved[cookie.name] = cookie
                    }
                }
                for reqName in self.request.until {
                    if resolved[reqName] == nil { return }
                }
                self.finished = true
                self.stop()
                let ordered = resolved.values.sorted { $0.name < $1.name }
                let header = ordered.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                self.onResolved(header)
            }
        }
    }
}

// MARK: - 悬浮胶囊底部导航栏（对标 Apple Music iOS 26 分体胶囊 + 随滚动嵌入融合动效）

/// 全局搜索框主动聚焦广播通知
public extension Notification.Name {
    static let mygoFocusSearchField = Notification.Name("MyGoFocusSearchField")
}

/// 遵循 Apple iOS HIG 与 Apple Music iOS 26 悬浮胶囊规范的底部导航栏尺寸常量
public enum FloatingTabBarMetrics {
    public static let barHeight: CGFloat = 66
    public static let outerInset: CGFloat = 5
    public static let activePillHeight: CGFloat = barHeight - outerInset * 2
    public static let itemSpacing: CGFloat = 4
    public static let horizontalPadding: CGFloat = 16
    public static let maxWidth: CGFloat = 428
    public static let iconSize: CGFloat = 21.5
    public static let iconFrameHeight: CGFloat = 24
    public static let iconLabelSpacing: CGFloat = 3
    public static let labelFontSize: CGFloat = 10.5
    public static let overlaySpacing: CGFloat = 10
    public static let miniExpandedHeight: CGFloat = 56
    public static let compactBarHeight: CGFloat = 52
    public static let searchCircleSize: CGFloat = barHeight
    public static let splitSpacing: CGFloat = 10
    public static let compactSplitSpacing: CGFloat = 8
    public static let bottomInsetEmptyPlayer: CGFloat = 88
    public static let bottomInsetWithMiniPlayer: CGFloat = 160
}

/// 底部导航主浏览页签与独立搜索圆钮之间的槽位映射模型
public enum MainTabMapping {
    public static let searchTabID: Int = 1
    public static let primaryTabIDs: [Int] = [0, 2, 3]

    /// 将全局 Tab ID（0 首页 / 2 音乐库 / 3 设置）映射到左侧主胶囊槽位索引
    public static func slotIndex(for tabID: Int) -> Int? {
        primaryTabIDs.firstIndex(of: tabID)
    }

    /// 将左侧主胶囊槽位索引还原为全局 Tab ID
    public static func tabID(forSlotIndex slot: Int) -> Int {
        guard !primaryTabIDs.isEmpty else { return 0 }
        let clamped = min(max(0, slot), primaryTabIDs.count - 1)
        return primaryTabIDs[clamped]
    }

    /// 计算收起至左下角圆形按钮时应当展示的代表性主页签 ID
    public static func effectivePrimaryTab(selectedTab: Int, lastPrimaryTab: Int) -> Int {
        if slotIndex(for: selectedTab) != nil {
            return selectedTab
        }
        return slotIndex(for: lastPrimaryTab) != nil ? lastPrimaryTab : (primaryTabIDs.first ?? 0)
    }
}

/// 垂直滚动触发底部导航栏折叠/展开状态机（含顶部滞留、方向防抖与触底橡皮筋回弹保护）
public enum FloatingTabBarMinimizeMath {
    public static let topAlwaysExpandedOffset: CGFloat = 14
    public static let minScrollableSpanForCollapse: CGFloat = 60
    public static let collapseDeltaThreshold: CGFloat = 20
    public static let expandDeltaThreshold: CGFloat = 16
    public static let bottomBounceTolerance: CGFloat = 3

    public struct StepResult: Equatable, Sendable {
        public let isMinimized: Bool
        public let accumulatedDelta: CGFloat

        public init(isMinimized: Bool, accumulatedDelta: CGFloat) {
            self.isMinimized = isMinimized
            self.accumulatedDelta = accumulatedDelta
        }
    }

    /// 根据当前垂直偏移与手指交互步进，计算下一时刻导航栏是否收起以及累积偏移量
    public static func evaluateScrollStep(
        currentlyMinimized: Bool,
        accumulatedDelta: CGFloat,
        normalizedOffsetY: CGFloat,
        deltaY: CGFloat,
        maxScrollOffset: CGFloat,
        isUserInteracting: Bool
    ) -> StepResult {
        guard maxScrollOffset >= minScrollableSpanForCollapse,
              normalizedOffsetY > topAlwaysExpandedOffset else {
            return StepResult(isMinimized: false, accumulatedDelta: 0)
        }
        guard isUserInteracting else {
            return StepResult(isMinimized: currentlyMinimized, accumulatedDelta: accumulatedDelta)
        }
        let isBottomRubberBanding = normalizedOffsetY >= (maxScrollOffset - bottomBounceTolerance) && deltaY < 0
        if isBottomRubberBanding {
            return StepResult(isMinimized: currentlyMinimized, accumulatedDelta: 0)
        }
        guard abs(deltaY) > 0.25 else {
            return StepResult(isMinimized: currentlyMinimized, accumulatedDelta: accumulatedDelta)
        }

        let nextAccum: CGFloat
        if (accumulatedDelta > 0 && deltaY < 0) || (accumulatedDelta < 0 && deltaY > 0) {
            nextAccum = deltaY
        } else {
            nextAccum = accumulatedDelta + deltaY
        }

        if !currentlyMinimized && nextAccum >= collapseDeltaThreshold {
            return StepResult(isMinimized: true, accumulatedDelta: 0)
        }
        if currentlyMinimized && nextAccum <= -expandDeltaThreshold {
            return StepResult(isMinimized: false, accumulatedDelta: 0)
        }
        return StepResult(isMinimized: currentlyMinimized, accumulatedDelta: nextAccum)
    }
}

/// 垂直滚动偏移采样载荷
public struct VerticalScrollMetrics: Sendable {
    public let normalizedOffsetY: CGFloat
    public let deltaY: CGFloat
    public let maxScrollOffset: CGFloat
    public let isUserInteracting: Bool

    public init(
        normalizedOffsetY: CGFloat,
        deltaY: CGFloat,
        maxScrollOffset: CGFloat,
        isUserInteracting: Bool
    ) {
        self.normalizedOffsetY = normalizedOffsetY
        self.deltaY = deltaY
        self.maxScrollOffset = maxScrollOffset
        self.isUserInteracting = isUserInteracting
    }
}

private struct VerticalScrollReportKey: EnvironmentKey {
    static let defaultValue: @MainActor (VerticalScrollMetrics) -> Void = { _ in }
}

private struct VerticalScrollResetKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

public extension EnvironmentValues {
    var mygoReportVerticalScroll: @MainActor (VerticalScrollMetrics) -> Void {
        get { self[VerticalScrollReportKey.self] }
        set { self[VerticalScrollReportKey.self] = newValue }
    }

    var mygoResetScrollTracker: @MainActor () -> Void {
        get { self[VerticalScrollResetKey.self] }
        set { self[VerticalScrollResetKey.self] = newValue }
    }
}

@MainActor
private final class TabBarScrollCoordinator: ObservableObject {
    @Published var isMinimized: Bool = false
    private var accumulatedDelta: CGFloat = 0

    func handleScroll(_ metrics: VerticalScrollMetrics) {
        // 过滤瞬间尺寸重构造成的大跨度跳变
        guard abs(metrics.deltaY) < 220 else {
            if metrics.normalizedOffsetY <= FloatingTabBarMinimizeMath.topAlwaysExpandedOffset {
                setMinimized(false)
            }
            accumulatedDelta = 0
            return
        }
        let step = FloatingTabBarMinimizeMath.evaluateScrollStep(
            currentlyMinimized: isMinimized,
            accumulatedDelta: accumulatedDelta,
            normalizedOffsetY: metrics.normalizedOffsetY,
            deltaY: metrics.deltaY,
            maxScrollOffset: metrics.maxScrollOffset,
            isUserInteracting: metrics.isUserInteracting
        )
        accumulatedDelta = step.accumulatedDelta
        setMinimized(step.isMinimized)
    }

    func expand() {
        accumulatedDelta = 0
        setMinimized(false)
    }

    func resetAccumulatorAndExpand() {
        accumulatedDelta = 0
        setMinimized(false)
    }

    private func setMinimized(_ minimized: Bool) {
        guard isMinimized != minimized else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
            isMinimized = minimized
        }
    }
}

#if canImport(UIKit)
private struct VerticalScrollProbeRepresentable: UIViewRepresentable {
    let onScroll: @MainActor (VerticalScrollMetrics) -> Void

    func makeUIView(context: Context) -> VerticalScrollProbeUIView {
        let view = VerticalScrollProbeUIView()
        view.onScroll = onScroll
        return view
    }

    func updateUIView(_ uiView: VerticalScrollProbeUIView, context: Context) {
        uiView.onScroll = onScroll
        uiView.scheduleAttachIfNeeded()
    }
}

private final class VerticalScrollProbeUIView: UIView {
    var onScroll: (@MainActor (VerticalScrollMetrics) -> Void)?
    private weak var observedScrollView: UIScrollView?
    private var contentOffsetObservation: NSKeyValueObservation?
    private var retryGeneration: Int = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        contentOffsetObservation?.invalidate()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            detach()
        } else {
            scheduleAttachIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleAttachIfNeeded()
    }

    func scheduleAttachIfNeeded() {
        guard observedScrollView == nil, window != nil else { return }
        attachNow()
        guard observedScrollView == nil else { return }

        retryGeneration += 1
        let gen = retryGeneration
        for delay in [0.05, 0.20, 0.50, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.retryGeneration == gen,
                      self.observedScrollView == nil,
                      self.window != nil else { return }
                self.attachNow()
            }
        }
    }

    private func detach() {
        retryGeneration += 1
        contentOffsetObservation?.invalidate()
        contentOffsetObservation = nil
        observedScrollView = nil
    }

    private func attachNow() {
        guard observedScrollView == nil, let sv = findTargetVerticalScrollView() else { return }
        observedScrollView = sv
        contentOffsetObservation = sv.observe(\.contentOffset, options: [.new, .old]) { [weak self] scrollView, change in
            guard let self,
                  self.window != nil,
                  scrollView.window != nil,
                  self.isViewVisibleInHierarchy(self),
                  scrollView.bounds.height > 0 else { return }

            let oldY = change.oldValue?.y ?? scrollView.contentOffset.y
            let newY = change.newValue?.y ?? scrollView.contentOffset.y
            let delta = newY - oldY
            let insetTop = scrollView.adjustedContentInset.top
            let insetBottom = scrollView.adjustedContentInset.bottom
            let normalizedY = newY + insetTop
            let maxOffset = max(0, scrollView.contentSize.height + insetTop + insetBottom - scrollView.bounds.height)
            let isInteracting = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
            let metrics = VerticalScrollMetrics(
                normalizedOffsetY: normalizedY,
                deltaY: delta,
                maxScrollOffset: maxOffset,
                isUserInteracting: isInteracting
            )
            DispatchQueue.main.async { [weak self] in
                self?.onScroll?(metrics)
            }
        }
    }

    private func isViewVisibleInHierarchy(_ target: UIView) -> Bool {
        var current: UIView? = target
        while let v = current {
            if v.isHidden || v.alpha < 0.05 {
                return false
            }
            if v is UIWindow {
                break
            }
            current = v.superview
        }
        return true
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let vc = next as? UIViewController {
                return vc
            }
            responder = next
        }
        return nil
    }

    private func findTargetVerticalScrollView() -> UIScrollView? {
        // 1. 优先沿父视图链上溯查找自身直接嵌套于其中的纵向 ScrollView
        var ancestor = superview
        while let current = ancestor {
            if let sv = current as? UIScrollView, isPrimaryVerticalScrollView(sv) {
                return sv
            }
            ancestor = current.superview
        }

        // 2. 在当前页面级 ViewController 子树中做广度优先与坐标重合匹配（仅忽略明显隐身分支）
        let probeFrame = convert(bounds, to: window)
        if let vc = nearestViewController(),
           !(vc.parent == nil && vc.presentingViewController == nil && type(of: vc).description().contains("UIHostingController")),
           let vcRoot = vc.view,
           let match = bestVerticalScrollView(in: vcRoot, matchingFrameInWindow: probeFrame, requireVisible: false) {
            return match
        }

        // 3. 当退回到跨 Tab 共享的根托管视图控制器时，严格过滤隐藏 Tab 分支后按区域重叠寻找主纵向滚动视图
        var searchRoot: UIView? = superview
        for _ in 0..<8 {
            guard let root = searchRoot else { break }
            if let match = bestVerticalScrollView(in: root, matchingFrameInWindow: probeFrame, requireVisible: true) {
                return match
            }
            if root === window { break }
            searchRoot = root.superview
        }
        return nil
    }

    private func bestVerticalScrollView(
        in root: UIView,
        matchingFrameInWindow probeFrame: CGRect,
        requireVisible: Bool
    ) -> UIScrollView? {
        if requireVisible && (root.isHidden || root.alpha < 0.05) {
            return nil
        }
        var queue: [UIView] = [root]
        var index = 0
        var bestMatch: UIScrollView?
        var bestScore: CGFloat = -1

        while index < queue.count {
            let current = queue[index]
            index += 1
            if requireVisible && (current.isHidden || current.alpha < 0.05) {
                continue
            }
            if let sv = current as? UIScrollView,
               isPrimaryVerticalScrollView(sv),
               (!requireVisible || isViewVisibleInHierarchy(sv)) {
                let svFrame = sv.convert(sv.bounds, to: window)
                if probeFrame.isEmpty || probeFrame.width < 4 || probeFrame.height < 4 {
                    return sv
                }
                let overlap = svFrame.intersection(probeFrame)
                if !overlap.isNull && overlap.width > 10 && overlap.height > 10 {
                    let area = overlap.width * overlap.height
                    if area > bestScore {
                        bestScore = area
                        bestMatch = sv
                    }
                }
            }
            queue.append(contentsOf: current.subviews)
        }
        return bestMatch
    }

    private func isPrimaryVerticalScrollView(_ sv: UIScrollView) -> Bool {
        if sv.alwaysBounceHorizontal && !sv.alwaysBounceVertical {
            return false
        }
        if sv.contentSize.width > sv.bounds.width + 8 && sv.contentSize.height <= sv.bounds.height + 2 {
            return false
        }
        return sv.bounds.height >= 160
    }
}
#endif

private struct VerticalScrollTrackingModifier: ViewModifier {
    @Environment(\.mygoReportVerticalScroll) private var reportVerticalScroll
    @Environment(\.mygoResetScrollTracker) private var resetScrollTracker

    func body(content: Content) -> some View {
        content
            #if canImport(UIKit)
            .background(
                VerticalScrollProbeRepresentable { metrics in
                    reportVerticalScroll(metrics)
                }
                .allowsHitTesting(false)
            )
            #endif
            .onAppear {
                resetScrollTracker()
            }
    }
}

public extension View {
    /// 追踪当前页面主纵向滚动视图的上下滑动方向，驱动底部胶囊与迷你播放条自动融合/展开
    func mygoTrackVerticalScroll() -> some View {
        modifier(VerticalScrollTrackingModifier())
    }
}

/// 悬浮胶囊导航栏滑块几何与手势切换计算模型
public enum FloatingTabBarSliderMath {
    /// 计算单个标签槽位宽度
    public static func slotWidth(barWidth: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return max(1, barWidth) }
        let innerWidth = max(0, barWidth - FloatingTabBarMetrics.outerInset * 2)
        let totalSpacing = FloatingTabBarMetrics.itemSpacing * CGFloat(max(0, count - 1))
        return max(1, (innerWidth - totalSpacing) / CGFloat(count))
    }

    /// 计算第 index 个标签槽位的水平中心 X 坐标
    public static func slotCenterX(index: Int, barWidth: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return barWidth * 0.5 }
        let clampedIndex = min(max(0, index), count - 1)
        let width = slotWidth(barWidth: barWidth, count: count)
        return FloatingTabBarMetrics.outerInset
            + width * 0.5
            + CGFloat(clampedIndex) * (width + FloatingTabBarMetrics.itemSpacing)
    }

    /// 对超出首尾槽位中心范围的拖拽坐标施加 Apple 橡皮筋阻尼
    public static func clampedPillCenterX(rawX: CGFloat, barWidth: CGFloat, count: Int) -> CGFloat {
        guard count > 1 else {
            return slotCenterX(index: 0, barWidth: barWidth, count: count)
        }
        let minX = slotCenterX(index: 0, barWidth: barWidth, count: count)
        let maxX = slotCenterX(index: count - 1, barWidth: barWidth, count: count)
        let limit = FloatingTabBarMetrics.outerInset * 0.7
        if rawX < minX {
            let delta = minX - rawX
            return minX - limit * (delta / (delta + limit * 2.5))
        }
        if rawX > maxX {
            let delta = rawX - maxX
            return maxX + limit * (delta / (delta + limit * 2.5))
        }
        return rawX
    }

    /// 将水平坐标映射到最近的标签槽位索引
    public static func tabIndex(forX x: CGFloat, barWidth: CGFloat, count: Int) -> Int {
        guard count > 1 else { return 0 }
        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for idx in 0..<count {
            let dist = abs(x - slotCenterX(index: idx, barWidth: barWidth, count: count))
            if dist < bestDistance {
                bestDistance = dist
                bestIndex = idx
            }
        }
        return bestIndex
    }

    /// 结合拖放落点与快速轻扫速度，解析松手后的最终目标标签
    public static func resolvedTargetTab(
        selectedTab: Int,
        pillCenterX: CGFloat,
        translationWidth: CGFloat,
        predictedEndTranslationWidth: CGFloat,
        barWidth: CGFloat,
        count: Int
    ) -> Int {
        guard count > 1 else { return 0 }
        let directTarget = tabIndex(forX: pillCenterX, barWidth: barWidth, count: count)
        if directTarget != selectedTab {
            return directTarget
        }
        let slotW = slotWidth(barWidth: barWidth, count: count)
        let extraMomentum = predictedEndTranslationWidth - translationWidth
        let isQuickFlick = abs(extraMomentum) > 30 || abs(predictedEndTranslationWidth) > slotW * 0.55
        if isQuickFlick && abs(translationWidth) >= 8 {
            let step = translationWidth > 0 ? 1 : -1
            return min(max(0, selectedTab + step), count - 1)
        }
        return directTarget
    }
}

private struct MainTabItem: Identifiable {
    let id: Int
    let titleKey: String
    let icon: String
    let selectedIcon: String
}

private struct PrimaryTabsCapsuleBar: View {
    @Binding var selectedTab: Int
    let lastPrimaryTab: Int
    let isCompactHeight: Bool
    let isCollapsedToCircle: Bool
    let targetWidth: CGFloat
    let targetHeight: CGFloat
    let onSelect: (Int) -> Void
    let onExpandFromCircle: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var barWidth: CGFloat = 0
    @State private var pillCenterX: CGFloat? = nil
    @State private var hoveredSlot: Int? = nil
    @State private var pressedSlot: Int? = nil
    @State private var isDraggingPill: Bool = false
    @State private var grabOffset: CGFloat = 0
    @State private var didLockStartState: Bool = false
    @State private var cancelledGesture: Bool = false
    @State private var hapticCount: Int = 0
    @State private var lastHapticSlot: Int? = nil

    private let items: [MainTabItem] = [
        MainTabItem(id: 0, titleKey: "Home", icon: "house", selectedIcon: "house.fill"),
        MainTabItem(id: 2, titleKey: "Library", icon: "music.note.list", selectedIcon: "music.note.list"),
        MainTabItem(id: 3, titleKey: "Settings", icon: "gearshape", selectedIcon: "gearshape.fill")
    ]

    var body: some View {
        let effectivePrimaryID = MainTabMapping.effectivePrimaryTab(
            selectedTab: selectedTab,
            lastPrimaryTab: lastPrimaryTab
        )
        let selectedSlot = MainTabMapping.slotIndex(for: selectedTab)
        let effectiveSlot = MainTabMapping.slotIndex(for: effectivePrimaryID) ?? 0
        let activeHighlightSlot: Int? = isDraggingPill ? (hoveredSlot ?? selectedSlot) : selectedSlot

        let activeBarWidth = barWidth > 0 ? barWidth : targetWidth
        let pillWidth = FloatingTabBarSliderMath.slotWidth(barWidth: activeBarWidth, count: items.count)
        let restCenterX = FloatingTabBarSliderMath.slotCenterX(
            index: selectedSlot ?? effectiveSlot,
            barWidth: activeBarWidth,
            count: items.count
        )
        let displayCenterX = (isDraggingPill ? pillCenterX : nil) ?? restCenterX
        let showActivePill = !isCollapsedToCircle && (selectedSlot != nil || isDraggingPill)
        let innerHeight = max(36, targetHeight - FloatingTabBarMetrics.outerInset * 2)

        ZStack {
            if !isCollapsedToCircle && activeBarWidth > 40 {
                activeIndicatorPill(width: pillWidth, height: innerHeight)
                    .position(x: displayCenterX, y: targetHeight * 0.5)
                    .opacity(showActivePill ? 1 : 0)
                    .scaleEffect(showActivePill ? 1 : 0.85)
                    .allowsHitTesting(false)
            }

            HStack(spacing: isCollapsedToCircle ? 0 : FloatingTabBarMetrics.itemSpacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { slotIndex, item in
                    let shouldShowItem = !isCollapsedToCircle || item.id == effectivePrimaryID
                    if shouldShowItem {
                        let isSelected = (activeHighlightSlot == slotIndex)
                        let isPrimaryInCircle = isCollapsedToCircle && (selectedTab == item.id)
                        let isHighlight = isCollapsedToCircle ? isPrimaryInCircle : isSelected
                        let isPressingInactive = (!isCollapsedToCircle && !isDraggingPill && pressedSlot == slotIndex && selectedSlot != slotIndex)

                        VStack(spacing: isCollapsedToCircle || isCompactHeight ? 0 : FloatingTabBarMetrics.iconLabelSpacing) {
                            Image(systemName: isHighlight ? item.selectedIcon : item.icon)
                                .font(.system(
                                    size: isCollapsedToCircle || isCompactHeight ? 20 : FloatingTabBarMetrics.iconSize,
                                    weight: isHighlight ? .semibold : .medium
                                ))
                                .frame(height: FloatingTabBarMetrics.iconFrameHeight)
                                .scaleEffect(
                                    isHighlight
                                        ? (isDraggingPill ? 1.07 : 1.03)
                                        : (isPressingInactive ? 0.94 : 1.0)
                                )

                            if !isCollapsedToCircle && !isCompactHeight {
                                Text(I18n.t(item.titleKey))
                                    .font(.system(
                                        size: FloatingTabBarMetrics.labelFontSize,
                                        weight: isHighlight ? .semibold : .medium
                                    ))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
                            }
                        }
                        .foregroundStyle(foregroundColor(isSelected: isHighlight))
                        .opacity(isPressingInactive ? 0.72 : 1.0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Capsule(style: .continuous))
                        .transition(.opacity.combined(with: .scale(scale: 0.5)))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(I18n.t(item.titleKey))
                        .accessibilityAddTraits(isHighlight ? [.isButton, .isSelected] : [.isButton])
                        .accessibilityAction {
                            if isCollapsedToCircle {
                                onExpandFromCircle()
                            } else {
                                onSelect(item.id)
                            }
                        }
                    }
                }
            }
            .padding(isCollapsedToCircle ? 0 : FloatingTabBarMetrics.outerInset)
        }
        .frame(width: targetWidth, height: targetHeight)
        .mygoLiquidGlass(in: Capsule(style: .continuous), isHighlighted: isCollapsedToCircle && selectedSlot != nil)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        barWidth = proxy.size.width
                    }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        barWidth = newWidth
                    }
            }
        }
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            guard isCollapsedToCircle else { return }
            hapticCount += 1
            onExpandFromCircle()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard !isCollapsedToCircle else { return }
                    handleDragChanged(value, selectedSlot: selectedSlot, activeBarWidth: activeBarWidth)
                }
                .onEnded { value in
                    guard !isCollapsedToCircle else {
                        resetDragTransientState()
                        return
                    }
                    handleDragEnded(value, selectedSlot: selectedSlot, activeBarWidth: activeBarWidth)
                }
        )
        .onChange(of: isCollapsedToCircle) { _, collapsed in
            if collapsed {
                resetDragTransientState()
            }
        }
        .sensoryFeedback(.selection, trigger: hapticCount)
    }

    private func activeIndicatorPill(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(isDraggingPill ? draggingPillColor : activePillColor)
            Capsule(style: .continuous)
                .strokeBorder(activePillBorderGradient, lineWidth: isDraggingPill ? 0.9 : 0.65)
        }
        .frame(width: max(40, width), height: height)
        .scaleEffect(x: isDraggingPill ? 1.07 : 1.0, y: isDraggingPill ? 1.11 : 1.0)
        .shadow(
            color: .black.opacity(isDraggingPill ? (colorScheme == .dark ? 0.28 : 0.09) : 0),
            radius: isDraggingPill ? 10 : 0,
            x: 0,
            y: isDraggingPill ? 3 : 0
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isDraggingPill)
    }

    private func resetDragTransientState() {
        didLockStartState = false
        cancelledGesture = false
        pressedSlot = nil
        lastHapticSlot = nil
        isDraggingPill = false
        pillCenterX = nil
        hoveredSlot = nil
    }

    private func handleDragChanged(_ value: DragGesture.Value, selectedSlot: Int?, activeBarWidth: CGFloat) {
        guard activeBarWidth > 0 else { return }
        if !didLockStartState {
            didLockStartState = true
            cancelledGesture = false
            lastHapticSlot = nil
            let startSlot = FloatingTabBarSliderMath.tabIndex(
                forX: value.startLocation.x,
                barWidth: activeBarWidth,
                count: items.count
            )
            pressedSlot = startSlot
            if let currentSlot = selectedSlot, startSlot == currentSlot {
                grabOffset = FloatingTabBarSliderMath.slotCenterX(
                    index: currentSlot,
                    barWidth: activeBarWidth,
                    count: items.count
                ) - value.startLocation.x
            } else {
                grabOffset = 0
            }
        }

        guard !cancelledGesture else { return }

        if !isDraggingPill {
            if abs(value.translation.height) > 36 && abs(value.translation.height) > abs(value.translation.width) * 1.3 {
                cancelledGesture = true
                pressedSlot = nil
                return
            }
            if abs(value.translation.width) >= 6 {
                isDraggingPill = true
                pressedSlot = nil
                let rawCenter = value.location.x + grabOffset
                let clamped = FloatingTabBarSliderMath.clampedPillCenterX(
                    rawX: rawCenter,
                    barWidth: activeBarWidth,
                    count: items.count
                )
                let initialHover = FloatingTabBarSliderMath.tabIndex(
                    forX: clamped,
                    barWidth: activeBarWidth,
                    count: items.count
                )
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.84)) {
                    pillCenterX = clamped
                    hoveredSlot = initialHover
                }
                if initialHover != selectedSlot {
                    emitHapticIfNeeded(forSlot: initialHover)
                }
            }
            return
        }

        if abs(value.translation.height) > 100 {
            cancelledGesture = true
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                isDraggingPill = false
                pillCenterX = nil
                hoveredSlot = nil
            }
            return
        }

        let clamped = FloatingTabBarSliderMath.clampedPillCenterX(
            rawX: value.location.x + grabOffset,
            barWidth: activeBarWidth,
            count: items.count
        )
        let nextHover = FloatingTabBarSliderMath.tabIndex(
            forX: clamped,
            barWidth: activeBarWidth,
            count: items.count
        )
        pillCenterX = clamped
        if nextHover != hoveredSlot {
            withAnimation(.snappy(duration: 0.16)) {
                hoveredSlot = nextHover
            }
            emitHapticIfNeeded(forSlot: nextHover)
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value, selectedSlot: Int?, activeBarWidth: CGFloat) {
        let wasDragging = isDraggingPill
        let wasCancelled = cancelledGesture
        let previousHapticSlot = lastHapticSlot
        let currentBaseSlot = selectedSlot ?? FloatingTabBarSliderMath.tabIndex(
            forX: value.startLocation.x,
            barWidth: activeBarWidth,
            count: items.count
        )
        let fallbackCenter = pillCenterX ?? FloatingTabBarSliderMath.slotCenterX(
            index: currentBaseSlot,
            barWidth: activeBarWidth,
            count: items.count
        )
        didLockStartState = false
        cancelledGesture = false
        pressedSlot = nil
        lastHapticSlot = nil

        guard !wasCancelled else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                isDraggingPill = false
                pillCenterX = nil
                hoveredSlot = nil
            }
            return
        }

        let targetSlot: Int
        if wasDragging {
            targetSlot = FloatingTabBarSliderMath.resolvedTargetTab(
                selectedTab: currentBaseSlot,
                pillCenterX: fallbackCenter,
                translationWidth: value.translation.width,
                predictedEndTranslationWidth: value.predictedEndTranslation.width,
                barWidth: activeBarWidth,
                count: items.count
            )
        } else {
            targetSlot = FloatingTabBarSliderMath.tabIndex(
                forX: value.location.x,
                barWidth: activeBarWidth,
                count: items.count
            )
        }

        let targetTabID = MainTabMapping.tabID(forSlotIndex: targetSlot)
        if targetTabID != selectedTab && previousHapticSlot != targetSlot {
            hapticCount += 1
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            isDraggingPill = false
            pillCenterX = nil
            hoveredSlot = nil
        }
        onSelect(targetTabID)
    }

    private func emitHapticIfNeeded(forSlot slot: Int) {
        guard lastHapticSlot != slot else { return }
        lastHapticSlot = slot
        hapticCount += 1
    }

    private var activePillColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.15)
            : Color.black.opacity(0.065)
    }

    private var draggingPillColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.24)
            : Color.white.opacity(0.86)
    }

    private var activePillBorderGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [Color.white.opacity(0.24), Color.white.opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color.white.opacity(0.85), Color.black.opacity(0.04)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func foregroundColor(isSelected: Bool) -> Color {
        if isSelected {
            return MyGoTheme.accent
        }
        return colorScheme == .dark
            ? Color.white.opacity(0.76)
            : Color(white: 0.16)
    }
}

private struct ScalePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.91 : 1.0)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct SearchCircleButton: View {
    let isSelected: Bool
    let size: CGFloat
    let isCompact: Bool
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if isSelected {
                    Circle()
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.15)
                                : Color.black.opacity(0.06)
                        )
                        .padding(FloatingTabBarMetrics.outerInset)
                }

                Image(systemName: "magnifyingglass")
                    .font(.system(
                        size: isCompact ? 19.5 : 22,
                        weight: isSelected ? .bold : .medium
                    ))
                    .foregroundStyle(
                        isSelected
                            ? MyGoTheme.accent
                            : (colorScheme == .dark ? Color.white.opacity(0.88) : Color(white: 0.14))
                    )
            }
            .frame(width: size, height: size)
            .mygoLiquidGlass(in: Circle(), isHighlighted: isSelected)
        }
        .buttonStyle(ScalePressButtonStyle())
        .accessibilityLabel(I18n.t("Search"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

private struct AdaptiveFloatingBottomChrome: View {
    @EnvironmentObject private var app: AppModel
    @Binding var selectedTab: Int
    let lastPrimaryTab: Int
    let isMinimized: Bool
    let onSelectTab: (Int) -> Void
    let onExpandFromCircle: () -> Void
    let onSearchTap: () -> Void

    @State private var measuredWidth: CGFloat = 360

    var body: some View {
        let hasTrack = (app.player.currentTrack != nil)
        let isCompactRow = isMinimized && hasTrack
        let isCompactWithoutTrack = isMinimized && !hasTrack
        let rowHeight: CGFloat = isMinimized
            ? FloatingTabBarMetrics.compactBarHeight
            : FloatingTabBarMetrics.barHeight
        let rowSpacing: CGFloat = isCompactRow
            ? FloatingTabBarMetrics.compactSplitSpacing
            : FloatingTabBarMetrics.splitSpacing
        let searchSize = rowHeight
        let expandedTabWidth = max(160, measuredWidth - rowSpacing - searchSize)
        let tabWidth = isCompactRow ? rowHeight : expandedTabWidth
        let miniWidth = isCompactRow
            ? max(120, measuredWidth - rowHeight * 2 - rowSpacing * 2)
            : measuredWidth
        let miniHeight = isCompactRow
            ? FloatingTabBarMetrics.compactBarHeight
            : FloatingTabBarMetrics.miniExpandedHeight
        let miniBottomOffset: CGFloat = isCompactRow
            ? 0
            : -(FloatingTabBarMetrics.barHeight + FloatingTabBarMetrics.overlaySpacing)
        let chromeHeight: CGFloat = hasTrack
            ? (isCompactRow ? rowHeight : FloatingTabBarMetrics.barHeight + FloatingTabBarMetrics.overlaySpacing + FloatingTabBarMetrics.miniExpandedHeight)
            : rowHeight

        VStack(spacing: FloatingTabBarMetrics.overlaySpacing) {
            if let toast = app.toastMessage {
                Text(toast)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.82), in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: rowSpacing) {
                    PrimaryTabsCapsuleBar(
                        selectedTab: $selectedTab,
                        lastPrimaryTab: lastPrimaryTab,
                        isCompactHeight: isCompactWithoutTrack,
                        isCollapsedToCircle: isCompactRow,
                        targetWidth: tabWidth,
                        targetHeight: rowHeight,
                        onSelect: onSelectTab,
                        onExpandFromCircle: onExpandFromCircle
                    )

                    if isCompactRow {
                        Color.clear
                            .frame(width: miniWidth, height: 1)
                            .allowsHitTesting(false)
                    }

                    SearchCircleButton(
                        isSelected: selectedTab == MainTabMapping.searchTabID,
                        size: searchSize,
                        isCompact: isMinimized,
                        onTap: onSearchTap
                    )
                }
                .frame(width: measuredWidth, height: rowHeight, alignment: .bottom)

                if hasTrack {
                    MiniPlayerBarView(isCompact: isCompactRow)
                        .frame(width: miniWidth, height: miniHeight)
                        .offset(y: miniBottomOffset)
                }
            }
            .frame(width: measuredWidth, height: chromeHeight, alignment: .bottom)
        }
        .frame(maxWidth: FloatingTabBarMetrics.maxWidth)
        .padding(.horizontal, FloatingTabBarMetrics.horizontalPadding)
        .background {
            GeometryReader { proxy in
                let innerW = max(240, proxy.size.width - FloatingTabBarMetrics.horizontalPadding * 2)
                Color.clear
                    .onAppear {
                        measuredWidth = innerW
                    }
                    .onChange(of: innerW) { _, newW in
                        measuredWidth = newW
                    }
            }
        }
    }
}

// MARK: - iOS 应用根视图（对应 ui_main.go 中的 view）

public struct MainView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var scrollCoordinator = TabBarScrollCoordinator()
    @State private var selectedTab: Int = 0
    @State private var lastPrimaryTab: Int = 0
    @State private var activatedTabs: Set<Int> = [0]
    @State private var isKeyboardVisible: Bool = false

    public init() {}

    private var preferredScheme: ColorScheme? {
        switch app.settings.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var bottomOverlayPadding: CGFloat {
        #if os(iOS)
        return 8
        #else
        return 12
        #endif
    }

    @ViewBuilder
    private func tabWithBottomOverlayInset<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let insetHeight: CGFloat = isKeyboardVisible
            ? 0
            : (app.player.currentTrack == nil
                ? FloatingTabBarMetrics.bottomInsetEmptyPlayer
                : FloatingTabBarMetrics.bottomInsetWithMiniPlayer)
        content()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: insetHeight)
                    .allowsHitTesting(false)
            }
    }

    @ViewBuilder
    private func tabViewport<Content: View>(index: Int, @ViewBuilder content: () -> Content) -> some View {
        let isActive = (selectedTab == index)
        if activatedTabs.contains(index) || isActive {
            tabWithBottomOverlayInset(content: content)
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .accessibilityHidden(!isActive)
                .zIndex(isActive ? 1 : 0)
        }
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                tabViewport(index: 0) { HomeView() }
                tabViewport(index: 1) { SearchView() }
                tabViewport(index: 2) { LibraryView() }
                tabViewport(index: 3) { SettingsView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.mygoReportVerticalScroll) { metrics in
                scrollCoordinator.handleScroll(metrics)
            }
            .environment(\.mygoResetScrollTracker) {
                scrollCoordinator.resetAccumulatorAndExpand()
            }

            // Apple Music iOS 26 分体悬浮液态玻璃底栏（支持上滑内容后音乐条自动融进底部一行，输入法弹起时平滑避让）
            AdaptiveFloatingBottomChrome(
                selectedTab: $selectedTab,
                lastPrimaryTab: lastPrimaryTab,
                isMinimized: scrollCoordinator.isMinimized,
                onSelectTab: { targetTab in
                    switchToTab(targetTab)
                },
                onExpandFromCircle: {
                    if selectedTab == MainTabMapping.searchTabID {
                        switchToTab(lastPrimaryTab)
                    } else {
                        scrollCoordinator.expand()
                    }
                },
                onSearchTap: {
                    handleSearchCircleTap()
                }
            )
            .padding(.bottom, bottomOverlayPadding)
            .frame(height: isKeyboardVisible ? 0 : nil, alignment: .bottom)
            .opacity(isKeyboardVisible ? 0 : 1)
            .clipped()
            .allowsHitTesting(!isKeyboardVisible)
        }
        .preferredColorScheme(preferredScheme)
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.20)) {
                isKeyboardVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.20)) {
                isKeyboardVisible = false
            }
        }
        #endif
        .onChange(of: selectedTab) { _, newTab in
            MyGoKeyboard.dismiss()
            if MainTabMapping.slotIndex(for: newTab) != nil {
                lastPrimaryTab = newTab
            }
            scrollCoordinator.resetAccumulatorAndExpand()
        }
        .onChange(of: app.isNowPlayingPresented) { _, presented in
            if presented {
                MyGoKeyboard.dismiss()
            }
        }
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
        #if DEBUG
        .onAppear {
            print(String(format: "[MyGoStartup] MainView first frame appeared (syncInit=%.2fms)", app.syncInitDurationMs))
            applyDebugLaunchOptionsIfNeeded()
        }
        #endif
        .sheet(isPresented: $app.isSignInSheetPresented) {
            SignInDialogSheetView()
                .environmentObject(app)
        }
        .sheet(item: $app.activeWebSignInRequest) { req in
            WebSignInSheetView(request: req)
                .environmentObject(app)
        }
        .onOpenURL { url in
            #if DEBUG
            if handleDebugURL(url) {
                return
            }
            #endif
            app.handleDeepLink(url)
        }
    }

    private func switchToTab(_ targetTab: Int) {
        MyGoKeyboard.dismiss()
        activatedTabs.insert(targetTab)
        if MainTabMapping.slotIndex(for: targetTab) != nil {
            lastPrimaryTab = targetTab
        }
        scrollCoordinator.resetAccumulatorAndExpand()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.80)) {
            selectedTab = targetTab
        }
    }

    private func handleSearchCircleTap() {
        let searchTab = MainTabMapping.searchTabID
        if selectedTab != searchTab {
            switchToTab(searchTab)
        } else if scrollCoordinator.isMinimized {
            scrollCoordinator.expand()
        } else {
            NotificationCenter.default.post(name: .mygoFocusSearchField, object: nil)
        }
    }

    #if DEBUG
    /// 根据字符串设置律动与播放器子面板（供 DEBUG 自动化联调使用）。
    private func applyDebugStageConfig(pane: String?, style: String?) {
        switch pane?.lowercased() {
        case "stage": app.activeNowPlayingPane = .stage
        case "lyrics": app.activeNowPlayingPane = .lyrics
        case "queue": app.activeNowPlayingPane = .queue
        case "wall": app.activeNowPlayingPane = .wall
        default: break
        }
        switch style?.lowercased() {
        case "flow": app.settings.stageStyle = .flow
        case "partita": app.settings.stageStyle = .partita
        case "tilt": app.settings.stageStyle = .tilt
        default: break
        }
    }

    /// 冷启动阶段读取环境变量或启动参数（等待首帧窗口就绪后再弹窗）。
    private func applyDebugLaunchOptionsIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        let shouldOpen = args.contains("-MyGoOpenNowPlaying") || env["MYGO_DEBUG_OPEN"] == "1"
        guard shouldOpen else { return }

        let paneArg = args.first(where: { $0.hasPrefix("-MyGoPane:") })?.split(separator: ":").last.map(String.init) ?? env["MYGO_DEBUG_PANE"]
        let styleArg = args.first(where: { $0.hasPrefix("-MyGoStageStyle:") })?.split(separator: ":").last.map(String.init) ?? env["MYGO_DEBUG_STYLE"]
        let autoPlay = args.contains("-MyGoAutoPlay") || env["MYGO_DEBUG_PLAY"] == "1"
        let seekArg = args.first(where: { $0.hasPrefix("-MyGoSeek:") })?.split(separator: ":").last.map(String.init) ?? env["MYGO_DEBUG_SEEK"]

        Task { @MainActor in
            await app.waitUntilStartupReady()
            // 等待 UIWindowScene 首帧完全挂载，避免 fullScreenCover 被吞掉
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard app.player.currentTrack != nil else { return }
            applyDebugStageConfig(pane: paneArg ?? (app.settings.lyricsStage ? "stage" : "lyrics"), style: styleArg)
            app.isNowPlayingPresented = true
            if autoPlay {
                app.player.resume()
            }
            if let seekStr = seekArg, let sec = Double(seekStr) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                app.player.seek(to: sec)
            }
        }
    }

    /// 处理仅在 DEBUG 构建生效的调试深链（mygo-music-dev://debug?...），便于动态切换界面与校验状态。
    private func handleDebugURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "mygo-music" || scheme == "mygo-music-dev",
              url.host?.lowercased() == "debug" else {
            return false
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.compactMap { item in
            item.value.map { (item.name.lowercased(), $0) }
        }, uniquingKeysWith: { _, latest in latest })

        if !app.isStartupReady {
            Task { @MainActor in
                await app.waitUntilStartupReady()
                applyDebugQuery(query)
            }
            return true
        }
        applyDebugQuery(query)
        return true
    }

    private func applyDebugQuery(_ query: [String: String]) {
        if let tabStr = query["tab"], let tab = Int(tabStr), (0...3).contains(tab) {
            activatedTabs.insert(tab)
            selectedTab = tab
            if MainTabMapping.slotIndex(for: tab) != nil {
                lastPrimaryTab = tab
            }
        }
        if let minStr = query["minimized"]?.lowercased() {
            if minStr == "1" || minStr == "true" {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                    scrollCoordinator.isMinimized = true
                }
            } else if minStr == "0" || minStr == "false" {
                scrollCoordinator.expand()
            }
        }
        switch query["appearance"]?.lowercased() {
        case "light": app.settings.appearance = .light
        case "dark": app.settings.appearance = .dark
        case "system": app.settings.appearance = .system
        default: break
        }
        applyDebugStageConfig(pane: query["pane"], style: query["style"])

        if let open = query["open"]?.lowercased() {
            if open == "nowplaying" || open == "1" || open == "true" {
                app.isNowPlayingPresented = true
            } else if open == "close" || open == "0" || open == "false" {
                app.isNowPlayingPresented = false
            }
        }
        if let play = query["play"] {
            if play == "1" || play == "true" {
                app.player.resume()
            } else if play == "0" || play == "false" {
                app.player.pause()
            }
        }
        if let seekStr = query["seek"], let sec = Double(seekStr) {
            app.player.seek(to: sec)
        }
    }
    #endif
}

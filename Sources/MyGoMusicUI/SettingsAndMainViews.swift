// SettingsAndMainViews.swift
// 对应原项目 internal/app/ui_settings.go, ui_player.go, ui_main.go 的设置、迷你播放条与根容器视图

import Combine
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

private struct RepoLinkTarget: Identifiable {
    let id: String
    let name: String
}

public struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.mygoIsViewVisible) private var isViewVisible
    @Environment(\.openURL) private var openURL
    @State private var showInstallSheet = false
    @State private var showPluginImporter = false
    @State private var githubRepoInput = ""
    @State private var repoLinkTarget: RepoLinkTarget? = nil
    @State private var repoLinkInput = ""
    @State private var repoLinkError: String? = nil
    @State private var cacheUsedBytes: Int64 = 0
    public let embedInNavigationStack: Bool

    public init(embedInNavigationStack: Bool = true) {
        self.embedInNavigationStack = embedInNavigationStack
    }

    public var body: some View {
        if embedInNavigationStack {
            NavigationStack {
                settingsContent
            }
        } else {
            settingsContent
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
            ScrollViewReader { scrollProxy in
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

                    AccentColorPickerRow()
                }

                // 2. 播放与音质
                SwiftUI.Section(I18n.t("Playback")) {
                    HStack(spacing: 8) {
                        Image(systemName: app.isOnCellularNetwork ? "antenna.radiowaves.left.and.right" : "wifi")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(app.isOnCellularNetwork ? .orange : MyGoTheme.accent)
                        Text(app.isOnCellularNetwork ? I18n.t("Current Network: Cellular") : I18n.t("Current Network: Wi-Fi"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Picker(I18n.t("Wi-Fi Quality"), selection: $app.settings.wifiQuality) {
                        ForEach(AudioQuality.allCases) { q in
                            Text(I18n.t(q.labelKey)).tag(q)
                        }
                    }
                    .onChange(of: app.settings.wifiQuality) { _, newValue in
                        if !app.isOnCellularNetwork {
                            app.settings.quality = newValue
                        }
                    }

                    Picker(I18n.t("Cellular Quality"), selection: $app.settings.cellularQuality) {
                        ForEach(AudioQuality.allCases) { q in
                            Text(I18n.t(q.labelKey)).tag(q)
                        }
                    }

                    Toggle(isOn: $app.settings.gaplessPlayback) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(I18n.t("Gapless Playback"))
                            Text(I18n.t("Eliminate gaps between consecutive tracks"))
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

                    Toggle(isOn: $app.settings.coverPlayerMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(I18n.t("Cover Player"))
                            Text(I18n.t("Display the Apple Music-style large cover player by default"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: app.settings.coverPlayerMode) { _, enabled in
                        if enabled {
                            app.settings.lyricsStage = false
                            app.activeNowPlayingPane = .cover
                        } else if app.activeNowPlayingPane == .cover {
                            app.activeNowPlayingPane = app.preferredDefaultNowPlayingPane()
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

                // 4. 插件管理（对应 Plugins）
                SwiftUI.Section {
                    // 内置本地文件源
                    PluginSourceRowView(
                        source: app.localSource,
                        isBuiltIn: true,
                        onRemove: nil
                    )
                    .id("pluginsSection")

                    // 已安装的 JS/TS 插件列表
                    ForEach(app.pluginSources, id: \.manifest.id) { plugin in
                        let pid = plugin.manifest.id
                        let resolvedOrigin = app.pluginOrigins[pid]
                        PluginSourceRowView(
                            source: plugin,
                            isBuiltIn: false,
                            pendingUpdateVersion: app.settings.pluginUpdates[pid],
                            origin: resolvedOrigin,
                            checkState: app.pluginCheckStates[pid],
                            isUpdating: app.updatingPluginIDs.contains(pid),
                            onCheckUpdate: {
                                Task { await app.checkPluginUpdate(id: pid) }
                            },
                            onUpdate: {
                                Task { await app.updatePlugin(id: pid) }
                            },
                            onForceReinstall: {
                                Task { await app.updatePlugin(id: pid, forceReinstall: true) }
                            },
                            onLinkRepository: {
                                repoLinkInput = resolvedOrigin?.repo ?? ""
                                repoLinkError = nil
                                repoLinkTarget = RepoLinkTarget(id: pid, name: plugin.info().name)
                            },
                            onOpenGitHub: resolvedOrigin.flatMap { origin in
                                URL(string: "https://github.com/\(origin.repo)")
                            }.map { url in
                                { openURL(url) }
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

                    if app.availablePluginUpdateCount >= 2 {
                        Button {
                            Task { await app.updateAllPlugins() }
                        } label: {
                            if app.isUpdatingAllPlugins {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(I18n.t("Updating…"))
                                }
                                .foregroundStyle(MyGoTheme.accent)
                            } else {
                                Label(
                                    "\(I18n.t("Update All Plugins")) (\(app.availablePluginUpdateCount))",
                                    systemImage: "arrow.down.circle.fill"
                                )
                                .foregroundStyle(MyGoTheme.accent)
                            }
                        }
                        .disabled(app.isUpdatingAllPlugins || app.isInstallingPlugin)
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

                    if !app.pluginSources.isEmpty {
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
                                    Spacer()
                                    if app.settings.pluginsCheckedAt > 0 {
                                        Text(Date(timeIntervalSince1970: app.settings.pluginsCheckedAt), style: .relative)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(.secondary)
                                    }
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
                    HStack(spacing: 8) {
                        Text(I18n.t("Plugins"))
                        if app.availablePluginUpdateCount > 0 {
                            Text(I18n.tf("Updates Available (%d)", app.availablePluginUpdateCount))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(MyGoTheme.accent, in: Capsule())
                        }
                    }
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
                    .id("settingsBottom")
                }
            }
            .mygoTrackVerticalScroll()
            .navigationTitle(I18n.t("Settings"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear {
                cacheUsedBytes = app.player.diskCache.usedBytes()
                #if DEBUG
                if app.isStartupReady {
                    scrollToDebugSectionIfNeeded(using: scrollProxy, delay: 0.25)
                }
                #endif
            }
            #if DEBUG
            .onChange(of: app.isStartupReady) { _, ready in
                guard ready else { return }
                scrollToDebugSectionIfNeeded(using: scrollProxy, delay: 0.35)
            }
            #endif
            }
            .sheet(isPresented: $showInstallSheet) {
                PluginRepoPickerSheet(
                    mode: .install,
                    repoInput: $githubRepoInput,
                    errorMessage: app.installErrorMessage,
                    isBusy: app.isInstallingPlugin,
                    onSubmit: { repo in
                        await app.installPluginFromGitHub(repoInput: repo)
                        if app.installErrorMessage == nil {
                            showInstallSheet = false
                        }
                    },
                    onCancel: {
                        showInstallSheet = false
                    }
                )
            }
            .sheet(item: $repoLinkTarget) { target in
                PluginRepoPickerSheet(
                    mode: .link(pluginName: target.name),
                    repoInput: $repoLinkInput,
                    errorMessage: repoLinkError,
                    isBusy: app.isCheckingUpdates || app.isInstallingPlugin,
                    onSubmit: { repo in
                        do {
                            _ = try PluginInstaller.parseRepo(repo)
                            let ok = await app.linkPluginRepository(
                                id: target.id,
                                repoInput: repo,
                                checkNow: true
                            )
                            if ok {
                                repoLinkTarget = nil
                            }
                        } catch {
                            repoLinkError = error.localizedDescription
                        }
                    },
                    onCancel: {
                        repoLinkTarget = nil
                    }
                )
            }
            .alert(
                I18n.t("Plugin Permission Update"),
                isPresented: Binding(
                    get: { app.pendingPluginUpdateApproval != nil },
                    set: { isPresented in
                        if !isPresented {
                            app.handlePendingPluginUpdateAlertDismissed()
                        }
                    }
                ),
                presenting: app.pendingPluginUpdateApproval
            ) { approval in
                Button(I18n.t("Confirm & Update")) {
                    app.approvePendingPluginUpdate(approval)
                }
                Button(I18n.t("Cancel"), role: .cancel) {
                    app.cancelPendingPluginUpdate(approval)
                }
            } message: { approval in
                Text(formatPermissionApprovalMessage(approval))
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

    #if DEBUG
    private func scrollToDebugSectionIfNeeded(using scrollProxy: ScrollViewProxy, delay: TimeInterval) {
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        let targetSection = args.first(where: { $0.hasPrefix("-MyGoSection:") })?
            .split(separator: ":").last.map(String.init) ?? env["MYGO_DEBUG_SECTION"]
        guard let section = targetSection?.lowercased() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if section == "plugins" {
                scrollProxy.scrollTo("pluginsSection", anchor: .top)
            } else if section == "bottom" {
                scrollProxy.scrollTo("settingsBottom", anchor: .bottom)
            }
        }
    }
    #endif

    private func formatPermissionApprovalMessage(_ approval: PendingPluginUpdateApproval) -> String {
        var lines: [String] = []
        if let hosts = approval.addedPermissions.network, !hosts.isEmpty {
            lines.append("• " + I18n.tf("Network access: %@", hosts.joined(separator: ", ")))
        }
        if let procs = approval.addedPermissions.process, !procs.isEmpty {
            let procLine = procs == ["*"]
                ? I18n.t("Run local helper processes")
                : "\(I18n.t("Run local helper processes")): \(procs.joined(separator: ", "))"
            lines.append("• " + procLine)
        }
        let verText = approval.targetVersion.isEmpty ? I18n.t("latest") : approval.targetVersion
        return I18n.tf(
            "%@ wants additional permissions in %@:\n%@",
            approval.pluginName,
            verText,
            lines.joined(separator: "\n")
        )
    }
}

/// 统一的 GitHub 仓库选择与社区目录面板（共用于首次安装插件与本地插件绑定更新源）
private struct PluginRepoPickerSheet: View {
    enum Mode {
        case install
        case link(pluginName: String)

        var title: String {
            switch self {
            case .install: return I18n.t("Install a Plugin")
            case .link(let pluginName): return "\(I18n.t("Link Update Source")) · \(pluginName)"
            }
        }

        var confirmTitle: String {
            switch self {
            case .install: return I18n.t("Install")
            case .link: return I18n.t("Save & Check Updates")
            }
        }
    }

    @EnvironmentObject private var app: AppModel
    let mode: Mode
    @Binding var repoInput: String
    let errorMessage: String?
    let isBusy: Bool
    let onSubmit: (String) async -> Void
    let onCancel: () -> Void

    private static let featuredRepos: [(repo: String, desc: String)] = [
        ("egoist/mygo-music-youtube-music", "YouTube Music 官方插件"),
        ("GentleM4dman/mygo-music-bilibili", "哔哩哔哩音乐插件"),
        ("AkinoKaede/mygo-music-netease-cloud-music", "网易云音乐插件"),
        ("sogud/mygo-music-netease", "网易云音乐插件（社区分支）"),
        ("xingkaixin/mygo-music-spotify", "Spotify 插件")
    ]

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    TextField(I18n.t("owner/repo or URL"), text: $repoInput)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif

                    if let errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text(modeHeaderText)
                } footer: {
                    Text(modeFooterText)
                }

                SwiftUI.Section {
                    if app.isLoadingCommunityPlugins && app.communityPlugins.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(I18n.t("Fetching community plugins…"))
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    } else if !app.communityPlugins.isEmpty {
                        ForEach(app.communityPlugins) { entry in
                            repoOptionButton(
                                repo: entry.repo,
                                subtitle: entry.description,
                                stars: entry.stars
                            )
                        }
                    } else if let err = app.communityPluginsError {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            ForEach(Self.featuredRepos, id: \.repo) { item in
                                repoOptionButton(repo: item.repo, subtitle: item.desc, stars: nil)
                            }
                        }
                    } else {
                        ForEach(Self.featuredRepos, id: \.repo) { item in
                            repoOptionButton(repo: item.repo, subtitle: item.desc, stars: nil)
                        }
                    }
                } header: {
                    HStack {
                        Text(I18n.t("Online Plugin Directory"))
                        Spacer()
                        Button {
                            Task { await app.loadCommunityPlugins(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .disabled(app.isLoadingCommunityPlugins)
                        .accessibilityLabel(I18n.t("Refresh"))
                    }
                }
            }
            .navigationTitle(mode.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(I18n.t("Cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isBusy {
                        ProgressView()
                    } else {
                        Button(mode.confirmTitle) {
                            let target = repoInput
                            Task { await onSubmit(target) }
                        }
                        .disabled(repoInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .task {
                await app.loadCommunityPlugins()
            }
        }
    }

    private var modeHeaderText: String {
        switch mode {
        case .install: return I18n.t("Install from GitHub")
        case .link: return I18n.t("Link GitHub Source…")
        }
    }

    private var modeFooterText: String {
        switch mode {
        case .install:
            return "例如: egoist/mygo-music-youtube-music 或 GentleM4dman/mygo-music-bilibili"
        case .link:
            return I18n.t("Link a GitHub repository (owner/repo) to enable one-tap online updates for this plugin.")
        }
    }

    private func repoOptionButton(repo: String, subtitle: String, stars: Int?) -> some View {
        let alreadyLinked = app.pluginOrigins.values.contains {
            $0.repo.caseInsensitiveCompare(repo) == .orderedSame
        }
        return Button {
            repoInput = repo
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(repo)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        if alreadyLinked {
                            Text(I18n.t("Installed"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(MyGoTheme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(MyGoTheme.accent.opacity(0.14), in: Capsule())
                        }
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if let stars, stars > 0 {
                    Label("\(stars)", systemImage: "star.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
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
    var checkState: PluginUpdateCheckState? = nil
    var isUpdating: Bool = false
    var onCheckUpdate: (() -> Void)? = nil
    var onUpdate: (() -> Void)? = nil
    var onForceReinstall: (() -> Void)? = nil
    var onLinkRepository: (() -> Void)? = nil
    var onOpenGitHub: (() -> Void)? = nil
    let onRemove: (() -> Void)?

    var body: some View {
        let info = source.info()
        let enabled = app.isSourceEnabled(info.id)
        let signedAccount = app.accountsBySource[info.id]
        let versionLabel = info.version.map { PluginInstaller.displayVersion($0) } ?? ""
        let pendingLabel = pendingUpdateVersion.map { PluginInstaller.displayVersion($0) } ?? ""

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(info.name)
                            .font(.system(size: 15, weight: .semibold))
                        if isBuiltIn {
                            Text(I18n.t("Built-in"))
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MyGoTheme.pillSurface, in: Capsule())
                        } else if !versionLabel.isEmpty {
                            Text(versionLabel)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        if !pendingLabel.isEmpty {
                            Text("→ \(pendingLabel)")
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
                pluginStatusAndActionRow(pendingLabel: pendingLabel)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func pluginStatusAndActionRow(pendingLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let checkState {
                switch checkState {
                case .checking:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(I18n.t("Checking for updates…"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                case .upToDate:
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11))
                        Text(I18n.t("Up to date"))
                            .font(.system(size: 11.5))
                    }
                    .foregroundStyle(.secondary)
                case .failed(let message):
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text(message)
                            .font(.system(size: 11.5))
                            .lineLimit(2)
                    }
                    .foregroundStyle(.red)
                case .updateAvailable:
                    EmptyView()
                }
            }

            HStack(alignment: .center, spacing: 8) {
                if let repo = origin?.repo, !repo.isEmpty {
                    if let onOpenGitHub {
                        Button(action: onOpenGitHub) {
                            HStack(spacing: 4) {
                                Text(repo)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10))
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .tint(.secondary)
                    } else {
                        Text(repo)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else if let onLinkRepository {
                    Button(action: onLinkRepository) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.system(size: 10.5))
                            Text(I18n.t("Link Update Source"))
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange.opacity(0.95))
                    }
                    .buttonStyle(.borderless)
                } else {
                    Text(I18n.t("Local import · No update source linked"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if isUpdating {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(I18n.t("Updating…"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                } else if !pendingLabel.isEmpty, let onUpdate {
                    Button(action: onUpdate) {
                        Text(I18n.t("Update"))
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(MyGoTheme.accent, in: Capsule())
                            .fixedSize()
                    }
                    .buttonStyle(.borderless)
                    .disabled(app.isInstallingPlugin)
                }

                Menu {
                    if origin != nil, let onCheckUpdate {
                        Button(action: onCheckUpdate) {
                            Label(I18n.t("Check for Update"), systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    if origin != nil, let onForceReinstall {
                        Button(action: onForceReinstall) {
                            Label(I18n.t("Reinstall Latest"), systemImage: "arrow.down.to.line")
                        }
                    }
                    if let onLinkRepository {
                        Button(action: onLinkRepository) {
                            Label(
                                I18n.t(origin == nil ? "Link GitHub Source…" : "Change Repository…"),
                                systemImage: "link"
                            )
                        }
                    }
                    if let onOpenGitHub {
                        Button(action: onOpenGitHub) {
                            Label(I18n.t("Open on GitHub"), systemImage: "safari")
                        }
                    }
                    if let onRemove {
                        Divider()
                        Button(role: .destructive, action: onRemove) {
                            Label(I18n.t("Remove"), systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .tint(.secondary)
            }
        }
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
                            .background(MyGoTheme.pillSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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

/// 悬浮液态玻璃在不同外观模式下的投影与透光参数（避免浅色白底出现厚重黑边蒙版）
public enum LiquidGlassElevationSpec {
    public static func primaryShadowOpacity(isDark: Bool) -> Double {
        isDark ? 0.48 : 0.048
    }

    public static func primaryShadowRadius(isDark: Bool) -> CGFloat {
        isDark ? 14 : 10
    }

    public static func primaryShadowOffsetY(isDark: Bool) -> CGFloat {
        isDark ? 5 : 3
    }

    public static func contactShadowOpacity(isDark: Bool) -> Double {
        isDark ? 0.24 : 0.024
    }

    public static func contactShadowRadius(isDark: Bool) -> CGFloat {
        isDark ? 3.5 : 2.2
    }

    public static func contactShadowOffsetY(isDark: Bool) -> CGFloat {
        isDark ? 1.5 : 0.8
    }
}

private struct LiquidGlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let isHighlighted: Bool
    var highOcclusion: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = (colorScheme == .dark)
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
                    .strokeBorder(borderGradient, lineWidth: isDark ? 0.75 : 0.90)
            )
            .shadow(
                color: .black.opacity(LiquidGlassElevationSpec.primaryShadowOpacity(isDark: isDark)),
                radius: LiquidGlassElevationSpec.primaryShadowRadius(isDark: isDark),
                x: 0,
                y: LiquidGlassElevationSpec.primaryShadowOffsetY(isDark: isDark)
            )
            .shadow(
                color: .black.opacity(LiquidGlassElevationSpec.contactShadowOpacity(isDark: isDark)),
                radius: LiquidGlassElevationSpec.contactShadowRadius(isDark: isDark),
                x: 0,
                y: LiquidGlassElevationSpec.contactShadowOffsetY(isDark: isDark)
            )
    }

    private var tintOverlay: Color {
        if colorScheme == .dark {
            // 沉稳黑曜石烟熏玻璃：迷你条模式提高遮蔽抑制底层列表高对比白字穿透
            if highOcclusion {
                return Color(red: 0.095, green: 0.095, blue: 0.115).opacity(0.82)
            }
            return Color(red: 0.085, green: 0.085, blue: 0.105).opacity(isHighlighted ? 0.64 : 0.54)
        }
        if highOcclusion {
            return Color(white: 0.96).opacity(0.78)
        }
        // 浅色采用微带通透银白雾的清亮基底，使高亮白色选中气泡与外缘反光能饱满浮凸而出
        return Color(white: 0.955).opacity(isHighlighted ? 0.60 : 0.46)
    }

    private var specularInnerSheen: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.15),
                    Color.white.opacity(0.035),
                    Color.clear,
                    Color.white.opacity(0.07)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [
                Color.white.opacity(0.82),
                Color.white.opacity(0.24),
                Color.white.opacity(0.04),
                Color.white.opacity(0.42)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var borderGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.28),
                    Color.white.opacity(0.085),
                    Color.white.opacity(0.055),
                    Color.white.opacity(0.15)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [
                Color.white.opacity(1.0),
                Color.white.opacity(0.50),
                Color.white.opacity(0.36),
                Color.white.opacity(0.88)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private extension View {
    func mygoLiquidGlass<S: InsettableShape>(in shape: S, isHighlighted: Bool = false, highOcclusion: Bool = false) -> some View {
        modifier(LiquidGlassSurfaceModifier(shape: shape, isHighlighted: isHighlighted, highOcclusion: highOcclusion))
    }
}

/// 液态玻璃内嵌选中态浮凸气泡（统一主 Tab 胶囊与搜索圆钮的 3D 高光与投影）
private struct LiquidGlassSelectionBubble<S: InsettableShape>: View {
    let shape: S
    var isEmphasized: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = (colorScheme == .dark)
        ZStack {
            shape.fill(fillColor(isDark: isDark))
            shape.strokeBorder(borderGradient(isDark: isDark), lineWidth: isEmphasized ? 0.95 : 0.75)
        }
        .shadow(
            color: .black.opacity(
                isEmphasized
                    ? (isDark ? 0.30 : 0.11)
                    : (isDark ? 0.22 : 0.06)
            ),
            radius: isEmphasized ? 10 : 5,
            x: 0,
            y: isEmphasized ? 3 : 1.5
        )
    }

    private func fillColor(isDark: Bool) -> Color {
        if isDark {
            return Color.white.opacity(isEmphasized ? 0.26 : 0.19)
        }
        return Color.white.opacity(isEmphasized ? 0.95 : 0.86)
    }

    private func borderGradient(isDark: Bool) -> LinearGradient {
        LinearGradient(
            colors: isDark
                ? [Color.white.opacity(0.32), Color.white.opacity(0.08)]
                : [Color.white.opacity(1.0), Color.black.opacity(0.055)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - 底部悬浮迷你播放条（对应 ui_player.go 中的 playerBar，支持 iOS 26 随滚动嵌合形态）

public struct MiniPlayerBarView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let isCompact: Bool
    public var isScrollPaused: Bool = false

    private enum DragAxisLock {
        case horizontal
        case vertical
    }

    @State private var pagerOffsetX: CGFloat = 0
    @State private var pagerSlotWidth: CGFloat = 220
    @State private var isCommittingTrackSwitch: Bool = false
    @State private var swipePullUpY: CGFloat = 0
    @State private var dragAxisLock: DragAxisLock? = nil
    @State private var didTriggerDragHaptic = false
    @State private var transitionVisibilityAlpha: Double = 1.0
    @State private var landingBounceScale: CGFloat = 1.0
    @State private var landingBounceY: CGFloat = 0.0

    public init(isCompact: Bool = false, isScrollPaused: Bool = false) {
        self.isCompact = isCompact
        self.isScrollPaused = isScrollPaused
    }

    public var body: some View {
        if let track = app.player.currentTrack {
            let capsuleShape = Capsule(style: .continuous)
            let barHeight = isCompact
                ? FloatingTabBarMetrics.compactBarHeight
                : FloatingTabBarMetrics.miniExpandedHeight
            let prevTrack = app.player.adjacentTrack(step: -1)
            let nextTrack = app.player.adjacentTrack(step: 1)
            // 外框胶囊仅保留极克制的微张力反馈，绝不整体平移撞击旁边圆形搜索按钮
            let shellTensionX = max(-3.5, min(3.5, pagerOffsetX * 0.032))

            HStack(spacing: 8) {
                // 左侧独立裁剪视口 + 右缘微羽化：承载 Apple Music 级三联曲目横滑轨（上一首 / 当前首 / 下一首）
                GeometryReader { slotGeo in
                    let slotW = max(120, slotGeo.size.width)
                    let progressRatio = abs(pagerOffsetX) / slotW
                    let activeScale = 1.0 - min(0.05, progressRatio * 0.05)
                    let activeOpacity = 1.0 - min(0.55, progressRatio * 0.55)

                    ZStack(alignment: .leading) {
                        if let prevTrack, pagerOffsetX > 0.5 {
                            let incomingProgress = min(1.0, pagerOffsetX / slotW)
                            miniTrackSlotContent(
                                for: prevTrack,
                                isCurrentSlot: false,
                                slotWidth: slotW
                            )
                            .scaleEffect(0.95 + 0.05 * incomingProgress)
                            .opacity(0.45 + 0.55 * incomingProgress)
                            .offset(x: pagerOffsetX - slotW)
                        }

                        miniTrackSlotContent(
                            for: track,
                            isCurrentSlot: true,
                            slotWidth: slotW
                        )
                        .scaleEffect(activeScale)
                        .opacity(activeOpacity)
                        .offset(x: pagerOffsetX)

                        if let nextTrack, pagerOffsetX < -0.5 {
                            let incomingProgress = min(1.0, -pagerOffsetX / slotW)
                            miniTrackSlotContent(
                                for: nextTrack,
                                isCurrentSlot: false,
                                slotWidth: slotW
                            )
                            .scaleEffect(0.95 + 0.05 * incomingProgress)
                            .opacity(0.45 + 0.55 * incomingProgress)
                            .offset(x: pagerOffsetX + slotW)
                        }
                    }
                    .frame(width: slotW, height: barHeight, alignment: .leading)
                    .clipped()
                    .mask {
                        if abs(pagerOffsetX) > 0.5 {
                            HStack(spacing: 0) {
                                Rectangle().fill(.black)
                                LinearGradient(
                                    colors: [.black, .black.opacity(0.0)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: 10)
                            }
                        } else {
                            Rectangle().fill(.black)
                        }
                    }
                    .onAppear {
                        pagerSlotWidth = slotW
                    }
                    .onChange(of: slotW) { _, newW in
                        pagerSlotWidth = newW
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 右侧播放控制按钮始终稳固锚定在胶囊右侧不动
                HStack(spacing: isCompact ? 0 : 4) {
                    Button {
                        MyGoHaptics.impact(.soft)
                        if app.player.errorMessage != nil {
                            app.player.retryCurrentTrack()
                        } else {
                            app.player.togglePlay()
                        }
                    } label: {
                        Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18.5, weight: .bold))
                            .foregroundStyle(.primary)
                            .scaleEffect(isCompact ? 0.96 : 1.0)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(I18n.t(app.player.isPlaying ? "Pause" : "Play"))

                    Button {
                        MyGoHaptics.impact(.light)
                        animateButtonNextSwitchIfPossible(hasNextTrack: nextTrack != nil)
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(I18n.t("Next Track"))
                    .frame(width: isCompact ? 0 : 34, alignment: .trailing)
                    .opacity(isCompact ? 0 : 1)
                    .allowsHitTesting(!isCompact)
                    .clipped()
                }
                .padding(.trailing, isCompact ? 8 : 10)
                .geometryGroup()
            }
            .frame(height: barHeight)
            .mygoLiquidGlass(in: capsuleShape, highOcclusion: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MiniPlayerFramePreferenceKey.self,
                        value: proxy.frame(in: .global)
                    )
                }
            )
            .geometryGroup()
            .contentShape(capsuleShape)
            .offset(x: shellTensionX, y: min(0, swipePullUpY * 0.28) + landingBounceY)
            .scaleEffect(
                (swipePullUpY < -12 ? 1.0 + min(0.035, -swipePullUpY / 1400) : 1.0) * landingBounceScale
            )
            .opacity(transitionVisibilityAlpha)
            .onReceive(NotificationCenter.default.publisher(for: .mygoMiniPlayerLandingPulse)) { _ in
                guard !reduceMotion else { return }
                landingBounceScale = 0.980
                landingBounceY = 2.0
                withAnimation(.spring(response: 0.28, dampingFraction: 0.62)) {
                    landingBounceScale = 1.0
                    landingBounceY = 0.0
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .mygoMiniPlayerSetTransitionAlpha)) { note in
                if let pair = note.object as? [Double], pair.count >= 2 {
                    let targetAlpha = pair[0]
                    let duration = pair[1]
                    if duration <= 0.001 {
                        transitionVisibilityAlpha = targetAlpha
                    } else {
                        withAnimation(.easeOut(duration: duration)) {
                            transitionVisibilityAlpha = targetAlpha
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .mygoNowPlayingDidCollapseToMiniBar)) { _ in
                transitionVisibilityAlpha = 1.0
            }
            .onTapGesture {
                app.presentNowPlaying()
            }
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        guard !isCommittingTrackSwitch else { return }
                        let dx = value.translation.width
                        let dy = value.translation.height

                        if dragAxisLock == nil {
                            if dy < -8 && abs(dy) > abs(dx) * 1.15 {
                                dragAxisLock = .vertical
                            } else if abs(dx) > 8 && abs(dx) > abs(dy) * 1.1 {
                                dragAxisLock = .horizontal
                            } else {
                                return
                            }
                        }

                        switch dragAxisLock {
                        case .vertical:
                            swipePullUpY = max(-84, min(0, dy))
                            pagerOffsetX = 0
                            if dy <= -42 && !didTriggerDragHaptic {
                                didTriggerDragHaptic = true
                                MyGoHaptics.impact(.light)
                            } else if dy > -34 {
                                didTriggerDragHaptic = false
                            }

                        case .horizontal:
                            swipePullUpY = 0
                            let canSlideRight = (prevTrack != nil)
                            let canSlideLeft = (nextTrack != nil)
                            let threshold = max(44, pagerSlotWidth * 0.28)
                            let clamped: CGFloat
                            if dx < 0 {
                                clamped = canSlideLeft ? max(-pagerSlotWidth, dx * 0.94) : max(-36, dx * 0.24)
                            } else {
                                clamped = canSlideRight ? min(pagerSlotWidth, dx * 0.94) : min(36, dx * 0.24)
                            }
                            pagerOffsetX = clamped
                            let canTrigger = (dx < 0 && canSlideLeft) || (dx > 0 && canSlideRight)
                            if canTrigger && abs(clamped) >= threshold && !didTriggerDragHaptic {
                                didTriggerDragHaptic = true
                                MyGoHaptics.impact(.light)
                            } else if abs(clamped) < threshold * 0.8 {
                                didTriggerDragHaptic = false
                            }

                        case nil:
                            break
                        }
                    }
                    .onEnded { value in
                        guard !isCommittingTrackSwitch else { return }
                        let axis = dragAxisLock
                        let finalX = pagerOffsetX
                        let finalY = swipePullUpY
                        let predictedDx = value.predictedEndTranslation.width
                        dragAxisLock = nil
                        didTriggerDragHaptic = false

                        if axis == .vertical {
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.76)) {
                                swipePullUpY = 0
                            }
                            if finalY <= -42 {
                                MyGoHaptics.impact(.soft)
                                app.presentNowPlaying()
                            }
                            return
                        }

                        let threshold = max(44, pagerSlotWidth * 0.28)
                        let triggerNext = (nextTrack != nil) && (finalX <= -threshold || (finalX < -18 && predictedDx <= -125))
                        let triggerPrev = (prevTrack != nil) && (finalX >= threshold || (finalX > 18 && predictedDx >= 125))

                        if triggerNext {
                            commitHorizontalTrackChange(direction: -1)
                        } else if triggerPrev {
                            commitHorizontalTrackChange(direction: 1)
                        } else {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                                pagerOffsetX = 0
                                swipePullUpY = 0
                            }
                        }
                    }
            )
        }
    }

    /// 渲染单个横向滑轨曲目条目（左槽 38x38 封面 + 双行歌名/歌手）
    @ViewBuilder
    private func miniTrackSlotContent(
        for displayTrack: Track,
        isCurrentSlot: Bool,
        slotWidth: CGFloat
    ) -> some View {
        let artworkSlotSize: CGFloat = 38
        let artworkRadius: CGFloat = 9.5

        HStack(spacing: 10) {
            ArtworkView(
                urlString: displayTrack.album.imageUrl,
                pixelSize: 160,
                size: artworkSlotSize,
                cornerRadius: artworkRadius
            )
            .background {
                if isCurrentSlot {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MiniPlayerArtworkFramePreferenceKey.self,
                            value: abs(pagerOffsetX) < 1.0 ? proxy.frame(in: .global) : .zero
                        )
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: artworkRadius, style: .continuous)
                    .fill(MyGoTheme.placeholderFill)
                    .shadow(color: .black.opacity(0.16), radius: 4, x: 0, y: 1.5)
            )
            .scaleEffect(isCompact ? 0.94 : 1.0)
            .geometryGroup()

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 4) {
                    MyGoMarqueeText(
                        displayTrack.name,
                        font: .system(size: 14.5, weight: .semibold),
                        foregroundStyle: .primary,
                        isActive: isCurrentSlot && !app.isNowPlayingPresented && abs(pagerOffsetX) < 1.0
                    )
                    if isCurrentSlot, let radio = app.player.radioName, !radio.isEmpty {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 10.5))
                            .foregroundStyle(MyGoTheme.accent)
                            .frame(width: isCompact ? 0 : 14)
                            .clipped()
                            .opacity(isCompact ? 0 : 1)
                    }
                }
                if isCurrentSlot, let errMsg = app.player.errorMessage, !errMsg.isEmpty {
                    Text(errMsg)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    MyGoMarqueeText(
                        displayTrack.artistNames,
                        font: .system(size: 12),
                        foregroundStyle: .secondary,
                        isActive: isCurrentSlot && !app.isNowPlayingPresented && abs(pagerOffsetX) < 1.0
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .geometryGroup()
        }
        .padding(.leading, 9)
        .frame(width: slotWidth, alignment: .leading)
        .geometryGroup()
    }

    private func animateButtonNextSwitchIfPossible(hasNextTrack: Bool) {
        guard !isCommittingTrackSwitch else { return }
        guard hasNextTrack, !reduceMotion else {
            app.player.next()
            return
        }
        commitHorizontalTrackChange(direction: -1, duration: 0.22)
    }

    /// 顺滑将目标曲目滑入视口正中后再无闪烁归零交棒，杜绝回弹硬切
    private func commitHorizontalTrackChange(direction: CGFloat, duration: Double = 0.20) {
        isCommittingTrackSwitch = true
        MyGoHaptics.impact(.medium)
        let targetX = direction * max(120, pagerSlotWidth)

        withAnimation(.spring(response: duration, dampingFraction: 0.88)) {
            pagerOffsetX = targetX
            swipePullUpY = 0
        }

        let waitNs = UInt64((duration * 0.78) * 1_000_000_000)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: waitNs)
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                if direction < 0 {
                    app.player.next()
                } else {
                    app.player.skipToPreviousTrack()
                }
                pagerOffsetX = 0
                isCommittingTrackSwitch = false
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

/// 全局界面触发广播通知（主动聚焦搜索框 / 跳转设置页 / 主屏幕快捷跳转）
public extension Notification.Name {
    static let mygoFocusSearchField = Notification.Name("MyGoFocusSearchField")
    static let mygoOpenSettings = Notification.Name("MyGoOpenSettings")
    static let mygoOpenHomeDaily = Notification.Name("MyGoOpenHomeDaily")
    static let mygoOpenLibraryTarget = Notification.Name("MyGoOpenLibraryTarget")
    static let mygoOpenHomeTarget = Notification.Name("MyGoOpenHomeTarget")
    static let mygoNowPlayingDidCollapseToMiniBar = Notification.Name("MyGoNowPlayingDidCollapseToMiniBar")
    static let mygoMiniPlayerSetTransitionAlpha = Notification.Name("MyGoMiniPlayerSetTransitionAlpha")
    static let mygoMiniPlayerLandingPulse = Notification.Name("MyGoMiniPlayerLandingPulse")
    #if DEBUG
    static let mygoDebugDemoDismissMorph = Notification.Name("MyGoDebugDemoDismissMorph")
    static let mygoDebugDemoLyricsMorph = Notification.Name("MyGoDebugDemoLyricsMorph")
    static let mygoDebugSwitchPane = Notification.Name("MyGoDebugSwitchPane")
    #endif
}

private struct MiniPlayerFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let candidate = nextValue()
        if candidate.width > 20 && candidate.height > 20 {
            value = candidate
        }
    }
}

private struct MiniPlayerArtworkFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let candidate = nextValue()
        if candidate.width > 12 && candidate.height > 12 {
            value = candidate
        }
    }
}

/// 遵循 Apple iOS HIG 与 Apple Music iOS 26 悬浮胶囊规范的底部导航栏尺寸常量
public enum FloatingTabBarMetrics {
    public static let barHeight: CGFloat = 64
    public static let outerInset: CGFloat = 4
    public static let activePillHeight: CGFloat = barHeight - outerInset * 2
    public static let itemSpacing: CGFloat = 4
    public static let horizontalPadding: CGFloat = 22
    public static let maxWidth: CGFloat = 396
    public static let iconSize: CGFloat = 23
    public static let iconFrameHeight: CGFloat = 25
    public static let iconLabelSpacing: CGFloat = 2.5
    public static let labelFontSize: CGFloat = 10.5
    public static let overlaySpacing: CGFloat = 10
    public static let miniExpandedHeight: CGFloat = 56
    public static let compactBarHeight: CGFloat = 56
    public static let searchCircleSize: CGFloat = barHeight
    public static let splitSpacing: CGFloat = 12
    public static let compactSplitSpacing: CGFloat = 10
    public static let bottomInsetEmptyPlayer: CGFloat = 98
    public static let bottomInsetWithMiniPlayer: CGFloat = 168

    /// 计算纵向滚动容器在系统安全区之外还需追加的底部留白，确保所有页脚完整高于悬浮胶囊与迷你播放条
    public static func extraScrollBottomInset(
        hasTrack: Bool,
        isKeyboardVisible: Bool,
        bottomOverlayPadding: CGFloat,
        systemSafeAreaBottom: CGFloat
    ) -> CGFloat {
        guard !isKeyboardVisible else { return 0 }
        let clearance: CGFloat = hasTrack ? 24 : 22
        let chromePhysicalHeight: CGFloat = hasTrack
            ? (bottomOverlayPadding + barHeight + overlaySpacing + miniExpandedHeight + clearance)
            : (bottomOverlayPadding + barHeight + clearance)
        return max(0, chromePhysicalHeight - max(0, systemSafeAreaBottom))
    }
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

private struct VerticalScrollBottomOverlayInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
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

    /// 底部悬浮胶囊与迷你播放条所需的额外底部滚动安全边距（穿透 NavigationStack 传递到各级滚动视图）
    var mygoBottomOverlayInset: CGFloat {
        get { self[VerticalScrollBottomOverlayInsetKey.self] }
        set { self[VerticalScrollBottomOverlayInsetKey.self] = newValue }
    }
}

/// 120Hz 滚动监听降噪过滤器：避免亚像素微震在主线程上触发高频无意义回调
public enum VerticalScrollProbeFilter {
    public static func shouldEmit(
        lastNormalizedY: CGFloat?,
        currentNormalizedY: CGFloat,
        lastInteracting: Bool?,
        currentInteracting: Bool,
        maxOffset: CGFloat
    ) -> Bool {
        guard let prevY = lastNormalizedY, let prevInteracting = lastInteracting else {
            return true
        }
        if currentInteracting != prevInteracting {
            return true
        }
        // 顶/底安全区间必须精确传达以触发底栏边界复位或触底回弹
        let nearTop = currentNormalizedY <= FloatingTabBarMinimizeMath.topAlwaysExpandedOffset + 24
            || prevY <= FloatingTabBarMinimizeMath.topAlwaysExpandedOffset + 24
        let nearBottom = maxOffset > 0
            && (currentNormalizedY >= maxOffset - 24 || prevY >= maxOffset - 24)
        if nearTop || nearBottom {
            return abs(currentNormalizedY - prevY) >= 0.4
        }
        return abs(currentNormalizedY - prevY) >= 1.0
    }
}

/// 同帧多笔 KVO 偏移增量累加器，防止高频滚动下后一帧微震覆盖前一帧有效位移
public struct VerticalScrollDeltaAccumulator: Sendable {
    public private(set) var pendingDelta: CGFloat = 0

    public init() {}

    public mutating func add(_ delta: CGFloat) {
        pendingDelta += delta
    }

    public mutating func drain() -> CGFloat {
        let value = pendingDelta
        pendingDelta = 0
        return value
    }

    public mutating func reset() {
        pendingDelta = 0
    }
}

/// 持有底栏滚动协同器的无 `@Published` 容器，防止 `isMinimized` 变化连带触发整棵 Tab 树重建
@MainActor
private final class ScrollCoordinatorStore: ObservableObject {
    let coordinator = TabBarScrollCoordinator()
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
        withAnimation(.spring(response: 0.36, dampingFraction: 0.90)) {
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
    private var lastReportedNormalizedY: CGFloat?
    private var lastReportedInteracting: Bool?
    private var pendingMetrics: VerticalScrollMetrics?
    private var deltaAccumulator = VerticalScrollDeltaAccumulator()
    private var isFlushScheduled: Bool = false

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
        lastReportedNormalizedY = nil
        lastReportedInteracting = nil
        pendingMetrics = nil
        deltaAccumulator.reset()
        isFlushScheduled = false
    }

    private func attachNow() {
        guard observedScrollView == nil, let sv = findTargetVerticalScrollView() else { return }
        observedScrollView = sv
        contentOffsetObservation = sv.observe(\.contentOffset, options: [.new, .old]) { [weak self] scrollView, change in
            guard let self,
                  self.window != nil,
                  scrollView.window != nil,
                  !self.isHidden,
                  scrollView.bounds.height > 0,
                  self.isViewVisibleInHierarchy(self) else { return }

            let oldY = change.oldValue?.y ?? scrollView.contentOffset.y
            let newY = change.newValue?.y ?? scrollView.contentOffset.y
            let delta = newY - oldY
            let insetTop = scrollView.adjustedContentInset.top
            let insetBottom = scrollView.adjustedContentInset.bottom
            let normalizedY = newY + insetTop
            let maxOffset = max(0, scrollView.contentSize.height + insetTop + insetBottom - scrollView.bounds.height)
            let isInteracting = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating

            self.deltaAccumulator.add(delta)

            guard VerticalScrollProbeFilter.shouldEmit(
                lastNormalizedY: self.lastReportedNormalizedY,
                currentNormalizedY: normalizedY,
                lastInteracting: self.lastReportedInteracting,
                currentInteracting: isInteracting,
                maxOffset: maxOffset
            ) else {
                return
            }

            self.lastReportedNormalizedY = normalizedY
            self.lastReportedInteracting = isInteracting

            // 每帧最多合并派发一次主线程异步回调，直到实际派发时才取出并归零累计偏移，避免同帧连续采样相互覆盖
            self.pendingMetrics = VerticalScrollMetrics(
                normalizedOffsetY: normalizedY,
                deltaY: 0,
                maxScrollOffset: maxOffset,
                isUserInteracting: isInteracting
            )
            guard !self.isFlushScheduled else { return }
            self.isFlushScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isFlushScheduled = false
                guard let snapshot = self.pendingMetrics else { return }
                self.pendingMetrics = nil
                let accumulated = self.deltaAccumulator.drain()
                let resolved = VerticalScrollMetrics(
                    normalizedOffsetY: snapshot.normalizedOffsetY,
                    deltaY: accumulated,
                    maxScrollOffset: snapshot.maxScrollOffset,
                    isUserInteracting: snapshot.isUserInteracting
                )
                self.onScroll?(resolved)
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
    @Environment(\.mygoBottomOverlayInset) private var bottomOverlayInset

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.bottom, bottomOverlayInset)
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
    let expandedWidth: CGFloat
    let targetWidth: CGFloat
    let targetHeight: CGFloat
    var settingsBadgeCount: Int = 0
    let onSelect: (Int) -> Void
    let onExpandFromCircle: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pillCenterX: CGFloat? = nil
    @State private var hoveredSlot: Int? = nil
    @State private var pressedSlot: Int? = nil
    @State private var isDraggingPill: Bool = false
    @State private var grabOffset: CGFloat = 0
    @State private var didLockStartState: Bool = false
    @State private var cancelledGesture: Bool = false
    @State private var hapticCount: Int = 0
    @State private var lastHapticSlot: Int? = nil
    @State private var tabTiltDegrees: [Int: Double] = [:]

    // 首页采用 v6 小房子，音乐库采用 v5 叠层圆角音符卡，设置采用 v5 单齿轮（四图标完全对齐大小与基线）
    private let items: [MainTabItem] = [
        MainTabItem(id: 0, titleKey: "Home", icon: "house", selectedIcon: "house.fill"),
        MainTabItem(id: 2, titleKey: "Library", icon: "music.note.square.stack", selectedIcon: "music.note.square.stack.fill"),
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

        let activeBarWidth = max(160, expandedWidth)
        let fullBarHeight = FloatingTabBarMetrics.barHeight
        let pillWidth = FloatingTabBarSliderMath.slotWidth(barWidth: activeBarWidth, count: items.count)
        let restCenterX = FloatingTabBarSliderMath.slotCenterX(
            index: selectedSlot ?? effectiveSlot,
            barWidth: activeBarWidth,
            count: items.count
        )
        let displayCenterX = (isDraggingPill ? pillCenterX : nil) ?? restCenterX
        let showActivePill = !isCollapsedToCircle && (selectedSlot != nil || isDraggingPill)
        let innerHeight = max(36, fullBarHeight - FloatingTabBarMetrics.outerInset * 2)

        ZStack(alignment: .leading) {
            // 高亮滑块仅在展开态显示，收起成圆时提前平稳淡出，避免与左圆高亮竞争
            activeIndicatorPill(width: pillWidth, height: innerHeight)
                .position(x: displayCenterX, y: targetHeight * 0.5)
                .opacity(showActivePill ? 1 : 0)
                .scaleEffect(showActivePill ? 1 : 0.72)
                .animation(
                    isCollapsedToCircle
                        ? .easeOut(duration: 0.11)
                        : .easeOut(duration: 0.16),
                    value: showActivePill
                )
                .allowsHitTesting(false)

            // 主浏览槽位：遵循 iOS 27 悬浮胶囊对齐标准（定高 24×22 图标框 + 定高 13pt 圆体文字行，收缩单圆时平滑隐去文字）
            ForEach(Array(items.enumerated()), id: \.element.id) { slotIndex, item in
                let isPrimarySlot = (slotIndex == effectiveSlot)
                let isSelected = (activeHighlightSlot == slotIndex)
                let isPrimaryInCircle = isCollapsedToCircle && (selectedTab == item.id)
                let isHighlight = isCollapsedToCircle ? isPrimaryInCircle : isSelected
                let isPressingInactive = (!isCollapsedToCircle && !isDraggingPill && pressedSlot == slotIndex && selectedSlot != slotIndex)
                let expandedCenterX = FloatingTabBarSliderMath.slotCenterX(
                    index: slotIndex,
                    barWidth: activeBarWidth,
                    count: items.count
                )
                let itemCenterX: CGFloat = (isCollapsedToCircle && isPrimarySlot)
                    ? targetHeight * 0.5
                    : expandedCenterX
                let isSlotVisible = !isCollapsedToCircle || isPrimarySlot

                VStack(spacing: isCollapsedToCircle ? 0 : (isCompactHeight ? 1.5 : 2.5)) {
                    tabGlyphIcon(item: item, isHighlight: isHighlight)
                        .overlay(alignment: .topTrailing) {
                            if item.id == 3 && settingsBadgeCount > 0 {
                                Circle()
                                    .fill(MyGoTheme.accent)
                                    .frame(width: 7, height: 7)
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                colorScheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.9),
                                                lineWidth: 1
                                            )
                                    )
                                    .offset(x: 3, y: -3)
                            }
                        }

                    if !isCollapsedToCircle {
                        Text(I18n.t(item.titleKey))
                            .font(.system(
                                size: FloatingTabBarMetrics.labelFontSize,
                                weight: isHighlight ? .semibold : .medium,
                                design: .rounded
                            ))
                            .tracking(-0.1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(height: 13, alignment: .center)
                    }
                }
                .frame(width: pillWidth, height: fullBarHeight, alignment: .center)
                .foregroundStyle(foregroundColor(isSelected: isHighlight))
                .opacity(isPressingInactive ? 0.72 : 1.0)
                .geometryGroup()
                .opacity(isSlotVisible ? 1 : 0)
                .animation(
                    isCollapsedToCircle
                        ? .easeOut(duration: 0.075)
                        : .easeOut(duration: 0.16).delay(0.05),
                    value: isSlotVisible
                )
                .position(x: itemCenterX, y: targetHeight * 0.5)
                .contentShape(Rectangle())
                .allowsHitTesting(!isCollapsedToCircle)
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
        .frame(width: targetWidth, height: targetHeight)
        .mygoLiquidGlass(in: Capsule(style: .continuous), isHighlighted: isCollapsedToCircle && selectedSlot != nil)
        .geometryGroup()
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
        .onChange(of: selectedTab) { _, newTab in
            triggerTabIconAnimation(for: newTab)
        }
        .sensoryFeedback(.selection, trigger: hapticCount)
    }

    @ViewBuilder
    private func tabGlyphIcon(item: MainTabItem, isHighlight: Bool) -> some View {
        let tilt = tabTiltDegrees[item.id] ?? 0
        Group {
            if item.id == 2 {
                v5LibraryTabIcon(isHighlight: isHighlight)
            } else {
                Image(systemName: isHighlight ? item.selectedIcon : item.icon)
                    .font(.system(
                        size: 20.0,
                        weight: isHighlight ? .semibold : .medium
                    ))
                    .symbolRenderingMode(.monochrome)
            }
        }
        .frame(width: 24, height: 22.5, alignment: .center)
        .rotationEffect(.degrees(tilt))
    }

    @ViewBuilder
    private func v5LibraryTabIcon(isHighlight: Bool) -> some View {
        VStack(spacing: 1.4) {
            Capsule(style: .continuous)
                .fill(.foreground.opacity(isHighlight ? 0.68 : 0.55))
                .frame(width: 11.0, height: 1.55)
            Capsule(style: .continuous)
                .fill(.foreground.opacity(isHighlight ? 0.92 : 0.80))
                .frame(width: 15.0, height: 1.65)

            ZStack {
                if isHighlight {
                    RoundedRectangle(cornerRadius: 4.8, style: .continuous)
                        .fill(.foreground)
                    Image(systemName: "music.note")
                        .font(.system(size: 10.4, weight: .bold))
                        .blendMode(.destinationOut)
                } else {
                    RoundedRectangle(cornerRadius: 4.8, style: .continuous)
                        .strokeBorder(.foreground, lineWidth: 1.75)
                    Image(systemName: "music.note")
                        .font(.system(size: 9.8, weight: .semibold))
                }
            }
            .compositingGroup()
            .frame(width: 18.5, height: 16.2)
        }
        .frame(width: 21.5, height: 21.5, alignment: .center)
    }

    private func triggerTabIconAnimation(for tabID: Int) {
        guard MainTabMapping.slotIndex(for: tabID) != nil, !reduceMotion else { return }
        withAnimation(.spring(response: 0.16, dampingFraction: 0.52)) {
            tabTiltDegrees[tabID] = -8.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.54)) {
                tabTiltDegrees[tabID] = 4.5
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.68)) {
                tabTiltDegrees[tabID] = 0
            }
        }
    }

    private func activeIndicatorPill(width: CGFloat, height: CGFloat) -> some View {
        LiquidGlassSelectionBubble(
            shape: Capsule(style: .continuous),
            isEmphasized: isDraggingPill
        )
        .frame(width: max(40, width), height: height)
        .scaleEffect(x: isDraggingPill ? 1.07 : 1.0, y: isDraggingPill ? 1.11 : 1.0)
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
            .opacity(configuration.isPressed ? 0.78 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct SearchCircleButton: View {
    let isSelected: Bool
    let size: CGFloat
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchTiltDegrees: Double = 0

    var body: some View {
        Button {
            triggerTiltAnimation()
            onTap()
        } label: {
            ZStack {
                if isSelected {
                    LiquidGlassSelectionBubble(shape: Circle())
                        .padding(FloatingTabBarMetrics.outerInset)
                }

                Image(systemName: "magnifyingglass")
                    .font(.system(
                        size: 20.5,
                        weight: isSelected ? .semibold : .medium
                    ))
                    .symbolRenderingMode(.monochrome)
                    .frame(width: 24, height: 24, alignment: .center)
                    .rotationEffect(.degrees(searchTiltDegrees))
                    .foregroundStyle(
                        isSelected
                            ? MyGoTheme.accent
                            : (colorScheme == .dark ? Color.white.opacity(0.88) : Color(white: 0.14))
                    )
            }
            .frame(width: size, height: size)
            .mygoLiquidGlass(in: Circle(), isHighlighted: isSelected)
            .geometryGroup()
        }
        .buttonStyle(ScalePressButtonStyle())
        .onChange(of: isSelected) { _, selected in
            if selected {
                triggerTiltAnimation()
            }
        }
        .accessibilityLabel(I18n.t("Search"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    private func triggerTiltAnimation() {
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.16, dampingFraction: 0.52)) {
            searchTiltDegrees = -8.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.54)) {
                searchTiltDegrees = 4.5
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.68)) {
                searchTiltDegrees = 0
            }
        }
    }
}

private struct AdaptiveFloatingBottomChrome: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var scrollCoordinator: TabBarScrollCoordinator
    @ObservedObject var tabStore: MainTabSelectionStore
    let onSelectTab: (Int) -> Void
    let onExpandFromCircle: () -> Void
    let onSearchTap: () -> Void

    @State private var measuredWidth: CGFloat = 360

    var body: some View {
        let selectedTab = tabStore.selectedTab
        let lastPrimaryTab = tabStore.lastPrimaryTab
        let isMinimized = scrollCoordinator.isMinimized
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
        let fullExpandedTabWidth = max(
            160,
            measuredWidth - FloatingTabBarMetrics.splitSpacing - FloatingTabBarMetrics.barHeight
        )
        let tabWidth = isCompactRow ? rowHeight : fullExpandedTabWidth
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
                HStack(alignment: .bottom, spacing: 0) {
                    PrimaryTabsCapsuleBar(
                        selectedTab: $tabStore.selectedTab,
                        lastPrimaryTab: lastPrimaryTab,
                        isCompactHeight: isCompactWithoutTrack,
                        isCollapsedToCircle: isCompactRow,
                        expandedWidth: fullExpandedTabWidth,
                        targetWidth: tabWidth,
                        targetHeight: rowHeight,
                        settingsBadgeCount: app.availablePluginUpdateCount,
                        onSelect: onSelectTab,
                        onExpandFromCircle: onExpandFromCircle
                    )

                    Spacer(minLength: 0)

                    SearchCircleButton(
                        isSelected: selectedTab == MainTabMapping.searchTabID,
                        size: searchSize,
                        onTap: onSearchTap
                    )
                }
                .frame(width: measuredWidth, height: rowHeight, alignment: .bottom)

                if hasTrack {
                    MiniPlayerBarView(
                        isCompact: isCompactRow,
                        isScrollPaused: false
                    )
                    .frame(width: miniWidth, height: miniHeight)
                    .geometryGroup()
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

private struct AddToPlaylistSheetView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let track: Track

    var body: some View {
        let playlists = app.myPlaylists.filter { $0.fixed != true }
        NavigationStack {
            List {
                SwiftUI.Section {
                    HStack(spacing: 12) {
                        ArtworkView(
                            urlString: track.album.imageUrl,
                            pixelSize: 120,
                            size: 44,
                            cornerRadius: 8
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.name)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                            Text(track.artistNames)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }

                SwiftUI.Section(I18n.t("Add to Playlist")) {
                    if playlists.isEmpty {
                        Text(I18n.t("Nothing here yet"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(playlists) { pl in
                            Button {
                                dismiss()
                                Task { await app.addTrack(track, toPlaylist: pl.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(
                                        urlString: pl.imageUrl,
                                        pixelSize: 120,
                                        size: 38,
                                        cornerRadius: 8,
                                        systemIcon: "music.note.list"
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pl.name)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(.primary)
                                        if let count = pl.trackCount {
                                            Text(I18n.songs(count))
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(I18n.t("Add to Playlist"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(I18n.t("Cancel")) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 非响应式迷你播放条坐标存储器：底栏收起/展开形变期间静默更新物理落点，不触发 MainView 或各页 Tab 的任何 SwiftUI 刷新
@MainActor
private final class MiniPlayerGeometryStore: ObservableObject {
    var barFrame: CGRect = .zero
    var artworkFrame: CGRect = .zero
}

#if os(iOS)
/// 硬件级 120Hz 「播放页 ↔ 迷你条」真同源双层分离式 UIKit 交互缩放转场宿主
private struct NowPlayingOverlayHost: View {
    @ObservedObject var app: AppModel
    let geometryStore: MiniPlayerGeometryStore
    let headersProvider: @MainActor (URL) -> [String: String]

    var body: some View {
        NowPlayingModalContainer(
            app: app,
            isPresented: $app.isNowPlayingPresented,
            geometryStore: geometryStore,
            headersProvider: headersProvider
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct NowPlayingModalContainer: UIViewRepresentable {
    @ObservedObject var app: AppModel
    @Binding var isPresented: Bool
    let geometryStore: MiniPlayerGeometryStore
    let headersProvider: @MainActor (URL) -> [String: String]

    final class BridgeAnchorView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attachToWindow(window)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> BridgeAnchorView {
        let anchor = BridgeAnchorView(frame: .zero)
        anchor.isHidden = true
        anchor.isUserInteractionEnabled = false
        anchor.coordinator = context.coordinator
        context.coordinator.anchorView = anchor
        return anchor
    }

    func updateUIView(_ uiView: BridgeAnchorView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.geometryStore = geometryStore
        context.coordinator.attachToWindow(uiView.window)
        context.coordinator.syncPresentation(to: isPresented)
    }

    static func dismantleUIView(_ uiView: BridgeAnchorView, coordinator: Coordinator) {
        coordinator.detachFromWindow()
    }

    final class NowPlayingPassthroughView: UIView {
        weak var hostController: NowPlayingHostController?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let host = hostController,
                  host.coordinator?.isInteractiveForHitTesting == true,
                  !isHidden,
                  isUserInteractionEnabled,
                  alpha > 0.01 else {
                return nil
            }
            return super.hitTest(point, with: event)
        }
    }

    final class SolidBackdropGradientView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
        var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

        func applyTint(_ tint: BackdropRGBColor) {
            let pair = BackdropFogMath.backdropColors(from: tint)
            let topColor = UIColor(
                red: CGFloat(pair.top.r * 0.94),
                green: CGFloat(pair.top.g * 0.94),
                blue: CGFloat(pair.top.b * 0.94),
                alpha: 1.0
            )
            let midColor = UIColor(
                red: CGFloat((pair.top.r + pair.foot.r) * 0.5 * 0.90),
                green: CGFloat((pair.top.g + pair.foot.g) * 0.5 * 0.90),
                blue: CGFloat((pair.top.b + pair.foot.b) * 0.5 * 0.90),
                alpha: 1.0
            )
            let footColor = UIColor(
                red: CGFloat(pair.foot.r * 0.74),
                green: CGFloat(pair.foot.g * 0.74),
                blue: CGFloat(pair.foot.b * 0.74),
                alpha: 1.0
            )
            gradientLayer.colors = [topColor.cgColor, midColor.cgColor, footColor.cgColor]
            gradientLayer.locations = [0.0, 0.45, 1.0]
            gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
            gradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        }
    }

    final class NowPlayingHostController: UIViewController {
        weak var coordinator: Coordinator?
        let backdropView = UIView()
        let cardShadowView = UIView()
        let cardClipView = UIView()
        /// 全程 100% 不透明的专辑主色调渐变底卡（在拖拽与退场期间彻底隔绝背后列表与导航栏穿透）
        let cardSolidBackdropView = SolidBackdropGradientView()
        /// 退场后半段承接层：将专辑主色平滑过渡至与迷你条一致的高遮蔽实体胶囊底色
        let cardSolidCapsuleTintView = UIView()
        let cardGlassView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        let morphingMiniHeaderView = UIView()
        let morphingMiniArtworkView = UIImageView()
        let morphingMiniPlaceholderIcon = UIImageView()
        let morphingMiniTitleLabel = UILabel()
        let morphingMiniSubtitleLabel = UILabel()
        let morphingMiniPlayPauseIcon = UIImageView()
        let morphingMiniNextIcon = UIImageView()
        /// 独立浮在 cardClipView 之上的实心实体专辑封面图层（直接执行 Apple Music 式从大到小缩融飞越，杜绝双影与裁切）
        let floatingHeroShadowView = UIView()
        let floatingHeroClipView = UIView()
        let floatingHeroArtworkView = UIImageView()
        let floatingHeroPlaceholderIcon = UIImageView()
        private var morphingMiniHeightConstraint: NSLayoutConstraint?
        private var lastLaidOutBounds: CGRect = .zero

        override func loadView() {
            let passthrough = NowPlayingPassthroughView()
            passthrough.hostController = self
            passthrough.backgroundColor = .clear
            self.view = passthrough
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear

            backdropView.frame = view.bounds
            backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            backdropView.backgroundColor = .black
            backdropView.alpha = 0
            backdropView.isUserInteractionEnabled = false
            view.addSubview(backdropView)

            cardShadowView.frame = view.bounds
            cardShadowView.backgroundColor = .clear
            cardShadowView.isUserInteractionEnabled = false
            cardShadowView.layer.cornerCurve = .continuous
            cardShadowView.layer.shadowColor = UIColor.black.cgColor
            cardShadowView.layer.shadowOpacity = 0.0
            cardShadowView.layer.shadowRadius = 22
            cardShadowView.layer.shadowOffset = CGSize(width: 0, height: 10)
            view.addSubview(cardShadowView)

            cardClipView.frame = view.bounds
            cardClipView.clipsToBounds = true
            cardClipView.layer.cornerCurve = .continuous
            cardClipView.backgroundColor = .clear
            view.addSubview(cardClipView)

            cardSolidBackdropView.frame = cardClipView.bounds
            cardSolidBackdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cardSolidBackdropView.alpha = 0
            cardSolidBackdropView.isUserInteractionEnabled = false
            cardSolidBackdropView.applyTint(.defaultTint)
            cardClipView.addSubview(cardSolidBackdropView)

            cardSolidCapsuleTintView.frame = cardClipView.bounds
            cardSolidCapsuleTintView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cardSolidCapsuleTintView.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.095, green: 0.095, blue: 0.115, alpha: 0.96)
                    : UIColor(white: 0.96, alpha: 0.94)
            }
            cardSolidCapsuleTintView.alpha = 0
            cardSolidCapsuleTintView.isUserInteractionEnabled = false
            cardClipView.addSubview(cardSolidCapsuleTintView)

            // 自适应深浅外观的液态磨砂玻璃底板：颜色对齐 MiniPlayerBarView 的 LiquidGlassSurfaceModifier 消除交棒色差
            cardGlassView.frame = cardClipView.bounds
            cardGlassView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cardGlassView.contentView.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.085, green: 0.085, blue: 0.105, alpha: 0.56)
                    : UIColor(white: 0.955, alpha: 0.48)
            }
            cardGlassView.alpha = 0
            cardGlassView.isUserInteractionEnabled = false
            cardClipView.addSubview(cardGlassView)

            // 锚定在收缩卡片顶部内沿的「音乐播放导航栏」承接层（对标 Apple Music 卡片上沿渐显）
            morphingMiniHeaderView.translatesAutoresizingMaskIntoConstraints = false
            morphingMiniHeaderView.alpha = 0
            morphingMiniHeaderView.isUserInteractionEnabled = false
            cardClipView.addSubview(morphingMiniHeaderView)

            let miniHeightConstraint = morphingMiniHeaderView.heightAnchor.constraint(equalToConstant: 58)
            morphingMiniHeightConstraint = miniHeightConstraint
            NSLayoutConstraint.activate([
                morphingMiniHeaderView.topAnchor.constraint(equalTo: cardClipView.topAnchor),
                morphingMiniHeaderView.leadingAnchor.constraint(equalTo: cardClipView.leadingAnchor),
                morphingMiniHeaderView.trailingAnchor.constraint(equalTo: cardClipView.trailingAnchor),
                miniHeightConstraint
            ])

            morphingMiniArtworkView.translatesAutoresizingMaskIntoConstraints = false
            morphingMiniArtworkView.contentMode = .scaleAspectFill
            morphingMiniArtworkView.clipsToBounds = true
            morphingMiniArtworkView.layer.cornerRadius = 9.5
            morphingMiniArtworkView.layer.cornerCurve = .continuous
            morphingMiniArtworkView.backgroundColor = UIColor.secondarySystemFill
            morphingMiniHeaderView.addSubview(morphingMiniArtworkView)

            morphingMiniPlaceholderIcon.image = UIImage(systemName: "music.note")
            morphingMiniPlaceholderIcon.tintColor = .secondaryLabel
            morphingMiniPlaceholderIcon.contentMode = .scaleAspectFit
            morphingMiniPlaceholderIcon.translatesAutoresizingMaskIntoConstraints = false
            morphingMiniArtworkView.addSubview(morphingMiniPlaceholderIcon)

            let textStack = UIStackView(arrangedSubviews: [morphingMiniTitleLabel, morphingMiniSubtitleLabel])
            textStack.axis = .vertical
            textStack.spacing = 1.5
            textStack.translatesAutoresizingMaskIntoConstraints = false
            morphingMiniHeaderView.addSubview(textStack)

            morphingMiniTitleLabel.font = .systemFont(ofSize: 14.5, weight: .semibold)
            morphingMiniTitleLabel.textColor = .label
            morphingMiniTitleLabel.lineBreakMode = .byTruncatingTail

            morphingMiniSubtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
            morphingMiniSubtitleLabel.textColor = .secondaryLabel
            morphingMiniSubtitleLabel.lineBreakMode = .byTruncatingTail

            morphingMiniPlayPauseIcon.contentMode = .center
            morphingMiniPlayPauseIcon.tintColor = .label
            morphingMiniPlayPauseIcon.translatesAutoresizingMaskIntoConstraints = false
            morphingMiniHeaderView.addSubview(morphingMiniPlayPauseIcon)

            morphingMiniNextIcon.image = UIImage(
                systemName: "forward.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            )
            morphingMiniNextIcon.contentMode = .center
            morphingMiniNextIcon.tintColor = .label
            morphingMiniNextIcon.translatesAutoresizingMaskIntoConstraints = false
            morphingMiniHeaderView.addSubview(morphingMiniNextIcon)

            NSLayoutConstraint.activate([
                morphingMiniArtworkView.leadingAnchor.constraint(equalTo: morphingMiniHeaderView.leadingAnchor, constant: 9),
                morphingMiniArtworkView.centerYAnchor.constraint(equalTo: morphingMiniHeaderView.centerYAnchor),
                morphingMiniArtworkView.widthAnchor.constraint(equalToConstant: 38),
                morphingMiniArtworkView.heightAnchor.constraint(equalToConstant: 38),

                morphingMiniPlaceholderIcon.centerXAnchor.constraint(equalTo: morphingMiniArtworkView.centerXAnchor),
                morphingMiniPlaceholderIcon.centerYAnchor.constraint(equalTo: morphingMiniArtworkView.centerYAnchor),
                morphingMiniPlaceholderIcon.widthAnchor.constraint(equalToConstant: 16),
                morphingMiniPlaceholderIcon.heightAnchor.constraint(equalToConstant: 16),

                textStack.leadingAnchor.constraint(equalTo: morphingMiniArtworkView.trailingAnchor, constant: 10),
                textStack.centerYAnchor.constraint(equalTo: morphingMiniHeaderView.centerYAnchor),
                textStack.trailingAnchor.constraint(lessThanOrEqualTo: morphingMiniPlayPauseIcon.leadingAnchor, constant: -8),

                morphingMiniPlayPauseIcon.centerYAnchor.constraint(equalTo: morphingMiniHeaderView.centerYAnchor),
                morphingMiniPlayPauseIcon.widthAnchor.constraint(equalToConstant: 34),
                morphingMiniPlayPauseIcon.heightAnchor.constraint(equalToConstant: 34),
                morphingMiniPlayPauseIcon.trailingAnchor.constraint(equalTo: morphingMiniNextIcon.leadingAnchor, constant: -4),

                morphingMiniNextIcon.centerYAnchor.constraint(equalTo: morphingMiniHeaderView.centerYAnchor),
                morphingMiniNextIcon.widthAnchor.constraint(equalToConstant: 34),
                morphingMiniNextIcon.heightAnchor.constraint(equalToConstant: 34),
                morphingMiniNextIcon.trailingAnchor.constraint(equalTo: morphingMiniHeaderView.trailingAnchor, constant: -10)
            ])

            if let coordinator {
                coordinator.attachPanGesture(to: cardClipView)
            }

            // 独立实心专辑封面飞越层：挂载在 host.view 最顶层，突破胶囊下沿物理裁切以还原 Apple Music“先沉底再由下向上回弹归槽”
            floatingHeroShadowView.backgroundColor = .clear
            floatingHeroShadowView.isUserInteractionEnabled = false
            floatingHeroShadowView.isHidden = true
            floatingHeroShadowView.alpha = 0
            floatingHeroShadowView.layer.cornerCurve = .continuous
            floatingHeroShadowView.layer.shadowColor = UIColor.black.cgColor
            floatingHeroShadowView.layer.shadowOpacity = 0.0
            floatingHeroShadowView.layer.shadowRadius = 18
            floatingHeroShadowView.layer.shadowOffset = CGSize(width: 0, height: 10)
            view.addSubview(floatingHeroShadowView)

            floatingHeroClipView.clipsToBounds = true
            floatingHeroClipView.isUserInteractionEnabled = false
            floatingHeroClipView.layer.cornerCurve = .continuous
            floatingHeroClipView.backgroundColor = UIColor.secondarySystemFill
            floatingHeroShadowView.addSubview(floatingHeroClipView)

            floatingHeroArtworkView.contentMode = .scaleAspectFill
            floatingHeroArtworkView.clipsToBounds = true
            floatingHeroClipView.addSubview(floatingHeroArtworkView)

            floatingHeroPlaceholderIcon.image = UIImage(systemName: "music.note")
            floatingHeroPlaceholderIcon.tintColor = .secondaryLabel
            floatingHeroPlaceholderIcon.contentMode = .scaleAspectFit
            floatingHeroClipView.addSubview(floatingHeroPlaceholderIcon)
        }

        func setMorphingMiniHeaderHeight(_ height: CGFloat) {
            let clamped = max(48, height)
            if abs((morphingMiniHeightConstraint?.constant ?? 0) - clamped) > 0.5 {
                morphingMiniHeightConstraint?.constant = clamped
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            guard view.bounds != lastLaidOutBounds, view.bounds.width > 0, view.bounds.height > 0 else { return }
            lastLaidOutBounds = view.bounds
            coordinator?.handleContainerBoundsChanged()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: NowPlayingModalContainer
        weak var anchorView: BridgeAnchorView?
        var hostController: NowPlayingHostController?
        var hostingController: UIHostingController<AnyView>?
        let modalBridge = NowPlayingModalBridge()
        weak var geometryStore: MiniPlayerGeometryStore?
        var canInteractiveDismiss: Bool = true

        private var currentlyPresented: Bool = false
        private var isTransitioning: Bool = false
        var isInteractiveForHitTesting: Bool {
            currentlyPresented
        }
        private var activeProgress: CGFloat = 1.0
        private var activeDragOffsetX: CGFloat = 0
        private var transitionEpoch: Int = 0
        private var lockedHeroSnapshot: NowPlayingHeroArtworkSnapshot? = nil
        private var cachedCoverHeroRect: CGRect? = nil
        private weak var trackingScrollView: UIScrollView?
        private var demoDismissObserver: NSObjectProtocol?
        private var demoLyricsObserver: NSObjectProtocol?

        init(parent: NowPlayingModalContainer) {
            self.parent = parent
            super.init()
            #if DEBUG
            demoDismissObserver = NotificationCenter.default.addObserver(
                forName: .mygoDebugDemoDismissMorph,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.runDebugMorphDemo()
                }
            }
            demoLyricsObserver = NotificationCenter.default.addObserver(
                forName: .mygoDebugDemoLyricsMorph,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.runDebugLyricsDemo()
                }
            }
            #endif
        }

        deinit {
            if let demoDismissObserver {
                NotificationCenter.default.removeObserver(demoDismissObserver)
            }
            if let demoLyricsObserver {
                NotificationCenter.default.removeObserver(demoLyricsObserver)
            }
        }

        func attachPanGesture(to targetView: UIView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = false
            targetView.addGestureRecognizer(pan)
        }

        func handleContainerBoundsChanged() {
            guard let host = hostController,
                  host.view.bounds.width > 0 else { return }
            if currentlyPresented && hostingController == nil {
                ensureHostingMounted()
            }
            guard let hostingView = hostingController?.view else { return }
            if !isTransitioning {
                hostingView.transform = .identity
                hostingView.bounds = CGRect(origin: .zero, size: host.view.bounds.size)
                applyDragGeometry(progress: currentlyPresented ? 0.0 : 1.0, dragOffsetX: 0)
            }
        }

        func attachToWindow(_ window: UIWindow?) {
            guard let rootVC = window?.rootViewController else { return }
            let host: NowPlayingHostController
            if let existing = hostController {
                host = existing
            } else {
                let created = NowPlayingHostController()
                created.coordinator = self
                created.view.isHidden = !currentlyPresented && !isTransitioning
                created.view.isUserInteractionEnabled = currentlyPresented
                hostController = created
                host = created
            }
            if host.parent !== rootVC {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()

                rootVC.addChild(host)
                host.view.frame = rootVC.view.bounds
                host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                rootVC.view.addSubview(host.view)
                host.didMove(toParent: rootVC)
            } else if host.view.superview === rootVC.view {
                if host.view.frame != rootVC.view.bounds {
                    host.view.frame = rootVC.view.bounds
                }
                if currentlyPresented || isTransitioning {
                    rootVC.view.bringSubviewToFront(host.view)
                }
            }
        }

        func detachFromWindow() {
            if let host = hostController {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
            }
            hostController = nil
        }

        func syncPresentation(to presented: Bool) {
            if hostController == nil {
                attachToWindow(anchorView?.window)
            }
            guard presented != currentlyPresented else { return }
            currentlyPresented = presented
            if presented {
                animateExpandFromMiniBar()
            } else {
                animateCollapseToMiniBar(initialVelocity: 0.6)
            }
        }

        private func ensureHostingMounted() {
            guard let host = hostController else { return }
            let boundsSize = host.view.bounds.size
            guard boundsSize.width > 0, boundsSize.height > 0 else { return }

            if hostingController == nil {
                let dismissAction: () -> Void = { [weak self] in
                    self?.dismissFromButtonOrSwipe()
                }
                let canDismissCallback: (Bool) -> Void = { [weak self] allowed in
                    self?.canInteractiveDismiss = allowed
                }
                modalBridge.onRequestDismiss = dismissAction
                let root = AnyView(
                    NowPlayingView()
                        .environmentObject(parent.app)
                        .environment(\.mygoImageHeadersProvider, parent.headersProvider)
                        .environment(\.mygoNowPlayingModalBridge, modalBridge)
                        .environment(\.mygoDismissNowPlaying, dismissAction)
                        .environment(\.mygoOnNowPlayingCanDismissChanged, canDismissCallback)
                )
                let hc = UIHostingController(rootView: root)
                hc.view.backgroundColor = .clear
                host.addChild(hc)
                hc.view.transform = .identity
                hc.view.bounds = CGRect(origin: .zero, size: boundsSize)
                hc.view.center = CGPoint(x: boundsSize.width / 2, y: boundsSize.height / 2)
                host.cardClipView.insertSubview(hc.view, aboveSubview: host.cardGlassView)
                host.cardClipView.bringSubviewToFront(host.morphingMiniHeaderView)
                host.view.bringSubviewToFront(host.floatingHeroShadowView)
                hc.didMove(toParent: host)
                hc.view.setNeedsLayout()
                hc.view.layoutIfNeeded()
                hostingController = hc
            } else if let hc = hostingController {
                hc.view.transform = .identity
                hc.view.bounds = CGRect(origin: .zero, size: boundsSize)
                hc.view.layoutIfNeeded()
                host.cardClipView.bringSubviewToFront(host.morphingMiniHeaderView)
                host.view.bringSubviewToFront(host.floatingHeroShadowView)
            }
        }

        private func unmountHostingIfHidden() {
            guard !currentlyPresented, !isTransitioning else { return }
            // 先保持冻结并完整拆除 hostingController，绝不在缩微期提前解冻触发 SwiftUI 写入 y<0 脏快照
            modalBridge.freezeHeroSnapshotUpdates = true
            if let hc = hostingController {
                hc.willMove(toParent: nil)
                hc.view.removeFromSuperview()
                hc.removeFromParent()
                hostingController = nil
            }
            modalBridge.hideInnerHeroArtwork = false
            lockedHeroSnapshot = nil
            hostController?.cardShadowView.layer.shadowOpacity = 0
            hostController?.cardClipView.alpha = 1.0
            hostController?.morphingMiniHeaderView.transform = .identity
            hostController?.morphingMiniHeaderView.alpha = 0
            hostController?.cardGlassView.alpha = 0
            hostController?.cardSolidCapsuleTintView.alpha = 0
            hostController?.cardSolidBackdropView.alpha = 0
            hostController?.floatingHeroShadowView.transform = .identity
            hostController?.floatingHeroShadowView.alpha = 0
            hostController?.floatingHeroShadowView.isHidden = true
            hostController?.view.isHidden = true
            hostController?.view.isUserInteractionEnabled = false
        }

        private func resolvedTargetBarRect(in container: UIView) -> CGRect {
            let b = container.bounds
            let recorded = geometryStore?.barFrame ?? .zero
            if recorded.width > 40 && recorded.height > 24 {
                return container.window != nil ? container.convert(recorded, from: nil) : recorded
            }
            let w = max(240, b.width - 44)
            return CGRect(x: (b.width - w) / 2, y: b.height - 140, width: w, height: 56)
        }

        /// 计算 cardClipView 本地坐标系左端 38×38 迷你封面的精确矩形（与 MiniPlayerBarView 零像素对齐）
        private func localMiniArtworkSlotRect(barHeight: CGFloat) -> CGRect {
            let effectiveH = max(48, barHeight)
            return CGRect(
                x: 9.0,
                y: (effectiveH - 38.0) * 0.5,
                width: 38.0,
                height: 38.0
            )
        }

        /// 计算 host.view 全局坐标系下迷你条左端 38×38 迷你封面的精确矩形
        private func globalMiniArtworkSlotRect(forBarRect barRect: CGRect) -> CGRect {
            let localSlot = localMiniArtworkSlotRect(barHeight: barRect.height)
            return CGRect(
                x: barRect.minX + localSlot.minX,
                y: barRect.minY + localSlot.minY,
                width: localSlot.width,
                height: localSlot.height
            )
        }

        private func isValidCoverHeroRect(_ rect: CGRect, baseSide: CGFloat, in bounds: CGRect) -> Bool {
            abs(rect.width - baseSide) < 8.0
                && abs(rect.midX - bounds.midX) < 8.0
                && rect.minY >= 36
                && rect.minY <= bounds.height * 0.28
        }

        private func isValidLyricsHeroRect(_ rect: CGRect, in bounds: CGRect, safeTop: CGFloat) -> Bool {
            rect.width >= 76
                && rect.width <= 106
                && rect.minY >= max(36, safeTop)
                && rect.minY <= bounds.height * 0.28
                && rect.minX >= 10
                && rect.minX <= 80
        }

        /// 将全局快照转为 host.view 本地坐标并严格校验边界；任何缩放态或越界脏快照一律丢弃并回退精确数学基准坐标
        private func resolvedExpandedHeroSnapshot(in host: NowPlayingHostController, allowLiveSnapshot: Bool = true) -> NowPlayingHeroArtworkSnapshot {
            let bounds = host.view.bounds
            let safeTop = max(host.view.safeAreaInsets.top, host.view.window?.safeAreaInsets.top ?? 0)
            let h = max(667, bounds.height)
            let baseSide = max(210, min(bounds.width - 36, round(h * 0.419)))
            let x = (bounds.width - baseSide) * 0.5
            let gapTop = round(h * 0.021)
            let formulaCoverRect = CGRect(x: x, y: safeTop + 16 + gapTop, width: baseSide, height: baseSide)
            let formulaLyricsRect = CGRect(x: 22, y: safeTop + 63, width: 96, height: 96)
            let pane = parent.app.activeNowPlayingPane

            if allowLiveSnapshot {
                let snap = modalBridge.currentHeroSnapshot
                if snap.isVisibleInCurrentPane, snap.globalRect.width > 12, snap.globalRect.height > 12 {
                    let localRect = host.view.window != nil
                        ? host.view.convert(snap.globalRect, from: nil)
                        : snap.globalRect
                    if pane == .cover, isValidCoverHeroRect(localRect, baseSide: baseSide, in: bounds) {
                        cachedCoverHeroRect = localRect
                        return NowPlayingHeroArtworkSnapshot(
                            globalRect: localRect,
                            cornerRadius: snap.cornerRadius,
                            isVisibleInCurrentPane: true
                        )
                    } else if pane == .lyrics, isValidLyricsHeroRect(localRect, in: bounds, safeTop: safeTop) {
                        return NowPlayingHeroArtworkSnapshot(
                            globalRect: localRect,
                            cornerRadius: snap.cornerRadius,
                            isVisibleInCurrentPane: true
                        )
                    }
                }
            }
            if pane == .cover, let cached = cachedCoverHeroRect, isValidCoverHeroRect(cached, baseSide: baseSide, in: bounds) {
                return NowPlayingHeroArtworkSnapshot(
                    globalRect: cached,
                    cornerRadius: 12,
                    isVisibleInCurrentPane: true
                )
            }
            if pane == .lyrics {
                return NowPlayingHeroArtworkSnapshot(
                    globalRect: formulaLyricsRect,
                    cornerRadius: 16,
                    isVisibleInCurrentPane: true
                )
            }
            return NowPlayingHeroArtworkSnapshot(
                globalRect: formulaCoverRect,
                cornerRadius: 12,
                isVisibleInCurrentPane: pane == .cover
            )
        }

        private func refreshMorphingMiniBarContent(in host: NowPlayingHostController, barHeight: CGFloat, hideMiniArtwork: Bool) {
            let track = parent.app.player.currentTrack
            let thumbImg = ArtworkImageLoader.cachedPlatformImage(rawURLString: track?.album.imageUrl, pixelSize: 160)
                ?? ArtworkImageLoader.cachedPlatformImage(rawURLString: track?.album.imageUrl, pixelSize: 960)
            let heroImg = ArtworkImageLoader.cachedPlatformImage(rawURLString: track?.album.imageUrl, pixelSize: 960)
                ?? thumbImg

            host.morphingMiniArtworkView.image = thumbImg
            host.morphingMiniArtworkView.alpha = hideMiniArtwork ? 0.0 : 1.0
            host.morphingMiniPlaceholderIcon.isHidden = (thumbImg != nil)

            host.floatingHeroArtworkView.image = heroImg
            host.floatingHeroPlaceholderIcon.isHidden = (heroImg != nil)

            host.morphingMiniTitleLabel.text = track?.name ?? ""
            host.morphingMiniSubtitleLabel.text = track?.artistNames ?? ""
            let symbolName = parent.app.player.isPlaying ? "pause.fill" : "play.fill"
            host.morphingMiniPlayPauseIcon.image = UIImage(
                systemName: symbolName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.5, weight: .bold)
            )
            host.setMorphingMiniHeaderHeight(barHeight)
        }

        private func syncSolidBackdropColors(in host: NowPlayingHostController) {
            UIView.performWithoutAnimation {
                host.cardSolidBackdropView.applyTint(modalBridge.currentBackdropTint)
            }
        }

        /// 锁定静态基准 bounds，全程仅通过 center + CGAffineTransform 等比缩放移动独立封面，彻底消除父子视图 bounds 过冲甩飞
        private func applyFloatingHeroTransform(
            baseSide: CGFloat,
            toRect rect: CGRect,
            cornerRadius: CGFloat,
            shadowOpacity: Float,
            shadowRadius: CGFloat,
            shadowY: CGFloat,
            in host: NowPlayingHostController
        ) {
            let safeBase = max(24, baseSide)
            let scaleX = max(0.05, rect.width / safeBase)
            let scaleY = max(0.05, rect.height / safeBase)
            let avgScale = (scaleX + scaleY) * 0.5
            let adjustedRadius = cornerRadius / avgScale

            if abs(host.floatingHeroShadowView.bounds.width - safeBase) > 0.5 ||
                abs(host.floatingHeroShadowView.bounds.height - safeBase) > 0.5 {
                UIView.performWithoutAnimation {
                    let fixedBounds = CGRect(x: 0, y: 0, width: safeBase, height: safeBase)
                    host.floatingHeroShadowView.transform = .identity
                    host.floatingHeroShadowView.bounds = fixedBounds
                    host.floatingHeroClipView.frame = fixedBounds
                    host.floatingHeroArtworkView.frame = fixedBounds
                    let iconSide = max(24, min(48, safeBase * 0.22))
                    host.floatingHeroPlaceholderIcon.bounds = CGRect(x: 0, y: 0, width: iconSide, height: iconSide)
                    host.floatingHeroPlaceholderIcon.center = CGPoint(x: safeBase * 0.5, y: safeBase * 0.5)
                }
            }

            host.floatingHeroShadowView.center = CGPoint(x: rect.midX, y: rect.midY)
            host.floatingHeroShadowView.transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
            host.floatingHeroShadowView.layer.cornerRadius = adjustedRadius
            host.floatingHeroShadowView.layer.shadowOpacity = shadowOpacity
            host.floatingHeroShadowView.layer.shadowRadius = shadowRadius / avgScale
            host.floatingHeroShadowView.layer.shadowOffset = CGSize(width: 0, height: shadowY / avgScale)
            host.floatingHeroClipView.layer.cornerRadius = adjustedRadius
        }

        private func applyCardFrameAndRadius(_ rectSize: CGSize, center: CGPoint, cornerRadius: CGFloat, shadowOpacity: Float, borderAlpha: CGFloat, in host: NowPlayingHostController) {
            host.cardClipView.bounds = CGRect(origin: .zero, size: rectSize)
            host.cardClipView.center = center
            host.cardClipView.layer.cornerRadius = cornerRadius
            host.cardClipView.layer.borderWidth = borderAlpha > 0.01 ? 0.65 : 0.0
            let dynamicBorder = UIColor { traits in
                let baseAlpha = traits.userInterfaceStyle == .dark ? borderAlpha * 1.4 : borderAlpha * 4.5
                return UIColor.white.withAlphaComponent(min(0.85, baseAlpha))
            }
            host.cardClipView.layer.borderColor = dynamicBorder.resolvedColor(with: host.traitCollection).cgColor

            host.cardShadowView.bounds = CGRect(origin: .zero, size: rectSize)
            host.cardShadowView.center = center
            host.cardShadowView.layer.cornerRadius = cornerRadius
            host.cardShadowView.layer.shadowOpacity = shadowOpacity
        }

        private func applyDragGeometry(progress p: CGFloat, dragOffsetX: CGFloat) {
            guard let host = hostController else { return }
            let fullBounds = host.view.bounds
            guard fullBounds.width > 0, fullBounds.height > 0 else { return }

            let clamped = max(-0.04, min(1.06, p))
            activeProgress = clamped
            activeDragOffsetX = dragOffsetX

            let norm = max(0, clamped)
            if norm > 0.001 {
                if lockedHeroSnapshot == nil {
                    lockedHeroSnapshot = resolvedExpandedHeroSnapshot(in: host, allowLiveSnapshot: true)
                    syncSolidBackdropColors(in: host)
                }
                modalBridge.freezeHeroSnapshotUpdates = true
            } else {
                lockedHeroSnapshot = nil
                modalBridge.freezeHeroSnapshotUpdates = false
            }

            // 对齐 Apple Music 原生逻辑：全宽抽屉垂直跟手一直拉到底部胶囊位置，仅顶边呈现 40pt 连续圆角，背后列表明亮透出
            let barEnd = resolvedTargetBarRect(in: host.view)
            let maxDropY = max(420.0, barEnd.minY + 12.0)
            let curW = fullBounds.width
            let curH = fullBounds.height
            let curCenterX = fullBounds.midX + dragOffsetX * 0.14
            let topY: CGFloat = clamped >= 0 ? norm * maxDropY : clamped * 220.0
            let curCenterY = topY + curH * 0.5
            let cornerRadius: CGFloat = norm <= 0.001 ? 0 : min(40.0, max(16.0, norm * 160.0))

            let shadowOpacity = Float(min(0.20, norm * 0.38))
            let borderAlpha = min(0.14, norm * 0.22)
            applyCardFrameAndRadius(
                CGSize(width: curW, height: curH),
                center: CGPoint(x: curCenterX, y: curCenterY),
                cornerRadius: cornerRadius,
                shadowOpacity: shadowOpacity,
                borderAlpha: borderAlpha,
                in: host
            )
            host.cardClipView.backgroundColor = .clear
            host.cardClipView.alpha = 1.0

            modalBridge.hideInnerHeroArtwork = false
            host.floatingHeroShadowView.alpha = 0
            host.floatingHeroShadowView.isHidden = true

            if let hostingView = hostingController?.view {
                hostingView.bounds = CGRect(origin: .zero, size: fullBounds.size)
                hostingView.transform = .identity
                hostingView.center = CGPoint(x: curW * 0.5, y: curH * 0.5)
                hostingView.alpha = 1.0
            }

            host.cardSolidBackdropView.alpha = 1.0
            host.cardSolidCapsuleTintView.alpha = 0.0
            host.cardGlassView.alpha = 0.0
            host.morphingMiniHeaderView.alpha = 0.0
            host.backdropView.alpha = max(0, min(0.08, 0.08 * (1.0 - norm)))
        }

        func dismissFromButtonOrSwipe() {
            guard currentlyPresented else { return }
            currentlyPresented = false
            if parent.isPresented {
                parent.isPresented = false
            }
            animateCollapseToMiniBar(initialVelocity: 0.0)
        }

        private func animateExpandFromMiniBar() {
            attachToWindow(anchorView?.window)
            guard let host = hostController else { return }
            if let superview = host.view.superview {
                host.view.frame = superview.bounds
                superview.bringSubviewToFront(host.view)
            }
            transitionEpoch += 1
            let epoch = transitionEpoch

            // 展开前即刻冻结快照回调，确保从迷你条缩微态挂起 SwiftUI 期间零脏数据写入
            modalBridge.freezeHeroSnapshotUpdates = true
            canInteractiveDismiss = true
            trackingScrollView = nil
            lockedHeroSnapshot = nil
            host.view.isHidden = false
            host.view.isUserInteractionEnabled = true
            host.view.layoutIfNeeded()
            ensureHostingMounted()

            let fullBounds = host.view.bounds
            let barStart = resolvedTargetBarRect(in: host.view)
            let slotStartGlobal = globalMiniArtworkSlotRect(forBarRect: barStart)
            let targetHero = resolvedExpandedHeroSnapshot(in: host, allowLiveSnapshot: false)
            let showHeroOnExpand = (parent.app.activeNowPlayingPane == .cover || parent.app.activeNowPlayingPane == .lyrics)
                && targetHero.globalRect.width > 12
            refreshMorphingMiniBarContent(in: host, barHeight: barStart.height, hideMiniArtwork: showHeroOnExpand)
            modalBridge.hideInnerHeroArtwork = showHeroOnExpand

            isTransitioning = true
            NotificationCenter.default.post(name: .mygoMiniPlayerSetTransitionAlpha, object: [0.0, 0.0])

            let heroBaseSide = max(24, targetHero.globalRect.width)
            syncSolidBackdropColors(in: host)

            UIView.performWithoutAnimation {
                host.backdropView.alpha = 0.0
                self.applyCardFrameAndRadius(
                    barStart.size,
                    center: CGPoint(x: barStart.midX, y: barStart.midY),
                    cornerRadius: barStart.height * 0.5,
                    shadowOpacity: 0.22,
                    borderAlpha: 0.14,
                    in: host
                )
                host.cardClipView.backgroundColor = .clear
                host.cardClipView.alpha = 1.0
                host.cardSolidBackdropView.alpha = 1.0
                host.cardSolidCapsuleTintView.alpha = 1.0
                host.cardGlassView.alpha = 0.0
                host.morphingMiniHeaderView.transform = .identity
                host.morphingMiniHeaderView.alpha = 1.0

                if let hostingView = self.hostingController?.view {
                    let s = max(0.84, barStart.width / max(1, fullBounds.width))
                    hostingView.bounds = CGRect(origin: .zero, size: fullBounds.size)
                    hostingView.transform = CGAffineTransform(scaleX: s, y: s)
                    // 顶边对齐 cardClipView 顶部，杜绝负向偏移
                    hostingView.center = CGPoint(x: barStart.width * 0.5, y: (fullBounds.height * s) * 0.5)
                    hostingView.alpha = 0.0
                }

                if showHeroOnExpand {
                    host.view.bringSubviewToFront(host.floatingHeroShadowView)
                    host.floatingHeroShadowView.isHidden = false
                    host.floatingHeroShadowView.alpha = 1.0
                    self.applyFloatingHeroTransform(
                        baseSide: heroBaseSide,
                        toRect: slotStartGlobal,
                        cornerRadius: 9.5,
                        shadowOpacity: 0.16,
                        shadowRadius: 4.0,
                        shadowY: 1.5,
                        in: host
                    )
                } else {
                    host.floatingHeroShadowView.alpha = 0
                    host.floatingHeroShadowView.isHidden = true
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, let host = self.hostController,
                      self.transitionEpoch == epoch, self.currentlyPresented else { return }

                let expandedHero = self.resolvedExpandedHeroSnapshot(in: host, allowLiveSnapshot: false)

                UIView.animate(
                    withDuration: 0.06,
                    delay: 0,
                    options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
                ) {
                    host.morphingMiniHeaderView.alpha = 0.0
                }
                UIView.animate(
                    withDuration: 0.26,
                    delay: 0.03,
                    options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
                ) {
                    host.cardSolidCapsuleTintView.alpha = 0.0
                }
                UIView.animate(
                    withDuration: 0.28,
                    delay: 0.18,
                    options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
                ) {
                    self.hostingController?.view.alpha = 1.0
                }

                // 灵动分频物理弹性：容器壳体从容展平全屏，独立专辑封面温润舒展飞越回正
                UIView.animate(
                    withDuration: 0.56,
                    delay: 0,
                    usingSpringWithDamping: 0.91,
                    initialSpringVelocity: 0.0,
                    options: [.allowUserInteraction, .beginFromCurrentState]
                ) {
                    self.activeProgress = 0.0
                    self.activeDragOffsetX = 0
                    host.backdropView.alpha = 0.08
                    self.applyCardFrameAndRadius(
                        fullBounds.size,
                        center: CGPoint(x: fullBounds.midX, y: fullBounds.midY),
                        cornerRadius: 0,
                        shadowOpacity: 0.0,
                        borderAlpha: 0.0,
                        in: host
                    )

                    if let hostingView = self.hostingController?.view {
                        hostingView.bounds = CGRect(origin: .zero, size: fullBounds.size)
                        hostingView.transform = .identity
                        hostingView.center = CGPoint(x: fullBounds.midX, y: fullBounds.midY)
                    }
                } completion: { _ in
                    guard self.transitionEpoch == epoch else { return }
                    self.isTransitioning = false
                    self.modalBridge.freezeHeroSnapshotUpdates = false
                    self.modalBridge.hideInnerHeroArtwork = false
                    self.modalBridge.snapshotRefreshTick &+= 1
                    host.floatingHeroShadowView.alpha = 0
                    host.floatingHeroShadowView.isHidden = true
                }

                if showHeroOnExpand {
                    UIView.animate(
                        withDuration: 0.54,
                        delay: 0,
                        usingSpringWithDamping: 0.86,
                        initialSpringVelocity: 0.25,
                        options: [.allowUserInteraction, .beginFromCurrentState]
                    ) {
                        self.applyFloatingHeroTransform(
                            baseSide: heroBaseSide,
                            toRect: expandedHero.globalRect,
                            cornerRadius: expandedHero.cornerRadius,
                            shadowOpacity: 0.32,
                            shadowRadius: 22.0,
                            shadowY: 12.0,
                            in: host
                        )
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                    guard let self, self.transitionEpoch == epoch, self.currentlyPresented else { return }
                    self.modalBridge.freezeHeroSnapshotUpdates = false
                    self.modalBridge.hideInnerHeroArtwork = false
                    self.modalBridge.snapshotRefreshTick &+= 1
                    UIView.animate(withDuration: 0.06, delay: 0, options: [.curveEaseOut]) {
                        host.floatingHeroShadowView.alpha = 0.0
                    } completion: { _ in
                        guard self.transitionEpoch == epoch else { return }
                        host.floatingHeroShadowView.isHidden = true
                    }
                }
            }
        }

        private func animateCollapseToMiniBar(initialVelocity: CGFloat) {
            guard let host = hostController else { return }
            transitionEpoch += 1
            let epoch = transitionEpoch

            modalBridge.freezeHeroSnapshotUpdates = true
            let fullBounds = host.view.bounds
            let barEnd = resolvedTargetBarRect(in: host.view)
            let slotEndGlobal = globalMiniArtworkSlotRect(forBarRect: barEnd)
            let baseSnapshot = lockedHeroSnapshot ?? resolvedExpandedHeroSnapshot(in: host, allowLiveSnapshot: true)
            let useHeroFlight = baseSnapshot.isVisibleInCurrentPane && baseSnapshot.globalRect.width > 12

            // 计算当前全宽卡片实时顶边位置，以及独立封面在 host.view 全局坐标系下的起始位置
            let currentCardFrame = host.cardClipView.frame
            let currentTopY = max(0, currentCardFrame.minY)
            let plungeTopY = barEnd.minY + 12.0
            let needsPlungePhase = currentTopY < (barEnd.minY * 0.62)

            let startHeroGlobal = CGRect(
                x: currentCardFrame.minX + baseSnapshot.globalRect.minX,
                y: currentCardFrame.minY + baseSnapshot.globalRect.minY,
                width: baseSnapshot.globalRect.width,
                height: baseSnapshot.globalRect.height
            )
            // 下沉终态封面位置：沉在底部胶囊下沿下方区域（保持饱满尺度，准备从容地由下往上回弹吸进左槽）
            let plungeHeroSide = min(baseSnapshot.globalRect.width * 0.72, 164.0)
            let plungeHeroGlobal = CGRect(
                x: max(16.0, slotEndGlobal.minX + 14.0),
                y: min(fullBounds.height - plungeHeroSide * 0.52, barEnd.maxY - 2.0),
                width: plungeHeroSide,
                height: plungeHeroSide
            )

            let heroBaseSide = max(24, baseSnapshot.globalRect.width)
            let cardVel = min(max(initialVelocity * 0.35, 0.0), 0.65)
            let heroVel = min(max(initialVelocity * 0.45, 0.15), 0.75)
            refreshMorphingMiniBarContent(in: host, barHeight: barEnd.height, hideMiniArtwork: useHeroFlight)
            syncSolidBackdropColors(in: host)

            UIView.performWithoutAnimation {
                host.cardSolidBackdropView.alpha = 1.0
                host.cardGlassView.alpha = 0.0
                host.morphingMiniHeaderView.transform = CGAffineTransform(translationX: 10, y: 1.0).scaledBy(x: 0.96, y: 0.96)
                host.morphingMiniHeaderView.alpha = 0.0
                self.modalBridge.hideInnerHeroArtwork = useHeroFlight
                if useHeroFlight {
                    host.view.bringSubviewToFront(host.floatingHeroShadowView)
                    host.floatingHeroShadowView.isHidden = false
                    host.floatingHeroShadowView.alpha = 1.0
                    self.applyFloatingHeroTransform(
                        baseSide: heroBaseSide,
                        toRect: startHeroGlobal,
                        cornerRadius: baseSnapshot.cornerRadius,
                        shadowOpacity: 0.28,
                        shadowRadius: 18.0,
                        shadowY: 9.0,
                        in: host
                    )
                } else {
                    host.floatingHeroShadowView.alpha = 0
                    host.floatingHeroShadowView.isHidden = true
                }
                NotificationCenter.default.post(name: .mygoMiniPlayerSetTransitionAlpha, object: [0.0, 0.0])
            }

            isTransitioning = true
            host.view.isUserInteractionEnabled = false

            let runCapsuleShrinkAndHeroBounceBack: () -> Void = { [weak self] in
                guard let self, let host = self.hostController,
                      self.transitionEpoch == epoch, !self.currentlyPresented else { return }

                UIView.animate(
                    withDuration: 0.24,
                    delay: 0.0,
                    options: [.curveEaseInOut, .beginFromCurrentState]
                ) {
                    host.cardSolidBackdropView.alpha = 0.0
                    host.cardSolidCapsuleTintView.alpha = 0.35
                    host.cardGlassView.alpha = 1.0
                }
                UIView.animate(
                    withDuration: 0.28,
                    delay: 0.06,
                    usingSpringWithDamping: 0.88,
                    initialSpringVelocity: 0.2,
                    options: [.beginFromCurrentState]
                ) {
                    host.morphingMiniHeaderView.alpha = 1.0
                    host.morphingMiniHeaderView.transform = .identity
                }

                // 外框胶囊舒展收缩成顶部悬停磨砂胶囊并落位 barEnd，留出下方封面从容抬升空间
                UIView.animate(
                    withDuration: 0.44,
                    delay: 0,
                    usingSpringWithDamping: 0.90,
                    initialSpringVelocity: cardVel,
                    options: [.beginFromCurrentState]
                ) {
                    self.activeProgress = 1.0
                    host.backdropView.alpha = 0.0
                    host.cardClipView.bounds = CGRect(origin: .zero, size: barEnd.size)
                    host.cardClipView.center = CGPoint(x: barEnd.midX, y: barEnd.midY)
                    host.cardClipView.layer.cornerRadius = barEnd.height * 0.5
                    host.cardClipView.layer.borderWidth = 0.65
                    let dynamicBorder = UIColor { traits in
                        let baseAlpha: CGFloat = traits.userInterfaceStyle == .dark ? 0.16 * 1.4 : 0.16 * 4.5
                        return UIColor.white.withAlphaComponent(min(0.85, baseAlpha))
                    }
                    host.cardClipView.layer.borderColor = dynamicBorder.resolvedColor(with: host.traitCollection).cgColor

                    host.cardShadowView.bounds = CGRect(origin: .zero, size: barEnd.size)
                    host.cardShadowView.center = CGPoint(x: barEnd.midX, y: barEnd.midY)
                    host.cardShadowView.layer.cornerRadius = barEnd.height * 0.5
                    host.cardShadowView.layer.shadowOpacity = 0.20

                    if let hostingView = self.hostingController?.view {
                        hostingView.alpha = 0.0
                    }
                }

                // 独立专辑封面：微滞后 30ms 启动，从胶囊下方低位带着柔和弹性由下向上从容回弹缩进 38×38 左槽
                if useHeroFlight {
                    UIView.animate(
                        withDuration: 0.56,
                        delay: 0.03,
                        usingSpringWithDamping: 0.80,
                        initialSpringVelocity: heroVel,
                        options: [.beginFromCurrentState]
                    ) {
                        self.applyFloatingHeroTransform(
                            baseSide: heroBaseSide,
                            toRect: slotEndGlobal,
                            cornerRadius: 9.5,
                            shadowOpacity: 0.16,
                            shadowRadius: 4.0,
                            shadowY: 1.5,
                            in: host
                        )
                    }
                }

                // 待封面后段优雅回弹稳住后再无感交棒 + 接球轻柔缓冲
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) { [weak self] in
                    guard let self, self.transitionEpoch == epoch, !self.currentlyPresented else { return }
                    NotificationCenter.default.post(name: .mygoMiniPlayerSetTransitionAlpha, object: [1.0, 0.0])
                    NotificationCenter.default.post(name: .mygoMiniPlayerLandingPulse, object: nil)
                    UIView.animate(
                        withDuration: 0.10,
                        delay: 0.01,
                        options: [.curveEaseIn, .beginFromCurrentState]
                    ) {
                        host.cardClipView.alpha = 0.0
                        host.cardShadowView.layer.shadowOpacity = 0.0
                        host.floatingHeroShadowView.alpha = 0.0
                    } completion: { _ in
                        guard self.transitionEpoch == epoch, !self.currentlyPresented else { return }
                        self.isTransitioning = false
                        NotificationCenter.default.post(name: .mygoNowPlayingDidCollapseToMiniBar, object: nil)
                        self.unmountHostingIfHidden()
                    }
                }
            }

            if needsPlungePhase {
                // Stage 1（高位轻扫/点收起按钮触发）：先整卡全宽从容优雅下沉到底，把大封面带到下方区域再回弹归槽
                UIView.animate(
                    withDuration: 0.22,
                    delay: 0,
                    options: [.curveEaseInOut, .beginFromCurrentState]
                ) {
                    host.backdropView.alpha = 0.0
                    self.hostingController?.view.alpha = 0.0
                    self.applyCardFrameAndRadius(
                        fullBounds.size,
                        center: CGPoint(x: fullBounds.midX, y: plungeTopY + fullBounds.height * 0.5),
                        cornerRadius: 38.0,
                        shadowOpacity: 0.18,
                        borderAlpha: 0.12,
                        in: host
                    )
                    if useHeroFlight {
                        self.applyFloatingHeroTransform(
                            baseSide: heroBaseSide,
                            toRect: plungeHeroGlobal,
                            cornerRadius: 16.0,
                            shadowOpacity: 0.24,
                            shadowRadius: 12.0,
                            shadowY: 6.0,
                            in: host
                        )
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
                    runCapsuleShrinkAndHeroBounceBack()
                }
            } else {
                // 慢速手势已直接将整卡全宽拖到底部下方：内页柔顺淡出，同步收拢外框并让下沉封面由下往上回弹归槽
                UIView.animate(
                    withDuration: 0.16,
                    delay: 0,
                    options: [.curveEaseOut, .beginFromCurrentState]
                ) {
                    self.hostingController?.view.alpha = 0.0
                }
                runCapsuleShrinkAndHeroBounceBack()
            }
        }

        private func animateBounceBackToFullscreen(initialVelocity: CGFloat) {
            transitionEpoch += 1
            let epoch = transitionEpoch
            isTransitioning = true
            guard let host = hostController else { return }

            UIView.animate(
                withDuration: 0.42,
                delay: 0,
                usingSpringWithDamping: 0.90,
                initialSpringVelocity: min(max(initialVelocity * 0.35, 0), 0.6),
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                self.applyDragGeometry(progress: 0.0, dragOffsetX: 0)
            } completion: { _ in
                guard self.transitionEpoch == epoch else { return }
                self.isTransitioning = false
                self.lockedHeroSnapshot = nil
                self.modalBridge.freezeHeroSnapshotUpdates = false
                self.modalBridge.hideInnerHeroArtwork = false
                self.modalBridge.snapshotRefreshTick &+= 1
                host.floatingHeroShadowView.alpha = 0
                host.floatingHeroShadowView.isHidden = true
                if self.currentlyPresented {
                    self.applyDragGeometry(progress: 0.0, dragOffsetX: 0)
                }
            }
        }

        // MARK: UIPanGestureRecognizer & UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard currentlyPresented, canInteractiveDismiss, let host = hostController,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return false
            }
            let vel = pan.velocity(in: host.view)
            guard vel.y > 14 && vel.y > abs(vel.x) * 1.1 else {
                return false
            }

            let loc = pan.location(in: host.cardClipView)
            if let hit = host.cardClipView.hitTest(loc, with: nil) {
                if hit is UISlider || hit.isDescendant(of: UISlider.self) {
                    return false
                }
                if let sv = nearestScrollView(from: hit) {
                    let topEdgeY = -sv.adjustedContentInset.top
                    if sv.contentOffset.y > topEdgeY + 2.0 {
                        return false
                    }
                    trackingScrollView = sv
                } else {
                    trackingScrollView = nil
                }
            } else {
                trackingScrollView = nil
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            return trackingScrollView != nil && otherGestureRecognizer.view === trackingScrollView
        }

        private func nearestScrollView(from view: UIView) -> UIScrollView? {
            var cur: UIView? = view
            while let v = cur {
                if let sv = v as? UIScrollView, sv.isScrollEnabled {
                    if sv.contentSize.height > sv.bounds.height - 4 || sv.alwaysBounceVertical {
                        return sv
                    }
                }
                if v === hostController?.cardClipView { break }
                cur = v.superview
            }
            return nil
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard let host = hostController, currentlyPresented else { return }
            let t = pan.translation(in: host.view)
            let v = pan.velocity(in: host.view)
            let barEnd = resolvedTargetBarRect(in: host.view)
            let dragScale = max(420.0, barEnd.minY + 12.0)

            switch pan.state {
            case .began:
                transitionEpoch += 1
                isTransitioning = true
                lockedHeroSnapshot = nil
                modalBridge.freezeHeroSnapshotUpdates = true
                modalBridge.hideInnerHeroArtwork = false
                host.cardClipView.layer.removeAllAnimations()
                host.cardShadowView.layer.removeAllAnimations()
                host.backdropView.layer.removeAllAnimations()
                host.cardSolidBackdropView.layer.removeAllAnimations()
                host.cardSolidCapsuleTintView.layer.removeAllAnimations()
                host.cardGlassView.layer.removeAllAnimations()
                host.morphingMiniHeaderView.layer.removeAllAnimations()
                syncSolidBackdropColors(in: host)
                host.floatingHeroShadowView.layer.removeAllAnimations()
                host.floatingHeroClipView.layer.removeAllAnimations()
                host.floatingHeroArtworkView.layer.removeAllAnimations()
                hostingController?.view.layer.removeAllAnimations()
                host.floatingHeroShadowView.alpha = 0
                host.floatingHeroShadowView.isHidden = true
                fallthrough

            case .changed:
                isTransitioning = true
                if let sv = trackingScrollView {
                    let topY = -sv.adjustedContentInset.top
                    if sv.contentOffset.y < topY {
                        sv.contentOffset.y = topY
                    }
                }
                let rawProgress = t.y / dragScale
                let damped: CGFloat
                if rawProgress >= 0 {
                    damped = rawProgress <= 1.0 ? rawProgress : (1.0 + min(0.06, (rawProgress - 1.0) * 0.15))
                } else {
                    damped = rawProgress * 0.16
                }
                applyDragGeometry(progress: damped, dragOffsetX: t.x)

            case .ended, .cancelled, .failed:
                trackingScrollView = nil
                let shouldDismiss = (activeProgress > 0.24) || (v.y > 520 && t.y > 24)
                if shouldDismiss {
                    MyGoHaptics.impact(.soft)
                    currentlyPresented = false
                    if parent.isPresented {
                        parent.isPresented = false
                    }
                    let springVel = min(1.1, max(0.35, v.y / max(160, host.view.bounds.height - barEnd.midY)))
                    animateCollapseToMiniBar(initialVelocity: springVel)
                } else {
                    animateBounceBackToFullscreen(initialVelocity: abs(v.y) / 600.0)
                }

            default:
                break
            }
        }

        #if DEBUG
        private func runDebugMorphDemo() async {
            // 连续 3 轮完整循环压测：第 1 轮含半拉回弹，第 2、3 轮验证 unmountHostingIfHidden 后的二次/三次重复展开与退场零飞出
            for round in 1...3 {
                if !parent.isPresented {
                    parent.isPresented = true
                    try? await Task.sleep(nanoseconds: 780_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 240_000_000)
                }
                guard currentlyPresented, let host = hostController else { return }

                if round == 1 {
                    // 第 1 轮先测试轻拉 18% 后松手回弹归位
                    for i in 1...8 {
                        guard currentlyPresented else { return }
                        let frac = CGFloat(i) / 8.0
                        applyDragGeometry(progress: 0.18 * sin(frac * .pi * 0.5), dragOffsetX: 0)
                        try? await Task.sleep(nanoseconds: 16_000_000)
                    }
                    try? await Task.sleep(nanoseconds: 140_000_000)
                    animateBounceBackToFullscreen(initialVelocity: 0.5)
                    try? await Task.sleep(nanoseconds: 540_000_000)
                }

                // 第 1 轮先测试半拉回顶 + 第 2 轮长距离全宽拖到底后松手由下向上回弹 + 第 3 轮高位轻扫快速沉底回弹
                guard currentlyPresented else { return }
                let dragTarget: CGFloat = (round == 2) ? 0.82 : 0.30
                let steps = (round == 2) ? 16 : 10
                for i in 1...steps {
                    guard currentlyPresented else { return }
                    let frac = CGFloat(i) / CGFloat(steps)
                    applyDragGeometry(progress: dragTarget * frac, dragOffsetX: 0)
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                MyGoHaptics.impact(.soft)
                currentlyPresented = false
                if parent.isPresented {
                    parent.isPresented = false
                }
                let springVel: CGFloat = host.view.bounds.height > 0 ? 0.65 : 0.5
                animateCollapseToMiniBar(initialVelocity: springVel)

                // 等待退场动画 (>0.82s) 及 unmountHostingIfHidden() 彻底完成后进入下一轮
                try? await Task.sleep(nanoseconds: 950_000_000)
            }
        }

        private func runDebugLyricsDemo() async {
            if !parent.isPresented {
                parent.app.activeNowPlayingPane = .cover
                parent.isPresented = true
                try? await Task.sleep(nanoseconds: 750_000_000)
                modalBridge.onDebugRunLyricsMorph?()
            }
        }
        #endif
    }
}

private extension UIView {
    func isDescendant(of type: UIView.Type) -> Bool {
        var cur: UIView? = self
        while let v = cur {
            if v.isKind(of: type) { return true }
            cur = v.superview
        }
        return false
    }
}
#endif

// MARK: - iOS 应用根视图（对应 ui_main.go 中的 view）

/// 使用独立 ObservableObject 管理根页签切换与激活态，确保 SwiftUI/Combine 跨视图树无条件同步，避免 iOS 26 容器漏刷新。
@MainActor
private final class MainTabSelectionStore: ObservableObject {
    @Published var selectedTab: Int = 0
    @Published var lastPrimaryTab: Int = 0
    @Published var activatedTabs: Set<Int> = [0]

    init() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        let tabArg = args.first(where: { $0.hasPrefix("-MyGoTab:") })?
            .split(separator: ":").last.map(String.init) ?? env["MYGO_DEBUG_TAB"]
        if let tabArg, let tab = Int(tabArg), (0...3).contains(tab) {
            selectedTab = tab
            activatedTabs = [tab]
            if MainTabMapping.slotIndex(for: tab) != nil {
                lastPrimaryTab = tab
            }
        }
        #endif
    }

    func select(_ tab: Int) {
        activatedTabs.insert(tab)
        if MainTabMapping.slotIndex(for: tab) != nil {
            lastPrimaryTab = tab
        }
        selectedTab = tab
    }
}

public struct MainView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var scrollStore = ScrollCoordinatorStore()
    @StateObject private var tabStore = MainTabSelectionStore()
    @StateObject private var miniGeometryStore = MiniPlayerGeometryStore()
    @State private var isKeyboardVisible: Bool = false
    @State private var bottomSafeAreaInset: CGFloat = 0

    public init() {}

    private var scrollCoordinator: TabBarScrollCoordinator {
        scrollStore.coordinator
    }

    private var preferredScheme: ColorScheme? {
        switch app.settings.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    @MainActor
    private var bottomOverlayPadding: CGFloat {
        #if os(iOS)
        let safeBottom = max(bottomSafeAreaInset, MyGoSystemAppearanceConfigurator.currentBottomSafeAreaInset)
        // 对齐 iOS 26 原生系统（Files / Apple Music 全面屏下沿距屏幕物理底边 ~22pt）
        return safeBottom >= 24 ? 22 : 14
        #else
        return 12
        #endif
    }

    @MainActor
    private var bottomScrollExtraInset: CGFloat {
        let safeBottom: CGFloat
        #if os(iOS)
        safeBottom = max(bottomSafeAreaInset, MyGoSystemAppearanceConfigurator.currentBottomSafeAreaInset)
        #else
        safeBottom = 0
        #endif
        return FloatingTabBarMetrics.extraScrollBottomInset(
            hasTrack: app.player.currentTrack != nil,
            isKeyboardVisible: isKeyboardVisible,
            bottomOverlayPadding: bottomOverlayPadding,
            systemSafeAreaBottom: safeBottom
        )
    }

    #if os(iOS)
    /// 原生 UIKit 子控制器容器：为四个页签分别持有独立 UIHostingController，切页通过 view.isHidden 瞬切，
    /// 彻底规避 iOS 26 ZStack 内多 NavigationStack 透明度/偏移失效引起的层叠穿帮，同时 100% 保留各页滚动位置与导航栈。
    private struct IOSTabPagesHost: UIViewControllerRepresentable {
        @ObservedObject var tabStore: MainTabSelectionStore
        let bottomOverlayInset: CGFloat
        let isNowPlayingPresented: Bool
        let accentPreset: AccentColorPreset
        let preferredScheme: ColorScheme?
        let app: AppModel
        let headersProvider: @MainActor (URL) -> [String: String]
        let onReportScroll: @MainActor (VerticalScrollMetrics) -> Void
        let onResetScroll: @MainActor () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIViewController(context: Context) -> UIViewController {
            let container = UIViewController()
            container.view.backgroundColor = .clear
            context.coordinator.bind(hostViewController: container, representable: self)
            return container
        }

        func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
            context.coordinator.bind(hostViewController: uiViewController, representable: self)
            context.coordinator.syncPages()
        }

        fileprivate func buildTabRootView(index: Int, isActive: Bool) -> AnyView {
            let base: AnyView
            switch index {
            case 0: base = AnyView(HomeView())
            case 1: base = AnyView(SearchView())
            case 2: base = AnyView(LibraryView())
            case 3: base = AnyView(SettingsView())
            default: base = AnyView(HomeView())
            }
            return AnyView(
                base
                    .environmentObject(app)
                    .environment(\.mygoImageHeadersProvider, headersProvider)
                    .environment(\.mygoBottomOverlayInset, bottomOverlayInset)
                    .environment(\.mygoReportVerticalScroll, onReportScroll)
                    .environment(\.mygoResetScrollTracker, onResetScroll)
                    .environment(\.mygoIsViewVisible, isActive && !isNowPlayingPresented)
                    .tint(MyGoTheme.color(for: accentPreset))
                    .preferredColorScheme(preferredScheme)
            )
        }

        private struct TabRootConfig: Equatable {
            let isActive: Bool
            let bottomOverlayInset: CGFloat
            let isNowPlayingPresented: Bool
            let accentPreset: AccentColorPreset
            let preferredScheme: ColorScheme?
        }

        @MainActor
        final class Coordinator {
            var controllers: [Int: UIHostingController<AnyView>] = [:]
            private var rootConfigs: [Int: TabRootConfig] = [:]
            weak var hostVC: UIViewController?
            var latestRepresentable: IOSTabPagesHost?
            private var tabCancellable: AnyCancellable?
            private weak var subscribedStore: MainTabSelectionStore?

            func bind(hostViewController: UIViewController, representable: IOSTabPagesHost) {
                hostVC = hostViewController
                latestRepresentable = representable
                if subscribedStore !== representable.tabStore {
                    subscribedStore = representable.tabStore
                    tabCancellable = representable.tabStore.$selectedTab
                        .combineLatest(representable.tabStore.$activatedTabs)
                        .receive(on: RunLoop.main)
                        .sink { [weak self] _, _ in
                            self?.syncPages()
                        }
                }
            }

            func syncPages() {
                guard let container = hostVC, let rep = latestRepresentable else { return }
                let bounds = container.view.bounds
                let selectedTab = rep.tabStore.selectedTab
                let activeIndices = rep.tabStore.activatedTabs.union([selectedTab])

                for index in activeIndices.sorted() {
                    let isActive = (index == selectedTab)
                    let targetConfig = TabRootConfig(
                        isActive: isActive,
                        bottomOverlayInset: rep.bottomOverlayInset,
                        isNowPlayingPresented: rep.isNowPlayingPresented,
                        accentPreset: rep.accentPreset,
                        preferredScheme: rep.preferredScheme
                    )

                    if let existing = controllers[index] {
                        if rootConfigs[index] != targetConfig {
                            existing.rootView = rep.buildTabRootView(index: index, isActive: isActive)
                            rootConfigs[index] = targetConfig
                        }
                        if bounds.width > 0 && bounds.height > 0 && existing.view.frame != bounds {
                            existing.view.frame = bounds
                        }
                        existing.view.isHidden = !isActive
                        existing.view.isUserInteractionEnabled = isActive
                    } else {
                        let rootView = rep.buildTabRootView(index: index, isActive: isActive)
                        let hc = UIHostingController(rootView: rootView)
                        hc.view.backgroundColor = .clear
                        container.addChild(hc)
                        hc.view.frame = bounds
                        hc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                        hc.view.isHidden = !isActive
                        hc.view.isUserInteractionEnabled = isActive
                        container.view.addSubview(hc.view)
                        hc.didMove(toParent: container)
                        controllers[index] = hc
                        rootConfigs[index] = targetConfig
                    }
                }

                if let activeVC = controllers[selectedTab] {
                    container.view.bringSubviewToFront(activeVC.view)
                }
            }
        }
    }
    #endif

    @ViewBuilder
    private func tabViewport<Content: View>(index: Int, @ViewBuilder content: () -> Content) -> some View {
        let isActive = (tabStore.selectedTab == index)
        if tabStore.activatedTabs.contains(index) || isActive {
            content()
                .environment(\.mygoIsViewVisible, isActive && !app.isNowPlayingPresented)
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .accessibilityHidden(!isActive)
                .zIndex(isActive ? 10 : -1)
        }
    }

    public var body: some View {
        let headersProvider: @MainActor (URL) -> [String: String] = { url in
            app.imageHeaders(for: url)
        }
        ZStack(alignment: .bottom) {
            #if os(iOS)
            IOSTabPagesHost(
                tabStore: tabStore,
                bottomOverlayInset: bottomScrollExtraInset,
                isNowPlayingPresented: app.isNowPlayingPresented,
                accentPreset: app.settings.accentPreset,
                preferredScheme: preferredScheme,
                app: app,
                headersProvider: headersProvider,
                onReportScroll: { metrics in
                    scrollCoordinator.handleScroll(metrics)
                },
                onResetScroll: {
                    scrollCoordinator.resetAccumulatorAndExpand()
                }
            )
            .ignoresSafeArea()
            .onReceive(NotificationCenter.default.publisher(for: .mygoOpenSettings)) { _ in
                switchToTab(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #else
            ZStack {
                tabViewport(index: 0) { HomeView() }
                tabViewport(index: 1) { SearchView() }
                tabViewport(index: 2) { LibraryView() }
                tabViewport(index: 3) { SettingsView() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .mygoOpenSettings)) { _ in
                switchToTab(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.mygoBottomOverlayInset, bottomScrollExtraInset)
            .environment(\.mygoReportVerticalScroll) { metrics in
                scrollCoordinator.handleScroll(metrics)
            }
            .environment(\.mygoResetScrollTracker) {
                scrollCoordinator.resetAccumulatorAndExpand()
            }
            #endif

            // Apple Music iOS 26 分体悬浮液态玻璃底栏（仅底栏独立订阅滚动折叠状态与页签状态，完全避免重绘四页内容树）
            AdaptiveFloatingBottomChrome(
                scrollCoordinator: scrollCoordinator,
                tabStore: tabStore,
                onSelectTab: { targetTab in
                    switchToTab(targetTab)
                },
                onExpandFromCircle: {
                    if tabStore.selectedTab == MainTabMapping.searchTabID {
                        switchToTab(tabStore.lastPrimaryTab)
                    } else {
                        scrollCoordinator.expand()
                    }
                },
                onSearchTap: {
                    handleSearchCircleTap()
                }
            )
            .padding(.bottom, bottomOverlayPadding)
            // 不使用 .clipped()，避免把悬浮玻璃阴影上下硬切出横贯全屏的分层线条；键盘弹出时平滑下移淡出避让
            .offset(y: isKeyboardVisible ? 36 : 0)
            .opacity(isKeyboardVisible ? 0 : 1)
            .allowsHitTesting(!isKeyboardVisible && !app.isNowPlayingPresented)
            .accessibilityHidden(isKeyboardVisible || app.isNowPlayingPresented)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea([.container, .keyboard], edges: .bottom)

            #if os(iOS)
            // 同树零尺寸窗口锚点（仅在展开时于 rootViewController 顶层呈现全屏播放页，彻底不占主屏点击事件）
            NowPlayingOverlayHost(
                app: app,
                geometryStore: miniGeometryStore,
                headersProvider: headersProvider
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            #endif
        }
        .onPreferenceChange(MiniPlayerFramePreferenceKey.self) { newFrame in
            if newFrame.width > 20 && newFrame.height > 20 {
                miniGeometryStore.barFrame = newFrame
            }
        }
        .onPreferenceChange(MiniPlayerArtworkFramePreferenceKey.self) { newArtFrame in
            if newArtFrame.width > 12 && newArtFrame.height > 12 {
                miniGeometryStore.artworkFrame = newArtFrame
            }
        }
        .background {
            GeometryReader { proxy in
                let safeBottom = proxy.safeAreaInsets.bottom
                Color.clear
                    .onAppear {
                        if abs(bottomSafeAreaInset - safeBottom) > 0.5 {
                            bottomSafeAreaInset = safeBottom
                        }
                    }
                    .onChange(of: safeBottom) { _, newValue in
                        if abs(bottomSafeAreaInset - newValue) > 0.5 {
                            bottomSafeAreaInset = newValue
                        }
                    }
            }
        }
        .environment(\.mygoImageHeadersProvider, headersProvider)
        .background(MyGoTheme.pageBackground.ignoresSafeArea())
        .tint(MyGoTheme.color(for: app.settings.accentPreset))
        .preferredColorScheme(preferredScheme)
        .onAppear {
            MyGoTheme.setAccentPreset(app.settings.accentPreset)
        }
        .onChange(of: app.settings.accentPreset) { _, newPreset in
            MyGoTheme.setAccentPreset(newPreset)
        }
        #if canImport(UIKit)
        .onAppear {
            MyGoSystemAppearanceConfigurator.apply(for: app.settings.appearance)
            DispatchQueue.main.async {
                MyGoSystemAppearanceConfigurator.apply(for: app.settings.appearance)
            }
        }
        .onChange(of: app.settings.appearance) { _, newAppearance in
            MyGoSystemAppearanceConfigurator.apply(for: newAppearance)
        }
        .onChange(of: colorScheme) { _, _ in
            MyGoSystemAppearanceConfigurator.apply(for: app.settings.appearance)
        }
        #endif
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
        .onChange(of: tabStore.selectedTab) { _, newTab in
            MyGoKeyboard.dismiss()
            if MainTabMapping.slotIndex(for: newTab) != nil {
                tabStore.lastPrimaryTab = newTab
            }
            scrollCoordinator.resetAccumulatorAndExpand()
        }
        .onChange(of: app.isNowPlayingPresented) { _, presented in
            if presented {
                MyGoKeyboard.dismiss()
            }
        }
        #if !os(iOS)
        .sheet(isPresented: $app.isNowPlayingPresented) {
            NowPlayingView()
                .environmentObject(app)
                .environment(\.mygoImageHeadersProvider, headersProvider)
                .frame(minWidth: 420, minHeight: 640)
        }
        #endif
        .onAppear {
            #if canImport(UIKit)
            if app.cachedArtworkImageProvider == nil {
                app.cachedArtworkImageProvider = { rawURL in
                    ArtworkImageLoader.cachedPlatformImage(rawURLString: rawURL, pixelSize: 600)
                }
            }
            consumePendingQuickActionIfAny()
            #endif
            #if DEBUG
            print(String(format: "[MyGoStartup] MainView first frame appeared (syncInit=%.2fms)", app.syncInitDurationMs))
            applyDebugLaunchOptionsIfNeeded()
            #endif
        }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: MyGoApplicationDelegate.quickActionNotification)) { note in
            if let type = note.object as? String,
               let kind = AppModel.QuickActionKind(rawValue: type) {
                executeQuickAction(kind)
            } else {
                consumePendingQuickActionIfAny()
            }
        }
        #endif
        .onChange(of: app.pendingQuickAction) { _, pending in
            guard let pending else { return }
            app.pendingQuickAction = nil
            executeQuickAction(pending)
        }
        .userActivity(
            "com.egoist.mygomusic.playing",
            element: app.player.currentTrack
        ) { track, activity in
            activity.title = MyGoShareHelper.shareText(for: track)
            activity.isEligibleForSearch = true
            activity.isEligibleForHandoff = false
            activity.userInfo = [
                "trackID": track.id,
                "trackName": track.name,
                "artist": track.artistNames
            ]
        }
        .sheet(isPresented: $app.isSignInSheetPresented) {
            SignInDialogSheetView()
                .environmentObject(app)
                .environment(\.mygoImageHeadersProvider, headersProvider)
        }
        .sheet(item: $app.activeWebSignInRequest) { req in
            WebSignInSheetView(request: req)
                .environmentObject(app)
                .environment(\.mygoImageHeadersProvider, headersProvider)
        }
        .sheet(item: $app.pendingAddToPlaylistTrack) { targetTrack in
            AddToPlaylistSheetView(track: targetTrack)
                .environmentObject(app)
                .environment(\.mygoImageHeadersProvider, headersProvider)
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
        scrollCoordinator.resetAccumulatorAndExpand()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.80)) {
            tabStore.select(targetTab)
        }
    }

    private func handleSearchCircleTap() {
        MyGoHaptics.impact(.light)
        let searchTab = MainTabMapping.searchTabID
        if tabStore.selectedTab != searchTab {
            switchToTab(searchTab)
        } else if scrollCoordinator.isMinimized {
            scrollCoordinator.expand()
        } else {
            NotificationCenter.default.post(name: .mygoFocusSearchField, object: nil)
        }
    }

    #if canImport(UIKit)
    private func consumePendingQuickActionIfAny() {
        guard let pendingType = MyGoApplicationDelegate.consumePendingShortcutType(),
              let kind = AppModel.QuickActionKind(rawValue: pendingType) else {
            return
        }
        executeQuickAction(kind)
    }
    #endif

    private func executeQuickAction(_ kind: AppModel.QuickActionKind) {
        MyGoHaptics.selection()
        Task { @MainActor in
            await app.waitUntilStartupReady()
            switch kind {
            case .resumePlayback:
                app.resumeOrStartQuickPlayback()
            case .likedSongs:
                switchToTab(2)
                NotificationCenter.default.post(name: .mygoOpenLibraryTarget, object: NavigationTarget.likedSongs)
            case .dailyMix:
                switchToTab(0)
                NotificationCenter.default.post(name: .mygoOpenHomeDaily, object: nil)
            case .searchMusic:
                switchToTab(MainTabMapping.searchTabID)
                try? await Task.sleep(nanoseconds: 120_000_000)
                NotificationCenter.default.post(name: .mygoFocusSearchField, object: nil)
            }
        }
    }

    #if DEBUG
    /// 根据字符串设置律动与播放器子面板（供 DEBUG 自动化联调使用）。
    private func applyDebugStageConfig(pane: String?, style: String?) {
        switch pane?.lowercased() {
        case "cover": app.activeNowPlayingPane = .cover
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
        let tabArg = args.first(where: { $0.hasPrefix("-MyGoTab:") })?.split(separator: ":").last.map(String.init) ?? env["MYGO_DEBUG_TAB"]
        let shouldOpen = args.contains("-MyGoOpenNowPlaying") || env["MYGO_DEBUG_OPEN"] == "1"
        guard shouldOpen || tabArg != nil else { return }

        let paneArg = args.first(where: { $0.hasPrefix("-MyGoPane:") })?.split(separator: ":").last.map(String.init) ?? env["MYGO_DEBUG_PANE"]
        let styleArg = args.first(where: { $0.hasPrefix("-MyGoStageStyle:") })?.split(separator: ":").last.map(String.init) ?? env["MYGO_DEBUG_STYLE"]
        let autoPlay = args.contains("-MyGoAutoPlay") || env["MYGO_DEBUG_PLAY"] == "1"
        let seekArg = args.first(where: { $0.hasPrefix("-MyGoSeek:") })?.split(separator: ":").last.map(String.init) ?? env["MYGO_DEBUG_SEEK"]

        Task { @MainActor in
            await app.waitUntilStartupReady()
            if let tabArg, let tab = Int(tabArg), (0...3).contains(tab) {
                applyDebugTabSelection(tab)
            }
            guard shouldOpen else { return }
            // 等待 UIWindowScene 首帧完全挂载，避免 fullScreenCover 被吞掉
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard app.player.currentTrack != nil else { return }
            applyDebugStageConfig(pane: paneArg ?? (app.settings.coverPlayerMode ? "cover" : (app.settings.lyricsStage ? "stage" : "lyrics")), style: styleArg)
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

    private func applyDebugTabSelection(_ tab: Int) {
        tabStore.select(tab)
    }

    private func applyDebugQuery(_ query: [String: String]) {
        if let tabStr = query["tab"], let tab = Int(tabStr), (0...3).contains(tab) {
            applyDebugTabSelection(tab)
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

        if let playHomeIdxStr = query["play_home"], let targetIdx = Int(playHomeIdxStr) {
            if let homeTracks = app.homeBrowse?.sections?.first(where: { !($0.tracks ?? []).isEmpty })?.tracks,
               homeTracks.indices.contains(targetIdx) {
                app.player.playTrack(homeTracks, at: targetIdx)
            }
        }
        if let open = query["open"]?.lowercased() {
            if open == "nowplaying" || open == "1" || open == "true" {
                app.isNowPlayingPresented = true
            } else if open == "close" || open == "0" || open == "false" {
                app.isNowPlayingPresented = false
            } else if open == "settings" {
                app.isNowPlayingPresented = false
                applyDebugTabSelection(3)
            } else if open == "artist" {
                app.isNowPlayingPresented = false
                let requestedName = query["artist_name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let matchedInHome: (artist: Artist, source: String?)? = {
                    guard let name = requestedName, !name.isEmpty,
                          let sections = app.homeBrowse?.sections else { return nil }
                    for sec in sections {
                        for tr in (sec.tracks ?? []) {
                            if let hit = tr.resolvedArtistsForNavigation.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                                return (hit, tr.source)
                            }
                        }
                    }
                    return nil
                }()
                let targetArtist = matchedInHome?.artist ?? app.player.currentTrack?.resolvedArtistsForNavigation.first
                let aid = query["artist_id"] ?? (requestedName == nil ? targetArtist?.id : matchedInHome?.artist.id) ?? ""
                let aname = requestedName ?? targetArtist?.name ?? "周杰伦"
                let asid = query["source"] ?? matchedInHome?.source ?? (requestedName == nil ? app.player.currentTrack?.source : nil) ?? app.activeSourceID
                tabStore.select(0)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    NotificationCenter.default.post(
                        name: .mygoOpenHomeTarget,
                        object: NavigationTarget.artist(id: aid, name: aname, sourceID: asid)
                    )
                }
            }
        }
        if let demo = query["demo"]?.lowercased() {
            if demo == "dismiss_morph" {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    NotificationCenter.default.post(name: .mygoDebugDemoDismissMorph, object: nil)
                }
            } else if demo == "lyrics_morph" {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    NotificationCenter.default.post(name: .mygoDebugDemoLyricsMorph, object: nil)
                }
            }
        }
        if let sp = query["switch_pane"]?.lowercased() {
            NotificationCenter.default.post(name: .mygoDebugSwitchPane, object: sp)
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
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if let iconArg = query["icon"]?.lowercased() {
            let targetName: String? = (iconArg == "applemusic" || iconArg == "apple")
                ? AppIconPreset.appleMusic.alternateIconName
                : nil
            print("[MyGoIconDebug] supportsAlternateIcons=\(UIApplication.shared.supportsAlternateIcons) current=\(String(describing: UIApplication.shared.alternateIconName)) target=\(String(describing: targetName))")
            UIApplication.shared.setAlternateIconName(targetName) { error in
                Task { @MainActor in
                    if let error {
                        print("[MyGoIconDebug] setAlternateIconName error=\(error)")
                        app.showToast("\(I18n.t("Failed to change app icon")): \(error.localizedDescription)")
                    } else {
                        print("[MyGoIconDebug] setAlternateIconName succeeded current=\(String(describing: UIApplication.shared.alternateIconName))")
                        app.settings.appIconPreset = (targetName == nil) ? .primary : .appleMusic
                        app.showToast(I18n.t("Alternate icon updated"))
                    }
                }
            }
        }
        #endif
    }
    #endif
}

#if canImport(UIKit)
/// 统一同步原生 UIWindow 暗黑模式与 UINavigationBar 磨砂外观（消除首页等界面滚动时顶部出现浑浊脏褐横条的问题）
@MainActor
private enum MyGoSystemAppearanceConfigurator {
    static var currentBottomSafeAreaInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let keyWindow = activeScene?.windows.first(where: { $0.isKeyWindow }) ?? activeScene?.windows.first
        return keyWindow?.safeAreaInsets.bottom ?? 0
    }

    static func apply(for appearance: AppAppearance) {
        let uiStyle: UIUserInterfaceStyle
        switch appearance {
        case .system: uiStyle = .unspecified
        case .light: uiStyle = .light
        case .dark: uiStyle = .dark
        }

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.overrideUserInterfaceStyle != uiStyle {
                window.overrideUserInterfaceStyle = uiStyle
            }
        }

        let standard = UINavigationBarAppearance()
        standard.configureWithDefaultBackground()
        standard.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(0.76)
                : UIColor.systemBackground.withAlphaComponent(0.84)
        }
        standard.shadowColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.08)
                : UIColor.black.withAlphaComponent(0.08)
        }

        let scrollEdge = UINavigationBarAppearance()
        scrollEdge.configureWithTransparentBackground()
        scrollEdge.backgroundColor = .clear
        scrollEdge.shadowColor = .clear

        let barProxy = UINavigationBar.appearance()
        barProxy.standardAppearance = standard
        barProxy.compactAppearance = standard
        barProxy.scrollEdgeAppearance = scrollEdge
        barProxy.compactScrollEdgeAppearance = scrollEdge

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let rootVC = window.rootViewController {
                    refreshNavigationBars(under: rootVC, standard: standard, scrollEdge: scrollEdge)
                }
            }
        }
    }

    private static func refreshNavigationBars(
        under vc: UIViewController,
        standard: UINavigationBarAppearance,
        scrollEdge: UINavigationBarAppearance
    ) {
        if let nav = vc as? UINavigationController {
            nav.navigationBar.standardAppearance = standard
            nav.navigationBar.compactAppearance = standard
            nav.navigationBar.scrollEdgeAppearance = scrollEdge
            nav.navigationBar.compactScrollEdgeAppearance = scrollEdge
            nav.navigationBar.setNeedsLayout()
        }
        for child in vc.children {
            refreshNavigationBars(under: child, standard: standard, scrollEdge: scrollEdge)
        }
        if let presented = vc.presentedViewController {
            refreshNavigationBars(under: presented, standard: standard, scrollEdge: scrollEdge)
        }
    }
}

// MARK: - iOS 应用宿主代理与桌面图标快捷操作（确保注册远程控制事件并完整响应 Quick Actions）

#if os(iOS)
public final class MyGoApplicationDelegate: NSObject, UIApplicationDelegate {
    public static let quickActionNotification = Notification.Name("MyGoQuickActionTriggered")

    @MainActor
    private static var pendingShortcutType: String?

    @MainActor
    static func enqueueShortcut(_ type: String) {
        pendingShortcutType = type
        NotificationCenter.default.post(name: quickActionNotification, object: type)
    }

    @MainActor
    public static func consumePendingShortcutType() -> String? {
        defer { pendingShortcutType = nil }
        return pendingShortcutType
    }

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 注册系统远程控制事件与长音频会话类别，保障切回桌面顺滑吸入灵动岛
        application.beginReceivingRemoteControlEvents()
        PlayerEngine.configurePlaybackAudioSessionCategory()
        if let shortcut = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            Task { @MainActor in
                Self.enqueueShortcut(shortcut.type)
            }
            return false
        }
        return true
    }

    public func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let shortcut = options.shortcutItem {
            Task { @MainActor in
                Self.enqueueShortcut(shortcut.type)
            }
        }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = MyGoSceneDelegate.self
        return config
    }
}

public final class MyGoSceneDelegate: NSObject, UIWindowSceneDelegate {
    public func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let shortcut = connectionOptions.shortcutItem {
            Task { @MainActor in
                MyGoApplicationDelegate.enqueueShortcut(shortcut.type)
            }
        }
    }

    public func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            MyGoApplicationDelegate.enqueueShortcut(shortcutItem.type)
            completionHandler(true)
        }
    }
}
#endif
#endif

// MARK: - 主题强调色与桌面图标选择器（#15）

private struct AccentColorPickerRow: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(I18n.t("Accent Color"))
                Spacer()
                Text(I18n.t(app.settings.accentPreset.labelKey))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ForEach(AccentColorPreset.allCases) { preset in
                    let isSelected = (app.settings.accentPreset == preset)
                    let swatch = MyGoTheme.color(for: preset)
                    Button {
                        MyGoHaptics.selection()
                        MyGoTheme.setAccentPreset(preset)
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.78)) {
                            app.settings.accentPreset = preset
                        }
                    } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                Circle()
                                    .fill(swatch)
                                    .frame(width: 32, height: 32)
                                if isSelected {
                                    Circle()
                                        .strokeBorder(swatch.opacity(0.45), lineWidth: 2.5)
                                        .frame(width: 40, height: 40)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12.5, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 40, height: 40)

                            Text(I18n.t(preset.labelKey))
                                .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(I18n.t(preset.labelKey))
                }
            }
        }
        .padding(.vertical, 4)
    }
}

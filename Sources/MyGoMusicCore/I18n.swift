// I18n.swift
// 对应原项目 internal/i18n/i18n.go 与 zh_cn.go 的多语言国际化系统

import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"
    case english = "en"
    case chinese = "zh-CN"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return I18n.t("Follow System")
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }
}

/// 国际化引擎（完整移植自 internal/i18n）
public final class I18n: @unchecked Sendable {
    public static let shared = I18n()

    private let lock = NSLock()
    private var selected: AppLanguage = .system

    private init() {}

    /// 设置当前语言偏好
    public static func setLanguage(_ lang: AppLanguage) {
        shared.lock.lock()
        shared.selected = lang
        shared.lock.unlock()
    }

    /// 获取实际生效的语言代码（"en" 或 "zh-CN"）
    public static func languageCode() -> String {
        shared.lock.lock()
        let current = shared.selected
        shared.lock.unlock()

        switch current {
        case .english:
            return "en"
        case .chinese:
            return "zh-CN"
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
            if preferred.lowercased().hasPrefix("zh") {
                return "zh-CN"
            }
            return "en"
        }
    }

    /// 翻译文本
    public static func t(_ key: String) -> String {
        if languageCode() == "zh-CN", let translated = zhCN[key] {
            return translated
        }
        if let pipeIndex = key.firstIndex(of: "|") {
            return String(key[..<pipeIndex])
        }
        return key
    }

    /// 带上下文的翻译（如 "Save|library"）
    public static func tc(_ key: String, _ context: String) -> String {
        return t("\(key)|\(context)")
    }

    /// 格式化翻译（自动将 Go 风格的 %s 转换为 Foundation String(format:) 所需的 %@）
    public static func tf(_ key: String, _ args: CVarArg...) -> String {
        let format = t(key).replacingOccurrences(of: "%s", with: "%@")
        return String(format: format, arguments: args)
    }

    /// 歌曲数量格式化
    public static func songs(_ count: Int) -> String {
        if count == 1 {
            return t("1 song")
        }
        return tf("%d songs", count)
    }

    /// 专辑数量格式化
    public static func albums(_ count: Int) -> String {
        if count == 1 {
            return t("1 album")
        }
        return tf("%d albums", count)
    }

    /// 播客节目期数格式化
    public static func episodes(_ count: Int) -> String {
        if count == 1 {
            return t("1 episode")
        }
        return tf("%d episodes", count)
    }

    /// 今日日期格式化（对应 i18n.Today）
    public static func today(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        if languageCode() == "zh-CN" {
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 EEEE"
        } else {
            formatter.locale = Locale(identifier: "en_US")
            formatter.dateFormat = "EEEE, MMMM d"
        }
        return formatter.string(from: date)
    }

    /// 问候语（对应 greeting）
    public static func greeting(for date: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        if hour < 5 {
            return t("Good night")
        } else if hour < 12 {
            return t("Good morning")
        } else if hour < 18 {
            return t("Good afternoon")
        } else {
            return t("Good evening")
        }
    }

    /// 相对时间格式化
    public static func relativeTime(from timestampMs: Int64?, now: Date = Date()) -> String {
        guard let ms = timestampMs, ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 {
            return t("just now")
        }
        let minutes = seconds / 60
        if minutes == 1 {
            return t("a minute ago")
        }
        if minutes < 60 {
            return tf("%d minutes ago", minutes)
        }
        let hours = minutes / 60
        if hours == 1 {
            return t("an hour ago")
        }
        if hours < 24 {
            return tf("%d hours ago", hours)
        }
        let days = hours / 24
        if days == 1 {
            return t("yesterday")
        }
        if days < 30 {
            return tf("%d days ago", days)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - 完整简体中文词典（移植自 internal/i18n/zh_cn.go）
    public static let zhCN: [String: String] = [
        "%.1f GB used": "已用 %.1f GB",
        "%d MB used": "已用 %d MB",
        "%d albums": "%d 张专辑",
        "%d days ago": "%d 天前",
        "%d episodes": "%d 期",
        "%d hours ago": "%d 小时前",
        "%d minutes ago": "%d 分钟前",
        "%d songs": "%d 首",
        "%d songs found": "找到 %d 首歌曲",
        "%s Mini Player": "%s迷你播放器",
        "%s and more · %s": "%s 等 · %s",
        "%s isn't available right now": "%s 暂时不可用",
        "%s needs setting up first": "%s 需要先进行设置",
        "%s, %s": "%s，%s",
        "1 GB": "1 GB",
        "1 album": "1 张专辑",
        "1 episode": "1 期",
        "1 song": "1 首",
        "10 GB": "10 GB",
        "2 GB": "2 GB",
        "5 GB": "5 GB",
        "About": "简介",
        "About %s": "关于%s",
        "About This Episode": "节目简介",
        "Account": "账户",
        "Add": "添加",
        "Add Folder…": "添加文件夹…",
        "Add a Music Folder": "添加音乐文件夹",
        "Add a music folder": "添加音乐文件夹",
        "Add the folders where your music lives": "添加存放音乐的文件夹",
        "Add to Playlist": "添加到歌单",
        "Added to Liked Songs": "已添加到我喜欢的音乐",
        "Added to the playlist": "已添加到歌单",
        "Adjust each song's volume by what its plugin measured of it, for them to sound as loud as each other": "按插件测得的响度调整每首歌的音量，让歌曲听起来一样响",
        "Album": "专辑",
        "Album Cover": "专辑封面",
        "Albums": "专辑",
        "Albums you save will show here": "收藏的专辑会显示在这里",
        "Appearance": "外观",
        "Artist": "歌手",
        "Artists": "歌手",
        "Back": "返回",
        "Buffering…": "正在缓冲…",
        "Built-in": "自带",
        "Cache": "缓存",
        "Can reach %s": "可访问 %s",
        "Can reach any website": "可访问任何网站",
        "Cancel": "取消",
        "Captions": "字幕",
        "Captions are off": "字幕已关闭",
        "Captions for Podcasts": "为播客生成字幕",
        "Change Repeat Mode": "切换循环模式",
        "Check for Updates": "检查更新",
        "Checking for updates…": "正在检查更新…",
        "Choose where your music lives, and it will all be here: MP3, FLAC, Ogg, WAV and M4A files, with their tags, covers and lyrics.": "选择存放音乐的位置，歌曲都会出现在这里：MP3、FLAC、Ogg、WAV 与 M4A 文件，连同标签、封面和歌词。",
        "Clear": "清除",
        "Clear Recent Searches": "清空搜索历史",
        "Clear Search": "清除搜索",
        "Clear the Cache": "清除缓存",
        "Close": "关闭",
        "Comments": "评论",
        "Controls": "控制",
        "Copy": "拷贝",
        "Copy Link": "复制链接",
        "Copy Title": "复制歌名",
        "Copy Title and Artists": "复制歌名和歌手",
        "Couldn't add it to the playlist. Try again later.": "添加失败，请稍后再试",
        "Couldn't check for updates": "无法检查更新",
        "Couldn't create the playlist. Try again later.": "创建歌单失败，请稍后再试",
        "Couldn't delete the playlist. Try again later.": "删除失败，请稍后再试",
        "Couldn't download this song": "下载失败，请稍后再试",
        "Couldn't load the comments": "评论加载失败",
        "Couldn't load the stations": "电台加载失败",
        "Couldn't load this album": "专辑加载失败",
        "Couldn't load this artist": "歌手加载失败",
        "Couldn't load this page": "页面加载失败",
        "Couldn't load this playlist": "歌单加载失败",
        "Couldn't load this podcast": "播客加载失败",
        "Couldn't load your albums": "专辑加载失败",
        "Couldn't load your liked songs": "喜欢的音乐加载失败",
        "Couldn't load your playlists": "歌单加载失败",
        "Couldn't load your podcasts": "播客加载失败",
        "Couldn't load. Click to try again.": "加载失败，点按重试",
        "Couldn't move the song. Try again later.": "移动失败，请稍后再试",
        "Couldn't play this song": "无法播放这首歌",
        "Couldn't post your comment. Try again later.": "评论发送失败，请稍后再试",
        "Couldn't reach this plugin": "无法连接这个插件",
        "Couldn't remove it from the playlist. Try again later.": "移除失败，请稍后再试",
        "Couldn't rename the playlist. Try again later.": "重命名失败，请稍后再试",
        "Couldn't sign out": "退出登录失败",
        "Create": "创建",
        "Creating…": "正在创建…",
        "Current Version %s": "当前版本 %s",
        "Dark": "深色",
        "Daily Picks": "每日推荐",
        "Daily Song Picks": "每日歌曲推荐",
        "Delete": "删除",
        "Delete Playlist": "删除歌单",
        "Delete Playlist…": "删除歌单…",
        "Delete all the songs kept here": "删除保存在本机的全部歌曲",
        "Delete the playlist “%s”? This can't be undone.": "确定删除歌单“%s”吗？删除后无法恢复。",
        "Discover": "发现",
        "Download": "下载",
        "Download…": "下载…",
        "Downloaded %s": "已下载《%s》",
        "Downloading…": "正在下载…",
        "Edit": "编辑",
        "Enable %s": "启用 %s",
        "Episodes": "节目",
        "Even Out Loudness": "音量均衡",
        "Experiments": "实验性功能",
        "File": "文件",
        "Fill in %s for it to work": "填写%s后才能使用",
        "Flow": "流光",
        "Fog Backdrop": "烟雾背景",
        "The album-colored fog drifts behind the Now Playing screen.": "播放页背景会随音乐缓慢流动封面色雾效。",
        "Fog Backdrop Description": "播放页封面色雾效随音乐缓慢流动。",
        "Follow": "关注",
        "Follow System": "跟随系统",
        "Following": "已关注",
        "Forward": "前进",
        "From %s": "来自 %s",
        "From GitHub…": "从 GitHub…",
        "From a Folder…": "从文件夹…",
        "From a Zip…": "从 Zip 文件…",
        "From this computer": "来自本机",
        "General": "通用",
        "Go to Album: %s": "查看专辑：%s",
        "Go to Artist: %s": "查看歌手：%s",
        "Go to Podcast": "查看播客",
        "Good afternoon": "下午好",
        "Good evening": "晚上好",
        "Good morning": "早上好",
        "Good night": "夜深了",
        "Grow From the Cover": "从封面展开",
        "Hear something new": "听见更多好音乐",
        "High": "高",
        "Home": "首页",
        "Import Audio Files…": "导入音频文件…",
        "No audio files imported": "没有导入音频文件，请检查所选项目是否包含受支持的音频格式。",
        "In intros, breaks and outros, a song's top comments show in place of the lyrics": "前奏、间奏与尾奏时，歌词处换成这首歌的热门评论",
        "Install": "安装",
        "Install %s": "安装 %s",
        "Install %s?": "要安装 %s 吗？",
        "Install a Plugin": "安装插件",
        "Install from GitHub": "从 GitHub 安装",
        "Language": "语言",
        "Leave %s": "退出%s",
        "Left %s": "已退出%s",
        "Library": "音乐库",
        "Light": "浅色",
        "Like": "喜欢",
        "Like/Unlike": "喜欢/取消喜欢",
        "Liked Songs": "我喜欢的音乐",
        "Loading…": "正在加载…",
        "Local Files": "本地文件",
        "Looking for music…": "正在查找音乐…",
        "Lossless": "无损",
        "Lyrics": "歌词",
        "More": "更多",
        "More for %s": "%s 的更多操作",
        "Move Down": "下移",
        "Move Up": "上移",
        "Music without end": "无尽音乐",
        "Mute": "静音",
        "My Page": "我的主页",
        "My Playlists": "我的歌单",
        "New Playlist": "新建歌单",
        "New Playlist…": "新建歌单…",
        "Next": "下一首",
        "No albums": "暂无专辑",
        "No comments yet": "还没有评论",
        "No episodes yet": "暂无节目",
        "No lyrics. Enjoy the music.": "纯音乐，请欣赏",
        "No music found": "没有找到音乐",
        "No settings found": "没有找到相关设置",
        "No stations yet": "暂无电台",
        "Not Playing": "未在播放",
        "Nothing found": "没有找到相关结果",
        "Nothing here yet": "这里还什么都没有",
        "Now Playing": "正在播放",
        "Effects Preview": "效果预览",
        "Choose a song to preview its cover colors.": "选择歌曲后可预览封面配色与烟雾效果。",
        "Off": "关闭",
        "Open": "打开",
        "Open %s": "打开%s",
        "Open Now Playing": "打开正在播放",
        "Open Settings": "打开设置",
        "Open on GitHub": "在 GitHub 上打开",
        "Opening the plugin…": "正在打开插件…",
        "Pause": "暂停播放",
        "Play": "播放",
        "Play/Pause": "播放/暂停",
        "Playback": "播放",
        "Playing": "正在播放",
        "Playing something else elsewhere": "另一端正在播放其他内容",
        "Playlist": "歌单",
        "Playlist Name": "歌单名称",
        "Playlist deleted": "已删除歌单",
        "Playlists": "歌单",
        "Plugin": "插件",
        "Plugins": "插件",
        "Podcast": "播客",
        "Podcasts": "播客",
        "Podcasts you subscribe to will show here": "订阅的播客会显示在这里",
        "Post": "发送",
        "Previous": "上一首",
        "Progress": "播放进度",
        "Quality": "音质",
        "Queue": "播放队列",
        "Radio": "电台",
        "Recent Searches": "搜索历史",
        "Recently Played": "最近播放",
        "Remove": "移除",
        "Remove %s?": "要移除 %s 吗？",
        "Remove from Playlist": "从歌单中移除",
        "Remove from Saved": "取消收藏",
        "Remove…": "移除…",
        "Removed from Liked Songs": "已取消喜欢",
        "Removed from Saved": "已取消收藏",
        "Rename Playlist": "重命名歌单",
        "Rename…": "重命名…",
        "Repeat": "循环",
        "Rescan": "重新扫描",
        "Resume": "继续播放",
        "Retry": "重试",
        "Save": "保存",
        "Save|library": "收藏",
        "Saved": "已收藏",
        "Saved Albums": "收藏的专辑",
        "Saved Playlists": "收藏的歌单",
        "Search": "搜索",
        "Search Results": "搜索结果",
        "Search Settings": "搜索设置",
        "Search for something to play.": "搜索想听的音乐。",
        "Search for “%s”": "搜索“%s”",
        "Search · %s": "搜索 · %s",
        "See All": "查看全部",
        "Services": "服务",
        "Settings": "设置",
        "Settings…": "设置…",
        "Shuffle": "随机播放",
        "Sign In": "登录",
        "Sign Out": "退出登录",
        "Sign in to %s": "登录 %s",
        "Sign in to %s to see this": "登录 %s 后才能查看",
        "Sign in to play this song": "登录后才能播放这首歌",
        "Signed in as %s": "已登录：%s",
        "Smoke on the Progress Bar": "进度条烟雾特效",
        "A glowing playhead trails smoke during playback; it pauses while seeking.": "播放时进度头会发光并拖出烟雾；暂停或拖动进度条时停止。",
        "Progress Smoke Description": "播放时，进度头会发光并拖出烟雾；暂停或拖动进度条时停止。",
        "Song": "歌曲",
        "Song Cache": "歌曲缓存",
        "Songs": "歌曲",
        "Songs will show here as they're found.": "找到的歌曲会显示在这里。",
        "Songs you like will show here": "喜欢的歌曲会显示在这里",
        "Source": "音源",
        "Sources": "音源切换",
        "Sparks": "火花",
        "Stage": "律动",
        "Stage Style": "律动效果",
        "Standard": "标准",
        "Start Listening": "开始收听",
        "Stations": "电台",
        "Steps": "云阶",
        "Subscribe": "订阅",
        "Subscribed": "已订阅",
        "Suggestions": "搜索建议",
        "System": "跟随系统",
        "That didn't work. Try again later.": "操作失败，请稍后再试",
        "That's all the comments": "没有更多评论了",
        "The plugin needs setting up": "插件需要先进行设置",
        "The plugin of this song is gone": "这首歌的插件已不存在",
        "The search failed": "搜索失败，请稍后再试",
        "The station didn't answer": "电台没有响应",
        "The station has nothing more right now": "电台暂时没有更多歌曲",
        "There are no music files in the folders you chose. Try another.": "所选文件夹中没有音乐文件，请换一个试试。",
        "There's no such public repository on GitHub": "GitHub 上没有这个公开仓库",
        "This episode has no description": "这期节目没有简介",
        "This page is gone": "这个页面已不存在",
        "This song isn't available": "这首歌无法播放",
        "This station can't play right now. Try again later.": "电台暂时无法播放，请稍后再试",
        "Tilt": "倾诉",
        "Top Comment": "热评",
        "Top Comments in Quiet Parts": "间奏时显示热评",
        "Tuning in…": "正在调频…",
        "Turn On": "开启",
        "Unfollowed": "已取消关注",
        "Unlike": "取消喜欢",
        "Unsubscribed": "已取消订阅",
        "Up Next": "待播清单",
        "Up to date": "已是最新",
        "Update to %s": "更新到 %s",
        "Updates": "更新",
        "Updating…": "正在更新…",
        "Various Artists": "群星",
        "View Comments": "查看评论",
        "Volume": "音量",
        "Waiting for you to finish signing in…": "正在等待你完成登录…",
        "Wall": "选歌",
        "Write a comment…": "写评论…",
        "Write a repository as owner/repo, or its address on GitHub": "请填写 owner/repo，或仓库的 GitHub 地址",
        "Zip Archive": "Zip 压缩包",
        "a minute ago": "1 分钟前",
        "an hour ago": "1 小时前",
        "just now": "刚刚",
        "owner/repo or URL": "owner/repo 或网址",
        "yesterday": "昨天",
        // 上游 v0.1.23~v0.1.24 与完整功能补全词条
        "Current value": "当前值",
        "Save changes": "保存修改",
        "Discard changes": "放弃修改",
        "Import Plugin Folder": "导入本地插件文件夹",
        "Check for Plugin Updates": "检查插件更新",
        "GitHub Token": "GitHub 访问令牌（可选）",
        "Optional token to avoid GitHub rate limits": "填写个人访问令牌可避免 GitHub 接口限流",
        "AirPlay": "AirPlay 投屏",
        "Output Device": "音频输出设备",
        "Load More": "加载更多",
        "Live Captions": "实时字幕",
        "Turn On Captions": "开启字幕",
        "Speech recognition not authorized": "未授权语音识别权限",
        "Recognizing captions…": "正在识别字幕…",
        "No updates available": "全部插件均为最新版本",
        "Update to %s available": "有新版本 %s 可更新",
        "Not installed via GitHub": "非 GitHub 安装插件",
        "Plugin Settings": "插件设置",
        "%s needs MyGo Music %s or later": "%@ 需要 MyGo Music %@ 或更高版本",
        "All Formats": "全部音质",
        "Installing…": "正在安装…",
        "Reload Page": "刷新页面",
        "Fade Between Songs": "切歌平滑淡入淡出",
        "Smoothly fade audio out and in when switching or pausing tracks": "切歌或暂停时让声音渐强渐弱过渡",
        "Open Now Playing with a spring transition from the mini bar": "打开播放页时采用弹性展开动画",
        "Automatically generate timed captions for local podcast episodes": "为本地或离线播客生成同步时间轴字幕",
        "Import Plugin (Folder / Zip)…": "导入本地插件（文件夹 / Zip）…",
        "Checking…": "正在检查…",
        "Plugin Load Errors": "插件加载异常",
        "Needs Process Permission": "需要本地进程权限",
        "Grant Permission": "授予权限",
        "Process permission granted": "已授予进程权限",
        "Update": "更新",
        "Lock Screen Lyrics": "锁屏歌词",
        "Show the active lyric line in the Lock Screen media title while playing": "播放时在系统锁屏和蓝牙媒体卡片实时显示当前歌词",
        "Playback timed out while buffering. Please try again.": "缓冲超时，请检查网络或切换音质后重试",
        "Current audio format (%@) is not supported on iOS yet": "当前音频格式（%@）暂不支持在 iOS 播放",
        "No playable tracks in this list (VIP or copyright restricted)": "当前列表暂无可播放歌曲（需要 VIP 或无版权）",
        "VIP / No Rights": "VIP / 暂无版权",
        // 插件在线更新与社区目录词条
        "Check for Update": "检查更新",
        "Update All Plugins": "一键更新全部插件",
        "Link GitHub Source…": "绑定 GitHub 更新源…",
        "Change Repository…": "更换 GitHub 仓库…",
        "Save & Check Updates": "保存并检查更新",
        "Local import · No update source linked": "本地导入 · 未绑定更新源",
        "Link Update Source": "绑定更新源",
        "Reinstall Latest": "重新拉取最新版本",
        "Online Plugin Directory": "在线社区插件目录",
        "Fetching community plugins…": "正在从 GitHub 获取插件目录…",
        "No community plugins found": "暂未搜索到社区插件",
        "Tap to install from GitHub": "点击即可从 GitHub 在线安装",
        "Installed": "已安装",
        "Updates Available (%d)": "有 %d 个更新可用",
        "Linked GitHub update source": "已绑定 GitHub 更新源",
        "Plugin Permission Update": "插件权限变更确认",
        "Confirm & Update": "允许并更新",
        "%@ wants additional permissions in %@:\n%@": "%@ 在升级到 %@ 时申请了新的权限：\n%@",
        "Network access: %@": "网络访问：%@",
        "Run local helper processes": "运行本地辅助进程",
        "Updated %@ %@": "已更新 %@ %@",
        "Installed %@": "已安装 %@",
        "Checked updates · %d available": "检查完成 · 有 %d 个插件可更新",
        "No plugins have a GitHub update source yet": "当前已安装插件均未绑定 GitHub 更新源",
        "Link a GitHub repository (owner/repo) to enable one-tap online updates for this plugin.": "为该本地插件绑定 GitHub 仓库（owner/repo 或完整链接），即可支持在线检查与一键更新。",
        "Refresh": "刷新",
        "Top Songs": "热门歌曲",
        "Latest Release": "最新发行",
        "Show Less": "收起",
        // iOS 系统特性与灵动岛/交互体验词条
        "Play Next": "下一首播放",
        "Add to Queue": "添加到播放队列",
        "Added to queue": "已添加到播放队列",
        "Playing next": "将在下一首播放",
        "Share": "分享",
        "Share Track": "分享歌曲",
        "Sleep Timer": "睡眠定时",
        "Turn Off Timer": "关闭定时",
        "After Current Track": "播完当前这首后停止",
        "15 Minutes": "15 分钟后停止",
        "30 Minutes": "30 分钟后停止",
        "45 Minutes": "45 分钟后停止",
        "60 Minutes": "60 分钟后停止",
        "Sleep timer turned off": "已关闭睡眠定时",
        "Sleep timer set for %d minutes": "睡眠定时：%d 分钟后暂停播放",
        "Playback will stop after current track": "将在当前歌曲播放完毕后停止",
        "Sleep timer ended · Playback paused": "睡眠定时已结束 · 已暂停播放",
        "Resume Playback": "继续播放",
        "Dismiss Now Playing": "收起正在播放界面",
        "More Actions": "更多操作",
        "Previous Track": "上一首",
        "Next Track": "下一首",
        "Toggle Shuffle": "切换随机播放",
        "Cycle Repeat Mode": "切换循环模式",
        "No recent tracks available": "暂无可续播的最近歌曲",
        "Go to Album": "前往专辑",
        "Daily Mix": "每日推荐",
        // 12项体验升级与系统集成词条
        "Gapless Playback": "无缝切歌",
        "Eliminate gaps between consecutive tracks": "预缓冲下一首曲目，实现无停顿连贯切歌",
        "Crossfade": "交叉淡入淡出",
        "Overlap the end of one song into the next": "上一首末尾渐弱并与下一首开头平滑混音重叠",
        "Crossfade Duration": "交叉淡化时长",
        "Equalizer": "均衡器与音效",
        "10-Band Parametric EQ": "10 段均衡器",
        "Enable Equalizer": "开启均衡器",
        "Preamp": "前置增益",
        "Reset Flat": "重置平坦",
        "Preset": "音效预设",
        "Flat": "原声平坦",
        "Pop": "流行",
        "Rock": "摇滚",
        "Classical": "古典",
        "Jazz": "爵士",
        "Vocal": "人声增强",
        "Bass Boost": "超重低音",
        "Late Night": "深夜模式",
        "Custom": "自定义",
        "Wi-Fi Quality": "Wi-Fi 播放音质",
        "Cellular Quality": "移动网络播放音质",
        "Current Network: Wi-Fi": "当前网络：Wi-Fi（采用 Wi-Fi 音质）",
        "Current Network: Cellular": "当前网络：移动蜂窝（采用省流音质）",
        "Audio Signal Path": "音频信号路径",
        "Source & Decoding": "音源与解码",
        "DSP Processing": "音频信号处理 (DSP)",
        "Hardware Output": "硬件音频输出",
        "Delivery Mode": "传输方式",
        "Container Format": "音频容器",
        "Sample Rate & Bit Depth": "采样率与位深",
        "Loudness Normalization": "响度均衡",
        "Transition": "切歌过渡",
        "Output Device Name": "当前输出设备",
        "Offline File": "本地永久离线文件",
        "Disk Cache": "本地磁盘缓存秒开",
        "Streaming Proxy": "边播边缓流式代理",
        "Direct Stream": "网络直连音频流",
        "Waveform Seek Bar": "全曲音频波形进度条",
        "Visualize track energy envelope along the seek bar": "在进度条渲染全曲音频能量分布波形",
        "Locate Current": "定位当前",
        "Save as Playlist": "存为歌单",
        "Clear Queue": "清空队列",
        "Queue Cleared": "已清空待播清单",
        "Playlist saved": "已保存为新歌单",
        "Download Offline": "下载到本地",
        "Remove Download": "删除离线文件",
        "Offline Downloads": "离线下载",
        "Downloaded for offline playback": "已保存至本地离线曲库",
        "Download failed": "离线下载失败",
        "Removed offline download": "已移除本地离线文件",
        "Download All": "全部离线",
        "Select": "多选",
        "Select All": "全选",
        "Deselect All": "取消全选",
        "Accent Color": "主题强调色",
        "Crimson": "绯红",
        "Amber Gold": "黑金琥珀",
        "Glacier Blue": "冰川蓝",
        "Dream Purple": "星云紫",
        "Emerald Green": "翡翠绿",
        "App Icon": "桌面应用图标",
        "MyGo Music": "MyGo Music",
        "Apple Music": "Apple Music",
        "Alternate icon updated": "已切换桌面应用图标",
        "Failed to change app icon": "切换桌面图标失败",
        "Done": "完成",
        "%d Selected": "已选 %d 首",
        "Playing next %d tracks": "已将 %d 首加入下一首播放",
        "Batch Add to Playlist": "批量添加到歌单",
        "Added %d tracks to playlist": "已将 %d 首歌曲添加到歌单",
        "New Playlist Name": "新歌单名称",
        "Enter a name for the new playlist": "为当前待播清单创建一个新歌单",
        "Save Queue": "保存待播清单",
        "%d Tracks": "共 %d 首",
        "Bit-Perfect Lossless": "无损母带级直出（无降级原声）",
        "Standard Audio": "压缩编码传输（已启用节流/常规音质）",
        "Swipe Down or Tap Outside to Dismiss": "向下滑动或点击空白处关闭",
        "Tap to view signal path": "点击查看音频信号路径",
        "Queue is empty": "待播清单为空",
        "Start batch download for %d tracks": "开始离线下载 %d 首歌曲",
        "All selected tracks are already downloaded": "所选歌曲已全部离线下载",
        "Queued tracks saved": "已保存待播清单为新歌单",
        "Selected": "已选",
        "Cover": "封面",
        "Cover Player": "经典封面播放页",
        "Display the Apple Music-style large cover player by default": "打开播放器时优先展现 Apple Music 风格大封面界面",
        "View Mode": "切换视图"
    ]
}

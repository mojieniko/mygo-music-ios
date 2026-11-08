// ThemeAndComponents.swift
// 对应原项目 internal/app/ui_kit.go, ui_daily.go, artwork.go 的主题配色与通用 UI 组件

#if canImport(MyGoMusicCore)
import MyGoMusicCore
#endif
import CoreImage
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - 二维码生成器（对应原项目 internal/app/ui_account.go 中的 qr.Encode）

public enum MyGoQRCodeGenerator {
    private static let context = CIContext()

    /// 将文本或 URL 字符串编码为高清无锯齿二维码 SwiftUI Image
    public static func generate(from string: String) -> Image? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 兼容 data:image/png;base64,... 格式
        if trimmed.hasPrefix("data:image/"),
           let commaIdx = trimmed.firstIndex(of: ",") {
            let b64 = String(trimmed[trimmed.index(after: commaIdx)...])
            if let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
               let img = makeSwiftUIImage(from: data) {
                return img
            }
        }

        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(trimmed.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if canImport(UIKit)
        return Image(uiImage: UIImage(cgImage: cgImage))
        #elseif canImport(AppKit)
        return Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
        #endif
    }

    public static func makeSwiftUIImage(from data: Data) -> Image? {
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #elseif canImport(AppKit)
        guard let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
        #endif
    }
}

// MARK: - 带插件防盗链 Header 支持的封面图片缓存加载器

@MainActor
public final class ArtworkImageLoader: ObservableObject {
    private static let cache = NSCache<NSString, NSData>()
    private static let paletteContext = CIContext()
    @Published public private(set) var image: Image? = nil
    @Published public private(set) var dominantColor: Color? = nil

    public init() {}

    public func load(
        rawURLString: String?,
        pixelSize: Int,
        extractDominantColor: Bool = false,
        headersProvider: ((URL) -> [String: String])?
    ) async {
        if extractDominantColor { dominantColor = nil }
        guard let resolved = sizedImageURL(rawURLString, px: pixelSize), !resolved.isEmpty else {
            self.image = nil
            self.dominantColor = nil
            return
        }

        let cacheKey = resolved as NSString
        if let cached = Self.cache.object(forKey: cacheKey),
           let img = MyGoQRCodeGenerator.makeSwiftUIImage(from: cached as Data) {
            self.image = img
            if extractDominantColor { updateDominantColor(from: cached as Data) }
            return
        }

        if resolved.hasPrefix("data:image/"),
           let comma = resolved.firstIndex(of: ",") {
            let b64 = String(resolved[resolved.index(after: comma)...])
            if let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
               let img = MyGoQRCodeGenerator.makeSwiftUIImage(from: data) {
                Self.cache.setObject(data as NSData, forKey: cacheKey)
                self.image = img
                if extractDominantColor { updateDominantColor(from: data) }
            }
            return
        }

        let targetURL: URL?
        if resolved.hasPrefix("file://") {
            let stripped = String(resolved.dropFirst("file://".count))
            targetURL = URL(fileURLWithPath: stripped.removingPercentEncoding ?? stripped)
        } else if resolved.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: resolved)
        } else {
            targetURL = URL(string: resolved)
        }

        guard let url = targetURL else {
            self.image = nil
            return
        }

        if url.isFileURL {
            if let data = try? Data(contentsOf: url),
               let img = MyGoQRCodeGenerator.makeSwiftUIImage(from: data) {
                Self.cache.setObject(data as NSData, forKey: cacheKey)
                self.image = img
                if extractDominantColor { updateDominantColor(from: data) }
            }
            return
        }

        var req = URLRequest(url: url)
        let headers = headersProvider?(url) ?? [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) mygo-music/0.1"
        ]
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }

        if let (data, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400,
           let img = MyGoQRCodeGenerator.makeSwiftUIImage(from: data) {
            Self.cache.setObject(data as NSData, forKey: cacheKey)
            self.image = img
            if extractDominantColor { updateDominantColor(from: data) }
        }
    }

    private func updateDominantColor(from data: Data) {
        #if canImport(UIKit)
        guard let image = UIImage(data: data), let cgImage = image.cgImage else { return }
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return }
        var pixel = [UInt8](repeating: 0, count: 4)
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        Self.paletteContext.render(output, toBitmap: &pixel, rowBytes: 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

        let average = UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        let tint = UIColor(
            hue: hue,
            saturation: min(max(saturation * 1.25, 0.38), 0.82),
            brightness: min(max(brightness * 1.65, 0.48), 0.82),
            alpha: 1
        )
        dominantColor = Color(uiColor: tint)
        #endif
    }
}

// MARK: - 颜色与主题系统（移植自 internal/app/ui_kit.go）

public enum MyGoTheme {
    /// 主强调色（对应原项目 Oklch(0.66, 0.2, 22) 暖珊瑚红）
    public static let accent = Color(red: 0.93, green: 0.32, blue: 0.26)
    /// 无损音质徽章金色（对应 #f5d58a）
    public static let losslessGold = Color(red: 0.96, green: 0.84, blue: 0.54)
    /// 深色背景（对应 #141416）
    public static let darkBg = Color(red: 0.078, green: 0.078, blue: 0.086)
    /// 深色侧栏/卡片底色（对应 #1c1c1f）
    public static let darkSurface = Color(red: 0.11, green: 0.11, blue: 0.122)
    /// 正在播放深邃背景（对应 #0b0b0d）
    public static let nowPlayingBg = Color(red: 0.043, green: 0.043, blue: 0.051)

    /// 格式化秒数为 m:ss（对应 clock）
    public static func formatClock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 封面图片组件（支持网络 URL、{size} 占位符、本地路径及优雅占位符）

public struct ArtworkView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var loader = ArtworkImageLoader()

    public let urlString: String?
    public let pixelSize: Int
    public let size: CGFloat
    public let cornerRadius: CGFloat
    public var systemIcon: String = "music.note"

    public init(
        urlString: String?,
        pixelSize: Int = 400,
        size: CGFloat = 48,
        cornerRadius: CGFloat = 8,
        systemIcon: String = "music.note"
    ) {
        self.urlString = urlString
        self.pixelSize = pixelSize
        self.size = size
        self.cornerRadius = cornerRadius
        self.systemIcon = systemIcon
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.07))

            if let image = loader.image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                placeholderIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: urlString) {
            await loader.load(rawURLString: urlString, pixelSize: pixelSize) { url in
                app.imageHeaders(for: url)
            }
        }
    }

    private var placeholderIcon: some View {
        Image(systemName: systemIcon)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(.secondary.opacity(0.55))
    }
}

// MARK: - 动态音频波形条（对应 ui_kit.go 中的 barState / bars）

public struct EqualizerBarsView: View {
    public let bands: [Float]
    public let isPlaying: Bool
    public var color: Color = MyGoTheme.accent
    public var barCount: Int = 4

    public init(bands: [Float], isPlaying: Bool, color: Color = MyGoTheme.accent, barCount: Int = 4) {
        self.bands = bands
        self.isPlaying = isPlaying
        self.color = color
        self.barCount = barCount
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { idx in
                let level = idx < bands.count ? CGFloat(bands[idx]) : 0.2
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 2.8, height: max(3, 14 * (isPlaying ? level : 0.2)))
                    .animation(.easeOut(duration: 0.09), value: level)
            }
        }
        .frame(height: 14)
    }
}

// MARK: - 每日推荐胶片黑胶卡片（移植自 internal/app/ui_daily.go）

public struct DailyFeatureCardView: View {
    public let section: MusicSection
    public let isPlayingFromCard: Bool
    public let audioBands: [Float]
    public let onPlay: () -> Void
    public let onOpen: () -> Void

    @State private var spinAngle: Double = 0

    public init(
        section: MusicSection,
        isPlayingFromCard: Bool,
        audioBands: [Float],
        onPlay: @escaping () -> Void,
        onOpen: @escaping () -> Void
    ) {
        self.section = section
        self.isPlayingFromCard = isPlayingFromCard
        self.audioBands = audioBands
        self.onPlay = onPlay
        self.onOpen = onOpen
    }

    public var body: some View {
        let tracks = section.tracks ?? []
        let firstTrack = tracks.first
        let artistSummary: String = {
            var seen = Set<String>()
            var ordered: [String] = []
            for name in tracks.compactMap({ $0.artists?.first?.name }) {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
                seen.insert(trimmed)
                ordered.append(trimmed)
                if ordered.count >= 2 { break }
            }
            return ordered.joined(separator: ", ")
        }()

        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [
                        MyGoTheme.accent.opacity(0.88),
                        Color(red: 0.45, green: 0.14, blue: 0.26),
                        Color(red: 0.14, green: 0.10, blue: 0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // 右侧旋转黑胶唱片（对应 dailySpin）
                HStack {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(
                                AngularGradient(
                                    colors: [.black, .white.opacity(0.14), .black, .white.opacity(0.12), .black],
                                    center: .center
                                )
                            )
                            .frame(width: 128, height: 128)
                            .overlay(
                                Circle()
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                            )

                        ArtworkView(
                            urlString: firstTrack?.album.imageUrl,
                            pixelSize: 300,
                            size: 54,
                            cornerRadius: 27
                        )
                        Circle()
                            .fill(.black)
                            .frame(width: 10, height: 10)
                    }
                    .rotationEffect(.degrees(spinAngle))
                    .offset(x: 16, y: 6)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title ?? I18n.t("Daily Picks"))
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(.white)

                    if !artistSummary.isEmpty {
                        Text("\(artistSummary) · \(I18n.songs(tracks.count))")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                    } else {
                        Text(I18n.songs(tracks.count))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.78))
                    }

                    Spacer(minLength: 12)

                    Button(action: onPlay) {
                        HStack(spacing: 6) {
                            if isPlayingFromCard {
                                EqualizerBarsView(bands: audioBands, isPlaying: true, color: .white, barCount: 3)
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            Text(I18n.t("Play"))
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
            }
            .frame(height: 156)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .onAppear {
            if isPlayingFromCard {
                withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
                    spinAngle = 360
                }
            }
        }
    }
}

// MARK: - 通用单曲列表行（对应 trackRow）

public struct TrackRowView: View {
    @EnvironmentObject private var app: AppModel
    public let track: Track
    public let index: Int?
    public let onPlay: () -> Void

    public init(track: Track, index: Int? = nil, onPlay: @escaping () -> Void) {
        self.track = track
        self.index = index
        self.onPlay = onPlay
    }

    private var isCurrent: Bool {
        app.player.currentTrack?.compositeKey == track.compositeKey
    }

    public var body: some View {
        HStack(spacing: 12) {
            ZStack {
                ArtworkView(urlString: track.album.imageUrl, pixelSize: 120, size: 44, cornerRadius: 8)
                if isCurrent {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.black.opacity(0.45))
                        .frame(width: 44, height: 44)
                    EqualizerBarsView(
                        bands: app.player.audioBands,
                        isPlaying: app.player.isPlaying,
                        color: .white
                    )
                }
            }
            .onTapGesture(perform: onPlay)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                    .font(.system(size: 15, weight: isCurrent ? .bold : .medium))
                    .foregroundStyle(isCurrent ? MyGoTheme.accent : .primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if !track.artistNames.isEmpty {
                        Text(track.artistNames)
                    }
                    if !track.album.name.isEmpty {
                        Text("· \(track.album.name)")
                    }
                }
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onPlay)

            if track.duration > 0 {
                Text(MyGoTheme.formatClock(track.durationSeconds))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if app.activeSource.can("like") {
                let liked = app.isTrackLiked(track)
                Button {
                    Task { await app.toggleLike(track) }
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 15))
                        .foregroundStyle(liked ? MyGoTheme.accent : .secondary.opacity(0.7))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }

            Menu {
                Button(action: onPlay) {
                    Label(I18n.t("Play"), systemImage: "play.fill")
                }
                if app.activeSource.can("like") {
                    let liked = app.isTrackLiked(track)
                    Button {
                        Task { await app.toggleLike(track) }
                    } label: {
                        Label(liked ? I18n.t("Unlike") : I18n.t("Like"), systemImage: liked ? "heart.slash" : "heart")
                    }
                }
                if app.activeSource.can("addToPlaylist"), !app.myPlaylists.isEmpty {
                    Menu(I18n.t("Add to Playlist")) {
                        ForEach(app.myPlaylists.filter { $0.fixed != true }) { pl in
                            Button(pl.name) {
                                Task { await app.addTrack(track, toPlaylist: pl.id) }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCurrent ? MyGoTheme.accent.opacity(0.08) : Color.clear)
        )
        .opacity(track.unavailable == true ? 0.45 : 1.0)
    }
}

// MARK: - 通用方形封面卡片（对应 coverCard）

public struct CoverCardView: View {
    public let title: String
    public let subtitle: String?
    public let imageURL: String?
    public var systemIcon: String = "music.note"
    public var isCircular: Bool = false
    public var onPlay: (() -> Void)? = nil

    public init(
        title: String,
        subtitle: String? = nil,
        imageURL: String? = nil,
        systemIcon: String = "music.note",
        isCircular: Bool = false,
        onPlay: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.systemIcon = systemIcon
        self.isCircular = isCircular
        self.onPlay = onPlay
    }

    public var body: some View {
        VStack(alignment: isCircular ? .center : .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(
                    urlString: imageURL,
                    pixelSize: 400,
                    size: 148,
                    cornerRadius: isCircular ? 74 : 12,
                    systemIcon: systemIcon
                )
                .shadow(color: .black.opacity(0.14), radius: 8, x: 0, y: 4)

                if let onPlay {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(MyGoTheme.accent, in: Circle())
                            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            }

            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 148)
    }
}

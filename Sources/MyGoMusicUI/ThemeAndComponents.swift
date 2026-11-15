// ThemeAndComponents.swift
// 对应原项目 internal/app/ui_kit.go, ui_daily.go, artwork.go 的主题配色与通用 UI 组件

#if canImport(MyGoMusicCore)
import MyGoMusicCore
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
import AVKit
import CoreImage
import CryptoKit
import ImageIO
#if canImport(MediaPlayer)
import MediaPlayer
#endif
import SwiftUI
import UniformTypeIdentifiers
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

    /// 根据目标显示像素进行 `ImageIO` 高效降采样解码（可在后台线程直接调用），避免超高分辨率封面占用过多内存
    public static func makeCGImage(from data: Data, maxPixelSize: Int? = nil) -> CGImage? {
        if let maxPixel = maxPixelSize, maxPixel > 0,
           let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return cg
            }
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// 根据目标显示像素生成平台已解码图像，在 UIKit 上预先完成渲染位图解压以消除主线程卡顿
    #if canImport(UIKit)
    public static func makeDecodedPlatformImage(from data: Data, maxPixelSize: Int? = nil) -> UIImage? {
        guard let cg = makeCGImage(from: data, maxPixelSize: maxPixelSize) else {
            return UIImage(data: data)
        }
        let ui = UIImage(cgImage: cg)
        return ui.preparingForDisplay() ?? ui
    }
    #elseif canImport(AppKit)
    public static func makeDecodedPlatformImage(from data: Data, maxPixelSize: Int? = nil) -> NSImage? {
        guard let cg = makeCGImage(from: data, maxPixelSize: maxPixelSize) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    #endif

    public static func makeSwiftUIImage(from data: Data, maxPixelSize: Int? = nil) -> Image? {
        #if canImport(UIKit)
        guard let ui = makeDecodedPlatformImage(from: data, maxPixelSize: maxPixelSize) else { return nil }
        return Image(uiImage: ui)
        #elseif canImport(AppKit)
        guard let ns = makeDecodedPlatformImage(from: data, maxPixelSize: maxPixelSize) else { return nil }
        return Image(nsImage: ns)
        #endif
    }
}

// MARK: - 轻量只读环境依赖（解耦全局 AppModel 订阅，防止无谓连锁重绘）

private struct MyGoImageHeadersProviderKey: EnvironmentKey {
    static let defaultValue: @MainActor (URL) -> [String: String] = { _ in
        [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) mygo-music/0.1"
        ]
    }
}

private struct MyGoIsViewVisibleKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

public extension EnvironmentValues {
    /// 只读封面请求头提供器（由根容器注入，使列表中数百个 ArtworkView 脱离 AppModel.objectWillChange 订阅）
    var mygoImageHeadersProvider: @MainActor (URL) -> [String: String] {
        get { self[MyGoImageHeadersProviderKey.self] }
        set { self[MyGoImageHeadersProviderKey.self] = newValue }
    }

    /// 标示当前页面是否处于可见激活态（隐藏 Tab 或被全屏覆蓋时暂停后台耗能特效循环）
    var mygoIsViewVisible: Bool {
        get { self[MyGoIsViewVisibleKey.self] }
        set { self[MyGoIsViewVisibleKey.self] = newValue }
    }
}

// MARK: - 并发限流器与两级解码图片缓存管线

/// 支持 Swift Task 取消的轻量异步并发限流器（防止 NAS / 插件大图瞬间打满连接与解码队列）
private final class ArtworkConcurrencyLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var running: Int = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if running < limit {
                    running += 1
                    lock.unlock()
                    continuation.resume(returning: true)
                } else {
                    waiters.append((waiterID, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            var cancelledCont: CheckedContinuation<Bool, Never>?
            if let idx = waiters.firstIndex(where: { $0.id == waiterID }) {
                cancelledCont = waiters.remove(at: idx).continuation
            }
            lock.unlock()
            cancelledCont?.resume(returning: false)
        }
    }

    func release() {
        lock.lock()
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            lock.unlock()
            next.continuation.resume(returning: true)
        } else {
            running = max(0, running - 1)
            lock.unlock()
        }
    }
}

private final class BackdropRGBBox: NSObject {
    let value: BackdropRGBColor
    init(_ value: BackdropRGBColor) { self.value = value }
}

private struct DecodedArtworkResult: @unchecked Sendable {
    #if canImport(UIKit)
    let platformImage: UIImage
    #elseif canImport(AppKit)
    let platformImage: NSImage
    #endif
    let dominantRGB: BackdropRGBColor?

    var swiftUIImage: Image {
        #if canImport(UIKit)
        Image(uiImage: platformImage)
        #elseif canImport(AppKit)
        Image(nsImage: platformImage)
        #endif
    }
}

/// 异步非阻塞、带已解码内存缓存、缩略磁盘缓存、同键请求合并与主色采样的封面图片加载器
@MainActor
public final class ArtworkImageLoader: ObservableObject {
    #if canImport(UIKit)
    public typealias PlatformImage = UIImage
    #elseif canImport(AppKit)
    public typealias PlatformImage = NSImage
    #endif

    public typealias NetworkDataFetcher = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let decodedCache: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        c.totalCostLimit = 96 * 1024 * 1024
        c.countLimit = 450
        return c
    }()

    private static let dominantColorCache: NSCache<NSString, BackdropRGBBox> = {
        let c = NSCache<NSString, BackdropRGBBox>()
        c.countLimit = 250
        return c
    }()

    private static let diskCacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyGoMusicArtworkCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private nonisolated static let pipelineLimiter = ArtworkConcurrencyLimiter(limit: 6)
    private static var inFlightTasks: [String: Task<DecodedArtworkResult?, Never>] = [:]
    private static var inFlightWaiters: [String: Set<UUID>] = [:]

    @Published public private(set) var image: Image? = nil
    @Published public private(set) var loadedCacheKey: String = ""
    @Published public private(set) var dominantColor: Color? = nil
    @Published public private(set) var dominantRGB: BackdropRGBColor? = nil
    private var currentTaskKey: String = ""

    public init() {}

    /// 根据原始地址与期望显示像素计算精确的缓存键
    public static func cacheKey(rawURLString: String?, pixelSize: Int) -> String? {
        guard let resolved = sizedImageURL(rawURLString, px: pixelSize), !resolved.isEmpty else {
            return nil
        }
        return cacheKey(resolvedURL: resolved, pixelSize: pixelSize)
    }

    /// 计算与封面尺寸匹配的统一缓存键
    public static func cacheKey(resolvedURL: String, pixelSize: Int) -> String {
        let decodeLimit = max(pixelSize * 2, 320)
        return "\(resolvedURL)|\(decodeLimit)"
    }

    /// 从已解码内存缓存中零延迟同步获取 SwiftUI Image（避免主线程解码或列表滚动回弹闪烁）
    public static func cachedSwiftUIImage(rawURLString: String?, pixelSize: Int) -> Image? {
        guard let key = cacheKey(rawURLString: rawURLString, pixelSize: pixelSize) else {
            return nil
        }
        guard let cached = decodedCache.object(forKey: key as NSString) else { return nil }
        #if canImport(UIKit)
        return Image(uiImage: cached)
        #elseif canImport(AppKit)
        return Image(nsImage: cached)
        #endif
    }

    /// 从主色调缓存中零延迟同步读取已提取的封面色彩（避免首页 Hero 卡片切回时闪回默认红色）
    public static func cachedDominantRGB(rawURLString: String?, pixelSize: Int) -> BackdropRGBColor? {
        guard let key = cacheKey(rawURLString: rawURLString, pixelSize: pixelSize) else {
            return nil
        }
        return dominantColorCache.object(forKey: key as NSString)?.value
    }

    /// 清空全部内存解码缓存（供单元测试或内存警告清理）
    public static func clearMemoryCache() {
        decodedCache.removeAllObjects()
        dominantColorCache.removeAllObjects()
    }

    /// 清空并移除全部磁盘图片缓存（仅供单元测试隔离校验）
    public static func clearDiskCacheForTesting() {
        try? FileManager.default.removeItem(at: diskCacheDir)
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
    }

    /// 使用 ImageIO 在后台完成单图降采样并生成轻量磁盘缓存，避免 NAS 原图数 MB 数据反复重解码
    public static func decodeAndCompactIfNeeded(
        data: Data,
        maxPixelSize: Int,
        extractDominantColor: Bool
    ) -> (image: Image?, cgImage: CGImage?, compactedDiskData: Data?, dominantRGB: BackdropRGBColor?) {
        guard let cg = MyGoQRCodeGenerator.makeCGImage(from: data, maxPixelSize: maxPixelSize) else {
            return (nil, nil, nil, nil)
        }
        let dominant = extractDominantColor ? extractDominantRGB(from: cg) : nil
        let compactDisk = compactThumbnailDataIfOversized(cgImage: cg, originalByteCount: data.count, maxPixelSize: maxPixelSize)
        #if canImport(UIKit)
        let ui = UIImage(cgImage: cg)
        let prepared = ui.preparingForDisplay() ?? ui
        return (Image(uiImage: prepared), cg, compactDisk, dominant)
        #elseif canImport(AppKit)
        let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return (Image(nsImage: ns), cg, compactDisk, dominant)
        #endif
    }

    public func load(
        rawURLString: String?,
        pixelSize: Int,
        extractDominantColor: Bool = false,
        networkFetcher: NetworkDataFetcher? = nil,
        headersProvider: ((URL) -> [String: String])?
    ) async {
        guard let resolved = sizedImageURL(rawURLString, px: pixelSize), !resolved.isEmpty else {
            self.image = nil
            self.loadedCacheKey = ""
            self.dominantColor = nil
            self.dominantRGB = nil
            return
        }

        let decodeLimit = max(pixelSize * 2, 320)
        let keyString = Self.cacheKey(resolvedURL: resolved, pixelSize: pixelSize)
        let coalescingKey = extractDominantColor ? "\(keyString)#dom" : keyString
        currentTaskKey = keyString
        let cacheKey = keyString as NSString

        // 1. 最快同步路径：直接命中已解码内存位图（零 I/O、零解码、零 Task 挂起）
        if let cachedPlatform = Self.decodedCache.object(forKey: cacheKey) {
            let swiftImg: Image = {
                #if canImport(UIKit)
                return Image(uiImage: cachedPlatform)
                #elseif canImport(AppKit)
                return Image(nsImage: cachedPlatform)
                #endif
            }()
            self.loadedCacheKey = keyString
            self.image = swiftImg
            if extractDominantColor {
                if let cachedDom = Self.dominantColorCache.object(forKey: cacheKey)?.value {
                    self.dominantRGB = cachedDom
                    self.dominantColor = Color(red: cachedDom.r, green: cachedDom.g, blue: cachedDom.b)
                    return
                }
            } else {
                self.dominantColor = nil
                self.dominantRGB = nil
                return
            }
        } else {
            if self.loadedCacheKey != keyString {
                self.image = nil
                self.loadedCacheKey = ""
            }
            if extractDominantColor {
                self.dominantColor = nil
                self.dominantRGB = nil
            }
        }

        // 2. 启动或加入同键合并后台任务（几十首歌同专辑封面仅发起一次 I/O 与一次后台解码）
        let fetcher = networkFetcher ?? { request in
            try await URLSession.shared.data(for: request)
        }
        let preparedRequest: URLRequest? = Self.buildURLRequestIfRemote(
            resolved: resolved,
            headersProvider: headersProvider
        )

        let waiterID = UUID()
        Self.inFlightWaiters[coalescingKey, default: []].insert(waiterID)

        let sharedTask: Task<DecodedArtworkResult?, Never>
        if let existing = Self.inFlightTasks[coalescingKey] {
            sharedTask = existing
        } else {
            let diskURL = Self.diskFileURL(forKey: keyString)
            let cacheDir = Self.diskCacheDir
            let created = Task.detached(priority: .userInitiated) { () -> DecodedArtworkResult? in
                guard await Self.pipelineLimiter.acquire() else { return nil }
                defer { Self.pipelineLimiter.release() }
                if Task.isCancelled { return nil }

                return await Self.executeBackgroundLoad(
                    resolved: resolved,
                    decodeLimit: decodeLimit,
                    extractDominantColor: extractDominantColor,
                    diskURL: diskURL,
                    cacheDir: cacheDir,
                    remoteRequest: preparedRequest,
                    networkFetcher: fetcher
                )
            }
            Self.inFlightTasks[coalescingKey] = created
            sharedTask = created
        }

        let result: DecodedArtworkResult? = await withTaskCancellationHandler {
            await sharedTask.value
        } onCancel: {
            Task { @MainActor in
                Self.releaseWaiter(waiterID: waiterID, coalescingKey: coalescingKey)
            }
        }

        Self.releaseWaiter(waiterID: waiterID, coalescingKey: coalescingKey, cancelIfEmpty: false)

        guard !Task.isCancelled, currentTaskKey == keyString, let result else { return }

        let byteCost = Self.platformImageMemoryCost(result.platformImage)
        Self.decodedCache.setObject(result.platformImage, forKey: cacheKey, cost: byteCost)
        self.loadedCacheKey = keyString
        self.image = result.swiftUIImage

        if extractDominantColor, let dom = result.dominantRGB {
            Self.dominantColorCache.setObject(BackdropRGBBox(dom), forKey: cacheKey)
            self.dominantRGB = dom
            self.dominantColor = Color(red: dom.r, green: dom.g, blue: dom.b)
        }
    }

    private static func releaseWaiter(waiterID: UUID, coalescingKey: String, cancelIfEmpty: Bool = true) {
        if var set = inFlightWaiters[coalescingKey] {
            set.remove(waiterID)
            if set.isEmpty {
                inFlightWaiters.removeValue(forKey: coalescingKey)
                let task = inFlightTasks.removeValue(forKey: coalescingKey)
                if cancelIfEmpty {
                    task?.cancel()
                }
            } else {
                inFlightWaiters[coalescingKey] = set
            }
        } else if !cancelIfEmpty {
            inFlightTasks.removeValue(forKey: coalescingKey)
        }
    }

    private static func buildURLRequestIfRemote(
        resolved: String,
        headersProvider: ((URL) -> [String: String])?
    ) -> URLRequest? {
        guard !resolved.hasPrefix("data:image/"),
              !resolved.hasPrefix("file://"),
              !resolved.hasPrefix("/"),
              let url = URL(string: resolved),
              !url.isFileURL else {
            return nil
        }
        var req = URLRequest(url: url)
        let headers = headersProvider?(url) ?? [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) mygo-music/0.1"
        ]
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        return req
    }

    private nonisolated static func executeBackgroundLoad(
        resolved: String,
        decodeLimit: Int,
        extractDominantColor: Bool,
        diskURL: URL,
        cacheDir: URL,
        remoteRequest: URLRequest?,
        networkFetcher: NetworkDataFetcher
    ) async -> DecodedArtworkResult? {
        if resolved.hasPrefix("data:image/"),
           let comma = resolved.firstIndex(of: ",") {
            let b64 = String(resolved[resolved.index(after: comma)...])
            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
            return makeDecodedResult(from: data, maxPixelSize: decodeLimit, extractDominantColor: extractDominantColor).result
        }

        if let localURL = resolveLocalFileURL(from: resolved) {
            guard let data = try? Data(contentsOf: localURL) else { return nil }
            return makeDecodedResult(from: data, maxPixelSize: decodeLimit, extractDominantColor: extractDominantColor).result
        }

        if let diskData = try? Data(contentsOf: diskURL) {
            let outcome = makeDecodedResult(from: diskData, maxPixelSize: decodeLimit, extractDominantColor: extractDominantColor)
            if let result = outcome.result {
                return result
            }
        }

        guard !Task.isCancelled, let req = remoteRequest else { return nil }
        guard let (data, resp) = try? await networkFetcher(req),
              (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              !Task.isCancelled else {
            return nil
        }

        let outcome = makeDecodedResult(from: data, maxPixelSize: decodeLimit, extractDominantColor: extractDominantColor)
        guard let result = outcome.result else { return nil }

        let dataToPersist = outcome.compactedDiskData ?? data
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? dataToPersist.write(to: diskURL, options: .atomic)
        return result
    }

    private nonisolated static func resolveLocalFileURL(from resolved: String) -> URL? {
        if resolved.hasPrefix("file://") {
            let stripped = String(resolved.dropFirst("file://".count))
            return URL(fileURLWithPath: stripped.removingPercentEncoding ?? stripped)
        }
        if resolved.hasPrefix("/") {
            return URL(fileURLWithPath: resolved)
        }
        if let url = URL(string: resolved), url.isFileURL {
            return url
        }
        return nil
    }

    private nonisolated static func makeDecodedResult(
        from data: Data,
        maxPixelSize: Int,
        extractDominantColor: Bool
    ) -> (result: DecodedArtworkResult?, compactedDiskData: Data?) {
        guard let cg = MyGoQRCodeGenerator.makeCGImage(from: data, maxPixelSize: maxPixelSize) else {
            return (nil, nil)
        }
        let dominant = extractDominantColor ? extractDominantRGB(from: cg) : nil
        let compactDisk = compactThumbnailDataIfOversized(cgImage: cg, originalByteCount: data.count, maxPixelSize: maxPixelSize)
        #if canImport(UIKit)
        let ui = UIImage(cgImage: cg)
        let prepared = ui.preparingForDisplay() ?? ui
        return (DecodedArtworkResult(platformImage: prepared, dominantRGB: dominant), compactDisk)
        #elseif canImport(AppKit)
        let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return (DecodedArtworkResult(platformImage: ns, dominantRGB: dominant), compactDisk)
        #endif
    }

    private nonisolated static func compactThumbnailDataIfOversized(
        cgImage: CGImage,
        originalByteCount: Int,
        maxPixelSize: Int
    ) -> Data? {
        guard maxPixelSize <= 640, originalByteCount > 128 * 1024 else {
            return nil
        }
        let hasAlpha: Bool = {
            switch cgImage.alphaInfo {
            case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
                return true
            default:
                return false
            }
        }()
        let outData = NSMutableData()
        let uti = (hasAlpha ? UTType.png.identifier : UTType.jpeg.identifier) as CFString
        guard let dest = CGImageDestinationCreateWithData(outData, uti, 1, nil) else {
            return nil
        }
        let props: CFDictionary? = hasAlpha
            ? nil
            : ([kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        CGImageDestinationAddImage(dest, cgImage, props)
        guard CGImageDestinationFinalize(dest) else {
            return nil
        }
        let encoded = outData as Data
        return encoded.count < originalByteCount ? encoded : nil
    }

    private static func platformImageMemoryCost(_ image: PlatformImage) -> Int {
        #if canImport(UIKit)
        if let cg = image.cgImage {
            return max(4096, cg.bytesPerRow * cg.height)
        }
        let scale = max(1, image.scale)
        return max(4096, Int(image.size.width * scale * image.size.height * scale * 4))
        #elseif canImport(AppKit)
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return max(4096, cg.bytesPerRow * cg.height)
        }
        return 65536
        #endif
    }

    private static func diskFileURL(forKey raw: String) -> URL {
        let digest = SHA256.hash(data: Data(raw.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskCacheDir.appendingPathComponent("\(name).img")
    }

    private nonisolated static func extractDominantRGB(from cgImage: CGImage) -> BackdropRGBColor? {
        let sampleSize = 24
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        return BackdropFogMath.dominantColorFromRGBA(
            bytes: pixels,
            width: sampleSize,
            height: sampleSize
        )
    }
}

// MARK: - 颜色与主题系统（对齐 Apple Music iOS 18 / iOS 26 浅色与深色模式语义色板）

public struct MyGoThemeTokens: Equatable, Sendable {
    public struct RGBA: Equatable, Sendable {
        public let r: Double
        public let g: Double
        public let b: Double
        public let a: Double

        public init(r: Double, g: Double, b: Double, a: Double = 1.0) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }
    }

    public let accent: RGBA
    public let pageBackground: RGBA
    public let elevatedSurface: RGBA
    public let pillSurface: RGBA
    public let surfaceStroke: RGBA
    public let currentTrackFill: RGBA
    public let placeholderFill: RGBA
    public let artworkBorder: RGBA
}

public enum MyGoTheme {
    /// Apple Music 浅色/深色统一色彩规范（单一数据源驱动动态颜色与单元测试）
    public static func tokens(isDark: Bool) -> MyGoThemeTokens {
        if isDark {
            return MyGoThemeTokens(
                // Apple Music 深色模式标准亮绯红 #FF375F
                accent: .init(r: 1.0, g: 0.216, b: 0.373),
                // OLED 纯黑画布 #000000
                pageBackground: .init(r: 0.0, g: 0.0, b: 0.0),
                // Apple 系统暗色卡片二级层级 #1C1C1E
                elevatedSurface: .init(r: 0.110, g: 0.110, b: 0.118),
                // 胶囊控件与按钮暗色层级 #252528
                pillSurface: .init(r: 0.145, g: 0.145, b: 0.157),
                // 暗底上的克制微光描边
                surfaceStroke: .init(r: 1.0, g: 1.0, b: 1.0, a: 0.09),
                // 深色下正在播放曲目采用纯净高雅炭灰浮层，避免暗红透明度叠纯黑发棕
                currentTrackFill: .init(r: 1.0, g: 1.0, b: 1.0, a: 0.095),
                // 无封面的暗色圆角占位底 #1C1C1E
                placeholderFill: .init(r: 0.110, g: 0.110, b: 0.118),
                // 专辑封面在纯黑背景下的极细轮廓边线
                artworkBorder: .init(r: 1.0, g: 1.0, b: 1.0, a: 0.11)
            )
        }
        return MyGoThemeTokens(
            // Apple Music 浅色模式生动绯红 #FA233B
            accent: .init(r: 0.980, g: 0.137, b: 0.231),
            pageBackground: .init(r: 1.0, g: 1.0, b: 1.0),
            elevatedSurface: .init(r: 0.0, g: 0.0, b: 0.0, a: 0.045),
            pillSurface: .init(r: 0.0, g: 0.0, b: 0.0, a: 0.068),
            surfaceStroke: .init(r: 0.0, g: 0.0, b: 0.0, a: 0.06),
            currentTrackFill: .init(r: 0.980, g: 0.137, b: 0.231, a: 0.075),
            placeholderFill: .init(r: 0.0, g: 0.0, b: 0.0, a: 0.065),
            artworkBorder: .init(r: 0.0, g: 0.0, b: 0.0, a: 0.07)
        )
    }

    private static let lightTokens = tokens(isDark: false)
    private static let darkTokens = tokens(isDark: true)

    private static func dynamic(_ keyPath: KeyPath<MyGoThemeTokens, MyGoThemeTokens.RGBA>) -> Color {
        let light = lightTokens[keyPath: keyPath]
        let dark = darkTokens[keyPath: keyPath]
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
        })
        #else
        return Color(red: dark.r, green: dark.g, blue: dark.b, opacity: dark.a)
        #endif
    }

    /// 主强调色（浅色 #FA233B / 深色 #FF375F）
    public static let accent = dynamic(\.accent)
    /// 主画布背景色（浅色纯白 / 深色 OLED 纯黑）
    public static let pageBackground = dynamic(\.pageBackground)
    /// 卡片与输入区域次级抬升表面
    public static let elevatedSurface = dynamic(\.elevatedSurface)
    /// 胶囊按钮与标签表面
    public static let pillSurface = dynamic(\.pillSurface)
    /// 卡片与胶囊细边框微光
    public static let surfaceStroke = dynamic(\.surfaceStroke)
    /// 列表中当前正在播放曲目高亮底色
    public static let currentTrackFill = dynamic(\.currentTrackFill)
    /// 无封面的媒体圆角占位底色
    public static let placeholderFill = dynamic(\.placeholderFill)
    /// 专辑/歌单封面防融边极细轮廓
    public static let artworkBorder = dynamic(\.artworkBorder)
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

    /// 跨平台线性混合两种颜色（对应 Go ui.Color.Mix）
    public static func mix(_ base: Color, with other: Color, ratio: CGFloat) -> Color {
        let t = min(max(ratio, 0), 1)
        let a = rgbaComponents(of: base)
        let b = rgbaComponents(of: other)
        return Color(
            red: Double(a.r + (b.r - a.r) * t),
            green: Double(a.g + (b.g - a.g) * t),
            blue: Double(a.b + (b.b - a.b) * t),
            opacity: Double(a.a + (b.a - a.a) * t)
        )
    }

    /// 提取并在深雾背景下提亮专辑主色，极低饱和度封面自动转为清透银暖高光
    public static func brightenAccentColor(_ base: Color) -> Color {
        #if canImport(UIKit)
        let ui = UIColor(base)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
            let targetSat: CGFloat = s < 0.14 ? 0.10 : min(max(s * 1.15, 0.50), 0.88)
            let targetBri: CGFloat = min(max(b * 1.25, 0.84), 0.98)
            return Color(hue: Double(h), saturation: Double(targetSat), brightness: Double(targetBri))
        }
        #elseif canImport(AppKit)
        if let ns = NSColor(base).usingColorSpace(.deviceRGB) {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let targetSat: CGFloat = s < 0.14 ? 0.10 : min(max(s * 1.15, 0.50), 0.88)
            let targetBri: CGFloat = min(max(b * 1.25, 0.84), 0.98)
            return Color(hue: Double(h), saturation: Double(targetSat), brightness: Double(targetBri))
        }
        #endif
        return base
    }

    private static func rgbaComponents(of color: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        #if canImport(UIKit)
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif canImport(AppKit)
        if let rgb = NSColor(color).usingColorSpace(.deviceRGB) {
            rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        }
        #endif
        return (r, g, b, a)
    }
}

// MARK: - 封面图片组件（支持网络 URL、{size} 占位符、本地路径及优雅占位符）

public struct ArtworkView: View {
    @Environment(\.mygoImageHeadersProvider) private var imageHeadersProvider
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

    private var renderedImage: Image? {
        if let targetKey = ArtworkImageLoader.cacheKey(rawURLString: urlString, pixelSize: pixelSize) {
            if loader.loadedCacheKey == targetKey, let img = loader.image {
                return img
            }
            return ArtworkImageLoader.cachedSwiftUIImage(rawURLString: urlString, pixelSize: pixelSize)
        }
        return nil
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(MyGoTheme.placeholderFill)

            if let image = renderedImage {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                placeholderIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(MyGoTheme.artworkBorder, lineWidth: 0.5)
        )
        .task(id: urlString) {
            await loader.load(rawURLString: urlString, pixelSize: pixelSize) { url in
                imageHeadersProvider(url)
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

// MARK: - 每日推荐 / 最近播放 3 封面错落黑胶 Hero 卡片（1:1 移植自 internal/app/ui_daily.go）

public struct DailyFeatureCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.mygoIsViewVisible) private var isViewVisible
    @Environment(\.mygoImageHeadersProvider) private var imageHeadersProvider
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let section: MusicSection
    public let isPlayingFromCard: Bool
    public let isQueueFromCard: Bool
    public let audioBands: [Float]
    public let onPlay: () -> Void
    public let onOpen: () -> Void

    @StateObject private var primaryArtLoader = ArtworkImageLoader()

    public init(
        section: MusicSection,
        isPlayingFromCard: Bool,
        isQueueFromCard: Bool = false,
        audioBands: [Float],
        onPlay: @escaping () -> Void,
        onOpen: @escaping () -> Void
    ) {
        self.section = section
        self.isPlayingFromCard = isPlayingFromCard
        self.isQueueFromCard = isQueueFromCard || isPlayingFromCard
        self.audioBands = audioBands
        self.onPlay = onPlay
        self.onOpen = onOpen
    }

    private var tracks: [Track] {
        section.tracks ?? []
    }

    private var coverURLs: [String?] {
        DailyFeatureCardMath.featuredCoverURLs(for: tracks, limit: 3)
    }

    private var primaryCoverURL: String? {
        coverURLs.first ?? tracks.first?.album.imageUrl
    }

    private var resolvedPrimaryImage: Image? {
        if let targetKey = ArtworkImageLoader.cacheKey(rawURLString: primaryCoverURL, pixelSize: 480),
           primaryArtLoader.loadedCacheKey == targetKey,
           let loaded = primaryArtLoader.image {
            return loaded
        }
        return ArtworkImageLoader.cachedSwiftUIImage(rawURLString: primaryCoverURL, pixelSize: 480)
    }

    private var resolvedDominantRGB: BackdropRGBColor? {
        if let targetKey = ArtworkImageLoader.cacheKey(rawURLString: primaryCoverURL, pixelSize: 480),
           primaryArtLoader.loadedCacheKey == targetKey,
           let dom = primaryArtLoader.dominantRGB {
            return dom
        }
        return ArtworkImageLoader.cachedDominantRGB(rawURLString: primaryCoverURL, pixelSize: 480)
    }

    private var isRecordAnimating: Bool {
        isPlayingFromCard && isViewVisible && !reduceMotion
    }

    public var body: some View {
        let colors = BackdropFogMath.dailyCardColors(from: resolvedDominantRGB)
        let deepColor = Color(red: colors.deep.r, green: colors.deep.g, blue: colors.deep.b)
        let richColor = Color(red: colors.rich.r, green: colors.rich.g, blue: colors.rich.b)
        let glowColor = Color(red: colors.glow.r, green: colors.glow.g, blue: colors.glow.b)
        let cardShape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        GeometryReader { geo in
            let compactLayout = geo.size.width < 355
            let sleeveSize: CGFloat = compactLayout ? 94 : 106
            let recordSize: CGFloat = compactLayout ? 86 : 98
            let stackWidth: CGFloat = compactLayout ? 142 : 158
            let trailingPadding: CGFloat = compactLayout ? 12 : 14
            let leadingPadding: CGFloat = compactLayout ? 16 : 18
            let coverCenterOffsetInStack: CGFloat = sleeveSize * 0.08
            let recordPullOut: CGFloat = isQueueFromCard ? sleeveSize * 0.34 : sleeveSize * 0.25
            let recordCenterX = geo.size.width
                - trailingPadding
                - stackWidth * 0.5
                + coverCenterOffsetInStack
                + recordPullOut
            let recordCenter = CGPoint(x: recordCenterX, y: geo.size.height * 0.5)

            ZStack {
                DailyFeatureBackdropView(
                    blurredCover: resolvedPrimaryImage,
                    deepColor: deepColor,
                    richColor: richColor,
                    glowColor: glowColor,
                    recordCenter: recordCenter,
                    recordDiameter: recordSize,
                    isAnimating: isRecordAnimating
                )
                .contentShape(cardShape)
                .onTapGesture(perform: onOpen)

                HStack(alignment: .center, spacing: compactLayout ? 8 : 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(I18n.today())
                            .font(.system(size: 11.5, weight: .semibold))
                            .tracking(0.3)
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)

                        Text(section.title ?? I18n.t("Daily Picks"))
                            .font(.system(size: compactLayout ? 23 : 26, weight: .heavy))
                            .tracking(-0.6)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)

                        Text(DailyFeatureCardMath.artistSummary(for: tracks))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(2)
                            .minimumScaleFactor(0.9)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 6)

                        DailyHeroPlayPillButton(
                            isQueueActive: isQueueFromCard,
                            isPlaying: isPlayingFromCard,
                            audioBands: audioBands,
                            onPlay: onPlay
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onOpen)

                    DailyHeroArtworkStack(
                        coverURLs: coverURLs,
                        primaryImage: resolvedPrimaryImage,
                        sleeveSize: sleeveSize,
                        recordSize: recordSize,
                        stackWidth: stackWidth,
                        coverCenterOffsetX: coverCenterOffsetInStack,
                        recordOffsetX: recordPullOut,
                        isPlaying: isPlayingFromCard,
                        isAnimating: isRecordAnimating
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onOpen)
                }
                .padding(.leading, leadingPadding)
                .padding(.trailing, trailingPadding)
                .padding(.vertical, 16)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(cardShape)
            .overlay(
                cardShape.strokeBorder(.white.opacity(0.14), lineWidth: 0.85)
            )
            .background(
                cardShape
                    .fill(deepColor)
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.36 : 0.18),
                        radius: 16,
                        x: 0,
                        y: 8
                    )
            )
        }
        .frame(height: 186)
        .animation(.easeInOut(duration: 0.55), value: resolvedDominantRGB)
        .task(id: primaryCoverURL) {
            await primaryArtLoader.load(
                rawURLString: primaryCoverURL,
                pixelSize: 480,
                extractDominantColor: true
            ) { url in
                imageHeadersProvider(url)
            }
        }
    }
}

/// Hero 卡片底层渐变、模糊纹理、发光光晕与同心圆黑胶纹理（对应 drawDailyBackdrop）
private struct DailyFeatureBackdropView: View {
    let blurredCover: Image?
    let deepColor: Color
    let richColor: Color
    let glowColor: Color
    let recordCenter: CGPoint
    let recordDiameter: CGFloat
    let isAnimating: Bool

    @State private var phaseAnchor = Date()

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: deepColor, location: 0.08),
                    .init(color: richColor, location: 0.84),
                    .init(color: MyGoTheme.mix(richColor, with: deepColor, ratio: 0.30), location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let blurredCover {
                Color.clear
                    .background {
                        blurredCover
                            .resizable()
                            .scaledToFill()
                            .scaleEffect(1.18)
                            .blur(radius: 28)
                            .opacity(0.24)
                    }
                    .clipped()
            }

            // 左侧压暗，确保任何高光封面上白色文字依旧保持高对比度清晰可读
            LinearGradient(
                stops: [
                    .init(color: deepColor.opacity(0.88), location: 0.0),
                    .init(color: deepColor.opacity(0.0), location: 0.62)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            // 右侧黑胶中心发出的柔和主题辉光
            GeometryReader { geo in
                RadialGradient(
                    colors: [glowColor.opacity(0.32), .clear],
                    center: UnitPoint(
                        x: geo.size.width > 0 ? recordCenter.x / geo.size.width : 0.78,
                        y: geo.size.height > 0 ? recordCenter.y / geo.size.height : 0.5
                    ),
                    startRadius: 4,
                    endRadius: 126
                )
            }

            // 以黑胶中心向外逐圈淡出的细密同心圆环纹理（播放时微速向外涟漪，平时 0 帧刷新静默渲染）
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isAnimating)) { timeline in
                let gap: CGFloat = 16
                let rippleOffset: CGFloat = isAnimating
                    ? CGFloat((timeline.date.timeIntervalSince(phaseAnchor) * Double(gap / 6.0)).truncatingRemainder(dividingBy: Double(gap)))
                    : 0

                Canvas { context, size in
                    var radius = recordDiameter * 0.5 + 6 + rippleOffset
                    let maxRadius = max(size.width, size.height) * 1.15
                    while radius < maxRadius {
                        let falloff = 1.0 - (radius - recordDiameter * 0.5) / (size.height * 1.45)
                        let fadeIn = min(1.0, (radius - recordDiameter * 0.5 - 6) / gap)
                        let alpha = 0.082 * falloff * fadeIn
                        if alpha <= 0.005 {
                            break
                        }
                        let ringRect = CGRect(
                            x: recordCenter.x - radius,
                            y: recordCenter.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                        context.stroke(
                            Path(ellipseIn: ringRect),
                            with: .color(.white.opacity(alpha)),
                            lineWidth: 1.0
                        )
                        radius += gap
                    }
                }
            }
        }
        .onChange(of: isAnimating) { _, active in
            if active {
                phaseAnchor = Date()
            }
        }
    }
}

/// 右侧 3 张错落专辑封面叠放 + 侧出旋转黑胶唱片（对应 dailyStack）
private struct DailyHeroArtworkStack: View {
    let coverURLs: [String?]
    let primaryImage: Image?
    let sleeveSize: CGFloat
    let recordSize: CGFloat
    let stackWidth: CGFloat
    let coverCenterOffsetX: CGFloat
    let recordOffsetX: CGFloat
    let isPlaying: Bool
    let isAnimating: Bool

    var body: some View {
        let thirdSize = sleeveSize * 0.78
        let secondSize = sleeveSize * 0.89
        let opaquePlaceholderBg = LinearGradient(
            colors: [
                Color(red: 0.17, green: 0.17, blue: 0.19),
                Color(red: 0.11, green: 0.11, blue: 0.13)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        ZStack {
            // 第 3 张专辑封面（最深层、左侧倾斜露出）
            if coverURLs.count >= 3 {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(opaquePlaceholderBg)
                    ArtworkView(
                        urlString: coverURLs[2],
                        pixelSize: 240,
                        size: thirdSize,
                        cornerRadius: 9,
                        systemIcon: "music.note"
                    )
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.black.opacity(0.16))
                }
                .frame(width: thirdSize, height: thirdSize)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .opacity(0.88)
                .rotationEffect(.degrees(-11.0))
                .offset(x: coverCenterOffsetX - sleeveSize * 0.35, y: 2)
                .shadow(color: .black.opacity(0.42), radius: 10, x: 0, y: 5)
            }

            // 第 2 张专辑封面（中层、稍微左倾露出）
            if coverURLs.count >= 2 {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(opaquePlaceholderBg)
                    ArtworkView(
                        urlString: coverURLs[1],
                        pixelSize: 240,
                        size: secondSize,
                        cornerRadius: 10,
                        systemIcon: "music.note"
                    )
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.06))
                }
                .frame(width: secondSize, height: secondSize)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(0.95)
                .rotationEffect(.degrees(-5.4))
                .offset(x: coverCenterOffsetX - sleeveSize * 0.18, y: 1)
                .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 6)
            }

            // 探出的黑胶唱片（位于主封面右侧背后，播放本队列时向外顺滑滑出并缓慢旋转）
            DailyMiniVinylRecordView(
                size: recordSize,
                labelImage: primaryImage,
                isAnimating: isAnimating
            )
            .offset(x: coverCenterOffsetX + recordOffsetX, y: 0)
            .shadow(color: .black.opacity(0.48), radius: 10, x: 0, y: 4)
            .animation(.spring(duration: 0.65, bounce: 0.25), value: recordOffsetX)

            // 第 1 张主专辑封面（最前方封套，不透明底托防止浅色模式透出背后黑胶）
            primarySleeveView(size: sleeveSize, cornerRadius: 11.5, placeholderGradient: opaquePlaceholderBg)
                .rotationEffect(.degrees(isPlaying ? -1.5 : 0))
                .offset(x: coverCenterOffsetX, y: isPlaying ? -1 : 0)
                .shadow(color: .black.opacity(0.50), radius: 14, x: 0, y: 7)
                .animation(.spring(duration: 0.55, bounce: 0.25), value: isPlaying)
        }
        .frame(width: stackWidth, height: sleeveSize + 10)
    }

    private func primarySleeveView(
        size: CGFloat,
        cornerRadius: CGFloat,
        placeholderGradient: LinearGradient
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return ZStack {
            shape.fill(placeholderGradient)

            if let primaryImage {
                primaryImage
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.60))
            }

            // 封套高光折光与极细亮边（对应 ui_daily.go sleeve gloss）
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.20), location: 0.0),
                    .init(color: .clear, location: 0.42),
                    .init(color: .clear, location: 0.72),
                    .init(color: .black.opacity(0.16), location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(.white.opacity(0.16), lineWidth: 1.0)
        )
    }
}

/// 卡片内迷你黑胶唱片绘制（同心微沟槽 + 双对角 Conic 光束 + 中心封面标签 + 转轴孔，对应 drawRecord）
private struct DailyMiniVinylRecordView: View {
    let size: CGFloat
    let labelImage: Image?
    let isAnimating: Bool

    @State private var spinStart = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)) { timeline in
            let angleDeg: Double = isAnimating
                ? (timeline.date.timeIntervalSince(spinStart) * 60.0).truncatingRemainder(dividingBy: 360.0)
                : 0
            let labelDiameter = size * 0.36

            ZStack {
                Circle()
                    .fill(Color(red: 0.055, green: 0.055, blue: 0.063))

                // 同心黑胶纹路
                Canvas { context, canvasSize in
                    let d = min(canvasSize.width, canvasSize.height)
                    let center = CGPoint(x: d * 0.5, y: d * 0.5)
                    var rr = d * 0.21
                    var index = 0
                    while rr < d * 0.48 {
                        let alpha = index.isMultiple(of: 3) ? 0.075 : 0.035
                        let rect = CGRect(x: center.x - rr, y: center.y - rr, width: rr * 2, height: rr * 2)
                        context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(alpha)), lineWidth: 0.7)
                        rr += 2.2
                        index += 1
                    }
                }

                // 固定光源反射的双对角黑胶扇形高光
                Circle()
                    .fill(
                        AngularGradient(
                            stops: [
                                .init(color: .clear, location: 0.00),
                                .init(color: .white.opacity(0.14), location: 0.08),
                                .init(color: .clear, location: 0.20),
                                .init(color: .clear, location: 0.50),
                                .init(color: .white.opacity(0.14), location: 0.58),
                                .init(color: .clear, location: 0.70),
                                .init(color: .clear, location: 1.00)
                            ],
                            center: .center,
                            angle: .degrees(20)
                        )
                    )

                Circle()
                    .strokeBorder(.white.opacity(0.11), lineWidth: 0.9)

                // 中心随唱片同步旋转的专辑封面圆贴标
                ZStack {
                    Circle().fill(Color(red: 0.847, green: 0.149, blue: 0.176))
                    if let labelImage {
                        labelImage
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: labelDiameter, height: labelDiameter)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1.2))
                .rotationEffect(.degrees(angleDeg))

                // 黑胶中心转轴孔
                Circle()
                    .fill(Color(red: 0.055, green: 0.055, blue: 0.063))
                    .frame(width: 4.5, height: 4.5)
            }
            .frame(width: size, height: size)
        }
        .onChange(of: isAnimating) { _, active in
            if active {
                spinStart = Date()
            }
        }
    }
}

/// 卡片左下纯白高亮胶囊播放按钮（对应 dailyPlayButton）
private struct DailyHeroPlayPillButton: View {
    let isQueueActive: Bool
    let isPlaying: Bool
    let audioBands: [Float]
    let onPlay: () -> Void

    private var labelText: String {
        if isPlaying {
            return I18n.t("Playing")
        }
        if isQueueActive {
            return I18n.t("Resume")
        }
        return I18n.t("Play")
    }

    var body: some View {
        let ink = Color(red: 0.114, green: 0.114, blue: 0.122)
        Button(action: onPlay) {
            HStack(spacing: 7) {
                if isPlaying {
                    EqualizerBarsView(bands: audioBands, isPlaying: true, color: MyGoTheme.accent, barCount: 3)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                }
                Text(labelText)
                    .font(.system(size: 13.5, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(Color.white, in: Capsule())
            .shadow(color: .black.opacity(0.30), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(DailyHeroPillPressStyle())
    }
}

private struct DailyHeroPillPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.90 : 1.0)
            .animation(.spring(duration: 0.22, bounce: 0.2), value: configuration.isPressed)
    }
}

// MARK: - 通用单曲列表行（对应 trackRow）

public struct TrackRowView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.mygoNavigate) private var navigate
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
                HStack(spacing: 6) {
                    Text(track.name)
                        .font(.system(size: 15, weight: isCurrent ? .bold : .medium))
                        .foregroundStyle(isCurrent ? MyGoTheme.accent : .primary)
                        .lineLimit(1)

                    if track.unavailable == true {
                        Text(I18n.t("VIP / No Rights"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(MyGoTheme.pillSurface)
                            )
                            .fixedSize()
                    }
                }

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
                if app.activeSource.can("addToPlaylist"), app.myPlaylists.contains(where: { $0.fixed != true }) {
                    Button {
                        app.pendingAddToPlaylistTrack = track
                    } label: {
                        Label(I18n.t("Add to Playlist"), systemImage: "text.badge.plus")
                    }
                }
                let trackArtists = track.resolvedArtistsForNavigation
                if trackArtists.count == 1, let artist = trackArtists.first {
                    Button {
                        navigate(.artist(id: artist.id, name: artist.name, sourceID: track.source))
                    } label: {
                        Label(I18n.tf("Go to Artist: %s", artist.name), systemImage: "person.wave.2")
                    }
                } else if trackArtists.count > 1 {
                    Menu(I18n.t("Artists")) {
                        ForEach(Array(trackArtists.enumerated()), id: \.offset) { _, artist in
                            Button {
                                navigate(.artist(id: artist.id, name: artist.name, sourceID: track.source))
                            } label: {
                                Label(artist.name, systemImage: "person.wave.2")
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
                .fill(isCurrent ? MyGoTheme.currentTrackFill : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isCurrent ? MyGoTheme.surfaceStroke : Color.clear, lineWidth: 0.5)
                )
        )
        .opacity(track.unavailable == true ? 0.45 : 1.0)
    }
}

// MARK: - 高性能懒加载歌曲列表容器（统一消除数千首大曲库全量实例化与重复 compositeKey 冲突）

public struct LazyTrackRowEntry: Identifiable {
    public let id: String
    public let index: Int
    public let track: Track
}

public struct LazyTrackRowsView: View {
    public let tracks: [Track]
    public var horizontalPadding: CGFloat = 8
    public let onPlay: ([Track], Int) -> Void

    public init(
        tracks: [Track],
        horizontalPadding: CGFloat = 8,
        onPlay: @escaping ([Track], Int) -> Void
    ) {
        self.tracks = tracks
        self.horizontalPadding = horizontalPadding
        self.onPlay = onPlay
    }

    /// 为大列表生成稳定且无重复碰撞的行 ID，同一首曲目出现多次时按次序附加后缀
    public static func buildRowEntries(for tracks: [Track]) -> [LazyTrackRowEntry] {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(tracks.count)
        var entries: [LazyTrackRowEntry] = []
        entries.reserveCapacity(tracks.count)
        for (idx, track) in tracks.enumerated() {
            let base = track.compositeKey
            let occ = counts[base, default: 0]
            counts[base] = occ + 1
            let rowID = occ == 0 ? base : "\(base)#\(occ)"
            entries.append(LazyTrackRowEntry(id: rowID, index: idx, track: track))
        }
        return entries
    }

    public var body: some View {
        let entries = Self.buildRowEntries(for: tracks)
        LazyVStack(spacing: 2) {
            ForEach(entries) { entry in
                TrackRowView(track: entry.track, index: entry.index) {
                    onPlay(tracks, entry.index)
                }
                .padding(.horizontal, horizontalPadding)
            }
        }
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
    public var onTap: (() -> Void)? = nil

    public init(
        title: String,
        subtitle: String? = nil,
        imageURL: String? = nil,
        systemIcon: String = "music.note",
        isCircular: Bool = false,
        onPlay: (() -> Void)? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.systemIcon = systemIcon
        self.isCircular = isCircular
        self.onPlay = onPlay
        self.onTap = onTap
    }

    public var body: some View {
        let shadowRadius: CGFloat = isCircular ? 74 : 12
        let cardContent = VStack(alignment: isCircular ? .center : .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(
                    urlString: imageURL,
                    pixelSize: 400,
                    size: 148,
                    cornerRadius: shadowRadius,
                    systemIcon: systemIcon
                )
                .background(
                    RoundedRectangle(cornerRadius: shadowRadius, style: .continuous)
                        .fill(MyGoTheme.placeholderFill)
                        .shadow(color: .black.opacity(0.14), radius: 8, x: 0, y: 4)
                )

                if let onPlay {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(MyGoTheme.accent)
                                    .shadow(color: .black.opacity(0.28), radius: 6, x: 0, y: 3)
                            )
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
        .contentShape(Rectangle())

        if let onTap {
            cardContent.onTapGesture(perform: onTap)
        } else {
            cardContent
        }
    }
}

// MARK: - 原生 AirPlay 音频输出设备选择器

public struct AirPlayRoutePickerView: View {
    public var tintColor: Color = .white

    public init(tintColor: Color = .white) {
        self.tintColor = tintColor
    }

    public var body: some View {
        #if canImport(UIKit)
        UIKitRoutePickerRepresentable(tintColor: UIColor(tintColor))
            .frame(width: 28, height: 28)
        #elseif canImport(AppKit)
        AppKitRoutePickerRepresentable(tintColor: NSColor(tintColor))
            .frame(width: 28, height: 28)
        #endif
    }
}

#if canImport(UIKit)
private struct UIKitRoutePickerRepresentable: UIViewRepresentable {
    let tintColor: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.backgroundColor = .clear
        picker.tintColor = tintColor
        picker.activeTintColor = UIColor(MyGoTheme.accent)
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
    }
}
#elseif canImport(AppKit)
private struct AppKitRoutePickerRepresentable: NSViewRepresentable {
    let tintColor: NSColor

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#endif

// MARK: - iOS 系统硬件音量双向实时同步

/// 监听并同步 iOS 系统硬件音量（实体音量键、控制中心、蓝牙路由切换）与播放器底部滑块
@MainActor
public final class SystemVolumeObserver: ObservableObject {
    @Published public private(set) var volume: Double
    @Published public private(set) var isDragging: Bool = false

    private let readSystemVolumeImpl: (() -> Double)?
    private let writeSystemVolumeImpl: ((Double) -> Void)?
    private var hardwareWriter: ((Double) -> Void)?
    private var lastNonZeroVolume: Double
    private var lastUserWriteAt: Date = .distantPast
    private var dragUnlockTask: Task<Void, Never>?
    private var isObserving: Bool = false
    private let observationBag = ObservationBag()

    /// 脱离 MainActor 隔离的观察令牌持有器，便于 deinit 安全释放
    private final class ObservationBag: @unchecked Sendable {
        var volumeObservation: NSKeyValueObservation?
        var notificationTokens: [NSObjectProtocol] = []

        func clear() {
            volumeObservation?.invalidate()
            volumeObservation = nil
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
            notificationTokens.removeAll()
        }

        deinit {
            clear()
        }
    }

    public init(
        initialVolume: Double? = nil,
        readSystemVolume: (() -> Double)? = nil,
        writeSystemVolume: ((Double) -> Void)? = nil,
        autoStart: Bool = true
    ) {
        self.readSystemVolumeImpl = readSystemVolume
        self.writeSystemVolumeImpl = writeSystemVolume

        let initial = Self.clamp(initialVolume ?? readSystemVolume?() ?? Self.readDeviceOutputVolume() ?? 0.8)
        self.volume = initial
        self.lastNonZeroVolume = initial > 0.01 ? initial : 0.5

        if autoStart {
            startObserving()
        }
    }

    /// 开始监听系统音频会话音量及音频路由变化
    public func startObserving() {
        refreshFromSystem(force: true)
        guard !isObserving else { return }
        isObserving = true

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if !session.isOtherAudioPlaying {
            if session.category != .playback {
                try? session.setCategory(.playback, mode: .default, options: [])
            }
            // 提前激活音频会话，确保尚未点击播放前按硬件音量键也能触发 outputVolume KVO
            try? session.setActive(true)
        }
        observationBag.volumeObservation = session.observe(\.outputVolume, options: [.initial, .new]) { [weak self] session, change in
            let latest = Double(change.newValue ?? session.outputVolume)
            Task { @MainActor [weak self] in
                self?.receiveExternalVolumeUpdate(latest)
            }
        }

        let routeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            let latest = Double(AVAudioSession.sharedInstance().outputVolume)
            Task { @MainActor [weak self] in
                self?.receiveExternalVolumeUpdate(latest)
            }
        }
        observationBag.notificationTokens.append(routeToken)
        #endif

        #if canImport(UIKit)
        let activeToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshFromSystem(force: false)
            }
        }
        observationBag.notificationTokens.append(activeToken)
        #endif
    }

    /// 停止监听系统音量与异步对齐任务
    public func stopObserving() {
        dragUnlockTask?.cancel()
        dragUnlockTask = nil
        observationBag.clear()
        isObserving = false
    }

    /// 绑定底层硬件音量写入句柄（由隐藏挂载的 MPVolumeView 注入）
    public func registerHardwareWriter(_ writer: @escaping (Double) -> Void) {
        self.hardwareWriter = writer
    }

    /// 标记用户开始拖动音量滑块，暂停外部 KVO 反向覆盖
    public func beginDragging() {
        dragUnlockTask?.cancel()
        dragUnlockTask = nil
        isDragging = true
    }

    /// 由 App 内滑块写入新音量并实时下发到系统硬件
    public func setUserVolume(_ rawValue: Double) {
        let clamped = Self.clamp(rawValue)
        if clamped > 0.01 {
            lastNonZeroVolume = clamped
        }
        volume = clamped
        lastUserWriteAt = Date()

        if let writeSystemVolumeImpl {
            writeSystemVolumeImpl(clamped)
        } else {
            hardwareWriter?(clamped)
        }
    }

    /// 用户松手后延迟一小段时间再解除拖动锁并与硬件步进结果对齐，避免回弹抖动
    public func endDragging(unlockDelayNanoseconds: UInt64 = 280_000_000) {
        dragUnlockTask?.cancel()
        dragUnlockTask = Task { @MainActor [weak self] in
            if unlockDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: unlockDelayNanoseconds)
            }
            guard !Task.isCancelled, let self else { return }
            self.isDragging = false
            self.refreshFromSystem(force: true)
        }
    }

    /// 一键静音或恢复静音前音量，并同步到系统音量
    public func toggleMute() {
        beginDragging()
        if volume <= 0.005 {
            let restoreTarget = lastNonZeroVolume > 0.05 ? lastNonZeroVolume : 0.5
            setUserVolume(restoreTarget)
        } else {
            lastNonZeroVolume = volume
            setUserVolume(0)
        }
        endDragging()
    }

    /// 主动从系统读取当前真实输出音量；force 为 true 时在非拖动态直接对齐
    public func refreshFromSystem(force: Bool = false) {
        guard let current = readSystemVolumeImpl?() ?? Self.readDeviceOutputVolume() else { return }
        if force {
            guard !isDragging else { return }
            let clamped = Self.clamp(current)
            if abs(clamped - volume) > 0.002 {
                volume = clamped
                if clamped > 0.01 {
                    lastNonZeroVolume = clamped
                }
            }
        } else {
            receiveExternalVolumeUpdate(current)
        }
    }

    /// 处理由硬件按键、控制中心或输出路由切换推送来的系统音量变更
    public func receiveExternalVolumeUpdate(_ rawValue: Double) {
        let clamped = Self.clamp(rawValue)
        guard !isDragging else { return }
        // 刚刚主动拖动或点静音后的短窗口内忽略自身产生的 KVO 回波，避免滑块来回跳动
        guard Date().timeIntervalSince(lastUserWriteAt) >= 0.28 else { return }
        if abs(clamped - volume) > 0.002 {
            volume = clamped
            if clamped > 0.01 {
                lastNonZeroVolume = clamped
            }
        }
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0.0), 1.0)
    }

    private static func readDeviceOutputVolume() -> Double? {
        #if os(iOS)
        return Double(AVAudioSession.sharedInstance().outputVolume)
        #else
        return nil
        #endif
    }
}

#if os(iOS) && canImport(UIKit) && canImport(MediaPlayer)
/// 隐蔽挂载原生态 MPVolumeView（必须可见且在窗口层级中，才能合法驱动真机硬件音量）
public struct SystemVolumeHardwareHostView: UIViewRepresentable {
    @ObservedObject var observer: SystemVolumeObserver

    public init(observer: SystemVolumeObserver) {
        self.observer = observer
    }

    public func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        volumeView.showsVolumeSlider = true
        volumeView.clipsToBounds = true
        volumeView.isUserInteractionEnabled = false
        bindHardwareWriter(on: volumeView)
        return volumeView
    }

    public func updateUIView(_ uiView: MPVolumeView, context: Context) {
        bindHardwareWriter(on: uiView)
    }

    private func bindHardwareWriter(on volumeView: MPVolumeView) {
        observer.registerHardwareWriter { [weak volumeView] target in
            guard let volumeView,
                  let slider = Self.findVolumeSlider(in: volumeView)
            else { return }
            let clamped = Float(min(max(target, 0.0), 1.0))
            if abs(slider.value - clamped) > 0.001 || clamped == 0 || clamped == 1 {
                slider.setValue(clamped, animated: false)
                slider.sendActions(for: .valueChanged)
            }
        }
    }

    private static func findVolumeSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider {
            return slider
        }
        for subview in view.subviews {
            if let found = findVolumeSlider(in: subview) {
                return found
            }
        }
        return nil
    }
}
#endif

// MARK: - 插件导航与发现页 Link 语义图标体系

/// 统一导航项与自定义 Link 卡片的图标语义分类（避免“无封面图片时退化成空占位灰框”）。
public enum MyGoNavIconKind: String, CaseIterable, Equatable, Sendable {
    case home
    case note
    case album
    case artist
    case playlist
    case radio
    case podcast
    case chart
    case calendar
    case heart
    case search
    case star
    case recent
    case cloud
    case vip
    case discover

    /// 徽章内展示的饱满 SF Symbol 名称
    public var badgeSymbol: String {
        switch self {
        case .home: return "house.fill"
        case .note: return "music.note"
        case .album: return "opticaldisc.fill"
        case .artist: return "person.wave.2.fill"
        case .playlist: return "music.note.list"
        case .radio: return "dot.radiowaves.left.and.right"
        case .podcast: return "mic.fill"
        case .chart: return "chart.bar.fill"
        case .calendar: return "calendar"
        case .heart: return "heart.fill"
        case .search: return "magnifyingglass"
        case .star: return "star.fill"
        case .recent: return "clock.fill"
        case .cloud: return "icloud.fill"
        case .vip: return "crown.fill"
        case .discover: return "sparkles"
        }
    }

    /// 资料库侧栏/列表展示用轮廓 SF Symbol（保持既有一致外观）
    public var listSymbol: String {
        switch self {
        case .home: return "house"
        case .note: return "music.note"
        case .album: return "opticaldisc"
        case .artist: return "person.wave.2"
        case .playlist: return "music.note.list"
        case .radio: return "dot.radiowaves.left.and.right"
        case .podcast: return "mic"
        case .chart: return "chart.bar.fill"
        case .calendar: return "calendar"
        case .heart: return "heart"
        case .search: return "magnifyingglass"
        case .star: return "star"
        case .recent: return "clock"
        case .cloud: return "icloud"
        case .vip: return "crown"
        case .discover: return "sparkles"
        }
    }

    /// 徽章渐变起始色与结束色
    public var badgeGradientColors: (start: Color, end: Color) {
        switch self {
        case .chart:
            return (Color(red: 0.99, green: 0.30, blue: 0.36), Color(red: 0.85, green: 0.12, blue: 0.25))
        case .radio:
            return (Color(red: 0.38, green: 0.42, blue: 0.98), Color(red: 0.56, green: 0.25, blue: 0.93))
        case .calendar:
            return (Color(red: 0.99, green: 0.54, blue: 0.20), Color(red: 0.93, green: 0.30, blue: 0.22))
        case .vip:
            return (Color(red: 0.96, green: 0.72, blue: 0.22), Color(red: 0.84, green: 0.49, blue: 0.08))
        case .recent:
            return (Color(red: 0.20, green: 0.65, blue: 0.98), Color(red: 0.13, green: 0.43, blue: 0.90))
        case .cloud:
            return (Color(red: 0.18, green: 0.72, blue: 0.96), Color(red: 0.09, green: 0.50, blue: 0.88))
        case .heart:
            return (Color(red: 0.98, green: 0.28, blue: 0.45), Color(red: 0.84, green: 0.12, blue: 0.30))
        case .podcast:
            return (Color(red: 0.58, green: 0.34, blue: 0.96), Color(red: 0.42, green: 0.18, blue: 0.84))
        case .artist:
            return (Color(red: 0.95, green: 0.42, blue: 0.30), Color(red: 0.82, green: 0.24, blue: 0.22))
        case .album, .playlist, .note:
            return (Color(red: 0.22, green: 0.70, blue: 0.64), Color(red: 0.12, green: 0.52, blue: 0.54))
        case .star, .home, .search, .discover:
            return (Color(red: 0.95, green: 0.32, blue: 0.54), Color(red: 0.74, green: 0.22, blue: 0.86))
        }
    }

    private static let explicitIconMap: [String: MyGoNavIconKind] = [
        "home": .home,
        "note": .note,
        "album": .album,
        "artist": .artist,
        "playlist": .playlist,
        "radio": .radio,
        "podcast": .podcast,
        "chart": .chart,
        "calendar": .calendar,
        "heart": .heart,
        "search": .search,
        "star": .star,
        "recent": .recent,
        "cloud": .cloud,
        "vip": .vip,
        "discover": .discover
    ]

    private static let pageKeywords: [(keywords: [String], kind: MyGoNavIconKind)] = [
        (["chart", "rank", "toplist"], .chart),
        (["fm", "radio", "station"], .radio),
        (["daily", "recommend"], .calendar),
        (["vip"], .vip),
        (["recent", "history"], .recent),
        (["cloud", "disk"], .cloud),
        (["like", "favorite"], .heart),
        (["podcast", "show"], .podcast),
        (["artist", "following"], .artist),
        (["album"], .album),
        (["playlist"], .playlist),
        (["song", "track"], .note)
    ]

    private static let titleKeywords: [(keywords: [String], kind: MyGoNavIconKind)] = [
        (["排行", "榜单", "chart", "rank", "top"], .chart),
        (["fm", "电台", "radio"], .radio),
        (["每日推荐", "日推", "daily"], .calendar),
        (["vip", "会员"], .vip),
        (["最近", "历史", "recent"], .recent),
        (["云盘", "cloud"], .cloud),
        (["喜欢", "收藏", "favorite"], .heart),
        (["播客", "podcast"], .podcast),
        (["歌手", "关注", "artist"], .artist),
        (["专辑", "album"], .album),
        (["歌单", "playlist"], .playlist)
    ]

    /// 将插件 NavItem.icon 字符串转换为列表用的 SF Symbol 名称。
    public static func sfSymbol(for iconName: String?) -> String {
        guard let normalized = iconName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let kind = explicitIconMap[normalized] else {
            return "music.note.list"
        }
        return kind.listSymbol
    }

    /// 结合插件 Navigation 声明、Link page 标识及展示标题，推断最精准的图标语义。
    public static func resolve(
        linkPage: String,
        linkTitle: String,
        navigationIcon: String? = nil
    ) -> MyGoNavIconKind {
        if let nav = navigationIcon?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let kind = explicitIconMap[nav] {
            return kind
        }

        let normalizedPage = linkPage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pageHead = normalizedPage.split(separator: ":").first.map(String.init) ?? normalizedPage
        for entry in pageKeywords where entry.keywords.contains(where: { pageHead == $0 || pageHead.hasPrefix($0) }) {
            return entry.kind
        }

        let normalizedTitle = linkTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for entry in titleKeywords where entry.keywords.contains(where: { normalizedTitle.contains($0) }) {
            return entry.kind
        }

        return .discover
    }
}

/// 发现页/自定义页 Link 左侧视觉视图：有封面 URL 显示专辑图，无图片则展示高辨识度渐变图标徽章。
public struct BrowseLinkIconView: View {
    public let urlString: String?
    public let page: String
    public let title: String
    public var navigationIcon: String? = nil
    public var size: CGFloat = 46
    public var cornerRadius: CGFloat = 10

    public init(
        urlString: String?,
        page: String,
        title: String,
        navigationIcon: String? = nil,
        size: CGFloat = 46,
        cornerRadius: CGFloat = 10
    ) {
        self.urlString = urlString
        self.page = page
        self.title = title
        self.navigationIcon = navigationIcon
        self.size = size
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let kind = MyGoNavIconKind.resolve(
            linkPage: page,
            linkTitle: title,
            navigationIcon: navigationIcon
        )
        let trimmedURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedURL.isEmpty {
            ArtworkView(
                urlString: trimmedURL,
                pixelSize: 120,
                size: size,
                cornerRadius: cornerRadius,
                systemIcon: kind.badgeSymbol
            )
        } else {
            let colors = kind.badgeGradientColors
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [colors.start, colors.end],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.24), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                Image(systemName: kind.badgeSymbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.16), radius: 2, x: 0, y: 1)
            }
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.75)
            )
            .shadow(color: colors.end.opacity(0.20), radius: 4, x: 0, y: 2)
        }
    }
}

// MARK: - 跨视图键盘统一收起工具（兼容系统输入法与第三方输入法）

public enum MyGoKeyboard {
    /// 主动结束当前所有窗口的第一响应者，确保搜索或提交后软键盘立即彻底退下。
    @MainActor
    public static func dismiss() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.endEditing(true)
            }
        }
        #elseif canImport(AppKit)
        let app: NSApplication? = NSApp
        app?.keyWindow?.makeFirstResponder(nil)
        #endif
    }
}

// MARK: - 跨页面共享深/浅自适应表面样式修饰符

extension View {
    /// 统一适配明暗双色的胶囊表面材质与微光描边（高亮态呈 Apple Music 绯红胶囊）
    func mygoPillSurface(isHighlighted: Bool = false) -> some View {
        background(
            isHighlighted ? AnyShapeStyle(MyGoTheme.accent) : AnyShapeStyle(MyGoTheme.pillSurface),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(isHighlighted ? Color.clear : MyGoTheme.surfaceStroke, lineWidth: 0.6)
        )
    }

    /// 统一适配明暗双色的圆形按钮表面材质与微光描边
    func mygoCircleSurface() -> some View {
        background(MyGoTheme.pillSurface, in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(MyGoTheme.surfaceStroke, lineWidth: 0.6)
            )
    }

    /// 统一适配明暗双色的圆角卡片表面材质与微光描边
    func mygoElevatedSurface(cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(MyGoTheme.elevatedSurface, in: shape)
            .overlay(
                shape.strokeBorder(MyGoTheme.surfaceStroke, lineWidth: 0.6)
            )
    }
}

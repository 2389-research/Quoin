#if canImport(AppKit) || canImport(UIKit)
import Foundation
import ImageIO
import CoreGraphics

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Off-main-thread image decoding with a shared cache, so opening a
/// document with heavy images never blocks first render. The renderer asks
/// for an image; on a miss it gets nil (draws a placeholder), decoding is
/// scheduled, and `onReady` fires once so the document can re-render.
final class AsyncImageStore: @unchecked Sendable {

    static let shared = AsyncImageStore()

    private let cache = NSCache<NSString, PlatformImage>()
    private var pending: Set<String> = []
    private let lock = NSLock()

    private init() {
        cache.countLimit = 200
    }

    /// Synchronous locked mutation — safe to call from async contexts because
    /// the closure contains no suspension points (Swift 6 forbids raw
    /// lock()/unlock() in async functions for exactly that hazard).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Cache key includes mtime so an edited image refreshes on reload.
    private func key(for url: URL, maxDimension: CGFloat) -> String {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .map { String($0.timeIntervalSince1970) } ?? "0"
        return "\(url.path)|\(mtime)|\(Int(maxDimension))"
    }

    func image(at url: URL, maxDimension: CGFloat, onReady: @escaping @Sendable () -> Void) -> PlatformImage? {
        let cacheKey = key(for: url, maxDimension: maxDimension)
        if let hit = cache.object(forKey: cacheKey as NSString) {
            return hit
        }

        let alreadyPending = withLock {
            let pending = self.pending.contains(cacheKey)
            if !pending { self.pending.insert(cacheKey) }
            return pending
        }
        guard !alreadyPending else { return nil }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let decoded = Self.decode(url: url, maxDimension: maxDimension)
            if let decoded {
                self.cache.setObject(decoded, forKey: cacheKey as NSString)
            }
            self.withLock { _ = self.pending.remove(cacheKey) }
            if decoded != nil { onReady() }
        }
        return nil
    }

    /// Blocking decode for callers that cannot tolerate a placeholder-then-
    /// re-render (exporters: PDF/RTF/print produce a single fixed output, so
    /// the async first-render placeholder would bake into the file). Checks
    /// the shared cache first, decodes on the calling thread on a miss, and
    /// caches the result so a later on-screen render hits.
    func imageSynchronously(at url: URL, maxDimension: CGFloat) -> PlatformImage? {
        let cacheKey = key(for: url, maxDimension: maxDimension)
        if let hit = cache.object(forKey: cacheKey as NSString) {
            return hit
        }
        guard let decoded = Self.decode(url: url, maxDimension: maxDimension) else {
            return nil
        }
        cache.setObject(decoded, forKey: cacheKey as NSString)
        withLock { _ = self.pending.remove(cacheKey) }
        return decoded
    }

    /// Decodes at display size via ImageIO so a 20 MP photo doesn't cost
    /// 80 MB of memory to show at 680 points wide.
    static func decode(url: URL, maxDimension: CGFloat) -> PlatformImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}
#endif

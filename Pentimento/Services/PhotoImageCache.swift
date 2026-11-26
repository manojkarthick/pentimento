import Foundation
import CoreGraphics
import ImageIO

/// Keeps display-sized, fully decoded images in memory. Originals are never changed.
actor PhotoImageCache {
    struct Request: Hashable {
        let url: URL
        let maxPixelSize: Int
        let revision: Int
    }
    private struct Entry {
        let image: CGImage
        let cost: Int
        var lastUsed: UInt64
    }
    private struct Pending {
        let id: UUID
        let task: Task<CGImage?, Never>
    }
    private let queue: OperationQueue
    private let byteLimit: Int
    private var entries: [Request: Entry] = [:]
    private var pending: [Request: Pending] = [:]
    private var clock: UInt64 = 0
    private(set) var cachedByteCount = 0

    init(byteLimit: Int = 64 * 1024 * 1024) {
        self.byteLimit = byteLimit
        queue = OperationQueue()
        queue.name = "Photo previews"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
    }
    func image(for request: Request) async -> CGImage? {
        clock &+= 1
        if var entry = entries[request] {
            entry.lastUsed = clock
            entries[request] = entry
            return entry.image
        }
        if let existing = pending[request] { return await existing.task.value }
        let id = UUID()
        let queue = queue
        let task = Task<CGImage?, Never> {
            await withCheckedContinuation { continuation in
                queue.addOperation {
                    let image = autoreleasepool { Self.decode(request) }
                    continuation.resume(returning: image)
                }
            }
        }
        pending[request] = Pending(id: id, task: task)
        let image = await task.value
        guard pending[request]?.id == id else { return nil }
        pending.removeValue(forKey: request)
        if let image {
            let cost = image.bytesPerRow * image.height
            if cost <= byteLimit {
                while cachedByteCount + cost > byteLimit, let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                    cachedByteCount -= oldest.value.cost
                    entries.removeValue(forKey: oldest.key)
                }
                clock &+= 1
                entries[request] = Entry(image: image, cost: cost, lastUsed: clock)
                cachedByteCount += cost
            }
        }
        return image
    }
    func invalidate(_ url: URL, beforeRevision revision: Int? = nil) {
        func isStale(_ key: Request) -> Bool {
            key.url == url && (revision.map { key.revision < $0 } ?? true)
        }
        for key in Array(entries.keys) where isStale(key) {
            cachedByteCount -= entries.removeValue(forKey: key)!.cost
        }
        for key in Array(pending.keys) where isStale(key) {
            pending.removeValue(forKey: key)?.task.cancel()
        }
    }
    func removeAll() {
        entries.removeAll()
        cachedByteCount = 0
        for read in pending.values { read.task.cancel() }
        pending.removeAll()
    }
    private static func decode(_ request: Request) -> CGImage? {
        guard request.maxPixelSize > 0,
              let source = CGImageSourceCreateWithURL(request.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: request.maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        // Materialize the small bitmap here so SwiftUI never starts a deferred HEIC decode.
        let colorSpace = thumbnail.colorSpace?.model == .rgb ? thumbnail.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
        return context.makeImage()
    }
}

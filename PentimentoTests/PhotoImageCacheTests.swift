import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Pentimento

final class PhotoImageCacheTests: XCTestCase {
    private func fixture(heic: Bool = false) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preview-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(heic ? "Synthetic.heic" : "Synthetic.jpg")
        try writeImage(url, width: heic ? 2048 : 320, height: heic ? 1536 : 240, red: false)
        return url
    }
    private func writeImage(_ url: URL, width: Int, height: Int, red: Bool) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red ? 0.9 : 0.1, green: 0.2, blue: red ? 0.1 : 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let type = url.pathExtension == "heic" ? UTType.heic : UTType.jpeg
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private func discard(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    func testHEICPreviewsAreDownsampledAndOrientedWithoutChangingTheFile() async throws {
        let url = try fixture(heic: true)
        defer { discard(url) }
        let original = try Data(contentsOf: url)
        let cache = PhotoImageCache()
        let thumbnail = await cache.image(for: .init(url: url, maxPixelSize: 96, revision: 0))
        let small = try XCTUnwrap(thumbnail)
        XCTAssertEqual(small.width, 72)
        XCTAssertEqual(small.height, 96)
        let preview = await cache.image(for: .init(url: url, maxPixelSize: 512, revision: 0))
        let large = try XCTUnwrap(preview)
        XCTAssertEqual(large.width, 384)
        XCTAssertEqual(large.height, 512)
        let bytes = await cache.cachedByteCount
        XCTAssertLessThan(bytes, 1_100_000, "Display images should not retain full-resolution HEIC bitmaps")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testConcurrentAndRepeatedRequestsShareTheDecodedImage() async throws {
        let url = try fixture()
        defer { discard(url) }
        let cache = PhotoImageCache()
        let request = PhotoImageCache.Request(url: url, maxPixelSize: 96, revision: 0)
        async let first = cache.image(for: request)
        async let second = cache.image(for: request)
        let (a, b) = await (first, second)
        let original = try XCTUnwrap(a)
        XCTAssertTrue(original === b)
        let cached = await cache.image(for: request)
        XCTAssertTrue(original === cached)
    }
    func testInvalidationLoadsChangedPixelsAndClearReleasesMemory() async throws {
        let url = try fixture()
        defer { discard(url) }
        let cache = PhotoImageCache()
        let request = PhotoImageCache.Request(url: url, maxPixelSize: 96, revision: 0)
        let first = await cache.image(for: request)
        let original = try XCTUnwrap(first)
        try writeImage(url, width: 320, height: 240, red: true)
        let cached = await cache.image(for: request)
        XCTAssertTrue(original === cached)
        await cache.invalidate(url)
        let updated = await cache.image(for: .init(url: url, maxPixelSize: 96, revision: 1))
        let fresh = try XCTUnwrap(updated)
        XCTAssertFalse(original === fresh)
        XCTAssertNotEqual(original.dataProvider?.data as Data?, fresh.dataProvider?.data as Data?)
        await cache.removeAll()
        let bytes = await cache.cachedByteCount
        XCTAssertEqual(bytes, 0)
    }
    func testDelayedInvalidationKeepsTheRefreshedThumbnail() async throws {
        let url = try fixture()
        defer { discard(url) }
        let cache = PhotoImageCache()
        let oldRequest = PhotoImageCache.Request(url: url, maxPixelSize: 96, revision: 0)
        let original = await cache.image(for: oldRequest)
        let oldImage = try XCTUnwrap(original)
        try writeImage(url, width: 320, height: 240, red: true)

        // The view can request the new revision before PhotoLibrary's invalidation task runs.
        let refreshedRequest = PhotoImageCache.Request(url: url, maxPixelSize: 96, revision: 1)
        let refreshed = await cache.image(for: refreshedRequest)
        let refreshedImage = try XCTUnwrap(refreshed)
        await cache.invalidate(url, beforeRevision: 1)

        let cachedRefreshedImage = await cache.image(for: refreshedRequest)
        XCTAssertTrue(refreshedImage === cachedRefreshedImage)
        XCTAssertFalse(oldImage === refreshedImage)
        let reloadedOldImage = await cache.image(for: oldRequest)
        XCTAssertFalse(oldImage === reloadedOldImage)
    }
    func testImageCacheEvictsImagesToStayWithinItsMemoryBudget() async throws {
        let a = try fixture(), b = try fixture()
        defer { discard(a); discard(b) }
        let cache = PhotoImageCache(byteLimit: 40_000)
        let request = PhotoImageCache.Request(url: a, maxPixelSize: 96, revision: 0)
        let original = await cache.image(for: request)
        _ = await cache.image(for: .init(url: b, maxPixelSize: 96, revision: 0))
        let bytes = await cache.cachedByteCount
        XCTAssertLessThanOrEqual(bytes, 40_000)
        let reloaded = await cache.image(for: request)
        XCTAssertNotNil(reloaded)
        XCTAssertFalse(original === reloaded, "The older image should have been evicted")
    }
}

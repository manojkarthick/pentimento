import XCTest
@testable import Pentimento

@MainActor final class PhotoLibraryCacheTests: XCTestCase {
    private func library(service: CacheTestService) -> PhotoLibrary {
        let defaults = UserDefaults(suiteName: "PhotoLibraryCacheTests.\(UUID().uuidString)")!
        return PhotoLibrary(service: service, defaults: defaults)
    }
    private func urls() -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (folder.appendingPathComponent("a.jpg"), folder.appendingPathComponent("b.jpg"))
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "Metadata state did not settle")
    }

    func testSwitchingSharesInFlightReadsAndUsesCachedMetadata() async throws {
        let service = CacheTestService(holdReads: true)
        let library = library(service: service)
        let (a, b) = urls()
        library.add([a, b])
        let deadline = Date().addingTimeInterval(3)
        while await service.counts().count < 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        library.selected = b
        library.selected = a
        try await service.finishReads()
        try await waitUntil { library.metadata?.url == a && library.summary(for: b) != "Reading…" }

        library.selected = b
        XCTAssertEqual(library.metadata?.url, b)
        XCTAssertFalse(library.busy)
        library.selected = a
        XCTAssertEqual(library.metadata?.url, a)
        XCTAssertFalse(library.busy)
        let counts = await service.counts()
        XCTAssertEqual(counts[a], 1, "Sidebar and detail must share one read")
        XCTAssertEqual(counts[b], 1, "Selecting a cached photo must not read it again")
        library.clearRecent()
    }

    func testExplicitRefreshReplacesCachedMetadata() async throws {
        let service = CacheTestService()
        let library = library(service: service)
        let (a, b) = urls()
        library.add([a, b])
        try await waitUntil { !library.busy && library.summary(for: b) != "Reading…" }
        await service.setValue("Refreshed", for: a)
        library.loadSelected(forceRefresh: true)
        try await waitUntil { !library.busy && library.metadata?.tags.first?.value == "Refreshed" }
        library.selected = b
        library.selected = a
        XCTAssertEqual(library.metadata?.tags.first?.value, "Refreshed")
        let counts = await service.counts()
        XCTAssertEqual(counts[a], 2)
        library.clearRecent()
    }

    func testRemovalUpdatesCacheAndRemovingPhotosEvictsIt() async throws {
        let service = CacheTestService()
        let library = library(service: service)
        let (a, b) = urls()
        library.add([a, b])
        try await waitUntil { !library.busy && library.summary(for: b) != "Reading…" }
        library.selectedKeys = ["EXIF:IFD0:Artist"]
        library.removeSelected(broad: false)
        try await waitUntil { library.result != nil }
        library.selected = b
        library.selected = a
        XCTAssertEqual(library.metadata?.tags.first?.value, "Edited")
        let afterWrite = await service.counts()
        XCTAssertEqual(afterWrite[a], 1, "The verified edit result should replace the cached metadata")

        library.removeFromList(a)
        library.add([a])
        try await waitUntil { !library.busy && library.metadata?.url == a }
        let afterRemove = await service.counts()
        XCTAssertEqual(afterRemove[a], 2)
        library.clearRecent()
        library.add([a])
        try await waitUntil { !library.busy && library.metadata?.url == a }
        let afterClear = await service.counts()
        XCTAssertEqual(afterClear[a], 3)
        library.clearRecent()
    }
    func testBatchRemovalSelectsSurvivorAndEvictsEveryRemovedPhoto() async throws {
        let service = CacheTestService()
        let library = library(service: service)
        let (a, b) = urls()
        let c = a.deletingLastPathComponent().appendingPathComponent("c.jpg")
        library.add([a, b, c])
        try await waitUntil { !library.busy && library.summary(for: b) != "Reading…" && library.summary(for: c) != "Reading…" }
        library.selectedKeys = ["EXIF:IFD0:Artist"]

        library.removeFromList([a, c])

        XCTAssertEqual(library.photos, [b])
        XCTAssertEqual(library.selected, b)
        XCTAssertEqual(library.metadata?.url, b)
        XCTAssertTrue(library.selectedKeys.isEmpty)
        XCTAssertEqual(library.summary(for: a), "Photo")
        XCTAssertEqual(library.summary(for: c), "Photo")

        library.add([a, c])
        try await waitUntil { !library.busy && library.summary(for: c) != "Reading…" }
        let counts = await service.counts()
        XCTAssertEqual(counts[a], 2)
        XCTAssertEqual(counts[b], 1)
        XCTAssertEqual(counts[c], 2)
        library.clearRecent()
    }

    func testBatchRemovalPreservesUnremovedSelection() async throws {
        let service = CacheTestService()
        let library = library(service: service)
        let (a, b) = urls()
        library.add([a, b])
        try await waitUntil { !library.busy && library.summary(for: b) != "Reading…" }
        library.selected = b
        library.selectedKeys = ["EXIF:IFD0:Artist"]

        library.removeFromList([a, URL(fileURLWithPath: "/not-in-library.jpg")])

        XCTAssertEqual(library.photos, [b])
        XCTAssertEqual(library.selected, b)
        XCTAssertEqual(library.metadata?.url, b)
        XCTAssertEqual(library.selectedKeys, ["EXIF:IFD0:Artist"])
        library.clearRecent()
    }

    func testBatchRemovalIgnoresLateReadResults() async throws {
        let service = CacheTestService(holdReads: true)
        let library = library(service: service)
        let (a, b) = urls()
        library.add([a, b])
        let deadline = Date().addingTimeInterval(3)
        while await service.counts().count < 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let startedReads = await service.counts()
        XCTAssertEqual(startedReads.count, 2)

        library.removeFromList([a, b])
        try await service.finishReads()
        // Yield to the cancelled read tasks so their late results are processed.
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(library.photos.isEmpty)
        XCTAssertNil(library.selected)
        XCTAssertNil(library.metadata)
        XCTAssertNil(library.error)
        XCTAssertFalse(library.busy)
        XCTAssertTrue(library.summaries.isEmpty)
        library.clearRecent()
    }

    func testBatchRemovalPersistsSurvivorsAndKeepsOriginalFiles() async throws {
        let service = CacheTestService()
        let defaults = UserDefaults(suiteName: "PhotoLibraryCacheTests.\(UUID().uuidString)")!
        let library = PhotoLibrary(service: service, defaults: defaults)
        let (a, b) = urls()
        let original = Data("Original photo contents".utf8)
        try FileManager.default.createDirectory(at: a.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        try original.write(to: a)
        try original.write(to: b)
        library.add([a, b])

        library.removeFromList(Set([a]))
        let restored = PhotoLibrary(service: service, defaults: defaults)

        XCTAssertEqual(restored.photos.map { $0.resolvingSymlinksInPath() }, [b.resolvingSymlinksInPath()])
        XCTAssertEqual(try Data(contentsOf: a), original)
        XCTAssertEqual(try Data(contentsOf: b), original)
        restored.clearRecent()
        library.removeFromList(Set([b]))
        XCTAssertTrue(PhotoLibrary(service: service, defaults: defaults).photos.isEmpty)
        library.clearRecent()
    }
}

private actor CacheTestService: MetadataServicing {
    private var readCounts: [URL: Int] = [:]
    private var values: [URL: String] = [:]
    private var holdReads: Bool
    private var waiters: [(URL, CheckedContinuation<PhotoMetadata, Error>)] = []
    init(holdReads: Bool = false) { self.holdReads = holdReads }
    func counts() -> [URL: Int] { readCounts }
    func setValue(_ value: String, for url: URL) { values[url] = value }
    func read(_ url: URL) async throws -> PhotoMetadata {
        readCounts[url, default: 0] += 1
        if holdReads {
            return try await withCheckedThrowingContinuation { waiters.append((url, $0)) }
        }
        return try metadata(url)
    }
    func finishReads() throws {
        holdReads = false
        for (url, continuation) in waiters { continuation.resume(returning: try metadata(url)) }
        waiters = []
    }
    func remove(_ url: URL, keys: [String]?, broad: Bool) async throws -> RemovalResult {
        values[url] = "Edited"
        return RemovalResult(metadata: try metadata(url), requested: 1, removed: 1, remaining: [], warnings: [])
    }
    private func metadata(_ url: URL) throws -> PhotoMetadata {
        let record = [["EXIF:IFD0:Artist": ["val": values[url] ?? "Original"]]]
        return try MetadataParser.parse(JSONSerialization.data(withJSONObject: record), url: url)
    }
}

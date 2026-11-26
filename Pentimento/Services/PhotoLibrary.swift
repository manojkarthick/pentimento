import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor final class PhotoLibrary: ObservableObject {
    @Published private(set) var photos: [URL] = []
    @Published var selected: URL? { didSet { if selected != oldValue { selectedKeys = []; result = nil; loadSelected() } } }
    @Published var metadata: PhotoMetadata?
    @Published var error: String?
    @Published var busy = false
    @Published var selectedKeys: Set<String> = []
    @Published var result: RemovalResult?
    @Published var search = ""
    @Published var groupFilter = "all"
    @Published private(set) var summaries: [URL: String] = [:]
    let imageCache = PhotoImageCache()
    @Published private var imageRevisions: [URL: Int] = [:]
    private let service: (any MetadataServicing)?
    private let defaults: UserDefaults
    private var metadataCache: [URL: PhotoMetadata] = [:]
    private var readErrors: [URL: String] = [:]
    private struct PendingRead {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var pendingReads: [URL: PendingRead] = [:]
    private var writing: Set<URL> = []
    private var activeScopes: Set<URL> = []
    private let storageKey = "recentPhotoBookmarks"

    init(service: (any MetadataServicing)? = nil, defaults: UserDefaults = .standard) {
        self.service = service ?? (try? ExifToolRunner.bundledOrLocal()).map { MetadataService(runner: $0) }
        self.defaults = defaults
        let bookmarks = defaults.array(forKey: storageKey) as? [Data] ?? []
        photos = bookmarks.compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
        }
        for url in photos {
            if url.startAccessingSecurityScopedResource() { activeScopes.insert(url) }
            loadSummary(url)
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.jpeg, .png, .tiff, .heic, .heif, .webP, .gif,
            UTType(filenameExtension: "avif"), UTType(filenameExtension: "dng"),
            UTType(filenameExtension: "cr2"), UTType(filenameExtension: "cr3"),
            UTType(filenameExtension: "nef"), UTType(filenameExtension: "arw"),
            UTType(filenameExtension: "raf"), UTType(filenameExtension: "orf"),
            UTType(filenameExtension: "rw2")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        let supported = urls.filter { MetadataService.readableExtensions.contains($0.pathExtension.lowercased()) }
        if supported.isEmpty && !urls.isEmpty { error = "Unsupported file. Choose a supported photo format."; return }
        for url in supported where !photos.contains(url) {
            photos.append(url)
            if url.startAccessingSecurityScopedResource() { activeScopes.insert(url) }
            loadSummary(url)
        }
        persist()
        if let first = supported.first { selected = first }
    }
    func removeFromList(_ url: URL) {
        removeFromList([url])
    }
    func removeFromList(_ urls: Set<URL>) {
        let removed = urls.intersection(photos)
        guard !removed.isEmpty else { return }
        for url in removed {
            if activeScopes.remove(url) != nil { url.stopAccessingSecurityScopedResource() }
            summaries.removeValue(forKey: url)
            imageRevisions.removeValue(forKey: url)
            invalidateRead(url)
            metadataCache.removeValue(forKey: url)
            readErrors.removeValue(forKey: url)
        }
        photos.removeAll { removed.contains($0) }
        Task {
            for url in removed { await imageCache.invalidate(url) }
        }
        if let selected, removed.contains(selected) { self.selected = photos.first }
        persist()
    }
    func clearRecent() {
        for url in activeScopes { url.stopAccessingSecurityScopedResource() }
        activeScopes.removeAll()
        photos = []
        summaries = [:]
        imageRevisions = [:]
        Task { await imageCache.removeAll() }
        for read in pendingReads.values { read.task.cancel() }
        pendingReads = [:]
        metadataCache = [:]
        readErrors = [:]
        selected = nil
        metadata = nil
        result = nil
        defaults.removeObject(forKey: storageKey)
    }
    private func persist() {
        let values = photos.compactMap { try? $0.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
        defaults.set(values, forKey: storageKey)
    }
    func loadSelected(forceRefresh: Bool = false) {
        guard let url = selected else { metadata = nil; error = nil; busy = false; return }
        metadata = metadataCache[url]
        error = nil
        if writing.contains(url) { busy = true; return }
        if forceRefresh {
            invalidateImage(url)
            invalidateRead(url)
            metadataCache.removeValue(forKey: url)
            readErrors.removeValue(forKey: url)
            result = nil
        } else if metadata != nil {
            busy = false
            return
        } else if let cachedError = readErrors[url] {
            error = cachedError
            busy = false
            return
        }
        busy = true
        startRead(url)
    }
    func removeSelected(broad: Bool) {
        guard let selected, let service, !busy else { return }
        let keys = Array(selectedKeys)
        writing.insert(selected)
        invalidateRead(selected)
        busy = true; error = nil; result = nil
        Task {
            do {
                let outcome = try await service.remove(selected, keys: broad ? nil : keys, broad: broad)
                if photos.contains(selected) {
                    cache(outcome.metadata, for: selected)
                    invalidateImage(selected)
                }
                if self.selected == selected {
                    self.metadata = outcome.metadata
                    self.selectedKeys = []
                    self.result = outcome
                }
            } catch {
                metadataCache.removeValue(forKey: selected)
                if self.selected == selected { self.error = error.localizedDescription }
            }
            writing.remove(selected)
            if self.selected == selected { self.busy = false }
        }
    }
    func imageRevision(for url: URL) -> Int { imageRevisions[url, default: 0] }
    private func invalidateImage(_ url: URL) {
        imageRevisions[url, default: 0] += 1
        let revision = imageRevisions[url, default: 0]
        Task { await imageCache.invalidate(url, beforeRevision: revision) }
    }
    func summary(for url: URL) -> String { summaries[url] ?? "Photo" }
    private func loadSummary(_ url: URL) {
        if metadataCache[url] == nil { startRead(url) }
    }
    private func startRead(_ url: URL) {
        // Sidebar summaries and the detail view share one read per photo.
        guard pendingReads[url] == nil else { return }
        summaries[url] = "Reading…"
        guard let service else {
            summaries[url] = "Can’t read file"
            readErrors[url] = "ExifTool is unavailable."
            if selected == url { error = readErrors[url]; busy = false }
            return
        }
        let id = UUID()
        let task = Task {
            do {
                let value = try await service.read(url)
                guard pendingReads[url]?.id == id, photos.contains(url) else { return }
                cache(value, for: url)
                if selected == url { metadata = value; error = nil; busy = false }
            } catch {
                guard pendingReads[url]?.id == id, photos.contains(url) else { return }
                readErrors[url] = error.localizedDescription
                summaries[url] = "Can’t read file"
                if selected == url { self.error = error.localizedDescription; busy = false }
            }
            pendingReads.removeValue(forKey: url)
        }
        pendingReads[url] = PendingRead(id: id, task: task)
    }
    private func cache(_ value: PhotoMetadata, for url: URL) {
        metadataCache[url] = value
        readErrors.removeValue(forKey: url)
        summaries[url] = value.sensitiveTags > 0 ? "\(value.sensitiveTags) sensitive \(value.sensitiveTags == 1 ? "tag" : "tags")" : "No personal info"
    }
    private func invalidateRead(_ url: URL) {
        pendingReads.removeValue(forKey: url)?.task.cancel()
    }
    func toggle(_ keys: [String], to selected: Bool) {
        if selected { selectedKeys.formUnion(keys) } else { selectedKeys.subtract(keys) }
    }
    func showInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

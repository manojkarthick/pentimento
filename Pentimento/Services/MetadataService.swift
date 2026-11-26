import Foundation
import ImageIO
import Darwin

protocol MetadataServicing: Sendable {
    func read(_ url: URL) async throws -> PhotoMetadata
    func remove(_ url: URL, keys: [String]?, broad: Bool) async throws -> RemovalResult
}

actor MetadataService: MetadataServicing {
    private let runner: ExifToolRunner
    private var writing: Set<String> = []
    static let writableExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif"]
    static let readableExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp", "avif", "gif", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"]

    init(runner: ExifToolRunner) { self.runner = runner }

    func read(_ url: URL) async throws -> PhotoMetadata {
        guard url.isFileURL, url.path.hasPrefix("/"), FileManager.default.fileExists(atPath: url.path) else { throw InspectorError.message("The photo is missing or inaccessible.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw InspectorError.message("This is not a regular file.") }
        let output = try await runner.run(ExifToolRunner.readArguments(url))
        guard let data = output.stdout.data(using: .utf8) else { throw InspectorError.message("ExifTool returned invalid text.") }
        return try MetadataParser.parse(data, url: url, stderr: output.stderr, exitCode: output.exitCode)
    }

    func remove(_ url: URL, keys: [String]?, broad: Bool) async throws -> RemovalResult {
        guard !writing.contains(url.path) else { throw InspectorError.message("This photo is already being updated.") }
        writing.insert(url.path)
        defer { writing.remove(url.path) }
        guard Self.writableExtensions.contains(url.pathExtension.lowercased()) else {
            throw InspectorError.message("Editing this format is disabled. JPEG, PNG, TIFF and HEIC/HEIF are supported; RAW and other formats are read-only.")
        }
        guard FileManager.default.isWritableFile(atPath: url.path), FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
            throw InspectorError.message("The photo or its folder is read-only.")
        }
        let beforeIdentity = try fileIdentity(url)
        let before = try await read(url)
        let eligible = Set(before.tags.filter(\.removable).map(\.key))
        let targets: [String]
        let preserveLivePhoto = broad && LivePhotoPolicy.isLivePhoto(before)
        if broad {
            targets = LivePhotoPolicy.broadTargets(in: before).map(\.key).sorted()
        }
        else {
            let proposed = Array(Set(keys ?? [])).sorted()
            guard !proposed.isEmpty, proposed.allSatisfy({ MetadataParser.validKey($0) && eligible.contains($0) }) else {
                throw InspectorError.message("Select one or more removable tags from this photo.")
            }
            targets = proposed
        }
        guard !targets.isEmpty else { throw InspectorError.message("This photo has no removable metadata under the current policy.") }
        let originalSignature = try PostModificationVerifier.imageSignature(url)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".pentimento-\(UUID().uuidString).\(url.pathExtension)")
        try FileManager.default.copyItem(at: url, to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let args = broad ? ExifToolRunner.broadArguments(temp, preserveLivePhoto: preserveLivePhoto) : ExifToolRunner.selectedArguments(targets, url: temp)
        let output = try await runner.run(args)
        let warnings = (output.stderr + "\n" + output.stdout).split(separator: "\n").map(String.init).filter {
            $0.hasPrefix("Warning:") || $0.hasPrefix("Error:")
        }
        guard output.exitCode == 0, !warnings.contains(where: { $0.hasPrefix("Error:") }), !output.stdout.contains("weren't updated due to errors") else {
            throw InspectorError.message("ExifTool could not complete the edit. \(warnings.first ?? "Exit code \(output.exitCode).")")
        }
        let after = try await read(temp)
        let remaining = PostModificationVerifier.remaining(targets, in: after)
        guard remaining.isEmpty else {
            throw InspectorError.message("The edited copy still contains \(remaining.count) requested tag(s): \(remaining.prefix(10).joined(separator: ", ")). The original was left unchanged.")
        }
        try LivePhotoPolicy.validatePairing(before: before, after: after)
        if preserveLivePhoto {
            let retained = before.tags.filter { LivePhotoPolicy.isPreservedDuringBroadRemoval($0, metadata: before) }
            guard retained.allSatisfy({ tag in after.tags.contains { $0.key == tag.key && $0.value == tag.value } }) else {
                throw InspectorError.message("The edited copy changed retained Live Photo metadata. The original was left unchanged.")
            }
        }
        let editedSignature = try PostModificationVerifier.imageSignature(temp)
        guard originalSignature == editedSignature else {
            throw InspectorError.message("The edited copy changed image pixels, orientation, color information or auxiliary image resources. The original was left unchanged.")
        }
        guard try fileIdentity(url) == beforeIdentity else {
            throw InspectorError.message("The photo changed while it was being edited. The original was left unchanged.")
        }
        if rename(temp.path, url.path) != 0 {
            throw InspectorError.message("Could not replace the original photo safely: \(String(cString: strerror(errno))).")
        }
        let final = try await read(url)
        let finalRemaining = PostModificationVerifier.remaining(targets, in: final)
        return RemovalResult(metadata: final, requested: targets.count, removed: targets.count - finalRemaining.count,
                             remaining: finalRemaining, warnings: warnings + final.warnings + (preserveLivePhoto ? ["Live Photo pairing was preserved. Apple Maker Notes and camera make/model remain and may contain identifying information. The companion MOV was not edited."] : []))
    }

    private struct FileIdentity: Equatable {
        let inode: ino_t
        let size: off_t
        let seconds: Int
        let nanoseconds: Int
        let changeSeconds: Int
        let changeNanoseconds: Int
    }
    private func fileIdentity(_ url: URL) throws -> FileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw InspectorError.message("The photo is missing or inaccessible.") }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw InspectorError.message("Editing symlinks and hard-linked files is disabled for safety.")
        }
        return FileIdentity(inode: info.st_ino, size: info.st_size, seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec, changeSeconds: info.st_ctimespec.tv_sec, changeNanoseconds: info.st_ctimespec.tv_nsec)
    }
}

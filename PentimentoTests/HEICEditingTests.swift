import XCTest
import ImageIO
import CoreImage
import UniformTypeIdentifiers
@testable import Pentimento

final class HEICEditingTests: XCTestCase {
    private let identifier = "11111111-2222-3333-4444-555555555555"
    private var runner: ExifToolRunner { get throws { try .bundledOrLocal() } }
    private func fixture(live: Bool, ext: String = "heic") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heic-edit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Synthetic." + ext)
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "Synthetic iPhone"]]
        if live { properties[kCGImagePropertyMakerAppleDictionary] = ["17": identifier] }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "HEIC encoder could not create the disposable fixture")
        return url
    }
    private func discard(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    private func inject(_ url: URL) async throws {
        let result = try await runner.run(["-overwrite_original", "-GPSLatitude=49.1", "-GPSLatitudeRef=N", "-GPSLongitude=123.1", "-GPSLongitudeRef=W", "-Artist=Synthetic Person", "-DateTimeOriginal=2020:01:02 03:04:05", "--", url.path])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }
    func testSelectiveHEICRemovalPreservesLivePhotoPairingAndImageResources() async throws {
        let url = try fixture(live: true)
        defer { discard(url) }
        try await inject(url)
        let service = MetadataService(runner: try runner)
        let before = try await service.read(url)
        XCTAssertTrue(LivePhotoPolicy.isLivePhoto(before))
        let signature = try PostModificationVerifier.imageSignature(url)
        let keys = before.tags.filter { $0.group == "EXIF:GPS" }.map(\.key)
        XCTAssertFalse(keys.isEmpty)
        let result = try await service.remove(url, keys: keys, broad: false)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.metadata.tags.first { $0.name == "ContentIdentifier" }?.value, identifier)
        XCTAssertTrue(result.metadata.tags.contains { $0.name == "Artist" })
        XCTAssertEqual(try PostModificationVerifier.imageSignature(url), signature)
    }
    func testBroadHEICRemovalPreservesPairingAndLeavesCompanionUntouched() async throws {
        let url = try fixture(live: true)
        defer { discard(url) }
        try await inject(url)
        // A sentinel proves the writer never modifies a companion path. It is not a playback fixture.
        let companion = url.deletingPathExtension().appendingPathExtension("MOV")
        let sentinel = Data("Disposable companion sentinel".utf8)
        try sentinel.write(to: companion)
        let service = MetadataService(runner: try runner)
        let signature = try PostModificationVerifier.imageSignature(url)
        let result = try await service.remove(url, keys: nil, broad: true)
        XCTAssertTrue(result.verified)
        XCTAssertFalse(result.metadata.tags.contains { $0.group == "EXIF:GPS" || $0.name == "Artist" || $0.name == "DateTimeOriginal" })
        XCTAssertEqual(result.metadata.tags.first { $0.name == "ContentIdentifier" }?.value, identifier)
        XCTAssertTrue(result.metadata.tags.contains { $0.name == "Make" })
        XCTAssertTrue(result.warnings.contains { $0.contains("companion MOV") })
        XCTAssertGreaterThan(result.metadata.sensitiveTags, 0, "Retained identifiers must remain visible in privacy counts")
        XCTAssertTrue(LivePhotoPolicy.broadTargets(in: result.metadata).isEmpty, LivePhotoPolicy.broadTargets(in: result.metadata).map(\.key).joined(separator: ", "))
        XCTAssertEqual(try Data(contentsOf: companion), sentinel)
        XCTAssertEqual(try PostModificationVerifier.imageSignature(url), signature)
    }
    func testBroadHEIFRemovalWithoutLivePhotoRemovesPrivateMetadata() async throws {
        let url = try fixture(live: false, ext: "heif")
        defer { discard(url) }
        try await inject(url)
        let service = MetadataService(runner: try runner)
        let signature = try PostModificationVerifier.imageSignature(url)
        let result = try await service.remove(url, keys: nil, broad: true)
        XCTAssertTrue(result.verified)
        XCTAssertFalse(result.metadata.tags.contains { ["GPSLatitude", "Artist", "Make", "Model", "DateTimeOriginal"].contains($0.name) })
        XCTAssertEqual(try PostModificationVerifier.imageSignature(url), signature)
    }
    func testPairingIdentifierIsProtectedFromSelectiveRemoval() async throws {
        let url = try fixture(live: true)
        defer { discard(url) }
        let service = MetadataService(runner: try runner)
        let before = try await service.read(url)
        let tag = try XCTUnwrap(before.tags.first { $0.name == "ContentIdentifier" })
        XCTAssertFalse(tag.removable)
        let original = try Data(contentsOf: url)
        do {
            _ = try await service.remove(url, keys: [tag.key], broad: false)
            XCTFail("Protected Live Photo pairing must not be removed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("removable tags")) }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let changed = try MetadataParser.parse(Data("[{}]".utf8), url: url)
        XCTAssertThrowsError(try LivePhotoPolicy.validatePairing(before: before, after: changed))
    }
    func testHEICStructuralTagsAreNotSelectable() {
        for name in ["Rotation", "ImageSpatialExtent", "GeneralProfileIDC", "ColorPrimaries", "MediaDataOffset", "PrimaryItemReference"] {
            XCTAssertFalse(PrivacyClassifier.isRemovable(group: "QuickTime", name: name), name)
        }
        XCTAssertTrue(PrivacyClassifier.isRemovable(group: "QuickTime:Keys", name: "GPSCoordinates"))
        let arguments = ExifToolRunner.broadArguments(URL(fileURLWithPath: "/tmp/synthetic.heic"), preserveLivePhoto: true)
        XCTAssertTrue(arguments.contains("-MakerNotes"))
        XCTAssertTrue(arguments.contains("--ICC_Profile:all"))
    }
    func testBroadHEICRemovalPreservesHDRGainMap() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Generating a fixture with explicit HDR headroom requires macOS 26") }
        let url = try fixture(live: false)
        defer { discard(url) }
        let bounds = CGRect(x: 0, y: 0, width: 128, height: 96)
        let sdr = CIImage(color: CIColor(red: 0.25, green: 0.3, blue: 0.4)).cropped(to: bounds)
        let hdr = sdr.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 2]).settingContentHeadroom(4)
        try CIContext().writeHEIFRepresentation(of: sdr, to: url, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, options: [.hdrImage: hdr])
        try await inject(url)
        let signature = try PostModificationVerifier.imageSignature(url)
        XCTAssertFalse(signature.frames.flatMap { $0.auxiliaryData.keys }.isEmpty, "Fixture must contain a real gain map")
        let service = MetadataService(runner: try runner)
        let result = try await service.remove(url, keys: nil, broad: true)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(try PostModificationVerifier.imageSignature(url), signature)
    }
}

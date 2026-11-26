import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Pentimento

final class PentimentoTests: XCTestCase {
    private var runner: ExifToolRunner {
        get throws { try ExifToolRunner.bundledOrLocal() }
    }
    private func fixture(_ ext: String = "jpg", name: String = "photo") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-native-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name + "." + ext)
        let color = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let type = ext == "png" ? UTType.png.identifier : ext == "tif" ? UTType.tiff.identifier : UTType.jpeg.identifier
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    private func discard(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    private func addTags(_ url: URL) async throws {
        let output = try await runner.run(["-overwrite_original", "-GPSLatitude=49.1", "-GPSLatitudeRef=N", "-GPSLongitude=123.1", "-GPSLongitudeRef=W", "-Make=Apple", "-Model=Synthetic", "-DateTimeOriginal=2020:01:02 03:04:05", "-Artist=Test Person", "-ImageDescription=Test caption", "-Orientation=Rotate 90 CW", "--", url.path])
        XCTAssertEqual(output.exitCode, 0, output.stderr)
    }
    func testParserPreservesGroupQualifiedDuplicateNames() throws {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        let json = """
        [{"EXIF:IFD0:Artist":{"val":"Alice","desc":"Artist"},"XMP:XMP-dc:Artist":{"val":"Bob","desc":"Artist"},"EXIF:GPS:GPSLatitude":{"val":"49.1","num":49.1},"Composite:GPSLatitude":{"val":"49.1","num":49.1},"Composite:GPSLongitude":{"val":"-123.1","num":-123.1}}]
        """
        let result = try MetadataParser.parse(Data(json.utf8), url: url)
        XCTAssertEqual(result.tags.filter { $0.name == "Artist" }.count, 2)
        XCTAssertEqual(result.findings.first(where: { $0.category == .people })?.tags.count, 2)
        XCTAssertEqual(result.gps?.longitude, -123.1)
    }
    func testMalformedResponseAndReadError() {
        let url = URL(fileURLWithPath: "/tmp/broken.jpg")
        XCTAssertThrowsError(try MetadataParser.parse(Data("oops".utf8), url: url))
        XCTAssertThrowsError(try MetadataParser.parse(Data("[]".utf8), url: url))
        let error = "[{\"File:FileName\":{\"val\":\"broken.jpg\"},\"ExifTool:Error\":{\"val\":\"Not an image\"}}]"
        XCTAssertThrowsError(try MetadataParser.parse(Data(error.utf8), url: url, exitCode: 1))
    }
    func testClassificationAndRemovability() {
        XCTAssertEqual(PrivacyClassifier.classify(group: "XMP:XMP-xmp", name: "CreatorTool"), .device)
        XCTAssertEqual(PrivacyClassifier.classify(group: "EXIF:ExifIFD", name: "BodySerialNumber"), .identifiers)
        XCTAssertEqual(PrivacyClassifier.classify(group: "File", name: "Comment"), .captions)
        XCTAssertNil(PrivacyClassifier.classify(group: "JFIF", name: "Make"))
        XCTAssertFalse(PrivacyClassifier.isRemovable(group: "File", name: "FileSize"))
        XCTAssertFalse(PrivacyClassifier.isRemovable(group: "EXIF:IFD0", name: "Orientation"))
        XCTAssertTrue(PrivacyClassifier.isRemovable(group: "EXIF:GPS", name: "GPSLatitude"))
    }
    func testExifToolArgumentsAndUnusualPaths() {
        let url = URL(fileURLWithPath: "/tmp/-odd name ' ü.jpg")
        XCTAssertEqual(ExifToolRunner.readArguments(url).suffix(2), ["--", url.path])
        XCTAssertEqual(ExifToolRunner.selectedArguments(["EXIF:GPS:GPSLatitude"], url: url).suffix(2), ["--", url.path])
        XCTAssertTrue(ExifToolRunner.selectedArguments(["EXIF:GPS:GPSLatitude"], url: url).contains("-EXIF:GPS:GPSLatitude="))
        XCTAssertEqual(ExifToolRunner.broadArguments(url).suffix(2), ["--", url.path])
        XCTAssertFalse(MetadataParser.validKey("-all="))
    }
    func testNonzeroExit() async throws {
        let output = try await runner.run(["-definitely-not-a-real-option"])
        XCTAssertNotEqual(output.exitCode, 0)
    }
    func testSelectiveRemovalKeepsUnrelatedTagsAndImage() async throws {
        let url = try fixture(name: "-unusual ' ü")
        defer { discard(url) }
        try await addTags(url)
        let service = MetadataService(runner: try runner)
        let before = try await service.read(url)
        let gps = before.tags.filter { $0.name.hasPrefix("GPS") && $0.removable }.map(\.key)
        XCTAssertFalse(gps.isEmpty)
        let result = try await service.remove(url, keys: gps, broad: false)
        XCTAssertTrue(result.verified)
        XCTAssertFalse(result.metadata.tags.contains { gps.contains($0.key) })
        XCTAssertTrue(result.metadata.tags.contains { $0.name == "Artist" })
        XCTAssertTrue(result.metadata.tags.contains { $0.name == "Orientation" })
    }
    func testBroadRemovalPreservesOrientationAndColor() async throws {
        let url = try fixture()
        defer { discard(url) }
        try await addTags(url)
        let service = MetadataService(runner: try runner)
        let before = try await service.read(url)
        XCTAssertTrue(before.tags.contains { $0.name == "Artist" })
        let result = try await service.remove(url, keys: nil, broad: true)
        XCTAssertTrue(result.verified)
        XCTAssertFalse(result.metadata.tags.contains { $0.name == "Artist" })
        XCTAssertTrue(result.metadata.tags.contains { $0.name == "Orientation" })
        XCTAssertNotNil(CGImageSourceCreateWithURL(url as CFURL, nil))
    }
    func testRAWAndUnsupportedWriteRestrictions() async throws {
        let url = try fixture()
        defer { discard(url) }
        let raw = url.deletingPathExtension().appendingPathExtension("cr2")
        try FileManager.default.copyItem(at: url, to: raw)
        let service = MetadataService(runner: try runner)
        do {
            _ = try await service.remove(raw, keys: nil, broad: true)
            XCTFail("RAW edit unexpectedly allowed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("disabled")) }
    }
    func testPNGAndTIFFBroadRemoval() async throws {
        for ext in ["png", "tif"] {
            let url = try fixture(ext)
            defer { discard(url) }
            let output = try await runner.run(["-overwrite_original", "-XMP-dc:Creator=Test Person", "--", url.path])
            XCTAssertEqual(output.exitCode, 0, output.stderr)
            let service = MetadataService(runner: try runner)
            let before = try await service.read(url)
            XCTAssertTrue(before.tags.contains { $0.name == "Creator" }, "Missing injected Creator for \(ext)")
            let result = try await service.remove(url, keys: nil, broad: true)
            XCTAssertTrue(result.verified)
            XCTAssertFalse(result.metadata.tags.contains { $0.name == "Creator" })
        }
    }

    func testResidualTagDetection() throws {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        let json = """
        [{"EXIF:IFD0:Artist":{"val":"Alice"},"XMP:XMP-dc:Creator":{"val":"Bob"}}]
        """
        let metadata = try MetadataParser.parse(Data(json.utf8), url: url)
        XCTAssertEqual(PostModificationVerifier.remaining(["EXIF:IFD0:Artist", "EXIF:GPS:GPSLatitude"], in: metadata), ["EXIF:IFD0:Artist"])
    }

}

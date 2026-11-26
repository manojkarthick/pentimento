import Foundation
import ImageIO
import CryptoKit

/// Checks requested tag disappearance and independently decodes images and auxiliary resources.
enum PostModificationVerifier {
    struct AuxiliarySignature: Equatable {
        let dataDigest: Data
        let description: NSDictionary
        let metadataDigest: Data?
    }
    struct FrameSignature: Equatable {
        let width: Int
        let height: Int
        let orientation: Int
        let bitsPerComponent: Int
        let bitsPerPixel: Int
        let colorModel: String
        let profile: String
        let profileDigest: Data?
        let pixelDigest: Data
        let auxiliaryData: [String: AuxiliarySignature]
    }
    struct ImageSignature: Equatable {
        let primaryIndex: Int
        let frames: [FrameSignature]
    }
    static func remaining(_ keys: [String], in metadata: PhotoMetadata) -> [String] {
        let present = Set(metadata.tags.map(\.key))
        return keys.filter(present.contains)
    }
    static func imageSignature(_ url: URL) throws -> ImageSignature {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw InspectorError.message("The image cannot be decoded safely. Editing is disabled.")
        }
        var frames: [FrameSignature] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  let pixels = image.dataProvider?.data else {
                throw InspectorError.message("An image resource cannot be decoded safely. Editing is disabled.")
            }
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let profile = props[kCGImagePropertyProfileName] as? String ?? ""
            let model = image.colorSpace?.model.rawValue.description ?? ""
            let profileDigest = image.colorSpace?.copyICCData().map { digest($0 as Data) }
            frames.append(FrameSignature(width: image.width, height: image.height, orientation: orientation,
                bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel,
                colorModel: model, profile: profile, profileDigest: profileDigest,
                pixelDigest: digest(pixels as Data), auxiliaryData: try auxiliarySignatures(source, index: index)))
        }
        return ImageSignature(primaryIndex: CGImageSourceGetPrimaryImageIndex(source), frames: frames)
    }
    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private static func auxiliarySignatures(_ source: CGImageSource, index: Int) throws -> [String: AuxiliarySignature] {
        var types: [CFString] = [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
            kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
            kCGImageAuxiliaryDataTypeHDRGainMap]
        if #available(macOS 15.0, *) { types.append(kCGImageAuxiliaryDataTypeISOGainMap) }
        var signatures: [String: AuxiliarySignature] = [:]
        for type in types {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type) as? [CFString: Any] else { continue }
            guard let data = info[kCGImageAuxiliaryDataInfoData] as? Data,
                  let description = info[kCGImageAuxiliaryDataInfoDataDescription] as? NSDictionary else {
                throw InspectorError.message("Auxiliary image data could not be verified. The original was left unchanged.")
            }
            var metadataDigest: Data?
            if let metadata = info[kCGImageAuxiliaryDataInfoMetadata] {
                guard CFGetTypeID(metadata as CFTypeRef) == CGImageMetadataGetTypeID(),
                      let xmp = CGImageMetadataCreateXMPData(metadata as! CGImageMetadata, nil) else {
                    throw InspectorError.message("Auxiliary image properties could not be verified. The original was left unchanged.")
                }
                metadataDigest = digest(xmp as Data)
            }
            signatures[type as String] = AuxiliarySignature(dataDigest: digest(data), description: description, metadataDigest: metadataDigest)
        }
        return signatures
    }
}

import Foundation

/// The still image's Apple Maker Notes contain the identifier that pairs it with its video.
enum LivePhotoPolicy {
    static let pairingNames: Set<String> = ["ContentIdentifier", "MediaGroupUUID", "LivePhotoVideoIndex"]

    static func pairingTags(in metadata: PhotoMetadata) -> [MetadataTag] {
        metadata.tags.filter { pairingNames.contains($0.name) }
    }
    static func isLivePhoto(_ metadata: PhotoMetadata) -> Bool {
        pairingTags(in: metadata).contains { $0.name != "LivePhotoVideoIndex" && !$0.value.isEmpty }
    }
    static func isPreservedDuringBroadRemoval(_ tag: MetadataTag, metadata: PhotoMetadata) -> Bool {
        guard isLivePhoto(metadata) else { return false }
        return tag.group.hasPrefix("MakerNotes") || pairingNames.contains(tag.name) || ["Make", "Model"].contains(tag.name)
    }
    static func broadTargets(in metadata: PhotoMetadata) -> [MetadataTag] {
        let preservePairing = isLivePhoto(metadata)
        return metadata.tags.filter { tag in
            tag.removable && (!preservePairing || (!tag.group.hasPrefix("MakerNotes") && !pairingNames.contains(tag.name) && !["Make", "Model"].contains(tag.name)))
        }
    }
    static func validatePairing(before: PhotoMetadata, after: PhotoMetadata) throws {
        let retained = pairingTags(in: before)
        let valuesAfter = Dictionary(uniqueKeysWithValues: after.tags.map { ($0.key, $0.value) })
        guard retained.allSatisfy({ valuesAfter[$0.key] == $0.value }) else {
            throw InspectorError.message("The edited copy changed Live Photo pairing information. The original was left unchanged.")
        }
    }
}

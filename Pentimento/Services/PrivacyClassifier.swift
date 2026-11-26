import Foundation

enum PrivacyClassifier {
    private static let location: Set<String> = ["City", "State", "Country", "CountryCode", "CountryName", "Province-State", "ProvinceState", "Country-PrimaryLocationName", "Country-PrimaryLocationCode", "Sub-location", "Sublocation", "Location", "LocationName", "WorldRegion"]
    private static let device: Set<String> = ["Make", "Model", "CameraModelName", "UniqueCameraModel", "LocalizedCameraModel", "LensMake", "LensModel", "LensInfo", "LensID", "Lens", "Software", "HostComputer", "CreatorTool", "ProcessingSoftware"]
    private static let identifiers: Set<String> = ["OwnerName", "CameraOwnerName", "ImageUniqueID", "DocumentID", "InstanceID", "OriginalDocumentID", "DerivedFromDocumentID", "DerivedFromInstanceID", "ContentIdentifier", "PhotoIdentifier", "ImageCaptureRequestID"]
    private static let people: Set<String> = ["Artist", "Author", "Creator", "By-line", "By-lineTitle", "AuthorsPosition", "Copyright", "CopyrightNotice", "Rights", "XPAuthor", "Credit", "Owner", "CaptionWriter", "Writer-Editor", "Contact", "RegionName", "RegionPersonDisplayName"]
    private static let dates: Set<String> = ["DateTimeOriginal", "DateTimeDigitized", "CreateDate", "ModifyDate", "DateCreated", "TimeCreated", "DigitalCreationDate", "DigitalCreationTime", "MetadataDate", "CreationDate", "ContentCreateDate", "DateTime"]
    private static let captions: Set<String> = ["ImageDescription", "UserComment", "Caption-Abstract", "Description", "Title", "ObjectName", "Headline", "Keywords", "Subject", "Comment", "XPComment", "XPTitle", "XPSubject", "XPKeywords", "Instructions", "SpecialInstructions"]
    private static let neutral: Set<String> = ["File", "ExifTool", "ICC_Profile", "JFIF"]
    private static let structuralNames: Set<String> = ["Orientation", "ColorSpace", "Gamma", "InteropIndex"]
    private static let structuralTags: Set<String> = ["BitDepth", "ColorType", "Compression", "Filter", "ImageHeight", "ImageWidth", "Interlace", "BitsPerSample", "PhotometricInterpretation", "SamplesPerPixel", "RowsPerStrip", "StripOffsets", "StripByteCounts", "PlanarConfiguration", "ResolutionUnit", "XResolution", "YResolution", "SRGBRendering", "ExifImageWidth", "ExifImageHeight", "ExtraSamples", "FillOrder", "SampleFormat", "ExifVersion", "FlashpixVersion", "ComponentsConfiguration", "YCbCrPositioning"]
    private static let readOnly: Set<String> = ["File", "Composite", "ExifTool", "ICC_Profile"]

    static func classify(group: String, name: String) -> PrivacyCategory? {
        let family = group.split(separator: ":").first.map(String.init) ?? group
        if family == "File" && name == "Comment" { return .captions }
        if neutral.contains(family) { return nil }
        if name.hasPrefix("GPS") || name.hasPrefix("LocationCreated") || name.hasPrefix("LocationShown") || location.contains(name) { return .location }
        if device.contains(name) { return .device }
        if identifiers.contains(name) || name.hasSuffix("SerialNumber") || name.hasSuffix("UUID") { return .identifiers }
        if people.contains(name) || name.hasPrefix("Creator") || name.hasPrefix("PersonInImage") { return .people }
        if dates.contains(name) || name.hasPrefix("OffsetTime") || name.hasPrefix("SubSecTime") || name.hasPrefix("SubSecDateTime") { return .dates }
        if captions.contains(name) { return .captions }
        return nil
    }

    static func isRemovable(group: String, name: String) -> Bool {
        let family = group.split(separator: ":").first.map(String.init) ?? group
        // ExifTool cannot delete individual Maker Note fields. Keep them visible as read-only.
        if family == "MakerNotes" || LivePhotoPolicy.pairingNames.contains(name) { return false }
        if family == "QuickTime" {
            // HEIF codec, rotation, item-reference and color fields are structural.
            let metadataGroups: Set<String> = ["Keys", "ItemList", "UserData"]
            let subgroup = group.split(separator: ":").last.map(String.init) ?? group
            return metadataGroups.contains(subgroup) || classify(group: group, name: name) != nil
        }
        return (family == "File" && name == "Comment") || (!readOnly.contains(family) && family != "JFIF" && !structuralNames.contains(name) && !structuralTags.contains(name))
    }

    static func findings(_ tags: [MetadataTag], gps: GPSCoordinates?) -> [PrivacyFinding] {
        PrivacyCategory.allCases.compactMap { category in
            let matching = tags.filter { $0.removable && $0.category == category }
            guard !matching.isEmpty else { return nil }
            let values = Array(NSOrderedSet(array: matching.map(\.value).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })) as? [String] ?? []
            var summary = values.prefix(2).joined(separator: " · ")
            if category == .location, let gps { summary = String(format: "%.5f, %.5f", gps.latitude, gps.longitude) }
            if category == .device {
                let make = matching.first(where: { $0.name == "Make" })?.value ?? ""
                let model = matching.first(where: { $0.name == "Model" })?.value ?? ""
                if !make.isEmpty || !model.isEmpty { summary = model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)".trimmingCharacters(in: .whitespaces) }
            }
            if category == .dates {
                summary = matching.first(where: { dates.contains($0.name) && !$0.value.isEmpty })?.value ?? "No date recorded"
            }
            if summary.count > 80 { summary = String(summary.prefix(79)) + "…" }
            return PrivacyFinding(category: category, summary: summary, tags: matching)
        }
    }
}

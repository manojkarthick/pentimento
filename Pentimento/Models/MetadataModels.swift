import Foundation

enum PrivacyCategory: String, CaseIterable, Identifiable {
    case location, device, identifiers, people, dates, captions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .location: "Location"
        case .device: "Device"
        case .identifiers: "Identifiers"
        case .people: "People"
        case .dates: "Date & Time"
        case .captions: "Captions"
        }
    }
    var detail: String {
        switch self {
        case .location: "Where the photo was taken"
        case .device: "Camera, phone, lens and software"
        case .identifiers: "Serial numbers and unique IDs"
        case .people: "Names, authorship and contact details"
        case .dates: "When the photo was taken or edited"
        case .captions: "Descriptions, comments and keywords"
        }
    }
    var symbol: String {
        switch self {
        case .location: "mappin"
        case .device: "iphone"
        case .identifiers: "number"
        case .people: "person"
        case .dates: "calendar"
        case .captions: "text.bubble"
        }
    }
}

struct MetadataTag: Identifiable, Equatable {
    let key: String
    let group: String
    let name: String
    let label: String
    let value: String
    let removable: Bool
    let category: PrivacyCategory?
    var id: String { key }
}

struct MetadataGroup: Identifiable {
    let id: String
    let label: String
    let tags: [MetadataTag]
    var removable: Bool { tags.contains(where: \.removable) }
}

struct PrivacyFinding: Identifiable {
    let category: PrivacyCategory
    let summary: String
    let tags: [MetadataTag]
    var id: String { category.id }
}

struct GPSCoordinates {
    let latitude: Double
    let longitude: Double
    let altitude: Double?
}

struct PhotoMetadata {
    let url: URL
    let fileType: String
    let fileSize: String
    let dimensions: String?
    let groups: [MetadataGroup]
    let findings: [PrivacyFinding]
    let gps: GPSCoordinates?
    let warnings: [String]
    var tags: [MetadataTag] { groups.flatMap(\.tags) }
    var totalTags: Int { tags.count }
    var removableTags: Int { tags.filter(\.removable).count }
    var sensitiveTags: Int { tags.filter { $0.category != nil }.count }
    var sensitiveCategories: Int { Set(tags.compactMap(\.category)).count }
    var protectedSensitiveTags: Int { tags.filter { $0.category != nil && !$0.removable }.count }
    var unclassifiedRemovableTags: Int { tags.filter { $0.removable && $0.category == nil }.count }
}

struct RemovalResult {
    let metadata: PhotoMetadata
    let requested: Int
    let removed: Int
    let remaining: [String]
    let warnings: [String]
    var verified: Bool { remaining.isEmpty }
}

enum InspectorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

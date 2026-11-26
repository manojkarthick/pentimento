import Foundation

enum MetadataParser {
    private static let labels = ["EXIF:IFD0": "EXIF · Camera & Image", "EXIF:ExifIFD": "EXIF · Capture Settings", "EXIF:GPS": "EXIF · GPS", "EXIF:IFD1": "EXIF · Thumbnail", "EXIF:InteropIFD": "EXIF · Interoperability", "File:System": "File System", "File": "File", "Composite": "Derived Values", "JFIF": "JFIF"]
    private static let order = ["EXIF:IFD0", "EXIF:ExifIFD", "EXIF:GPS", "XMP", "IPTC", "Photoshop", "QuickTime", "PNG", "MakerNotes", "EXIF:IFD1", "EXIF:InteropIFD", "EXIF"]
    static func validKey(_ key: String) -> Bool { key.range(of: "^[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)+$", options: .regularExpression) != nil }

    static func parse(_ data: Data, url: URL, stderr: String = "", exitCode: Int32 = 0) throws -> PhotoMetadata {
        guard let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let record = records.first else {
            throw InspectorError.message("\(url.lastPathComponent) returned malformed metadata.")
        }
        var ordered: [(String, MetadataTag)] = []
        var warnings: [String] = []
        var readError: String?
        for key in record.keys.sorted() {
            guard key != "SourceFile", let raw = record[key] as? [String: Any], let colon = key.lastIndex(of: ":") else { continue }
            let group = String(key[..<colon]), name = String(key[key.index(after: colon)...])
            if group.hasPrefix("ExifTool") {
                if name == "Error" { readError = format(raw["val"]) }
                else if name == "Warning" { warnings.append(format(raw["val"])) }
                continue
            }
            guard validKey(key) else { continue }
            let removable = PrivacyClassifier.isRemovable(group: group, name: name)
            ordered.append((group, MetadataTag(key: key, group: group, name: name,
                label: (raw["desc"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name,
                value: format(raw["val"]), removable: removable,
                category: PrivacyClassifier.classify(group: group, name: name))))
        }
        if let readError, ordered.allSatisfy({ $0.0.hasPrefix("File") }) {
            throw InspectorError.message("\(url.lastPathComponent) can't be read: \(readError)")
        }
        if let readError { warnings.insert(readError, at: 0) }
        let stderrMessages = stderr.split(separator: "\n").map(String.init).filter { $0.hasPrefix("Warning:") || $0.hasPrefix("Error:") }
        warnings += stderrMessages
        if exitCode != 0 && ordered.isEmpty { throw InspectorError.message("ExifTool could not read \(url.lastPathComponent): \(warnings.first ?? "exit code \(exitCode)")") }
        let tags = ordered.map(\.1)
        let groups = Dictionary(grouping: tags, by: \.group).map { MetadataGroup(id: $0.key, label: label($0.key), tags: $0.value) }
            .sorted { rank($0.id) == rank($1.id) ? $0.id < $1.id : rank($0.id) < rank($1.id) }
        let lat = number(record, "Composite:GPSLatitude"), lon = number(record, "Composite:GPSLongitude")
        let gps: GPSCoordinates? = if let lat, let lon, abs(lat) <= 90, abs(lon) <= 180 {
            GPSCoordinates(latitude: lat, longitude: lon, altitude: number(record, "Composite:GPSAltitude"))
        } else { nil }
        return PhotoMetadata(url: url,
            fileType: string(record, "File:FileType") ?? url.pathExtension.uppercased(),
            fileSize: string(record, "File:System:FileSize") ?? "",
            dimensions: string(record, "Composite:ImageSize")?.replacingOccurrences(of: "x", with: " × "),
            groups: groups, findings: PrivacyClassifier.findings(tags, gps: gps), gps: gps, warnings: warnings)
    }

    private static func label(_ id: String) -> String {
        if let known = labels[id] { return known }
        let parts = id.split(separator: ":").map(String.init)
        if parts.first == "MakerNotes" { return "Maker Notes · \(parts.dropFirst().first ?? "Camera")" }
        if parts.first == "XMP", parts.count > 1 { return "XMP · \(parts[1].replacingOccurrences(of: "XMP-", with: ""))" }
        return parts.count > 1 && parts[0] != parts[1] ? "\(parts[0]) · \(parts[1])" : parts.first ?? id
    }
    private static func rank(_ id: String) -> Int {
        if let rank = order.firstIndex(where: { id == $0 || id.hasPrefix($0 + ":") }) { return rank }
        if id == "Composite" { return 90 }
        if id.hasPrefix("File") { return 95 }
        if id.hasPrefix("ICC_Profile") { return 85 }
        return 80
    }
    private static func string(_ record: [String: Any], _ key: String) -> String? {
        guard let value = (record[key] as? [String: Any])?["val"] else { return nil }
        let formatted = format(value)
        return formatted.isEmpty ? nil : formatted
    }
    private static func number(_ record: [String: Any], _ key: String) -> Double? {
        guard let entry = record[key] as? [String: Any], let raw = entry["num"] ?? entry["val"] else { return nil }
        if let n = raw as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let n = Double(String(describing: raw)) { return n.isFinite ? n : nil }
        return nil
    }
    private static func format(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let text = value as? String {
            if let range = text.range(of: "^\\(Binary data ([0-9]+) bytes", options: .regularExpression),
               let bytes = Int(text[range].split(separator: " ")[2]) {
                let amount = bytes < 1024 ? "\(bytes) bytes" : bytes < 1_048_576 ? String(format: "%.1f KB", Double(bytes)/1024) : String(format: "%.1f MB", Double(bytes)/1_048_576)
                return "Binary data (\(amount))"
            }
            return text
        }
        if let values = value as? [Any] { return values.map { format($0) }.joined(separator: ", ") }
        if let object = value as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { return text }
        return String(describing: value)
    }
}

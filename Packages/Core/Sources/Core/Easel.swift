import Foundation

/// A canvas for collecting clippings, links and labels, belonging to a Space.
public struct Easel: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var spaceID: UUID
    public var title: String
    public var createdAt: Date

    public init(id: UUID = UUID(), spaceID: UUID, title: String, createdAt: Date = Date()) {
        self.id = id
        self.spaceID = spaceID
        self.title = title
        self.createdAt = createdAt
    }
}

public enum EaselItemKind: String, Sendable {
    /// A clipped or pasted picture; `imageHash` names its file.
    case image
    /// A card for a web page.
    case link
    /// A short label.
    case text
}

/// Something placed on an Easel. Coordinates are in canvas points, origin
/// top-left; `z` orders overlapping items (higher is in front).
public struct EaselItem: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var easelID: UUID
    public var kind: EaselItemKind
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var z: Int
    /// Text for labels; the page title for links and clippings.
    public var text: String
    /// The page a clipping came from, or a link's address.
    public var url: URL?
    /// SHA-256 of the PNG for images.
    public var imageHash: String?

    public init(
        id: UUID = UUID(), easelID: UUID, kind: EaselItemKind,
        x: Double, y: Double, width: Double, height: Double, z: Int = 0,
        text: String = "", url: URL? = nil, imageHash: String? = nil
    ) {
        self.id = id
        self.easelID = easelID
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.z = z
        self.text = text
        self.url = url
        self.imageHash = imageHash
    }
}

/// Every Easel and its items: synced in full, unlike tabs.
public struct EaselSnapshot: Equatable, Sendable {
    public var easels: [Easel]
    public var items: [EaselItem]

    public init(easels: [Easel] = [], items: [EaselItem] = []) {
        self.easels = easels
        self.items = items
    }

    /// Images the items need, by hash.
    public var imageHashes: Set<String> {
        Set(items.compactMap(\.imageHash))
    }
}

extension SyncMapping {
    static let easelPrefix = "easel:"
    static let easelItemPrefix = "easelItem:"

    public static func fields(from easels: EaselSnapshot) -> [String: SyncFields] {
        var result: [String: SyncFields] = [:]
        for easel in easels.easels {
            result[easelPrefix + easel.id.uuidString] = [
                "space": easel.spaceID.uuidString,
                "title": easel.title,
                "created": String(Int(easel.createdAt.timeIntervalSince1970)),
            ]
        }
        for item in easels.items {
            var fields: SyncFields = [
                "easel": item.easelID.uuidString,
                "kind": item.kind.rawValue,
                "frame": [item.x, item.y, item.width, item.height].map(format).joined(separator: ","),
                "z": String(item.z),
            ]
            if !item.text.isEmpty { fields["text"] = item.text }
            if let url = item.url { fields["url"] = url.absoluteString }
            if let hash = item.imageHash { fields["image"] = hash }
            result[easelItemPrefix + item.id.uuidString] = fields
        }
        return result
    }

    /// The Easels described by synced `fields`. Items whose Easel is gone are dropped.
    public static func easels(from fields: [String: SyncFields]) -> EaselSnapshot {
        var easels: [Easel] = []
        for (key, values) in fields where key.hasPrefix(easelPrefix) {
            guard let id = UUID(uuidString: String(key.dropFirst(easelPrefix.count))),
                  let space = values["space"].flatMap(UUID.init(uuidString:))
            else { continue }
            let created = values["created"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            easels.append(Easel(id: id, spaceID: space, title: values["title"] ?? "Easel", createdAt: created))
        }
        easels.sort { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        let easelIDs = Set(easels.map(\.id))

        var items: [EaselItem] = []
        for (key, values) in fields where key.hasPrefix(easelItemPrefix) {
            guard let id = UUID(uuidString: String(key.dropFirst(easelItemPrefix.count))),
                  let easel = values["easel"].flatMap(UUID.init(uuidString:)), easelIDs.contains(easel),
                  let kind = values["kind"].flatMap(EaselItemKind.init(rawValue:))
            else { continue }
            let frame = (values["frame"] ?? "").split(separator: ",").compactMap { Double(String($0)) }
            guard frame.count == 4 else { continue }
            items.append(EaselItem(
                id: id, easelID: easel, kind: kind,
                x: frame[0], y: frame[1], width: frame[2], height: frame[3],
                z: values["z"].flatMap(Int.init) ?? 0,
                text: values["text"] ?? "",
                url: values["url"].flatMap(URL.init(string:)),
                imageHash: values["image"]
            ))
        }
        items.sort { ($0.z, $0.id.uuidString) < ($1.z, $1.id.uuidString) }
        return EaselSnapshot(easels: easels, items: items)
    }

    /// Whole points are enough for positions, and avoid sync churn from
    /// tiny floating-point differences.
    private static func format(_ value: Double) -> String {
        String(Int(value.rounded()))
    }
}

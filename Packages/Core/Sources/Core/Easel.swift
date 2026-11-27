import Foundation

/// A canvas for collecting clippings, links and labels, belonging to a Space.
public struct Easel: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var spaceID: UUID
    public var title: String
    public var createdAt: Date
    /// Where it sits among its Space's Easels in the sidebar (lower first;
    /// ties go by creation).
    public var position: Int
    /// Shown with the pinned tabs, above "New Tab".
    public var isPinned: Bool

    public init(id: UUID = UUID(), spaceID: UUID, title: String, createdAt: Date = Date(), position: Int = 0, isPinned: Bool = false) {
        self.id = id
        self.spaceID = spaceID
        self.title = title
        self.createdAt = createdAt
        self.position = position
        self.isPinned = isPinned
    }
}

public enum EaselItemKind: String, Sendable {
    /// A clipped or pasted picture; `imageHash` names its file.
    case image
    /// A card for a web page.
    case link
    /// A short label.
    case text
    /// Outlines drawn with the shape tools; they fill their frame.
    case ellipse
    case rectangle
    /// From `points[0]` to `points[1]`.
    case arrow
    /// A freehand stroke through `points`.
    case drawing

    /// Kinds whose shape comes from `points`.
    public var usesPoints: Bool { self == .arrow || self == .drawing }
}

/// A point inside an item's frame, from 0 to 1 on each axis, so a drawing
/// scales with its item.
public struct EaselPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// `"x,y x,y …"`, to 4 decimal places (plenty for a canvas).
    public static func encode(_ points: [EaselPoint]) -> String {
        points.map { "\(format($0.x)),\(format($0.y))" }.joined(separator: " ")
    }

    /// The points in `string`; malformed pairs are skipped.
    public static func decode(_ string: String) -> [EaselPoint] {
        string.split(separator: " ").compactMap { pair in
            let parts = pair.split(separator: ",")
            guard parts.count == 2, let x = Double(String(parts[0])), let y = Double(String(parts[1])) else { return nil }
            return EaselPoint(x: x, y: y)
        }
    }

    /// Rounded the way `encode` stores it, so saved and in-memory items match.
    public var rounded: EaselPoint {
        EaselPoint(x: (x * 10_000).rounded() / 10_000, y: (y * 10_000).rounded() / 10_000)
    }

    private static func format(_ value: Double) -> String {
        let rounded = (value * 10_000).rounded() / 10_000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
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
    /// The arrow's ends or the drawing's stroke, within the frame.
    public var points: [EaselPoint]
    /// A label's text size in points; nil makes the text fill its box.
    public var fontSize: Double?
    /// The colour of a label's text or a shape's line, as `#RRGGBB`; nil
    /// uses the usual text colour for light or dark mode.
    public var color: String?

    public init(
        id: UUID = UUID(), easelID: UUID, kind: EaselItemKind,
        x: Double, y: Double, width: Double, height: Double, z: Int = 0,
        text: String = "", url: URL? = nil, imageHash: String? = nil, points: [EaselPoint] = [],
        fontSize: Double? = nil, color: String? = nil
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
        self.points = points.map(\.rounded)
        self.fontSize = fontSize?.rounded()
        self.color = color
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
            var fields: SyncFields = [
                "space": easel.spaceID.uuidString,
                "title": easel.title,
                "created": String(Int(easel.createdAt.timeIntervalSince1970)),
                "position": String(easel.position),
            ]
            if easel.isPinned { fields["pinned"] = "1" }
            result[easelPrefix + easel.id.uuidString] = fields
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
            if !item.points.isEmpty { fields["points"] = EaselPoint.encode(item.points) }
            if let size = item.fontSize { fields["fontSize"] = format(size) }
            if let color = item.color { fields["color"] = color }
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
            easels.append(Easel(
                id: id, spaceID: space, title: values["title"] ?? "Easel", createdAt: created,
                position: values["position"].flatMap(Int.init) ?? 0,
                isPinned: values["pinned"] == "1"
            ))
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
                imageHash: values["image"],
                points: values["points"].map(EaselPoint.decode) ?? [],
                fontSize: values["fontSize"].flatMap(Double.init),
                color: values["color"]
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

import Foundation

/// What is saved about a tab so it can be restored after relaunch.
public struct TabRecord: Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The Space the tab belongs to; nil for favorites, which every Space shares.
    public var spaceID: UUID?
    /// Pinned tabs stay above the divider and are never auto-archived.
    public var isPinned: Bool
    /// Where a pinned tab or favorite goes back to when it is reset.
    public var pinnedURL: URL?
    public var url: URL?
    public var title: String
    /// When the tab was last selected. Auto-archiving uses this.
    public var lastActiveAt: Date
    /// WebKit's opaque session state (back/forward history and page
    /// position), from `WKWebView.interactionState`.
    public var sessionState: Data?

    public init(
        id: UUID = UUID(),
        spaceID: UUID? = nil,
        isPinned: Bool = false,
        pinnedURL: URL? = nil,
        url: URL?,
        title: String,
        lastActiveAt: Date = Date(),
        sessionState: Data? = nil
    ) {
        self.id = id
        self.spaceID = spaceID
        self.isPinned = isPinned
        self.pinnedURL = pinnedURL
        self.url = url
        self.title = title
        self.lastActiveAt = lastActiveAt
        self.sessionState = sessionState
    }

    public var isFavorite: Bool { spaceID == nil }
}

/// A Space: its own tabs, theme and, optionally, its own logins.
public struct SpaceRecord: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// An emoji shown in the Space switcher.
    public var icon: String
    public var themeID: String
    /// A separate website data store (cookies, logins, storage) when set;
    /// nil shares the default one.
    public var profileID: UUID?
    /// The tab last selected in this Space (may be a favorite).
    public var selectedTabID: UUID?
    /// When this Space's ordinary tabs are archived.
    public var archiveInterval: ArchiveInterval

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        themeID: String,
        profileID: UUID? = nil,
        selectedTabID: UUID? = nil,
        archiveInterval: ArchiveInterval = .default
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.themeID = themeID
        self.profileID = profileID
        self.selectedTabID = selectedTabID
        self.archiveInterval = archiveInterval
    }

    public static func makeDefault() -> SpaceRecord {
        SpaceRecord(name: "Personal", icon: "🪁", themeID: SpaceTheme.default.id)
    }
}

/// Everything needed to rebuild a window: Spaces in switcher order, then
/// favorites and every Space's tabs, each group in sidebar order.
public struct BrowserSnapshot: Equatable, Sendable {
    public var spaces: [SpaceRecord]
    public var tabs: [TabRecord]
    public var selectedSpaceID: UUID?
    /// Split View groups in each Space, keyed by Space ID.
    public var splits: [UUID: [SplitGroup]]

    public init(spaces: [SpaceRecord] = [], tabs: [TabRecord] = [], selectedSpaceID: UUID? = nil, splits: [UUID: [SplitGroup]] = [:]) {
        self.spaces = spaces
        self.tabs = tabs
        self.selectedSpaceID = selectedSpaceID
        self.splits = splits
    }
}

extension Array {
    /// Moves one element the way a list drop describes it: `insertionIndex`
    /// is the gap it was dropped into, counted before the element is removed
    /// (0 is above the first row, `count` is below the last).
    public mutating func move(from source: Int, toInsertionIndex insertionIndex: Int) {
        guard indices.contains(source), (0...count).contains(insertionIndex) else { return }
        let destination = insertionIndex > source ? insertionIndex - 1 : insertionIndex
        guard destination != source else { return }
        insert(remove(at: source), at: destination)
    }
}

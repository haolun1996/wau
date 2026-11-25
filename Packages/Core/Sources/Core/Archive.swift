import Foundation

/// How long an ordinary tab may go unseen before it's archived.
public enum ArchiveInterval: String, CaseIterable, Identifiable, Sendable {
    case twelveHours = "12h"
    case day = "1d"
    case week = "7d"
    case month = "30d"
    case never

    public static let `default` = ArchiveInterval.twelveHours

    public var id: String { rawValue }

    public var seconds: TimeInterval? {
        switch self {
        case .twelveHours: 12 * 3600
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        case .month: 30 * 24 * 3600
        case .never: nil
        }
    }

    public var displayName: String {
        switch self {
        case .twelveHours: "12 hours"
        case .day: "1 day"
        case .week: "1 week"
        case .month: "30 days"
        case .never: "Never"
        }
    }
}

/// Decides which tabs to archive.
public enum ArchivePolicy {
    public struct Candidate: Sendable {
        public let id: UUID
        public let lastActiveAt: Date
        /// On screen right now (selected or in a visible split); never archived.
        public let isVisible: Bool

        public init(id: UUID, lastActiveAt: Date, isVisible: Bool) {
            self.id = id
            self.lastActiveAt = lastActiveAt
            self.isVisible = isVisible
        }
    }

    /// Tabs unseen for longer than `interval`. Only ordinary tabs should be
    /// passed in: pinned tabs and favorites are never archived.
    public static func tabsToArchive(_ candidates: [Candidate], interval: ArchiveInterval, now: Date = Date()) -> [UUID] {
        guard let limit = interval.seconds else { return [] }
        return candidates
            .filter { !$0.isVisible && now.timeIntervalSince($0.lastActiveAt) > limit }
            .map(\.id)
    }
}

/// A tab that was archived; it can be brought back with its history.
public struct ArchivedTab: Identifiable, Equatable, Sendable {
    public var record: TabRecord
    public var archivedAt: Date

    public var id: UUID { record.id }

    public init(record: TabRecord, archivedAt: Date) {
        self.record = record
        self.archivedAt = archivedAt
    }
}

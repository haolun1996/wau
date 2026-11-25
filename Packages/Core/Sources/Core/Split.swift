import Foundation

public enum SplitAxis: String, Sendable {
    /// Panes side by side.
    case horizontal
    /// Panes stacked top to bottom.
    case vertical

    public var toggled: SplitAxis { self == .horizontal ? .vertical : .horizontal }
}

/// Two to four tabs of one Space shown together. `fractions` are each
/// pane's share of the space along `axis`, summing to 1.
public struct SplitGroup: Identifiable, Equatable, Sendable {
    public static let maxPanes = 4
    /// No pane may shrink below this share.
    static let minFraction = 0.1

    public var id: UUID
    public private(set) var tabIDs: [UUID]
    public var axis: SplitAxis
    public private(set) var fractions: [Double]

    public init(id: UUID = UUID(), tabIDs: [UUID], axis: SplitAxis = .horizontal, fractions: [Double]? = nil) {
        self.id = id
        self.tabIDs = Array(tabIDs.prefix(Self.maxPanes))
        self.axis = axis
        self.fractions = Self.equal(self.tabIDs.count)
        if let fractions { setFractions(fractions) }
    }

    /// A group needs at least two tabs to be shown as a split.
    public var isValid: Bool { tabIDs.count >= 2 }
    public var isFull: Bool { tabIDs.count >= Self.maxPanes }

    public func contains(_ tab: UUID) -> Bool { tabIDs.contains(tab) }

    /// Adds `tab` right after `neighbour` (or at the end), splitting the
    /// space equally again. Returns false if full or already present.
    @discardableResult
    public mutating func insert(_ tab: UUID, after neighbour: UUID? = nil) -> Bool {
        guard !isFull, !contains(tab) else { return false }
        let index = neighbour.flatMap { tabIDs.firstIndex(of: $0) }.map { $0 + 1 } ?? tabIDs.count
        tabIDs.insert(tab, at: index)
        fractions = Self.equal(tabIDs.count)
        return true
    }

    /// Removes `tab`; its share goes to the remaining panes in proportion.
    public mutating func remove(_ tab: UUID) {
        guard let index = tabIDs.firstIndex(of: tab) else { return }
        tabIDs.remove(at: index)
        var remaining = fractions
        remaining.remove(at: index)
        fractions = tabIDs.isEmpty ? [] : Self.normalized(remaining)
    }

    /// Keeps only tabs that still exist, in order.
    public mutating func retain(_ existing: Set<UUID>) {
        for tab in tabIDs where !existing.contains(tab) { remove(tab) }
    }

    /// Sets pane sizes (from dragging a divider): normalized to sum to 1,
    /// with no pane below the minimum. Ignored if the count doesn't match.
    public mutating func setFractions(_ newValue: [Double]) {
        guard newValue.count == tabIDs.count, !newValue.isEmpty else { return }
        let clamped = Self.normalized(newValue.map { max($0, 0) }).map { max($0, Self.minFraction) }
        fractions = Self.normalized(clamped)
    }

    static func equal(_ count: Int) -> [Double] {
        count == 0 ? [] : Array(repeating: 1 / Double(count), count: count)
    }

    static func normalized(_ values: [Double]) -> [Double] {
        let total = values.reduce(0, +)
        return total > 0 ? values.map { $0 / total } : equal(values.count)
    }
}

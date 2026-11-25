import Foundation
import Testing
@testable import Core

@Suite("ArchivePolicy")
struct ArchivePolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func candidate(hoursAgo: Double, visible: Bool = false) -> ArchivePolicy.Candidate {
        ArchivePolicy.Candidate(id: UUID(), lastActiveAt: now.addingTimeInterval(-hoursAgo * 3600), isVisible: visible)
    }

    @Test func onlyTabsUnseenPastTheIntervalGo() {
        let fresh = candidate(hoursAgo: 11.9)
        let stale = candidate(hoursAgo: 12.1)
        let staleButVisible = candidate(hoursAgo: 100, visible: true)
        let result = ArchivePolicy.tabsToArchive([fresh, stale, staleButVisible], interval: .twelveHours, now: now)
        #expect(result == [stale.id])
    }

    @Test func longerIntervalsAndNever() {
        let twoDays = candidate(hoursAgo: 48)
        #expect(ArchivePolicy.tabsToArchive([twoDays], interval: .day, now: now) == [twoDays.id])
        #expect(ArchivePolicy.tabsToArchive([twoDays], interval: .week, now: now).isEmpty)
        #expect(ArchivePolicy.tabsToArchive([candidate(hoursAgo: 10_000)], interval: .never, now: now).isEmpty)
    }

    @Test func intervalsSyncAsStableStrings() {
        #expect(ArchiveInterval.allCases.map(\.rawValue) == ["12h", "1d", "7d", "30d", "never"])
        #expect(ArchiveInterval.default == .twelveHours)
    }

    @Test func archiveSettingSyncsWithTheSpace() {
        let space = SpaceRecord(name: "Work", icon: "💼", themeID: "melaka", archiveInterval: .week)
        let snapshot = BrowserSnapshot(spaces: [space], tabs: [], selectedSpaceID: space.id)
        var fields = SyncMapping.fields(from: snapshot)
        #expect(fields["space:\(space.id.uuidString)"]?["archiveAfter"] == "7d")
        fields["space:\(space.id.uuidString)"]?["archiveAfter"] = "never"
        #expect(SyncMapping.apply(fields, to: snapshot).spaces.first?.archiveInterval == .never)
    }
}

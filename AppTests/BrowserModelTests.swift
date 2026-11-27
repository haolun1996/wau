import AppKit
import WebKit
import Core
import Foundation
import Storage
import Testing
@testable import Wau

/// The model never loads pages in these tests: tabs are opened with no URL.
@MainActor
@Suite("BrowserModel")
struct BrowserModelTests {
    private func titles(_ tabs: [Tab]) -> [String] { tabs.map(\.title) }

    /// A model with one Space holding regular tabs titled by `names`
    /// (restored, so they have titles without loading).
    private func model(regular names: [String], pinned: [String] = [], favorites: [String] = []) -> BrowserModel {
        let space = SpaceRecord.makeDefault()
        func record(_ name: String, spaceID: UUID?, pinned: Bool) -> TabRecord {
            TabRecord(spaceID: spaceID, isPinned: pinned, pinnedURL: URL(string: "https://\(name).example"),
                      url: URL(string: "https://\(name).example"), title: name)
        }
        let tabs = favorites.map { record($0, spaceID: nil, pinned: false) }
            + pinned.map { record($0, spaceID: space.id, pinned: true) }
            + names.map { record($0, spaceID: space.id, pinned: false) }
        let model = BrowserModel()
        model.restore(BrowserSnapshot(spaces: [space], tabs: tabs, selectedSpaceID: space.id))
        return model
    }

    @Test func newTabsGoOnTopAndBecomeSelected() {
        let model = model(regular: ["a", "b"])
        let tab = model.open(url: nil)
        #expect(model.currentSpace.tabs.first === tab)
        #expect(model.selected === tab)
    }

    @Test func linkTabsOpenRightAfterTheirOpener() {
        let model = model(regular: ["a", "b", "c"])
        let opener = model.currentSpace.tabs[0]
        let child = model.open(url: nil, opener: opener, select: false)
        #expect(model.currentSpace.tabs[1] === child)
        #expect(model.selected?.title == "a") // background tab doesn't steal selection
    }

    @Test func closingARegularTabSelectsItsNeighbourAndCanBeReopened() throws {
        let model = model(regular: ["a", "b", "c"])
        let b = model.currentSpace.tabs[1]
        model.select(b)
        model.close(b)
        #expect(titles(model.currentSpace.tabs) == ["a", "c"])
        #expect(model.selected?.title == "c")

        let reopened = try #require(model.reopenClosedTab())
        #expect(reopened.id == b.id)
        #expect(reopened.title == "b")
        #expect(model.selected === reopened)
    }

    @Test func closingAPinnedTabResetsItInPlace() {
        let model = model(regular: ["r"], pinned: ["p"])
        let pinned = model.currentSpace.pinned[0]
        model.select(pinned)
        model.close(pinned)
        #expect(model.currentSpace.pinned.count == 1)
        let reset = model.currentSpace.pinned[0]
        #expect(reset !== pinned) // a fresh, unloaded tab…
        #expect(reset.id == pinned.id) // …standing in for the same pinned tab
        #expect(reset.url == URL(string: "https://p.example"))
        #expect(model.selected?.title == "r")
        #expect(model.recentlyClosed.isEmpty)
    }

    @Test func draggingAcrossTheDividerPinsAndUnpins() {
        let model = model(regular: ["a", "b"], pinned: ["p"])
        let b = model.currentSpace.tabs[1]
        model.moveTab(b, to: .pinned, gap: 0)
        #expect(titles(model.currentSpace.pinned) == ["b", "p"])
        #expect(titles(model.currentSpace.tabs) == ["a"])
        #expect(b.pinnedURL == b.url)

        model.moveTab(b, to: .regular, gap: 1)
        #expect(titles(model.currentSpace.pinned) == ["p"])
        #expect(titles(model.currentSpace.tabs) == ["a", "b"])
        #expect(b.pinnedURL == nil)
    }

    @Test func favoritesAreSharedAcrossSpaces() {
        let model = model(regular: ["a"])
        let a = model.currentSpace.tabs[0]
        model.setFavorite(a, true)
        #expect(model.favorites.first === a)
        #expect(model.currentSpace.tabs.isEmpty)

        let other = model.createSpace(name: "Work", icon: "💼", themeID: "melaka", separateProfile: false)
        #expect(model.currentSpace === other)
        model.select(a) // a favorite selected from another Space stays in that Space
        #expect(model.currentSpace === other)
        #expect(model.selected === a)
    }

    @Test func movingBetweenSpacesWithTheSameProfileKeepsTheTab() {
        let model = model(regular: ["a"])
        let home = model.currentSpace
        let a = home.tabs[0]
        let work = model.createSpace(name: "Work", icon: "💼", themeID: "melaka", separateProfile: false)
        model.moveTab(a, toSpace: work)
        #expect(work.tabs.first === a)
        #expect(home.tabs.isEmpty)
    }

    @Test func movingIntoASeparateProfileRebuildsTheTab() {
        let model = model(regular: ["a"])
        let a = model.currentSpace.tabs[0]
        let work = model.createSpace(name: "Work", icon: "💼", themeID: "melaka", separateProfile: true)
        model.moveTab(a, toSpace: work)
        let moved = work.tabs.first
        #expect(moved !== a)
        #expect(moved?.id == a.id)
        #expect(moved?.webView.configuration.websiteDataStore !== a.webView.configuration.websiteDataStore)
    }

    @Test func deletingSpacesKeepsAtLeastOneAndReportsTheProfileToErase() throws {
        let model = model(regular: ["a"])
        let home = model.currentSpace
        #expect(model.deleteSpace(home) == nil) // the last Space can't go
        #expect(model.spaces.count == 1)

        let work = model.createSpace(name: "Work", icon: "💼", themeID: "melaka", separateProfile: true)
        let profile = try #require(work.profileID)
        #expect(model.deleteSpace(work) == profile)
        #expect(model.spaces.map(\.id) == [home.id])
        #expect(model.currentSpace === home)
    }

    @Test func switchingWrapsAround() {
        let model = model(regular: ["a"])
        let first = model.currentSpace
        let second = model.createSpace(name: "Two", icon: "🌙", themeID: "bulan", separateProfile: false)
        #expect(model.currentSpace === second)
        model.switchSpace(by: 1)
        #expect(model.currentSpace === first)
        model.switchSpace(by: -1)
        #expect(model.currentSpace === second)
    }

    @Test func snapshotRoundTripsStructure() {
        let model = model(regular: ["a", "b"], pinned: ["p"], favorites: ["f"])
        let work = model.createSpace(name: "Work", icon: "💼", themeID: "melaka", separateProfile: true)
        model.open(url: nil)
        let snapshot = model.snapshot

        let restored = BrowserModel()
        restored.restore(snapshot)
        #expect(restored.spaces.map(\.name) == ["Personal", "Work"])
        #expect(restored.currentSpaceID == work.id)
        #expect(restored.spaces[1].profileID == work.profileID)
        #expect(titles(restored.favorites) == ["f"])
        #expect(titles(restored.spaces[0].pinned) == ["p"])
        #expect(titles(restored.spaces[0].tabs) == ["a", "b"])
        #expect(restored.spaces[1].tabs.count == 1)
        #expect(restored.snapshot.tabs.map(\.id) == snapshot.tabs.map(\.id))
    }
}

@MainActor
@Suite("Incognito")
struct IncognitoTests {
    @Test func privateDataLastsWhileAnyWindowUsesIt() {
        let profile = Profiles.makePrivate()
        let store = Profiles.dataStore(for: profile)
        Profiles.retainPrivate(profile) // a tab dragged out to a second window
        Profiles.releasePrivate(profile) // the first window closes
        #expect(Profiles.dataStore(for: profile) === store)
        Profiles.releasePrivate(profile) // the last one closes
        // Asked for again, it's still never on disk.
        #expect(Profiles.dataStore(for: profile) !== store)
        #expect(!Profiles.dataStore(for: profile).isPersistent)
    }

    @Test func privateProfilesStayInMemory() {
        let profile = Profiles.makePrivate()
        #expect(!Profiles.dataStore(for: profile).isPersistent)
        #expect(Profiles.dataStore(for: nil).isPersistent)
        // An incognito Space's tabs all share that store.
        let model = BrowserModel()
        let space = SpaceRecord(name: "Incognito", icon: "🕶️", themeID: SpaceTheme.incognito.id, profileID: profile)
        model.restore(BrowserSnapshot(spaces: [space], selectedSpaceID: space.id))
        #expect(model.allTabs.isEmpty)
        let tab = model.open(url: nil)
        #expect(!tab.webView.configuration.websiteDataStore.isPersistent)
        Profiles.releasePrivate(profile)
        tab.tearDown()
    }
}

@MainActor
@Suite("BrowserModel.reconcile")
struct ReconcileTests {
    @Test func keepsOpenTabsAndAppliesSyncedChanges() throws {
        let model = BrowserModel()
        let pinned = model.open(url: nil)
        model.setPinned(pinned, true)
        let regular = model.open(url: nil)
        var snapshot = model.snapshot

        // A synced change: the Space is renamed and a new favorite arrives.
        snapshot.spaces[0].name = "Kerja"
        let favorite = TabRecord(url: URL(string: "https://kopi.example"), title: "kopi.example")
        snapshot.tabs.insert(favorite, at: 0)

        let removed = model.reconcile(with: snapshot)
        #expect(removed.isEmpty)
        #expect(model.currentSpace.name == "Kerja")
        #expect(model.currentSpace.pinned.first === pinned) // same live tab objects
        #expect(model.currentSpace.tabs.first === regular)
        #expect(model.favorites.first?.id == favorite.id)
    }

    @Test func removedSpacesReportTheirProfiles() throws {
        let model = BrowserModel()
        let home = model.currentSpace
        let work = model.createSpace(name: "Work", icon: "💼", themeID: "melaka", separateProfile: true)
        let doomed = model.open(url: nil)
        var snapshot = model.snapshot
        snapshot.spaces.removeAll { $0.id == work.id }
        snapshot.tabs.removeAll { $0.spaceID == work.id }

        let removed = model.reconcile(with: snapshot)
        #expect(removed == [try #require(work.profileID)])
        #expect(model.spaces.map(\.id) == [home.id])
        #expect(model.currentSpace === home)
        #expect(!model.allTabs.contains { $0 === doomed })
    }
}

@MainActor
@Suite("BrowserModel archiving")
struct ArchivingTests {
    @Test func staleOrdinaryTabsAreArchivedButNotSelectedOrPinnedOnes() throws {
        let model = BrowserModel()
        let old = Date().addingTimeInterval(-13 * 3600)
        let stale = model.open(url: nil, select: false)
        let pinned = model.open(url: nil, select: false)
        model.setPinned(pinned, true)
        let selected = model.open(url: nil)
        for tab in [stale, pinned, selected] { tab.lastActiveAt = old }

        let archived = model.archiveStaleTabs()
        #expect(archived.map(\.id) == [stale.id])
        #expect(archived.first?.spaceID == model.currentSpace.id)
        #expect(!model.allTabs.contains { $0 === stale })
        #expect(model.currentSpace.pinned.first === pinned)
        #expect(model.selected === selected)
    }

    @Test func neverArchiveAndRestore() throws {
        let model = BrowserModel()
        let space = model.currentSpace
        model.updateSpace(space, name: space.name, icon: space.icon, themeID: space.themeID, archiveInterval: .never)
        let tab = model.open(url: nil)
        model.open(url: nil) // selected tabs are never archived, so select another
        tab.lastActiveAt = .distantPast
        #expect(model.archiveStaleTabs().isEmpty)

        model.updateSpace(space, name: space.name, icon: space.icon, themeID: space.themeID, archiveInterval: .day)
        let record = try #require(model.archiveStaleTabs().first)
        let restored = model.restoreArchived(record)
        #expect(restored.id == tab.id)
        #expect(model.selected === restored)
    }
}

@MainActor
@Suite("BrowserModel split view")
struct SplitViewTests {
    @Test func splittingShowsPanesAndFocusesTheNewOne() {
        let model = BrowserModel()
        let a = model.open(url: nil)
        let b = model.open(url: nil, select: false)
        model.select(a)
        #expect(model.visibleTabs.map(\.id) == [a.id])

        #expect(model.addToSplit(b))
        #expect(model.visibleTabs.map(\.id) == [a.id, b.id])
        #expect(model.selected === b)
        model.select(a) // focusing another pane keeps the split on screen
        #expect(model.visibleTabs.count == 2)
    }

    @Test func atMostFourPanesAndClosingCleansUp() {
        let model = BrowserModel()
        let base = model.open(url: nil)
        let others = (0..<4).map { _ in model.open(url: nil, select: false) }
        model.select(base)
        for tab in others.prefix(3) {
            model.select(base)
            model.addToSplit(tab)
        }
        #expect(model.visibleTabs.count == 4)
        model.select(base)
        #expect(!model.canSplit(others[3]))

        for tab in others.prefix(3) { model.close(tab) }
        #expect(model.visibleSplit == nil) // a lone tab is no longer a split
        #expect(model.currentSpace.splits.isEmpty)
    }

    @Test func archivingSparesVisiblePanes() {
        let model = BrowserModel()
        let a = model.open(url: nil)
        let b = model.open(url: nil, select: false)
        model.select(a)
        model.addToSplit(b)
        model.select(a)
        b.lastActiveAt = .distantPast
        #expect(model.archiveStaleTabs().isEmpty)
    }

    @Test func aTabDraggedOutMovesToAnotherWindowStillOpen() {
        let source = BrowserModel()
        let a = source.open(url: nil)
        let b = source.open(url: nil, select: false)
        source.select(a)
        source.placeInSplit(b, beside: a, after: true)
        #expect(source.selected === b)
        // b leaves: its split goes, and a takes over.
        #expect(source.detach(b))
        #expect(source.currentSpace.splits.isEmpty)
        #expect(source.selected === a)
        #expect(source.recentlyClosed.isEmpty) // moved, not closed
        let target = BrowserModel()
        target.adopt(b)
        #expect(target.selected === b) // the same live tab, not a copy
        #expect(!source.detach(b))
    }

    @Test func droppingATabOnThePageSplitsOnThatSide() {
        let model = BrowserModel()
        let a = model.open(url: nil)
        let b = model.open(url: nil, select: false)
        let c = model.open(url: nil, select: false)
        model.select(a)
        #expect(!model.canPlace(a, beside: a)) // a lone page can't split with itself
        #expect(model.placeInSplit(b, beside: a, after: false))
        #expect(model.visibleTabs.map(\.id) == [b.id, a.id])
        #expect(model.selected === b)

        #expect(model.placeInSplit(c, beside: a, after: true))
        #expect(model.visibleTabs.map(\.id) == [b.id, a.id, c.id])
        // Dragging a pane to the other end moves it.
        #expect(model.placeInSplit(c, beside: b, after: false))
        #expect(model.visibleTabs.map(\.id) == [c.id, b.id, a.id])
        #expect(model.currentSpace.splits.count == 1)
    }

    @Test func droppingATabOnAnotherInTheSidebarSplitsThem() {
        let model = BrowserModel()
        let a = model.open(url: nil)
        let b = model.open(url: nil, select: false)
        let c = model.open(url: nil, select: false)
        model.select(a)
        // Neither b nor c is on screen; dropping b on c still splits them.
        #expect(!model.canPlace(b, beside: c))
        #expect(model.canJoin(b, beside: c))
        #expect(model.placeInSplit(b, beside: c, after: false))
        #expect(model.visibleTabs.map(\.id) == [b.id, c.id])
        #expect(model.selected === b)
        #expect(!model.canJoin(c, beside: c))
    }

    @Test func easelsJoinSplitsWithTabs() {
        let model = BrowserModel()
        let easel = UUID(), other = UUID()
        var easels: Set<UUID> = [easel, other]
        model.easelIDs = { _ in easels }
        let a = model.open(url: nil)
        let b = model.open(url: nil, select: false)
        model.select(a)

        // Two Easels alone don't make a split; an Easel with a tab does.
        #expect(!model.canJoin(other, beside: easel))
        #expect(model.placeInSplit(easel, beside: a.id, after: true))
        #expect(model.visiblePanes.map(\.id) == [a.id, easel])
        #expect(model.visibleTabs.map(\.id) == [a.id])
        #expect(model.focusedPaneID == easel) // the dropped Easel has the focus
        #expect(model.selected === a)

        // Clicking the tab pane focuses it; the split stays on screen.
        model.select(a)
        #expect(model.focusedPaneID == a.id)
        #expect(model.visiblePanes.count == 2)
        #expect(model.focusEasel(easel))
        #expect(model.focusedPaneID == easel)

        // Picking another tab leaves the split and the Easel's focus.
        model.select(b)
        #expect(model.focusedPaneID == b.id)
        #expect(!model.focusEasel(other)) // not in a split
        #expect(model.focusEasel(easel)) // brings the split back
        #expect(model.selected === a)

        // A deleted Easel leaves its split, which needs two panes.
        easels.remove(easel)
        model.easelsChanged()
        #expect(model.currentSpace.splits.isEmpty)
        #expect(model.focusedPaneID == a.id)
    }

    @Test func aSplitKeepsATabWhenItsTabsClose() {
        let model = BrowserModel()
        let e1 = UUID(), e2 = UUID()
        model.easelIDs = { _ in [e1, e2] }
        let a = model.open(url: nil)
        _ = model.open(url: nil, select: false)
        model.select(a)
        model.placeInSplit(e1, beside: a.id, after: true)
        model.placeInSplit(e2, beside: e1, after: true)
        #expect(model.visiblePanes.count == 3)
        model.close(a) // only Easels would be left
        #expect(model.currentSpace.splits.isEmpty)
    }

    @Test func droppingIntoAFullSplitIsRefused() {
        let model = BrowserModel()
        let base = model.open(url: nil)
        let others = (0..<4).map { _ in model.open(url: nil, select: false) }
        model.select(base)
        for tab in others.prefix(3) { model.placeInSplit(tab, beside: base, after: true) }
        #expect(model.visibleTabs.count == 4)
        #expect(!model.canPlace(others[3], beside: base))
        #expect(model.canPlace(others[0], beside: base)) // rearranging still works
    }

    @Test func favoritesAndOtherSpacesCantSplit() {
        let model = BrowserModel()
        let a = model.open(url: nil)
        let favorite = model.open(url: nil, select: false)
        model.setFavorite(favorite, true)
        model.select(a)
        #expect(!model.canSplit(favorite))
        let other = model.createSpace(name: "Two", icon: "🌙", themeID: "bulan", separateProfile: false)
        let elsewhere = model.open(url: nil)
        model.select(a)
        #expect(model.space(containing: elsewhere) === other)
        #expect(!model.canSplit(elsewhere))
    }
}

@MainActor
@Suite("EaselStore")
struct EaselStoreTests {
    func makeStore() throws -> (EaselStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (EaselStore(database: try AppDatabase.inMemory(), images: ImageStore(directory: directory)), directory)
    }

    @Test func easelsKeepTheOrderTheyAreDraggedInto() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let space = UUID()
        let a = store.createEasel(in: space, title: "A")
        let b = store.createEasel(in: space, title: "B")
        let c = store.createEasel(in: space, title: "C")
        let other = store.createEasel(in: UUID(), title: "Elsewhere")
        func titles() -> [String] { store.easels(in: space).map(\.title) }
        #expect(titles() == ["A", "B", "C"])

        store.move(c.id, toGap: 0)
        #expect(titles() == ["C", "A", "B"])
        store.move(c.id, toGap: 3) // the gap after B
        #expect(titles() == ["A", "B", "C"])
        store.move(a.id, toGap: 2) // between B and C
        #expect(titles() == ["B", "A", "C"])
        store.move(b.id, toGap: 1) // its own place: nothing changes
        #expect(titles() == ["B", "A", "C"])
        #expect(store.easels(in: other.spaceID).map(\.title) == ["Elsewhere"])
        _ = (a, b)
    }

    @Test func pinnedEaselsKeepTheirOwnOrder() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let space = UUID()
        let a = store.createEasel(in: space, title: "A")
        let b = store.createEasel(in: space, title: "B")
        let c = store.createEasel(in: space, title: "C")
        func pinned() -> [String] { store.easels(in: space).filter(\.isPinned).map(\.title) }
        func others() -> [String] { store.easels(in: space).filter { !$0.isPinned }.map(\.title) }

        store.setPinned(c.id, true)
        store.setPinned(a.id, true) // goes after C
        #expect(pinned() == ["C", "A"])
        #expect(others() == ["B"])
        // Dragged above "New Tab", to the top of the pinned ones.
        store.move(b.id, pinned: true, toGap: 0)
        #expect(pinned() == ["B", "C", "A"])
        #expect(others().isEmpty)
        // Unpinning goes to the top of the others.
        store.setPinned(c.id, false)
        #expect(pinned() == ["B", "A"])
        #expect(others() == ["C"])
    }

    @Test func itemsStackInFrontAndImagesAreScaled() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let easel = store.createEasel(in: UUID(), title: "Ideas")

        let image = NSImage(size: NSSize(width: 1040, height: 520), flipped: false) { rect in
            NSColor.systemRed.setFill(); rect.fill(); return true
        }
        let png = try #require(image.pngData)
        let clip = try #require(store.addImage(png, to: easel.id, caption: "Red", source: URL(string: "https://example.com")))
        #expect(clip.width == 520) // scaled to fit
        #expect(clip.height == 260) // keeps its shape
        #expect(store.image(for: try #require(clip.imageHash)) != nil)

        let label = store.addText("Note", to: easel.id)
        #expect(label.z > clip.z)
        #expect(label.y > clip.y) // placed below, not on top
        store.bringToFront(clip.id)
        #expect(store.items(in: easel.id).last?.id == clip.id)

        store.delete(easel.id)
        #expect(store.snapshot == EaselSnapshot())
    }

    @Test func syncReplacesEverythingAndNotifies() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var changes = 0
        store.onChange = { changes += 1 }
        let incoming = EaselSnapshot(easels: [Easel(spaceID: UUID(), title: "From the other Mac")])
        store.replaceAll(with: incoming)
        store.replaceAll(with: incoming) // unchanged: no notification
        #expect(store.snapshot == incoming)
        #expect(changes == 1)
    }
}

@MainActor
@Suite("Downloads")
struct DownloadTests {
    @Test func destinationsAreUniqueAndStayInTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = DownloadManager.uniqueDestination(for: "report.pdf", in: folder)
        #expect(first.lastPathComponent == "report.pdf")
        try Data().write(to: first)
        #expect(DownloadManager.uniqueDestination(for: "report.pdf", in: folder).lastPathComponent == "report 2.pdf")

        let sneaky = DownloadManager.uniqueDestination(for: "../../etc/passwd", in: folder)
        #expect(sneaky.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(DownloadManager.uniqueDestination(for: "...", in: folder).lastPathComponent == "Download")
    }
}

@MainActor
@Suite("Dropping a tab on the page")
struct WebContentDropTests {
    func makeView(panes: Int, axis: SplitAxis = .horizontal) -> WebContentView {
        let view = WebContentView()
        view.frame = NSRect(x: 0, y: 0, width: 808, height: 600)
        view.display((0..<panes).map { _ in WKWebView() }, axis: axis)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func aSinglePageSplitsLeftOrRight() throws {
        let view = makeView(panes: 1)
        let left = try #require(view.dropTarget(at: NSPoint(x: 100, y: 300)))
        #expect(left.pane == 0 && !left.after)
        #expect(left.zone.maxX <= 404 && left.zone.minX < 20)
        let right = try #require(view.dropTarget(at: NSPoint(x: 700, y: 300)))
        #expect(right.after)
        #expect(right.zone.minX >= 404 && right.zone.maxX > 780)
    }

    @Test func aSplitTargetsTheHalfOfThePaneUnderThePointer() throws {
        let view = makeView(panes: 2) // two 400pt panes with an 8pt gap
        let target = try #require(view.dropTarget(at: NSPoint(x: 750, y: 300)))
        #expect(target.pane == 1 && target.after)
        let gap = try #require(view.dropTarget(at: NSPoint(x: 404, y: 300)))
        #expect(gap.pane == 0 || gap.pane == 1) // the gap goes to a neighbour

        let stacked = makeView(panes: 2, axis: .vertical)
        let top = try #require(stacked.dropTarget(at: NSPoint(x: 400, y: 580)))
        #expect(top.pane == 0 && !top.after)
        #expect(top.zone.minY >= 450)
    }

    @Test func aNewSplitSharesThePageEvenly() throws {
        // Going from one page to two used to squash the first pane to nothing.
        let view = makeView(panes: 1)
        let pages = [WKWebView(), WKWebView()]
        view.display(pages, fractions: [0.5, 0.5])
        view.layoutSubtreeIfNeeded()
        for (page, minX) in zip(pages, [0.0, 408.0]) {
            let frame = view.convert(page.bounds, from: page)
            #expect(frame.minX == minX && frame.width == 400)
        }
    }

    @Test func noPagesNoDrop() {
        #expect(makeView(panes: 0).dropTarget(at: NSPoint(x: 10, y: 10)) == nil)
    }
}

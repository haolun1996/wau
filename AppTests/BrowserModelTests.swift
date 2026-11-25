import AppKit
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

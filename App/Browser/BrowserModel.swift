import AppKit
import Core
import WebKit

/// A Space as the app works with it: its record plus live tabs.
@MainActor
final class Space {
    let id: UUID
    var name: String
    var icon: String
    var themeID: String
    /// Fixed at creation: moving a Space's logins elsewhere isn't possible.
    let profileID: UUID?
    var archiveInterval: ArchiveInterval
    var pinned: [Tab] = []
    var tabs: [Tab] = []
    var selectedTabID: UUID?
    /// Split View groups among this Space's tabs and Easels; each is in at
    /// most one, and every group holds at least one tab.
    var splits: [SplitGroup] = []
    /// An Easel pane of the split on screen has the focus (the selected tab
    /// is then another pane of that split).
    var focusedEaselID: UUID?

    init(record: SpaceRecord) {
        id = record.id
        name = record.name
        icon = record.icon
        themeID = record.themeID
        profileID = record.profileID
        selectedTabID = record.selectedTabID
        archiveInterval = record.archiveInterval
    }

    var theme: SpaceTheme { SpaceTheme.theme(withID: themeID) ?? .default }

    var record: SpaceRecord {
        SpaceRecord(
            id: id, name: name, icon: icon, themeID: themeID, profileID: profileID,
            selectedTabID: selectedTabID, archiveInterval: archiveInterval
        )
    }
}

/// One pane of what's on screen: a tab, or an Easel in a split.
enum SplitPane {
    case tab(Tab)
    case easel(UUID)

    var id: UUID {
        switch self {
        case .tab(let tab): tab.id
        case .easel(let id): id
        }
    }
}

enum TabSection {
    case pinned
    case regular
}

/// One window's browsing state: Spaces, their tabs, and the favorites every
/// Space shares. The window shows one Space at a time.
@MainActor
final class BrowserModel {
    private(set) var spaces: [Space]
    private(set) var favorites: [Tab] = []
    private(set) var currentSpaceID: UUID
    /// Closed tabs, most recent last, for ⇧⌘T. Each keeps its history.
    private(set) var recentlyClosed: [TabRecord] = []
    private static let recentlyClosedLimit = 25

    /// The Easels of a Space, which can be split with its tabs.
    var easelIDs: (UUID) -> Set<UUID> = { _ in [] }
    /// Tabs, Spaces or the selection changed.
    var onChange: (() -> Void)?
    /// Split pane sizes changed; nothing else needs redrawing, only saving.
    var onLayoutChange: (() -> Void)?
    /// A tab's title, URL, icon or navigation state changed.
    var onTabUpdated: ((Tab) -> Void)?
    /// A tab finished loading a page.
    var onTabFinishedLoading: ((Tab) -> Void)?

    init() {
        let space = Space(record: .makeDefault())
        spaces = [space]
        currentSpaceID = space.id
    }

    // MARK: Lookup

    var currentSpace: Space {
        spaces.first { $0.id == currentSpaceID } ?? spaces[0]
    }

    var selected: Tab? {
        guard let id = currentSpace.selectedTabID else { return nil }
        return favorites.first { $0.id == id }
            ?? currentSpace.pinned.first { $0.id == id }
            ?? currentSpace.tabs.first { $0.id == id }
    }

    /// Favorites, then every Space's pinned and regular tabs.
    var allTabs: [Tab] {
        favorites + spaces.flatMap { $0.pinned + $0.tabs }
    }

    func space(containing tab: Tab) -> Space? {
        spaces.first { space in space.pinned.contains { $0 === tab } || space.tabs.contains { $0 === tab } }
    }

    func isFavorite(_ tab: Tab) -> Bool { favorites.contains { $0 === tab } }
    func isPinned(_ tab: Tab) -> Bool { spaces.contains { $0.pinned.contains { $0 === tab } } }

    // MARK: Saving and restoring

    /// Rebuilds from saved state. Tabs don't load until first shown.
    func restore(_ snapshot: BrowserSnapshot) {
        allTabs.forEach { $0.tearDown() }
        var restoredSpaces = snapshot.spaces.map(Space.init(record:))
        if restoredSpaces.isEmpty { restoredSpaces = [Space(record: .makeDefault())] }
        let byID = Dictionary(uniqueKeysWithValues: restoredSpaces.map { ($0.id, $0) })

        favorites = []
        for record in snapshot.tabs {
            if record.isFavorite {
                favorites.append(makeTab(restoring: record, profileID: nil))
            } else if let space = record.spaceID.flatMap({ byID[$0] }) ?? restoredSpaces.first {
                let tab = makeTab(restoring: record, profileID: space.profileID)
                if record.isPinned { space.pinned.append(tab) } else { space.tabs.append(tab) }
            }
        }
        for space in restoredSpaces {
            space.splits = snapshot.splits[space.id] ?? []
        }
        spaces = restoredSpaces
        currentSpaceID = snapshot.selectedSpaceID.flatMap { byID[$0]?.id } ?? restoredSpaces[0].id
        if selected == nil { currentSpace.selectedTabID = (currentSpace.tabs.first ?? currentSpace.pinned.first)?.id }
        selected?.lastActiveAt = Date() // on screen again, so it counts as used now
        changed()
    }

    var snapshot: BrowserSnapshot {
        var tabs = favorites.map { tab in record(of: tab, space: nil, pinned: false) }
        for space in spaces {
            tabs += space.pinned.map { record(of: $0, space: space, pinned: true) }
            tabs += space.tabs.map { record(of: $0, space: space, pinned: false) }
        }
        var splits: [UUID: [SplitGroup]] = [:]
        for space in spaces where !space.splits.isEmpty {
            splits[space.id] = space.splits
        }
        return BrowserSnapshot(spaces: spaces.map(\.record), tabs: tabs, selectedSpaceID: currentSpaceID, splits: splits)
    }

    private func record(of tab: Tab, space: Space?, pinned: Bool) -> TabRecord {
        var record = tab.record
        record.spaceID = space?.id
        record.isPinned = pinned
        return record
    }

    /// Makes the model match `snapshot` (e.g. after a sync), keeping open
    /// tabs alive where they still belong. Returns the separate profiles of
    /// Spaces that went away, whose website data should be erased.
    @discardableResult
    func reconcile(with snapshot: BrowserSnapshot) -> [UUID] {
        var existingTabs: [UUID: Tab] = [:]
        for tab in allTabs where existingTabs[tab.id] == nil { existingTabs[tab.id] = tab }
        let existingSpaces = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var newSpaces = snapshot.spaces.map { record -> Space in
            guard let space = existingSpaces[record.id] else { return Space(record: record) }
            space.name = record.name
            space.icon = record.icon
            space.themeID = record.themeID
            space.archiveInterval = record.archiveInterval
            return space
        }
        if newSpaces.isEmpty { newSpaces = [spaces.first ?? Space(record: .makeDefault())] }
        let selections = Dictionary(newSpaces.map { ($0.id, $0.selectedTabID) }, uniquingKeysWith: { first, _ in first })
        for space in newSpaces {
            space.pinned = []
            space.tabs = []
            space.splits = snapshot.splits[space.id] ?? []
        }

        var newFavorites: [Tab] = []
        var kept = Set<UUID>()
        for record in snapshot.tabs {
            let space = record.spaceID.flatMap { id in newSpaces.first { $0.id == id } }
            guard record.isFavorite || space != nil else { continue }
            let profile = space?.profileID
            let tab: Tab
            if let existing = existingTabs[record.id] {
                tab = existing.webView.configuration.websiteDataStore === Profiles.dataStore(for: profile)
                    ? existing
                    : recreate(existing, profileID: profile)
            } else {
                tab = makeTab(restoring: record, profileID: profile)
            }
            tab.pinnedURL = record.pinnedURL
            kept.insert(record.id)
            if record.isFavorite {
                newFavorites.append(tab)
            } else if record.isPinned {
                space?.pinned.append(tab)
            } else {
                space?.tabs.append(tab)
            }
        }
        for (id, tab) in existingTabs where !kept.contains(id) {
            tab.tearDown()
        }

        let newIDs = Set(newSpaces.map(\.id))
        let removedProfiles = spaces
            .filter { !newIDs.contains($0.id) }
            .compactMap(\.profileID)
            .filter { profile in !newSpaces.contains { $0.profileID == profile } }
        spaces = newSpaces
        favorites = newFavorites
        // A selection whose tab went away falls back to the Space's first tab.
        let favoriteIDs = Set(favorites.map(\.id))
        for space in spaces {
            let available = favoriteIDs.union((space.pinned + space.tabs).map(\.id))
            if let selected = selections[space.id] ?? nil, available.contains(selected) { continue }
            space.selectedTabID = space.tabs.first?.id
        }
        if !newIDs.contains(currentSpaceID) { currentSpaceID = spaces[0].id }
        changed()
        return removedProfiles
    }

    // MARK: Tabs

    /// Opens a tab. Tabs opened from a page go right after that page's tab
    /// in its Space; others go to the top of the current Space, as in Arc.
    @discardableResult
    func open(
        url: URL?,
        configuration: WKWebViewConfiguration? = nil,
        opener: Tab? = nil,
        select: Bool = true
    ) -> Tab {
        let space = opener.flatMap { self.space(containing: $0) } ?? currentSpace
        let tab = Tab(configuration: configuration ?? WebViewConfiguration.make(profileID: space.profileID))
        wire(tab)
        if let opener, let index = space.tabs.firstIndex(where: { $0 === opener }) {
            space.tabs.insert(tab, at: index + 1)
        } else {
            space.tabs.insert(tab, at: 0)
        }
        if select || space.selectedTabID == nil {
            currentSpaceID = space.id
            markSelected(tab, in: space)
        }
        // Announce the tab before loading: loading reports progress right
        // away, and observers expect the tab to be listed by then.
        changed()
        if let url { tab.load(url) }
        return tab
    }

    /// Takes in a tab from elsewhere (Little Wau) as the current Space's
    /// newest tab, keeping its page and history.
    /// Takes in a tab from elsewhere (Little Wau, another window) at the top
    /// of the current Space, selected. A tab on another profile's website
    /// data is reopened on this Space's; that's the tab returned.
    @discardableResult
    func adopt(_ tab: Tab) -> Tab {
        let space = currentSpace
        let sameStore = tab.webView.configuration.websiteDataStore === Profiles.dataStore(for: space.profileID)
        let adopted = sameStore ? tab : recreate(tab, profileID: space.profileID)
        wire(adopted)
        space.tabs.insert(adopted, at: 0)
        markSelected(adopted, in: space)
        changed()
        return adopted
    }

    /// Shows `tab`, switching to its Space if needed.
    func select(_ tab: Tab) {
        let space = self.space(containing: tab) ?? currentSpace
        guard space.id != currentSpaceID || space.selectedTabID != tab.id || space.focusedEaselID != nil else { return }
        currentSpaceID = space.id
        markSelected(tab, in: space)
        changed()
    }

    /// Regular tabs close. Pinned tabs and favorites go back to their pinned
    /// page and unload instead, as in Arc.
    /// Takes a tab out of this window, still open, to move it to another
    /// (dragged out of the window). Favorites stay.
    @discardableResult
    func detach(_ tab: Tab) -> Bool {
        guard let space = space(containing: tab) else { return false }
        let wasPinned = space.pinned.contains { $0 === tab }
        let list = wasPinned ? space.pinned : space.tabs
        guard let index = list.firstIndex(where: { $0 === tab }) else { return false }
        if wasPinned { space.pinned.remove(at: index) } else { space.tabs.remove(at: index) }
        if space.selectedTabID == tab.id {
            // The neighbour in the same list takes over, as when closing.
            let siblings = wasPinned ? space.pinned : space.tabs
            let next = siblings.isEmpty ? (space.tabs.first ?? space.pinned.first) : siblings[min(index, siblings.count - 1)]
            space.selectedTabID = nil
            if let next { markSelected(next, in: space) }
        }
        changed()
        return true
    }

    func close(_ tab: Tab) {
        if let index = favorites.firstIndex(where: { $0 === tab }) {
            favorites[index] = reset(tab, profileID: nil)
            deselect(tab)
        } else if let space = space(containing: tab), let index = space.pinned.firstIndex(where: { $0 === tab }) {
            space.pinned[index] = reset(tab, profileID: space.profileID)
            deselect(tab)
        } else if let space = space(containing: tab), let index = space.tabs.firstIndex(where: { $0 === tab }) {
            space.tabs.remove(at: index)
            var record = record(of: tab, space: space, pinned: false)
            record.lastActiveAt = Date()
            recentlyClosed.append(record)
            if recentlyClosed.count > Self.recentlyClosedLimit { recentlyClosed.removeFirst() }
            tab.tearDown()
            if space.selectedTabID == tab.id {
                let next = space.tabs.isEmpty ? nil : space.tabs[min(index, space.tabs.count - 1)]
                space.selectedTabID = nil
                if let next { markSelected(next, in: space) }
            }
        } else {
            return
        }
        changed()
    }

    /// Brings back the most recently closed tab, into the Space it came from.
    @discardableResult
    func reopenClosedTab() -> Tab? {
        guard let record = recentlyClosed.popLast() else { return nil }
        let space = spaces.first { $0.id == record.spaceID } ?? currentSpace
        let tab = makeTab(restoring: record, profileID: space.profileID)
        space.tabs.insert(tab, at: 0)
        currentSpaceID = space.id
        markSelected(tab, in: space)
        changed()
        return tab
    }

    /// Moves a tab within its Space into the gap at `gap` of `section`;
    /// moving between sections pins or unpins it.
    func moveTab(_ tab: Tab, to section: TabSection, gap: Int) {
        guard let space = space(containing: tab) else { return }
        let fromPinned = space.pinned.firstIndex { $0 === tab }
        let fromRegular = space.tabs.firstIndex { $0 === tab }
        switch (section, fromPinned, fromRegular) {
        case (.pinned, let source?, _):
            space.pinned.move(from: source, toInsertionIndex: gap)
        case (.regular, _, let source?):
            space.tabs.move(from: source, toInsertionIndex: gap)
        case (.pinned, nil, let source?):
            space.tabs.remove(at: source)
            tab.pinnedURL = tab.url
            space.pinned.insert(tab, at: min(gap, space.pinned.count))
        case (.regular, let source?, nil):
            space.pinned.remove(at: source)
            tab.pinnedURL = nil
            space.tabs.insert(tab, at: min(gap, space.tabs.count))
        default:
            return
        }
        changed()
    }

    func setPinned(_ tab: Tab, _ pinned: Bool) {
        guard let space = space(containing: tab), isPinned(tab) != pinned else { return }
        moveTab(tab, to: pinned ? .pinned : .regular, gap: pinned ? space.pinned.count : 0)
    }

    /// Favorites use the shared profile, so a tab from a Space with its own
    /// logins is copied rather than moved.
    func setFavorite(_ tab: Tab, _ favorite: Bool) {
        if favorite {
            guard !isFavorite(tab), let space = space(containing: tab) else { return }
            space.pinned.removeAll { $0 === tab }
            space.tabs.removeAll { $0 === tab }
            let moved = space.profileID == nil ? tab : recreate(tab, profileID: nil)
            moved.pinnedURL = moved.url
            favorites.append(moved)
        } else {
            guard let index = favorites.firstIndex(where: { $0 === tab }) else { return }
            favorites.remove(at: index)
            tab.pinnedURL = nil
            let space = currentSpace
            space.tabs.insert(tab, at: 0)
            if space.selectedTabID == tab.id { markSelected(tab, in: space) }
        }
        changed()
    }

    func moveTab(_ tab: Tab, toSpace target: Space) {
        guard let source = space(containing: tab), source !== target else { return }
        let wasSelected = source.selectedTabID == tab.id
        source.pinned.removeAll { $0 === tab }
        source.tabs.removeAll { $0 === tab }
        if wasSelected { source.selectedTabID = source.tabs.first?.id }
        // A web view can't change its data store, so crossing profiles
        // rebuilds the tab from its saved state.
        let moved = source.profileID == target.profileID ? tab : recreate(tab, profileID: target.profileID)
        moved.pinnedURL = nil
        target.tabs.insert(moved, at: 0)
        changed()
    }

    // MARK: Spaces

    func switchToSpace(_ space: Space) {
        guard space.id != currentSpaceID, spaces.contains(where: { $0 === space }) else { return }
        currentSpaceID = space.id
        selected?.lastActiveAt = Date()
        changed()
    }

    /// Switches by `offset` positions, wrapping around (for swipes and ⌥⌘←/→).
    func switchSpace(by offset: Int) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        let next = ((index + offset) % spaces.count + spaces.count) % spaces.count
        switchToSpace(spaces[next])
    }

    @discardableResult
    func createSpace(name: String, icon: String, themeID: String, separateProfile: Bool) -> Space {
        let space = Space(record: SpaceRecord(
            name: name, icon: icon, themeID: themeID,
            profileID: separateProfile ? UUID() : nil
        ))
        spaces.append(space)
        currentSpaceID = space.id
        changed()
        return space
    }

    func updateSpace(_ space: Space, name: String, icon: String, themeID: String, archiveInterval: ArchiveInterval? = nil) {
        space.name = name
        space.icon = icon
        space.themeID = themeID
        if let archiveInterval { space.archiveInterval = archiveInterval }
        changed()
    }

    // MARK: Archiving

    /// Removes ordinary tabs unseen for longer than their Space allows and
    /// returns them for the archive. Pinned tabs and favorites stay.
    func archiveStaleTabs(now: Date = Date()) -> [TabRecord] {
        var archived: [TabRecord] = []
        let onScreen = Set(visibleTabs.map(\.id))
        for space in spaces {
            let candidates = space.tabs.map { tab in
                ArchivePolicy.Candidate(
                    id: tab.id,
                    lastActiveAt: tab.lastActiveAt,
                    isVisible: onScreen.contains(tab.id)
                )
            }
            let stale = Set(ArchivePolicy.tabsToArchive(candidates, interval: space.archiveInterval, now: now))
            guard !stale.isEmpty else { continue }
            for tab in space.tabs where stale.contains(tab.id) {
                archived.append(record(of: tab, space: space, pinned: false))
                tab.tearDown()
            }
            space.tabs.removeAll { stale.contains($0.id) }
            if let selected = space.selectedTabID, stale.contains(selected) {
                space.selectedTabID = space.tabs.first?.id
            }
        }
        if !archived.isEmpty { changed() }
        return archived
    }

    /// Brings an archived tab back into its Space (or the current one) and shows it.
    @discardableResult
    func restoreArchived(_ record: TabRecord) -> Tab {
        let space = spaces.first { $0.id == record.spaceID } ?? currentSpace
        var record = record
        record.isPinned = false
        let tab = makeTab(restoring: record, profileID: space.profileID)
        space.tabs.insert(tab, at: 0)
        currentSpaceID = space.id
        markSelected(tab, in: space)
        changed()
        return tab
    }

    /// Closes the Space's tabs and removes it. The last Space can't be deleted.
    /// Returns the profile whose website data should now be erased, if any.
    @discardableResult
    func deleteSpace(_ space: Space) -> UUID? {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0 === space }) else { return nil }
        (space.pinned + space.tabs).forEach { $0.tearDown() }
        spaces.remove(at: index)
        if currentSpaceID == space.id { currentSpaceID = spaces[max(0, index - 1)].id }
        recentlyClosed.removeAll { $0.spaceID == space.id }
        changed()
        // Only erase data no other Space still uses.
        guard let profile = space.profileID, !spaces.contains(where: { $0.profileID == profile }) else { return nil }
        return profile
    }

    // MARK: Split View

    /// The split group the tab belongs to, in its Space.
    func split(containing tab: Tab) -> SplitGroup? {
        space(containing: tab)?.splits.first { $0.contains(tab.id) }
    }

    /// The split on screen, if the selected tab is in one.
    var visibleSplit: SplitGroup? {
        guard let selected, !isFavorite(selected) else { return nil }
        return currentSpace.splits.first { $0.contains(selected.id) }
    }

    /// The tabs on screen: the selected tab, or every tab of its split.
    var visibleTabs: [Tab] {
        visiblePanes.compactMap { if case .tab(let tab) = $0 { tab } else { nil } }
    }

    /// What's on screen, in order: the selected tab, or every pane of its
    /// split (tabs and Easels).
    var visiblePanes: [SplitPane] {
        guard let selected else { return [] }
        guard let group = visibleSplit else { return [.tab(selected)] }
        let spaceTabs = currentSpace.pinned + currentSpace.tabs
        let easels = easelIDs(currentSpaceID)
        let panes = group.tabIDs.compactMap { id -> SplitPane? in
            if let tab = spaceTabs.first(where: { $0.id == id }) { return .tab(tab) }
            return easels.contains(id) ? .easel(id) : nil
        }
        return panes.count >= 2 ? panes : [.tab(selected)]
    }

    /// The pane with the focus: an Easel of the split on screen, or the
    /// selected tab.
    var focusedPaneID: UUID? {
        currentSpace.focusedEaselID ?? currentSpace.selectedTabID
    }

    /// Whether `tab` can join the selected tab in a split.
    func canSplit(_ tab: Tab) -> Bool {
        guard let base = selected, base !== tab, !isFavorite(base), !isFavorite(tab),
              space(containing: tab) === currentSpace
        else { return false }
        if let group = visibleSplit { return !group.isFull || group.contains(tab.id) }
        return true
    }

    /// Shows `tab` next to the selected tab, starting a split or adding a
    /// pane (up to four). The new pane gets the focus.
    @discardableResult
    func addToSplit(_ tab: Tab) -> Bool {
        guard canSplit(tab), let base = selected else { return false }
        let space = currentSpace
        for index in space.splits.indices where space.splits[index].contains(tab.id) && !space.splits[index].contains(base.id) {
            space.splits[index].remove(tab.id)
        }
        if let index = space.splits.firstIndex(where: { $0.contains(base.id) }) {
            if !space.splits[index].contains(tab.id) {
                space.splits[index].insert(tab.id, after: base.id)
            }
        } else {
            space.splits.append(SplitGroup(tabIDs: [base.id, tab.id]))
        }
        markSelected(tab, in: space)
        changed()
        return true
    }

    /// Whether `id` is a tab (not a favorite) or an Easel of the current Space.
    private func isPaneCandidate(_ id: UUID) -> Bool {
        isTabInCurrentSpace(id) || easelIDs(currentSpaceID).contains(id)
    }

    private func isTabInCurrentSpace(_ id: UUID) -> Bool {
        (currentSpace.pinned + currentSpace.tabs).contains { $0.id == id }
    }

    /// Whether `id` (a tab or Easel) can join `target` (any tab or Easel of
    /// the current Space) in a split: they're different, the target's split
    /// has room or already holds it, and the split would hold a tab.
    func canJoin(_ id: UUID, beside target: UUID) -> Bool {
        guard id != target, isPaneCandidate(id), isPaneCandidate(target) else { return false }
        if let group = currentSpace.splits.first(where: { $0.contains(target) }) {
            return group.contains(id) || !group.isFull
        }
        return isTabInCurrentSpace(id) || isTabInCurrentSpace(target)
    }

    func canJoin(_ tab: Tab, beside target: Tab) -> Bool {
        canJoin(tab.id, beside: target.id)
    }

    /// Whether `id` can be dropped beside `target`, one of the panes on screen.
    func canPlace(_ id: UUID, beside target: UUID) -> Bool {
        visiblePanes.contains { $0.id == target } && canJoin(id, beside: target)
    }

    func canPlace(_ tab: Tab, beside target: Tab) -> Bool {
        canPlace(tab.id, beside: target.id)
    }

    /// Shows `id` (a tab or Easel) just before or after `target`: starts a
    /// split, adds a pane, or moves a pane that's already there. The dropped
    /// pane gets the focus, so the split comes on screen.
    @discardableResult
    func placeInSplit(_ id: UUID, beside target: UUID, after: Bool) -> Bool {
        guard canJoin(id, beside: target) else { return false }
        let space = currentSpace
        if let index = space.splits.firstIndex(where: { $0.contains(target) }) {
            for other in space.splits.indices where other != index { space.splits[other].remove(id) }
            space.splits[index].place(id, beside: target, after: after)
        } else {
            for other in space.splits.indices { space.splits[other].remove(id) }
            space.splits.append(SplitGroup(tabIDs: after ? [target, id] : [id, target]))
        }
        focus(id, in: space)
        changed()
        return true
    }

    @discardableResult
    func placeInSplit(_ tab: Tab, beside target: Tab, after: Bool) -> Bool {
        placeInSplit(tab.id, beside: target.id, after: after)
    }

    /// Shows the split holding Easel `id` with that Easel focused. False if
    /// it isn't in a split of the current Space.
    @discardableResult
    func focusEasel(_ id: UUID) -> Bool {
        guard currentSpace.splits.contains(where: { $0.contains(id) }) else { return false }
        focus(id, in: currentSpace)
        changed()
        return true
    }

    /// Gives a pane the focus: a tab is selected; an Easel is focused with
    /// one of its split's tabs selected, keeping the selected one if it's there.
    private func focus(_ id: UUID, in space: Space) {
        let spaceTabs = space.pinned + space.tabs
        if let tab = spaceTabs.first(where: { $0.id == id }) {
            markSelected(tab, in: space)
            return
        }
        guard let group = space.splits.first(where: { $0.contains(id) }) else { return }
        if space.selectedTabID.map(group.contains) != true,
           let tab = group.tabIDs.lazy.compactMap({ member in spaceTabs.first { $0.id == member } }).first {
            markSelected(tab, in: space)
        }
        space.focusedEaselID = id
    }

    /// Takes a tab or Easel out of its split.
    func removeFromSplit(paneID id: UUID) {
        guard let index = currentSpace.splits.firstIndex(where: { $0.contains(id) }) else { return }
        currentSpace.splits[index].remove(id)
        changed()
    }

    /// The split holding a tab or Easel of the current Space.
    func split(containing id: UUID) -> SplitGroup? {
        currentSpace.splits.first { $0.contains(id) }
    }

    /// Easels were added or deleted: drop deleted ones from splits.
    func easelsChanged() {
        changed()
    }

    /// Takes a tab out of its split; it stays open on its own.
    func removeFromSplit(_ tab: Tab) {
        guard let space = space(containing: tab),
              let index = space.splits.firstIndex(where: { $0.contains(tab.id) })
        else { return }
        space.splits[index].remove(tab.id)
        changed()
    }

    /// Switches the visible split between side by side and stacked.
    func toggleSplitAxis() {
        guard let group = visibleSplit, let index = currentSpace.splits.firstIndex(where: { $0.id == group.id }) else { return }
        currentSpace.splits[index].axis = group.axis.toggled
        changed()
    }

    func setSplitFractions(_ fractions: [Double], for groupID: UUID) {
        guard let index = currentSpace.splits.firstIndex(where: { $0.id == groupID }) else { return }
        currentSpace.splits[index].setFractions(fractions)
        onLayoutChange?()
    }

    // MARK: Helpers

    /// Tidies split groups after any change (tabs closed, moved, archived),
    /// then tells observers.
    private func changed() {
        for space in spaces {
            let tabIDs = Set((space.pinned + space.tabs).map(\.id))
            let ids = tabIDs.union(easelIDs(space.id))
            var claimed = Set<UUID>()
            space.splits = space.splits.compactMap { group in
                var group = group
                group.retain(ids.subtracting(claimed))
                claimed.formUnion(group.tabIDs)
                // A split needs a tab: Easels alone aren't shown together.
                return group.isValid && group.tabIDs.contains(where: tabIDs.contains) ? group : nil
            }
            // A focused Easel must be a pane of the selected tab's split.
            if let easel = space.focusedEaselID,
               !space.splits.contains(where: { $0.contains(easel) && space.selectedTabID.map($0.contains) == true }) {
                space.focusedEaselID = nil
            }
        }
        onChange?()
    }

    private func markSelected(_ tab: Tab, in space: Space) {
        space.selectedTabID = tab.id
        space.focusedEaselID = nil
        tab.lastActiveAt = Date()
    }

    private func deselect(_ tab: Tab) {
        for space in spaces where space.selectedTabID == tab.id {
            space.selectedTabID = nil
            if let next = space.tabs.first { markSelected(next, in: space) }
        }
    }

    private func makeTab(restoring record: TabRecord, profileID: UUID?) -> Tab {
        let tab = Tab(configuration: WebViewConfiguration.make(profileID: profileID), restoring: record)
        wire(tab)
        return tab
    }

    /// A fresh, unloaded copy of a pinned tab or favorite at its pinned page.
    private func reset(_ tab: Tab, profileID: UUID?) -> Tab {
        var record = tab.record
        record.url = tab.pinnedURL ?? tab.url
        record.sessionState = nil
        let fresh = makeTab(restoring: record, profileID: profileID)
        fresh.favicon = tab.favicon
        tab.tearDown()
        return fresh
    }

    /// The same tab (id, history) in a different profile.
    private func recreate(_ tab: Tab, profileID: UUID?) -> Tab {
        let fresh = makeTab(restoring: tab.record, profileID: profileID)
        fresh.favicon = tab.favicon
        tab.tearDown()
        return fresh
    }

    private func wire(_ tab: Tab) {
        tab.onChange = { [weak self] tab in self?.onTabUpdated?(tab) }
        tab.onFinishLoading = { [weak self] tab in self?.onTabFinishedLoading?(tab) }
        tab.onOpenTab = { [weak self, weak tab] configuration, url, inBackground in
            self?.open(url: url, configuration: configuration, opener: tab, select: !inBackground)
        }
        tab.onRequestClose = { [weak self] tab in self?.close(tab) }
        tab.onDownload = { DownloadManager.shared.start($0) }
    }
}

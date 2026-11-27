import AppKit
import Core

private extension NSPasteboard.PasteboardType {
    /// A tab being dragged within the sidebar; the value is its ID.
    static let wauTabRow = NSPasteboard.PasteboardType("dev.wau.tab-row")
    static let wauEaselRow = NSPasteboard.PasteboardType("dev.wau.easel-row")
}

/// A pane of a split row in the sidebar: a tab, or an Easel.
private enum SidebarMember {
    case tab(Tab)
    case easel(Easel)

    var id: UUID {
        switch self {
        case .tab(let tab): tab.id
        case .easel(let easel): easel.id
        }
    }
}

/// The left column, top to bottom: navigation buttons, address pill,
/// favorites, the current Space's pinned tabs, "New Tab", its other tabs,
/// and the Space switcher.
@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onOpenLocation: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onNewSpace: (() -> Void)?
    var onEditSpace: ((Space) -> Void)?
    var onDeleteSpace: ((Space) -> Void)?
    var onSplitWith: ((Tab) -> Void)?
    /// A blank or incognito window: one Space, no switcher or Space menu.
    var isSingleSpace = false {
        didSet {
            spaceBar.isHidden = isSingleSpace
            spaceMenuButton.isHidden = isSingleSpace
        }
    }
    /// A tab started (true) or stopped (false) being dragged out of the list.
    var onTabDrag: ((Bool) -> Void)?
    /// A tab was dropped outside every Wau window, at this screen point.
    var onTearOff: ((Tab, NSPoint) -> Void)?
    /// Whether a tab dragged from another window may move into this one.
    var canReceiveTab: ((UUID) -> Bool)?
    /// Moves that tab into this window; returns it (now in this window).
    var receiveTab: ((UUID) -> Tab?)?
    /// The current Space's Easels, listed below its tabs.
    var easelsInSpace: (() -> [Easel])?
    /// The Easel shown in the page area, highlighted in the list.
    var shownEaselID: (() -> UUID?)?
    var onSelectEasel: ((Easel) -> Void)?
    var onDeleteEasel: ((Easel) -> Void)?
    /// An Easel was dragged to a gap among the Space's Easels (0 is the top).
    /// An Easel was dragged to a gap among the pinned Easels (true) or the
    /// others (false); 0 is the top of that group.
    var onMoveEasel: ((Easel, Bool, Int) -> Void)?
    var onPinEasel: ((Easel, Bool) -> Void)?
    var onRenameEasel: ((Easel) -> Void)?
    /// The user picked a tab in the list (leaving any Easel that was shown).
    var onTabChosen: (() -> Void)?

    private enum Row {
        case pinned(Tab)
        case newTab
        /// Easels sit in the tab list, after the tabs, and look like tabs.
        case easel(Easel)
        case regular(Tab)
        /// A Split View group: one row, one segment per pane (tabs and Easels).
        case split([SidebarMember])

        var tab: Tab? {
            switch self {
            case .pinned(let tab), .regular(let tab): tab
            case .newTab, .easel, .split: nil
            }
        }

        /// Every tab and Easel the row stands for.
        var members: [SidebarMember] {
            switch self {
            case .pinned(let tab), .regular(let tab): [.tab(tab)]
            case .easel(let easel): [.easel(easel)]
            case .split(let members): members
            case .newTab: []
            }
        }

        /// Every tab the row stands for.
        var tabs: [Tab] {
            members.compactMap { if case .tab(let tab) = $0 { tab } else { nil } }
        }
    }

    private let model: BrowserModel
    private var rows: [Row] = []
    private let tableView = SidebarTableView()
    /// Half of a row, lit while a tab is held over it to make a split.
    private let rowDropHighlight = DropHighlightView(cornerRadius: 7, fillAlpha: 0.7, borderColor: .white)
    /// Where a drag over the list would drop: onto a row, to split with
    /// it, or into a gap between rows.
    private enum PendingDrop {
        case split(row: Int)
        case gap(Int)
    }
    private var pendingDrop: PendingDrop?
    /// The line between rows where a dragged tab would land.
    private let insertionLine = NSView()
    private let addressLabel = NSTextField(labelWithString: "")
    private let favoritesView = FavoritesView()
    private let spaceTitle = NSTextField(labelWithString: "")
    private let spaceMenuButton = NSButton()
    private let spaceBar = NSStackView()
    private let backButton = SidebarViewController.iconButton("chevron.left", "Back", #selector(BrowserWindowController.goBack(_:)))
    private let forwardButton = SidebarViewController.iconButton("chevron.right", "Forward", #selector(BrowserWindowController.goForward(_:)))
    private let reloadButton = SidebarViewController.iconButton("arrow.clockwise", "Reload", #selector(BrowserWindowController.reloadPage(_:)))
    private let sidebarButton = SidebarViewController.iconButton("sidebar.left", "Hide Sidebar (⌘S)", #selector(toggleSidebarClicked))
    /// Set while the table is being updated from the model, so the
    /// resulting selection callbacks are not sent back to the model.
    private var isSyncingSelection = false

    init(model: BrowserModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = NSView()
        sidebarButton.target = self

        // Sits beside the traffic lights, in the transparent title bar.
        let navRow = NSStackView(views: [backButton, forwardButton, reloadButton])
        navRow.spacing = 2

        let pill = AddressPill(label: addressLabel)
        pill.onClick = { [weak self] in self?.onOpenLocation?() }

        favoritesView.onSelect = { [weak self] tab in self?.model.select(tab) }
        favoritesView.menuForTab = { [weak self] tab in self?.menu(for: tab) }

        spaceTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        spaceTitle.textColor = .secondaryLabelColor
        spaceTitle.lineBreakMode = .byTruncatingTail
        spaceTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spaceMenuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Space options")
        spaceMenuButton.isBordered = false
        spaceMenuButton.contentTintColor = .tertiaryLabelColor
        spaceMenuButton.target = self
        spaceMenuButton.action = #selector(showSpaceMenu(_:))
        spaceMenuButton.toolTip = "Space options"
        let spaceHeader = NSStackView(views: [spaceTitle, NSView(), spaceMenuButton])
        spaceHeader.spacing = 4

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowHeight = 32
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableClicked)
        tableView.registerForDraggedTypes([.wauTabRow, .wauEaselRow])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        // The sidebar draws where a drop goes itself (see `updateDrop`).
        tableView.draggingDestinationFeedbackStyle = .none
        rowDropHighlight.isHidden = true
        tableView.addSubview(rowDropHighlight)
        insertionLine.isHidden = true
        insertionLine.wantsLayer = true
        insertionLine.layer?.cornerRadius = 1
        insertionLine.layer?.backgroundColor = DropHighlightView.color.cgColor
        tableView.addSubview(insertionLine)
        tableView.onDragUpdate = { [weak self] info in self?.updateDrop(info) ?? [] }
        tableView.onDrop = { [weak self] info in self?.performDrop(info) ?? false }
        tableView.onDragExit = { [weak self] in self?.clearDrop() }
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        tableView.menu = rowMenu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        spaceBar.spacing = 6

        for view in [sidebarButton, navRow, pill, favoritesView, spaceHeader, scrollView, spaceBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            // Just right of the traffic lights.
            sidebarButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 76),
            sidebarButton.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            navRow.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarButton.trailingAnchor, constant: 4),

            navRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            navRow.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 18),

            pill.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            pill.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            pill.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            pill.heightAnchor.constraint(equalToConstant: 34),

            favoritesView.topAnchor.constraint(equalTo: pill.bottomAnchor, constant: 10),
            favoritesView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            favoritesView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),

            spaceHeader.topAnchor.constraint(equalTo: favoritesView.bottomAnchor, constant: 10),
            spaceHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            spaceHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: spaceHeader.bottomAnchor, constant: 2),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: 2),
            scrollView.bottomAnchor.constraint(equalTo: spaceBar.topAnchor, constant: -6),

            spaceBar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spaceBar.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -16),
            spaceBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            spaceBar.heightAnchor.constraint(equalToConstant: 28),
        ])
        view = root
        reloadTabs()
    }

    // MARK: Updating from the model

    /// Rebuilds everything from the model.
    func reloadTabs() {
        let space = model.currentSpace
        // A split shows as one row, where its first tab would be; Easels in
        // it leave the Easel list.
        let spaceTabs = space.pinned + space.tabs
        let spaceEasels = easelsInSpace?() ?? []
        var shownSplits = Set<UUID>()
        func row(for tab: Tab, pinned: Bool) -> Row? {
            guard let group = space.splits.first(where: { $0.contains(tab.id) }) else {
                return pinned ? .pinned(tab) : .regular(tab)
            }
            guard shownSplits.insert(group.id).inserted else { return nil }
            let members = group.tabIDs.compactMap { id -> SidebarMember? in
                if let tab = spaceTabs.first(where: { $0.id == id }) { return .tab(tab) }
                return spaceEasels.first { $0.id == id }.map(SidebarMember.easel)
            }
            return members.count >= 2 ? .split(members) : (pinned ? .pinned(tab) : .regular(tab))
        }
        let pinnedRows = space.pinned.compactMap { row(for: $0, pinned: true) }
        let regularRows = space.tabs.compactMap { row(for: $0, pinned: false) }
        let inSplits = Set((pinnedRows + regularRows).flatMap(\.members).map(\.id))
        let listed = spaceEasels.filter { !inSplits.contains($0.id) }
        // Pinned Easels follow the pinned tabs; the rest follow the tabs.
        rows = pinnedRows + listed.filter(\.isPinned).map(Row.easel) + [.newTab]
            + regularRows + listed.filter { !$0.isPinned }.map(Row.easel)
        let shownEasel = shownEaselID?()

        isSyncingSelection = true
        defer { isSyncingSelection = false }
        tableView.reloadData()
        let selectedIndex = shownEasel != nil
            ? rows.firstIndex { if case .easel(let easel) = $0 { easel.id == shownEasel } else { false } }
            : rows.firstIndex { $0.tabs.contains { $0.id == space.selectedTabID } }
        if let index = selectedIndex {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        } else {
            tableView.deselectAll(nil)
        }

        favoritesView.show(model.favorites, selectedID: space.selectedTabID)
        spaceTitle.stringValue = "\(space.icon)  \(space.name)"
        rebuildSpaceBar()
        updateNavigation()
    }

    /// Updates one tab's row or favorite and, if selected, the navigation controls.
    func refresh(_ tab: Tab) {
        if let index = rows.firstIndex(where: { $0.tabs.contains { $0 === tab } }),
           index < tableView.numberOfRows {
            let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
            if let cell = cell as? TabCellView {
                cell.configure(with: tab)
            } else if let cell = cell as? SplitCellView {
                cell.configure(with: rows[index].members, focusedID: model.focusedPaneID)
            }
        }
        if model.isFavorite(tab) {
            favoritesView.show(model.favorites, selectedID: model.currentSpace.selectedTabID)
        }
        if tab === model.selected { updateNavigation() }
    }

    private func updateNavigation() {
        let tab = model.selected
        let host = tab?.displayHost ?? ""
        addressLabel.stringValue = host.isEmpty ? "Search or Enter URL…" : host
        addressLabel.textColor = host.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor
        backButton.isEnabled = tab?.canGoBack ?? false
        forwardButton.isEnabled = tab?.canGoForward ?? false
        reloadButton.isEnabled = tab != nil
    }

    private func rebuildSpaceBar() {
        spaceBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (number, space) in model.spaces.enumerated() {
            let button = SpaceButton(icon: space.icon, isCurrent: space.id == model.currentSpaceID)
            button.toolTip = number < 9 ? "\(space.name)  ⌃\(number + 1)" : space.name
            button.onClick = { [weak self] in self?.model.switchToSpace(space) }
            button.menu = spaceMenu(for: space)
            spaceBar.addArrangedSubview(button)
        }
        let add = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Space")!,
            target: self,
            action: #selector(newSpaceClicked)
        )
        add.isBordered = false
        add.contentTintColor = .tertiaryLabelColor
        add.toolTip = "New Space…"
        spaceBar.addArrangedSubview(add)
    }

    // MARK: Menus

    @objc private func showSpaceMenu(_ sender: NSButton) {
        spaceMenu(for: model.currentSpace).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func spaceMenu(for space: Space) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Edit Space…") { [weak self] in self?.onEditSpace?(space) })
        let delete = ClosureMenuItem("Delete Space…") { [weak self] in self?.onDeleteSpace?(space) }
        delete.isEnabled = model.spaces.count > 1
        menu.autoenablesItems = false
        menu.addItem(delete)
        return menu
    }

    /// Right-click menu for a tab row or favorite.
    private func menu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        if model.isFavorite(tab) {
            menu.addItem(ClosureMenuItem("Remove from Favorites") { [weak self] in self?.model.setFavorite(tab, false) })
        } else {
            let pinned = model.isPinned(tab)
            menu.addItem(ClosureMenuItem(pinned ? "Unpin Tab" : "Pin Tab") { [weak self] in self?.model.setPinned(tab, !pinned) })
            menu.addItem(ClosureMenuItem("Add to Favorites") { [weak self] in self?.model.setFavorite(tab, true) })
            if model.canSplit(tab) {
                menu.addItem(ClosureMenuItem("Open in Split View") { [weak self] in self?.onSplitWith?(tab) })
            }
            if model.split(containing: tab) != nil {
                menu.addItem(ClosureMenuItem("Remove from Split View") { [weak self] in self?.model.removeFromSplit(tab) })
            }
            let others = model.spaces.filter { $0 !== model.space(containing: tab) }
            if !others.isEmpty {
                let moveItem = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for space in others {
                    submenu.addItem(ClosureMenuItem("\(space.icon)  \(space.name)") { [weak self] in
                        self?.model.moveTab(tab, toSpace: space)
                    })
                }
                moveItem.submenu = submenu
                menu.addItem(moveItem)
            }
        }
        menu.addItem(.separator())
        let copy = ClosureMenuItem("Copy Link") {
            guard let url = tab.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        copy.isEnabled = tab.url != nil
        menu.autoenablesItems = false
        menu.addItem(copy)
        menu.addItem(.separator())
        let closeTitle = model.isFavorite(tab) || model.isPinned(tab) ? "Reset and Unload" : "Close Tab"
        menu.addItem(ClosureMenuItem(closeTitle) { [weak self] in self?.model.close(tab) })
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else { return }
        let member = member(atRow: row, windowPoint: NSApp.currentEvent?.locationInWindow)
        if case .easel(let easel) = member {
            menu.addItem(ClosureMenuItem("Open Easel") { [weak self] in self?.onSelectEasel?(easel) })
            menu.addItem(ClosureMenuItem("Rename Easel…") { [weak self] in self?.onRenameEasel?(easel) })
            menu.addItem(ClosureMenuItem(easel.isPinned ? "Unpin Tab" : "Pin Tab") { [weak self] in
                self?.onPinEasel?(easel, !easel.isPinned)
            })
            if model.split(containing: easel.id) != nil {
                menu.addItem(ClosureMenuItem("Remove from Split View") { [weak self] in
                    self?.model.removeFromSplit(paneID: easel.id)
                })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Delete Easel…") { [weak self] in self?.onDeleteEasel?(easel) })
            return
        }
        guard case .tab(let tab) = member else { return }
        for item in self.menu(for: tab).items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    @objc private func newSpaceClicked() {
        onNewSpace?()
    }

    @objc private func tableClicked() {
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .newTab:
            onNewTab?()
        case .split:
            // The row may already be selected; a click still picks a pane.
            guard let member = member(atRow: row, windowPoint: NSApp.currentEvent?.locationInWindow),
                  member.id != model.focusedPaneID
            else { return }
            choose(member)
        default:
            break
        }
    }

    /// Shows a tab, or an Easel (in its split, if it's in one).
    private func choose(_ member: SidebarMember) {
        switch member {
        case .tab(let tab):
            onTabChosen?()
            model.select(tab)
        case .easel(let easel):
            onSelectEasel?(easel)
        }
    }

    /// The tab or Easel a row stands for at a point in the window: for a
    /// split row, the pane under the point (or the focused pane, with no point).
    private func member(atRow row: Int, windowPoint: NSPoint?) -> SidebarMember? {
        guard rows.indices.contains(row) else { return nil }
        guard case .split(let members) = rows[row] else { return rows[row].members.first }
        let focused = members.first { $0.id == model.focusedPaneID } ?? members.first
        guard let windowPoint,
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SplitCellView,
              let index = cell.segmentIndex(at: cell.convert(windowPoint, from: nil)),
              members.indices.contains(index)
        else { return focused }
        return members[index]
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .newTab:
            return tableView.makeView(withIdentifier: NewTabCellView.identifier, owner: nil) as? NewTabCellView
                ?? NewTabCellView()
        case .easel(let easel):
            let cell = tableView.makeView(withIdentifier: TabCellView.identifier, owner: nil) as? TabCellView
                ?? TabCellView()
            cell.configure(with: easel)
            cell.onClose = { [weak self] in self?.onDeleteEasel?(easel) }
            return cell
        case .split(let members):
            let cell = tableView.makeView(withIdentifier: SplitCellView.identifier, owner: nil) as? SplitCellView
                ?? SplitCellView()
            cell.configure(with: members, focusedID: model.focusedPaneID)
            cell.onClose = { [weak self] member in
                switch member {
                case .tab(let tab): self?.model.close(tab)
                case .easel(let easel): self?.model.removeFromSplit(paneID: easel.id) // keeps the Easel
                }
            }
            return cell
        case .pinned, .regular:
            break
        }
        guard let tab = rows[row].tab else { return nil }
        let cell = tableView.makeView(withIdentifier: TabCellView.identifier, owner: nil) as? TabCellView
            ?? TabCellView()
        cell.configure(with: tab)
        cell.onClose = { [weak self, weak tab] in
            guard let self, let tab else { return }
            model.close(tab)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarRowView()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .pinned, .regular, .easel, .split: true
        case .newTab: false
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return }
        let event = NSApp.currentEvent
        let point = event?.type == .leftMouseDown ? event?.locationInWindow : nil
        guard let member = member(atRow: row, windowPoint: point) else { return }
        choose(member)
    }

    // MARK: Drag to reorder (and across "New Tab" to pin or unpin)

    // While a tab or Easel is dragged, the page area takes it for Split View.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        if rowIndexes.contains(where: { rows.indices.contains($0) && !rows[$0].members.isEmpty }) {
            onTabDrag?(true)
        }
        // A tab let go on the desktop opens in a new window right there,
        // instead of sliding back first.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onTabDrag?(false)
        clearDrop()
        // Let go outside every Wau window: the tab gets a window of its own.
        let overWau = NSApp.windows.contains { $0.isVisible && $0.windowController != nil && $0.frame.contains(screenPoint) }
        guard operation.isEmpty, !overWau,
              let id = session.draggingPasteboard.pasteboardItems?.first?.string(forType: .wauTabRow).flatMap(UUID.init(uuidString:)),
              let tab = (model.currentSpace.pinned + model.currentSpace.tabs).first(where: { $0.id == id })
        else { return }
        onTearOff?(tab, screenPoint)
    }

    // Every tab and Easel row can be dragged. Without this, pressing on an
    // Easel and moving would drag the selection across other rows instead,
    // switching away from the Easel.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        // A split row drags the pane that was pressed.
        switch member(atRow: row, windowPoint: NSApp.currentEvent?.locationInWindow) {
        case .tab(let tab):
            item.setString(tab.id.uuidString, forType: .wauTabRow)
            // Lets the page area take it for Split View.
            item.setString(tab.id.uuidString, forType: .wauTab)
        case .easel(let easel):
            item.setString(easel.id.uuidString, forType: .wauEaselRow)
            item.setString(easel.id.uuidString, forType: .wauTab)
        case nil:
            return nil
        }
        return item
    }

    /// The "New Tab" row, between the pinned rows and the rest.
    private var newTabRow: Int {
        rows.firstIndex { if case .newTab = $0 { true } else { false } } ?? 0
    }

    /// Where the pinned Easels start (after the pinned tabs).
    private var firstPinnedEaselRow: Int {
        rows[..<newTabRow].firstIndex { if case .easel = $0 { true } else { false } } ?? newTabRow
    }

    /// Where the other Easels start (after every tab).
    private var firstEaselRow: Int {
        rows[newTabRow...].firstIndex { if case .easel = $0 { true } else { false } } ?? rows.count
    }

    /// Works out where a drag over the list would drop and shows it: over
    /// the middle of a tab or Easel row, the half it would take beside it;
    /// otherwise a line in the gap between rows.
    private func updateDrop(_ info: any NSDraggingInfo) -> NSDragOperation {
        let fromHere = (info.draggingSource as? NSTableView) === tableView
        // A tab from another window can be dropped between rows to move here.
        let fromElsewhere = !fromHere && draggedPaneID(info).map { canReceiveTab?($0) ?? false } == true
        guard fromHere || fromElsewhere else {
            clearDrop()
            return []
        }
        let point = tableView.convert(info.draggingLocation, from: nil)
        let row = tableView.row(at: point)
        if row >= 0, fromHere {
            let middle = tableView.rect(ofRow: row).insetBy(dx: 0, dy: tableView.rect(ofRow: row).height / 4)
            if middle.contains(point), let target = splitDropTarget(info, row: row) {
                pendingDrop = .split(row: row)
                insertionLine.isHidden = true
                showRowDropZone(target.zone)
                return .move
            }
        }
        showRowDropZone(nil)
        // The gap nearest the pointer (the table is flipped: y grows down).
        var gap: Int
        if row >= 0 {
            gap = point.y < tableView.rect(ofRow: row).midY ? row : row + 1
        } else {
            gap = point.y < 0 ? 0 : rows.count
        }
        // Above "New Tab" is pinned: tabs first, then Easels. Below it, the
        // same: tabs, then Easels.
        let pinnedArea = gap <= newTabRow
        if info.draggingPasteboard.availableType(from: [.wauEaselRow]) != nil {
            gap = max(gap, pinnedArea ? firstPinnedEaselRow : firstEaselRow)
        } else {
            gap = min(gap, pinnedArea ? firstPinnedEaselRow : firstEaselRow)
        }
        pendingDrop = .gap(gap)
        showInsertionLine(atGap: gap)
        return .move
    }

    private func performDrop(_ info: any NSDraggingInfo) -> Bool {
        let drop = pendingDrop
        clearDrop()
        switch drop {
        case .split(let row):
            guard let target = splitDropTarget(info, row: row), let id = draggedPaneID(info) else { return false }
            if case .tab = target.target { onTabChosen?() }
            return model.placeInSplit(id, beside: target.target.id, after: target.after)
        case .gap(let gap):
            return dropInGap(info, gap: gap)
        case nil:
            return false
        }
    }

    /// Moves the dragged tab or Easel to a gap between rows.
    private func dropInGap(_ info: any NSDraggingInfo, gap row: Int) -> Bool {
        if let value = info.draggingPasteboard.pasteboardItems?.first?.string(forType: .wauEaselRow) {
            guard let id = UUID(uuidString: value),
                  let easel = (easelsInSpace?() ?? []).first(where: { $0.id == id })
            else { return false }
            // Above "New Tab" pins it; below unpins it.
            let pinned = row <= newTabRow
            let gap = max(0, row - (pinned ? firstPinnedEaselRow : firstEaselRow))
            // Dropped among the Easels, an Easel leaves its split.
            if model.split(containing: id) != nil { model.removeFromSplit(paneID: id) }
            onMoveEasel?(easel, pinned, gap)
            return true
        }
        let space = model.currentSpace
        // Rows are [pinned…, New Tab, regular…], and a split row stands for
        // several tabs; count the tabs above the gap in the section it's in.
        let above = Set(rows[..<min(row, rows.count)].flatMap(\.tabs).map(\.id))
        let pinned = row <= newTabRow
        var gap = (pinned ? space.pinned : space.tabs).filter { above.contains($0.id) }.count
        let tab: Tab
        if let own = draggedTab(info) {
            tab = own
        } else if let id = draggedPaneID(info), let received = receiveTab?(id) {
            // From another window: it arrives at the top of the tabs, one
            // place before every gap counted above.
            tab = received
            if !pinned { gap += 1 }
        } else {
            return false
        }
        // Dropped among the rows, a pane leaves its split.
        if model.split(containing: tab) != nil { model.removeFromSplit(tab) }
        model.moveTab(tab, to: pinned ? .pinned : .regular, gap: gap)
        return true
    }

    private func showInsertionLine(atGap gap: Int) {
        guard !rows.isEmpty else { return }
        let y = gap < rows.count
            ? tableView.rect(ofRow: gap).minY
            : tableView.rect(ofRow: rows.count - 1).maxY
        insertionLine.frame = NSRect(x: 10, y: y - 1, width: tableView.bounds.width - 20, height: 2)
        insertionLine.isHidden = false
        tableView.addSubview(insertionLine, positioned: .above, relativeTo: nil)
    }

    private func clearDrop() {
        pendingDrop = nil
        rowDropHighlight.isHidden = true
        insertionLine.isHidden = true
    }

    /// The tab or Easel being dragged.
    private func draggedPaneID(_ info: any NSDraggingInfo) -> UUID? {
        info.draggingPasteboard.pasteboardItems?.first?.string(forType: .wauTab).flatMap(UUID.init(uuidString:))
    }

    private func draggedTab(_ info: any NSDraggingInfo) -> Tab? {
        let space = model.currentSpace
        guard let value = info.draggingPasteboard.pasteboardItems?.first?.string(forType: .wauTabRow),
              let id = UUID(uuidString: value)
        else { return nil }
        return (space.pinned + space.tabs).first { $0.id == id }
    }

    /// Dropping a dragged tab or Easel onto a tab or Easel row: what it
    /// would join, on which side (by the half of the row, or of the split
    /// segment, under the pointer), and that half in table coordinates.
    private func splitDropTarget(_ info: any NSDraggingInfo, row: Int) -> (target: SidebarMember, after: Bool, zone: NSRect)? {
        guard rows.indices.contains(row), let id = draggedPaneID(info),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
        else { return nil }
        let members = rows[row].members
        let point = cell.convert(info.draggingLocation, from: nil)
        var area = cell.bounds.insetBy(dx: 2, dy: 2)
        let target: SidebarMember
        if let split = cell as? SplitCellView {
            guard let index = split.segmentIndex(at: point), members.indices.contains(index) else { return nil }
            target = members[index]
            area = split.segmentFrame(at: index)
        } else if members.count == 1 {
            target = members[0]
        } else {
            return nil
        }
        guard model.canJoin(id, beside: target.id) else { return nil }
        let after = point.x >= area.midX
        var zone = area
        zone.size.width = area.width / 2
        if after { zone.origin.x = area.midX }
        return (target, after, tableView.convert(zone, from: cell))
    }

    private func showRowDropZone(_ zone: NSRect?) {
        guard let zone else {
            rowDropHighlight.isHidden = true
            return
        }
        rowDropHighlight.frame = zone
        rowDropHighlight.isHidden = false
        // Keep it above the row views the table adds as it scrolls.
        tableView.addSubview(rowDropHighlight, positioned: .above, relativeTo: nil)
    }

    @objc private func toggleSidebarClicked() {
        onToggleSidebar?()
    }

    private static func iconButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))!
        // A nil target sends the action up the responder chain to the window controller.
        let button = NSButton(image: image, target: nil, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }
}

/// A menu item that runs a closure, for menus built in code.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

/// The tab list. Where a drag would drop is worked out by the sidebar on
/// every move: the table's own drop handling asks only now and then, so the
/// side of a row a tab would take could go stale.
private final class SidebarTableView: NSTableView {
    /// Shows where a drop would go; returns the operation it allows.
    var onDragUpdate: ((any NSDraggingInfo) -> NSDragOperation)?
    var onDrop: ((any NSDraggingInfo) -> Bool)?
    var onDragExit: (() -> Void)?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDragUpdate?(sender) ?? super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDragUpdate?(sender) ?? super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExit?()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDrop?(sender) ?? super.performDragOperation(sender)
    }
}

/// A list row that doesn't light up whole when a tab is held over it: the
/// sidebar shows which half the tab would take instead.
private final class SidebarRowView: NSTableRowView {
    override var isTargetForDropOperation: Bool {
        get { false }
        set {}
    }

    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {}
}

/// The rounded field at the top of the sidebar showing the current site.
/// Clicking it opens the command bar on the current tab, to change its page.
private final class AddressPill: NSView {
    var onClick: (() -> Void)?

    init(label: NSTextField) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// One tab row: site icon (or a spinner while loading), title and close button.
private final class TabCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TabCell")

    var onClose: (() -> Void)?
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let title = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        closeButton.isBordered = false
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        for view in [icon, spinner, title, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(with tab: Tab) {
        closeButton.toolTip = "Close Tab"
        title.stringValue = tab.title
        toolTip = tab.url?.absoluteString
        icon.image = tab.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        // A favicon keeps its own colors; only the fallback globe is tinted.
        icon.contentTintColor = tab.favicon == nil ? .secondaryLabelColor : nil
        if tab.isLoading {
            icon.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            icon.isHidden = false
        }
    }

    /// An Easel in the tab list: the same row, with an Easel icon; its
    /// close button deletes the Easel (after asking).
    func configure(with easel: Easel) {
        title.stringValue = easel.title
        toolTip = nil
        spinner.stopAnimation(nil)
        icon.isHidden = false
        icon.image = NSImage(systemSymbolName: "rectangle.on.rectangle.angled", accessibilityDescription: "Easel")
        icon.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Delete Easel…"
    }

    @objc private func closeClicked() {
        onClose?()
    }
}

/// A Split View group in the list: one segment per pane, side by side, the
/// focused pane picked out. Hovering a segment shows its close button.
private final class SplitCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SplitCell")

    var onClose: ((SidebarMember) -> Void)?
    private let stack = NSStackView()
    private var segments: [SplitSegmentView] = []
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(with members: [SidebarMember], focusedID: UUID?) {
        if segments.count != members.count {
            segments.forEach { $0.removeFromSuperview() }
            segments = members.map { _ in SplitSegmentView() }
            segments.forEach { stack.addArrangedSubview($0) }
        }
        for (index, (segment, member)) in zip(segments, members).enumerated() {
            segment.configure(with: member)
            segment.isFocused = member.id == focusedID
            segment.showsDivider = index > 0
            segment.onClose = { [weak self] in self?.onClose?(member) }
        }
        updateHover(at: nil)
    }

    /// A segment's frame in this view.
    func segmentFrame(at index: Int) -> NSRect {
        convert(segments[index].bounds, from: segments[index])
    }

    /// Which segment is under a point in this view.
    func segmentIndex(at point: NSPoint) -> Int? {
        guard !segments.isEmpty, bounds.contains(point) else { return nil }
        if let index = segments.firstIndex(where: { $0.frame.minX <= point.x && point.x < $0.frame.maxX }) {
            return index
        }
        return point.x < bounds.midX ? 0 : segments.count - 1 // in a gap
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { updateHover(at: nil) }

    private func updateHover(at point: NSPoint?) {
        let hovered = point.flatMap(segmentIndex(at:))
        for (index, segment) in segments.enumerated() { segment.isHovered = index == hovered }
    }
}

/// One pane of a split row: site icon, title, and a close button on hover.
private final class SplitSegmentView: NSView {
    var onClose: (() -> Void)?
    var isFocused = false {
        didSet { needsDisplay = true }
    }
    var isHovered = false {
        didSet { closeButton.isHidden = !isHovered }
    }
    var showsDivider = false {
        didSet { needsDisplay = true }
    }

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.isBordered = false
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab"
        closeButton.isHidden = true
        for view in [icon, title, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(with member: SidebarMember) {
        switch member {
        case .tab(let tab):
            title.stringValue = tab.title
            toolTip = tab.title
            icon.image = tab.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            icon.contentTintColor = tab.favicon == nil ? .secondaryLabelColor : nil
            icon.alphaValue = tab.isLoading ? 0.4 : 1
            closeButton.toolTip = "Close Tab"
        case .easel(let easel):
            title.stringValue = easel.title
            toolTip = easel.title
            icon.image = NSImage(systemSymbolName: "rectangle.on.rectangle.angled", accessibilityDescription: "Easel")
            icon.contentTintColor = .secondaryLabelColor
            icon.alphaValue = 1
            closeButton.toolTip = "Remove from Split View"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isFocused {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        if showsDivider {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 7, width: 1, height: bounds.height - 14).fill()
        }
    }

    @objc private func closeClicked() {
        onClose?()
    }
}

/// The "+ New Tab" row, which also divides pinned tabs from the rest.
private final class NewTabCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("NewTabCell")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let divider = NSBox()
        divider.boxType = .separator
        let icon = NSImageView(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: "New Tab")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        for view in [divider, icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// An emoji button in the Space switcher; the current Space gets a backdrop.
private final class SpaceButton: NSView {
    var onClick: (() -> Void)?

    init(icon: String, isCurrent: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = isCurrent ? NSColor.labelColor.withAlphaComponent(0.14).cgColor : nil
        let label = NSTextField(labelWithString: icon)
        label.font = .systemFont(ofSize: 15)
        label.alphaValue = isCurrent ? 1 : 0.6
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Favorites: a grid of site icons shared by every Space.
private final class FavoritesView: NSView {
    var onSelect: ((Tab) -> Void)?
    var menuForTab: ((Tab) -> NSMenu?)?

    private static let columns = 4
    private static let tileHeight: CGFloat = 40
    private static let spacing: CGFloat = 6
    private var tiles: [FavoriteTile] = []
    private var count = 0

    override var intrinsicContentSize: NSSize {
        let rows = (count + Self.columns - 1) / Self.columns
        let height = rows == 0 ? 0 : CGFloat(rows) * Self.tileHeight + CGFloat(rows - 1) * Self.spacing
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    func show(_ favorites: [Tab], selectedID: UUID?) {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = favorites.map { tab in
            let tile = FavoriteTile(tab: tab, isSelected: tab.id == selectedID)
            tile.onClick = { [weak self] in self?.onSelect?(tab) }
            tile.menu = menuForTab?(tab)
            addSubview(tile)
            return tile
        }
        count = favorites.count
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = (bounds.width - CGFloat(Self.columns - 1) * Self.spacing) / CGFloat(Self.columns)
        for (index, tile) in tiles.enumerated() {
            let column = index % Self.columns
            let row = index / Self.columns
            // AppKit's y axis points up; lay rows out from the top.
            let y = bounds.height - CGFloat(row + 1) * Self.tileHeight - CGFloat(row) * Self.spacing
            tile.frame = NSRect(x: CGFloat(column) * (width + Self.spacing), y: y, width: width, height: Self.tileHeight)
        }
    }
}

private final class FavoriteTile: NSView {
    var onClick: (() -> Void)?

    init(tab: Tab, isSelected: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isSelected ? 0.2 : 0.07).cgColor
        toolTip = tab.title
        let icon = NSImageView(image: tab.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!)
        icon.contentTintColor = tab.favicon == nil ? .secondaryLabelColor : nil
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

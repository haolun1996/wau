import AppKit
import Core

private extension NSPasteboard.PasteboardType {
    /// A tab row being dragged within the sidebar; the value is its row index.
    static let wauTabRow = NSPasteboard.PasteboardType("dev.wau.tab-row")
}

/// The left column, top to bottom: navigation buttons, address pill,
/// favorites, the current Space's pinned tabs, "New Tab", its other tabs,
/// and the Space switcher.
@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onOpenLocation: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onNewSpace: (() -> Void)?
    var onEditSpace: ((Space) -> Void)?
    var onDeleteSpace: ((Space) -> Void)?
    var onSplitWith: ((Tab) -> Void)?
    /// The current Space's Easels, listed below its tabs.
    var easelsInSpace: (() -> [Easel])?
    /// The Easel shown in the page area, highlighted in the list.
    var shownEaselID: (() -> UUID?)?
    var onSelectEasel: ((Easel) -> Void)?
    var onDeleteEasel: ((Easel) -> Void)?
    /// The user picked a tab in the list (leaving any Easel that was shown).
    var onTabChosen: (() -> Void)?

    private enum Row {
        case pinned(Tab)
        case newTab
        case easelHeader
        case easel(Easel)
        case regular(Tab)

        var tab: Tab? {
            switch self {
            case .pinned(let tab), .regular(let tab): tab
            case .newTab, .easelHeader, .easel: nil
            }
        }
    }

    private let model: BrowserModel
    private var rows: [Row] = []
    private let tableView = NSTableView()
    private let addressLabel = NSTextField(labelWithString: "")
    private let favoritesView = FavoritesView()
    private let spaceTitle = NSTextField(labelWithString: "")
    private let spaceMenuButton = NSButton()
    private let spaceBar = NSStackView()
    private let backButton = SidebarViewController.iconButton("chevron.left", "Back", #selector(BrowserWindowController.goBack(_:)))
    private let forwardButton = SidebarViewController.iconButton("chevron.right", "Forward", #selector(BrowserWindowController.goForward(_:)))
    private let reloadButton = SidebarViewController.iconButton("arrow.clockwise", "Reload", #selector(BrowserWindowController.reloadPage(_:)))
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
        tableView.registerForDraggedTypes([.wauTabRow])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        // Other rows slide apart to show where the tab will land.
        tableView.draggingDestinationFeedbackStyle = .gap
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        tableView.menu = rowMenu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        spaceBar.spacing = 6

        for view in [navRow, pill, favoritesView, spaceHeader, scrollView, spaceBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
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
        rows = space.pinned.map(Row.pinned) + [.newTab] + space.tabs.map(Row.regular)
        let easels = easelsInSpace?() ?? []
        if !easels.isEmpty {
            rows += [.easelHeader] + easels.map(Row.easel)
        }
        let shownEasel = shownEaselID?()

        isSyncingSelection = true
        defer { isSyncingSelection = false }
        tableView.reloadData()
        let selectedIndex = shownEasel != nil
            ? rows.firstIndex { if case .easel(let easel) = $0 { easel.id == shownEasel } else { false } }
            : rows.firstIndex { $0.tab != nil && $0.tab?.id == space.selectedTabID }
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
        if let index = rows.firstIndex(where: { $0.tab === tab }),
           index < tableView.numberOfRows,
           let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TabCellView {
            cell.configure(with: tab)
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
        if case .easel(let easel) = rows[row] {
            menu.addItem(ClosureMenuItem("Open Easel") { [weak self] in self?.onSelectEasel?(easel) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Delete Easel…") { [weak self] in self?.onDeleteEasel?(easel) })
            return
        }
        guard let tab = rows[row].tab else { return }
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
        if rows.indices.contains(row), case .newTab = rows[row] { onNewTab?() }
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
        case .easelHeader:
            return SectionHeaderCellView(title: "Easels")
        case .easel(let easel):
            return EaselCellView(title: easel.title)
        case .pinned, .regular:
            break
        }
        guard let tab = rows[row].tab else { return nil }
        let cell = tableView.makeView(withIdentifier: TabCellView.identifier, owner: nil) as? TabCellView
            ?? TabCellView()
        cell.configure(with: tab)
        cell.isInSplit = model.split(containing: tab) != nil
        cell.onClose = { [weak self, weak tab] in
            guard let self, let tab else { return }
            model.close(tab)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .pinned, .regular, .easel: true
        case .newTab, .easelHeader: false
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .easelHeader = rows[row] { return 26 }
        return tableView.rowHeight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return }
        if case .easel(let easel) = rows[row] {
            onSelectEasel?(easel)
            return
        }
        guard let tab = rows[row].tab else { return }
        onTabChosen?()
        model.select(tab)
    }

    // MARK: Drag to reorder (and across "New Tab" to pin or unpin)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard rows[row].tab != nil else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .wauTabRow)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard (info.draggingSource as? NSTableView) === tableView else { return [] }
        // Dropping onto a row means "next to it"; tabs don't nest.
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let value = info.draggingPasteboard.pasteboardItems?.first?.string(forType: .wauTabRow),
              let source = Int(value), rows.indices.contains(source), let tab = rows[source].tab
        else { return false }
        // Rows are [pinned…, New Tab, regular…]; gaps above New Tab are pinned.
        let pinnedCount = model.currentSpace.pinned.count
        if row <= pinnedCount {
            model.moveTab(tab, to: .pinned, gap: row)
        } else {
            // Drops below the tabs (onto the Easels) land at the end of the tabs.
            model.moveTab(tab, to: .regular, gap: min(row - pinnedCount - 1, model.currentSpace.tabs.count))
        }
        return true
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

/// The rounded field at the top of the sidebar showing the current site.
/// Clicking it opens the command bar on the current tab (like ⌘L).
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
    /// Shows a small split badge for tabs that are part of a Split View.
    var isInSplit = false {
        didSet { splitBadge.isHidden = !isInSplit }
    }
    private let splitBadge = NSImageView(image: NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "In Split View")!)
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

        splitBadge.contentTintColor = .tertiaryLabelColor
        splitBadge.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        splitBadge.isHidden = true

        for view in [icon, spinner, title, splitBadge, closeButton] as [NSView] {
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
            title.trailingAnchor.constraint(lessThanOrEqualTo: splitBadge.leadingAnchor, constant: -4),
            splitBadge.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            splitBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(with tab: Tab) {
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

/// A small heading row, e.g. "Easels".
private final class SectionHeaderCellView: NSTableCellView {
    init(title: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// An Easel in the sidebar list.
private final class EaselCellView: NSTableCellView {
    init(title: String) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "rectangle.on.rectangle.angled", accessibilityDescription: "Easel")!)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

import AppKit
import Core
import OSLog
import Storage
import WebKit

/// One browser window: sidebar on the left, the page card filling the rest,
/// and the command bar floating above both when open. It shows one Space at
/// a time. Command bar and Space features live in extensions in other files.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    static let defaultSidebarWidth: CGFloat = 240
    static let sidebarWidthRange: ClosedRange<CGFloat> = 200...420
    /// The page keeps at least this much room when the sidebar is widened.
    private static let minimumPageWidth: CGFloat = 360
    private static let sidebarWidthDefaultsKey = "WauSidebarWidth"
    static let inset: CGFloat = 8
    static let homeURL = URL(string: "https://www.google.com")!
    static let logger = Logger(subsystem: "dev.wau.Wau", category: "Window")
    /// Pre-Spaces builds stored one theme for the window here.
    private static let legacyThemeDefaultsKey = "WauThemeID"

    let model = BrowserModel()
    let database: AppDatabase
    let favicons: FaviconService
    var searchEngine: SearchEngine { Preferences.shared.searchEngine }
    /// Called after Spaces, tabs or the selection change (used to schedule a sync).
    var onModelChange: (() -> Void)?
    private let saver: SessionSaver
    private let history: HistoryRecorder
    let sidebar: SidebarViewController
    let content = WebContentView()
    let easels: EaselStore
    let easelCanvas: EaselCanvasView
    /// The Easel shown in the page area instead of tabs, if any.
    var shownEaselID: UUID?
    /// Canvases for Easels shown as panes of a split, by Easel.
    var paneCanvases: [UUID: EaselCanvasView] = [:]
    var captureOverlay: CaptureOverlayView?
    var findBar: FindBarView?
    private var titlebarDoubleClick: TitlebarDoubleClick?
    /// The tab selected at the last update, to notice when the user moves on from an Easel.
    private var lastSelectedTabID: UUID?
    let background = NSVisualEffectView()
    private let backdrop = ThemeBackdropView()
    private var sidebarLeading: NSLayoutConstraint!
    private var contentLeading: NSLayoutConstraint!
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private let sidebarResizeHandle = SidebarResizeHandle()
    private(set) var isSidebarVisible = true
    var commandBar: CommandBarView?
    var swipeMonitor: Any?
    var swipeDistance: CGFloat = 0
    var archiveTask: Task<Void, Never>?
    var archiveObservers: [NSObjectProtocol] = []

    init(database: AppDatabase, favicons: FaviconService, easels: EaselStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Without this the green button only zooms; with it, it enters full screen.
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 640, height: 420)
        self.database = database
        self.favicons = favicons
        self.easels = easels
        easelCanvas = EaselCanvasView(store: easels)
        saver = SessionSaver(database: database, snapshot: { [model] in model.snapshot })
        history = HistoryRecorder(database: database)
        sidebar = SidebarViewController(model: model)
        super.init(window: window)

        window.delegate = self
        model.easelIDs = { [easels] spaceID in Set(easels.easels(in: spaceID).map(\.id)) }
        buildLayout(in: window)
        bindModel()
        bindEasels()
        installSpaceSwipe()
        titlebarDoubleClick = TitlebarDoubleClick(window: window)
        startArchiving()
        applyTheme(model.currentSpace.theme)
        if !window.setFrameUsingName("BrowserWindow") { window.center() }
        window.setFrameAutosaveName("BrowserWindow")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Brings back the Spaces and tabs from last time, or opens the home page.
    func restoreSession() {
        var snapshot: BrowserSnapshot
        do {
            snapshot = try database.loadBrowser()
        } catch {
            Self.logger.error("Loading the saved session failed: \(error)")
            snapshot = BrowserSnapshot()
        }
        // The theme chosen before Spaces existed carries over to the first Space.
        if let legacyTheme = UserDefaults.standard.string(forKey: Self.legacyThemeDefaultsKey) {
            if snapshot.spaces.count == 1 { snapshot.spaces[0].themeID = legacyTheme }
            UserDefaults.standard.removeObject(forKey: Self.legacyThemeDefaultsKey)
        }
        model.restore(snapshot)
        for tab in model.allTabs {
            tab.favicon = favicons.cachedIcon(for: tab.url)
        }
        if model.allTabs.isEmpty {
            model.open(url: Self.homeURL)
        }
        // Catch up on tabs that went stale while Wau was closed.
        archiveStaleTabs()
    }

    /// Applies Spaces and tabs that arrived through sync. Returns separate
    /// profiles of Spaces that were deleted elsewhere.
    func applySyncedState(_ snapshot: BrowserSnapshot) -> [UUID] {
        let removed = model.reconcile(with: snapshot)
        for tab in model.allTabs where tab.favicon == nil {
            tab.favicon = favicons.cachedIcon(for: tab.pinnedURL ?? tab.url)
        }
        return removed
    }

    /// Records a visit for a page shown outside this window (Little Wau).
    func recordVisit(_ tab: Tab) {
        history.pageLoaded(tab)
    }

    /// Writes the session now instead of after the usual short delay.
    func saveSessionNow() {
        saver.saveNow()
    }

    // MARK: Layout

    private func buildLayout(in window: NSWindow) {
        // The whole window is a frosted background; the page card sits on it.
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        window.contentView = background

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.onAppearanceChange = { [weak self] in self?.updateSidebarAppearance() }
        background.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: background.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        let sidebarView = sidebar.view
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        easelCanvas.translatesAutoresizingMaskIntoConstraints = false
        easelCanvas.isHidden = true
        background.addSubview(sidebarView)
        background.addSubview(content)
        background.addSubview(easelCanvas)
        // Above the page so it wins the clicks along the shared edge.
        sidebarResizeHandle.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(sidebarResizeHandle)

        let savedWidth = UserDefaults.standard.double(forKey: Self.sidebarWidthDefaultsKey)
        let width = savedWidth > 0 ? CGFloat(savedWidth) : Self.defaultSidebarWidth
        sidebarWidthConstraint = sidebarView.widthAnchor.constraint(
            equalToConstant: min(max(width, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound)
        )
        sidebarLeading = sidebarView.leadingAnchor.constraint(equalTo: background.leadingAnchor)
        contentLeading = content.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor)
        NSLayoutConstraint.activate([
            sidebarLeading,
            sidebarView.topAnchor.constraint(equalTo: background.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            sidebarWidthConstraint,

            sidebarResizeHandle.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -5),
            sidebarResizeHandle.widthAnchor.constraint(equalToConstant: 8),
            sidebarResizeHandle.topAnchor.constraint(equalTo: content.topAnchor),
            sidebarResizeHandle.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            contentLeading,
            content.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.inset),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.inset),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Self.inset),

            easelCanvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            easelCanvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            easelCanvas.topAnchor.constraint(equalTo: content.topAnchor),
            easelCanvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        sidebar.onNewTab = { [weak self] in self?.newTab(nil) }
        sidebar.onToggleSidebar = { [weak self] in self?.toggleBrowserSidebar(nil) }
        sidebar.onSplitWith = { [weak self] tab in self?.model.addToSplit(tab) }
        sidebar.easelsInSpace = { [weak self] in
            guard let self else { return [] }
            return easels.easels(in: model.currentSpaceID)
        }
        sidebar.shownEaselID = { [weak self] in self?.shownEaselID }
        sidebar.onSelectEasel = { [weak self] easel in self?.showEasel(easel.id) }
        sidebar.onDeleteEasel = { [weak self] easel in self?.confirmDelete(easel) }
        sidebar.onRenameEasel = { [weak self] easel in self?.rename(easel) }
        sidebar.onMoveEasel = { [weak self] easel, gap in self?.easels.move(easel.id, toGap: gap) }
        sidebar.onTabChosen = { [weak self] in self?.hideEasel() }
        content.onFocusPane = { [weak self] index in
            guard let self else { return }
            let panes = model.visiblePanes
            guard panes.indices.contains(index) else { return }
            switch panes[index] {
            case .tab(let tab): model.select(tab)
            case .easel(let id): model.focusEasel(id)
            }
        }
        sidebar.onTabDrag = { [weak self] dragging in self?.content.isTabDragActive = dragging }
        content.canDropTab = { [weak self] id, pane, _ in
            guard let self, let target = paneID(at: pane) else { return false }
            return model.canPlace(id, beside: target)
        }
        content.onDropTab = { [weak self] id, pane, after in
            guard let self, let target = paneID(at: pane) else { return false }
            return model.placeInSplit(id, beside: target, after: after)
        }
        content.onFractionsChanged = { [weak self] fractions in
            guard let self, let group = model.visibleSplit else { return }
            model.setSplitFractions(fractions, for: group.id)
        }
        sidebar.onOpenLocation = { [weak self] in self?.openLocation(nil) }
        sidebar.onNewSpace = { [weak self] in self?.newSpace(nil) }
        sidebar.onEditSpace = { [weak self] space in self?.presentSpaceEditor(for: space) }
        sidebar.onDeleteSpace = { [weak self] space in self?.confirmDelete(space) }

        sidebarResizeHandle.currentWidth = { [weak self] in self?.sidebarWidthConstraint.constant ?? 0 }
        sidebarResizeHandle.onResize = { [weak self] width in self?.setSidebarWidth(width) }
        sidebarResizeHandle.onResizeEnded = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(sidebarWidthConstraint.constant), forKey: Self.sidebarWidthDefaultsKey)
        }
    }

    /// Clamped so the sidebar stays usable and the page keeps some room.
    /// The tab or Easel shown in the pane at `index`.
    private func paneID(at index: Int) -> UUID? {
        let panes = model.visiblePanes
        return panes.indices.contains(index) ? panes[index].id : nil
    }

    private func setSidebarWidth(_ width: CGFloat) {
        let windowWidth = window?.frame.width ?? .greatestFiniteMagnitude
        let upper = max(Self.sidebarWidthRange.lowerBound, min(Self.sidebarWidthRange.upperBound, windowWidth - Self.minimumPageWidth))
        sidebarWidthConstraint.constant = min(max(width, Self.sidebarWidthRange.lowerBound), upper)
    }

    private func bindModel() {
        model.onChange = { [weak self] in
            self?.modelDidChange()
            self?.saver.setNeedsSave()
            self?.onModelChange?()
        }
        model.onLayoutChange = { [weak self] in self?.saver.setNeedsSave() }
        model.onTabUpdated = { [weak self] tab in
            guard let self else { return }
            sidebar.refresh(tab)
            if tab === model.selected { window?.title = tab.title }
            history.tabChanged(tab)
            saver.setNeedsSave()
        }
        model.onTabFinishedLoading = { [weak self] tab in
            self?.history.pageLoaded(tab)
            self?.favicons.refresh(tab) { [weak self] host, icon in
                guard let self else { return }
                for tab in model.allTabs where FaviconService.host(of: tab.url) == host {
                    tab.favicon = icon
                }
            }
        }
    }

    private func modelDidChange() {
        if findBar != nil, model.selected?.id != lastSelectedTabID { closeFindBar() }
        // Moving to another tab or Space leaves the Easel.
        let selectedID = model.selected?.id
        if selectedID != lastSelectedTabID
            || shownEaselID.flatMap({ easels.easel(withID: $0)?.spaceID }) != model.currentSpaceID {
            if shownEaselID != nil { hideEasel() }
        }
        // An Easel that joined a split shows as its pane instead.
        if let shown = shownEaselID, model.split(containing: shown) != nil { hideEasel() }
        lastSelectedTabID = selectedID
        sidebar.reloadTabs()
        if backdrop.theme != model.currentSpace.theme {
            applyTheme(model.currentSpace.theme)
        }
        let selected = model.selected
        let panes = model.visiblePanes
        let split = model.visibleSplit
        content.display(
            panes.map(view(for:)),
            focused: panes.firstIndex { $0.id == model.focusedPaneID } ?? 0,
            axis: split?.axis ?? .horizontal,
            fractions: split?.fractions ?? []
        )
        // Canvases for Easels no longer in a split on screen can go.
        let shownEasels = Set(panes.compactMap { if case .easel(let id) = $0 { id } else { nil } })
        paneCanvases = paneCanvases.filter { shownEasels.contains($0.key) }
        if shownEaselID != nil { return }
        if let canvas = focusedPaneCanvas {
            window?.title = canvas.easelID.flatMap { easels.easel(withID: $0)?.title } ?? "Easel"
            if commandBar == nil, captureOverlay == nil { canvas.focusCanvas() }
            return
        }
        window?.title = selected?.title ?? model.currentSpace.name
        if commandBar == nil, captureOverlay == nil, let webView = selected?.webView {
            window?.makeFirstResponder(webView)
        }
    }

    /// The view for a pane: a tab's page, or a canvas for an Easel.
    private func view(for pane: SplitPane) -> NSView {
        switch pane {
        case .tab(let tab):
            tab.activateIfNeeded()
            return tab.webView
        case .easel(let id):
            if let canvas = paneCanvases[id] { return canvas }
            let canvas = makeEaselCanvas()
            if let easel = easels.easel(withID: id) { canvas.show(easel) }
            paneCanvases[id] = canvas
            return canvas
        }
    }

    /// The canvas of the focused pane, when that's an Easel in a split.
    var focusedPaneCanvas: EaselCanvasView? {
        guard shownEaselID == nil, let id = model.currentSpace.focusedEaselID else { return nil }
        return paneCanvases[id]
    }

    /// The canvas the zoom commands act on: the Easel shown on its own, or
    /// the focused Easel pane.
    var activeEaselCanvas: EaselCanvasView? {
        shownEaselID != nil ? easelCanvas : focusedPaneCanvas
    }

    // MARK: Actions (reached through the responder chain from menus and buttons)

    @objc func newTab(_ sender: Any?) {
        if commandBar != nil {
            dismissCommandBar()
        } else {
            showCommandBar(mode: .newTab, query: "")
        }
    }

    @objc func openLocation(_ sender: Any?) {
        guard let tab = model.selected else {
            showCommandBar(mode: .newTab, query: "")
            return
        }
        showCommandBar(mode: .currentTab, query: tab.url?.absoluteString ?? "")
    }

    @objc func closeTab(_ sender: Any?) {
        if commandBar != nil {
            dismissCommandBar()
        } else if let easel = focusedPaneCanvas?.easelID {
            // A focused Easel pane leaves the split; the Easel itself stays.
            model.removeFromSplit(paneID: easel)
        } else if let tab = model.selected {
            model.close(tab)
        } else {
            window?.performClose(nil)
        }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let tab = model.reopenClosedTab() else { NSSound.beep(); return }
        tab.favicon = favicons.cachedIcon(for: tab.url)
    }

    // MARK: Split View

    /// Opens the command bar to choose a page or tab for a new pane.
    @objc func addSplitView(_ sender: Any?) {
        guard let selected = model.selected, !model.isFavorite(selected) else { NSSound.beep(); return }
        if model.visibleSplit?.isFull == true { NSSound.beep(); return }
        showCommandBar(mode: .split, query: "")
    }

    @objc func removeFromSplitView(_ sender: Any?) {
        guard let focused = model.focusedPaneID, model.visibleSplit != nil else { NSSound.beep(); return }
        model.removeFromSplit(paneID: focused)
    }

    @objc func rotateSplitView(_ sender: Any?) {
        model.toggleSplitAxis()
    }

    @objc func togglePinned(_ sender: Any?) {
        guard let tab = model.selected, !model.isFavorite(tab) else { NSSound.beep(); return }
        model.setPinned(tab, !model.isPinned(tab))
    }

    @objc func copyPageLink(_ sender: Any?) {
        guard let url = model.selected?.url else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc func clearHistory(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear all browsing history?"
        alert.informativeText = "Wau will forget every page you've visited. Open tabs, logins and site data are not affected."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try database.clearHistory()
            } catch {
                Self.logger.error("Clearing history failed: \(error)")
            }
        }
    }

    @objc func goBack(_ sender: Any?) {
        model.selected?.webView.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        model.selected?.webView.goForward()
    }

    @objc func reloadPage(_ sender: Any?) {
        model.selected?.webView.reload()
    }

    @objc func toggleBrowserSidebar(_ sender: Any?) {
        isSidebarVisible.toggle()
        let visible = isSidebarVisible
        // When the sidebar slides out the traffic lights would float over
        // the page, so hide them with it.
        if visible { setTrafficLightsHidden(false) }
        sidebarResizeHandle.isHidden = !visible
        let width = sidebarWidthConstraint.constant
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            sidebarLeading.animator().constant = visible ? 0 : -width
            contentLeading.animator().constant = visible ? 0 : Self.inset
            background.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if !visible { self?.setTrafficLightsHidden(true) }
            }
        }
    }

    /// Menu: View ▸ Theme ▸ <name>. Sets the current Space's theme; the
    /// item's `representedObject` is the theme ID.
    @objc func selectTheme(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? String,
              let theme = SpaceTheme.theme(withID: id)
        else { return }
        setTheme(theme)
    }

    func setTheme(_ theme: SpaceTheme) {
        let space = model.currentSpace
        model.updateSpace(space, name: space.name, icon: space.icon, themeID: theme.id)
    }

    // MARK: Theme

    private func applyTheme(_ theme: SpaceTheme) {
        backdrop.theme = theme
        content.progressColor = NSColor(theme.accent)
        updateSidebarAppearance()
    }

    /// Dark themes get light sidebar text, light themes get dark text.
    private func updateSidebarAppearance() {
        sidebar.view.appearance = NSAppearance(named: backdrop.needsLightText ? .darkAqua : .aqua)
    }

    private func setTrafficLightsHidden(_ hidden: Bool) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(button)?.isHidden = hidden
        }
    }

    func windowWillClose(_ notification: Notification) {
        titlebarDoubleClick?.invalidate()
        removeSpaceSwipe()
        stopArchiving()
    }
}

extension BrowserWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let selected = model.selected
        switch menuItem.action {
        case #selector(goBack(_:)):
            return selected?.canGoBack ?? false
        case #selector(goForward(_:)):
            return selected?.canGoForward ?? false
        case #selector(reloadPage(_:)):
            return selected != nil
        case #selector(reopenClosedTab(_:)):
            return !model.recentlyClosed.isEmpty
        case #selector(copyPageLink(_:)):
            return selected?.url != nil
        case #selector(togglePinned(_:)):
            menuItem.title = selected.map(model.isPinned) == true ? "Unpin Tab" : "Pin Tab"
            return selected.map { !model.isFavorite($0) } ?? false
        case #selector(toggleBrowserSidebar(_:)):
            menuItem.title = isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            return true
        case #selector(selectTheme(_:)):
            menuItem.state = (menuItem.representedObject as? String) == model.currentSpace.themeID ? .on : .off
            return true
        case #selector(switchToSpaceNumber(_:)):
            let index = menuItem.tag - 1
            guard model.spaces.indices.contains(index) else {
                menuItem.isHidden = true
                return false
            }
            let space = model.spaces[index]
            menuItem.isHidden = false
            menuItem.title = "\(space.icon)  \(space.name)"
            menuItem.state = space.id == model.currentSpaceID ? .on : .off
            return true
        case #selector(nextSpace(_:)), #selector(previousSpace(_:)):
            return model.spaces.count > 1
        case #selector(deleteSpace(_:)):
            return model.spaces.count > 1
        case #selector(findInPage(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)):
            return selected != nil && activeEaselCanvas == nil
        case #selector(zoomInPage(_:)), #selector(zoomOutPage(_:)), #selector(actualSizePage(_:)):
            // On an Easel these zoom the canvas.
            return selected != nil || activeEaselCanvas != nil
        case #selector(selectTabNumber(_:)):
            return !(model.currentSpace.pinned + model.currentSpace.tabs).isEmpty
        case #selector(captureToEasel(_:)):
            return !model.visibleTabs.isEmpty && captureOverlay == nil
        case #selector(addPageToEasel(_:)):
            return selected?.url != nil
        case #selector(addSplitView(_:)):
            return selected.map { !model.isFavorite($0) } == true && model.visibleSplit?.isFull != true
        case #selector(removeFromSplitView(_:)), #selector(rotateSplitView(_:)):
            return model.visibleSplit != nil
        default:
            return true
        }
    }
}

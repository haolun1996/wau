import AppKit
import OSLog
import Storage

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "dev.wau.Wau", category: "App")

    /// The main window (first), whose tabs are saved and synced.
    private var windowControllers: [BrowserWindowController] = []
    /// Blank and incognito windows, which aren't kept.
    private var extraWindows: [BrowserWindowController] = []
    private var database: AppDatabase!
    private var favicons: FaviconService!
    private var easels: EaselStore!
    private var sync: SyncCoordinator!
    private var settingsWindow: SettingsWindowController?
    private var littleWauWindows: [LittleWauWindowController] = []
    /// Links that arrived before the main window was ready.
    private var pendingURLs: [URL] = []
    private lazy var archivedTabsMenu = ArchivedTabsMenu { [weak self] in self?.windowControllers.first }
    private let downloadsMenu = DownloadsMenu()

    /// Unit tests run inside the app; they must not touch the real database or open windows.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        database = Self.openDatabase()
        favicons = FaviconService(database: database)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        easels = EaselStore(database: database, images: ImageStore(directory: support.appendingPathComponent("Wau/EaselImages")))
        NSApp.mainMenu = MainMenu.make(archivedTabs: archivedTabsMenu, downloads: downloadsMenu)
        DownloadManager.shared.onNotice = { [weak self] message, file in
            guard let controller = self?.windowControllers.first else { return }
            controller.showToast(message, action: file.map { file in
                ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([file]) })
            })
        }

        let controller = BrowserWindowController(database: database, favicons: favicons, easels: easels)
        connect(controller)
        windowControllers.append(controller)
        controller.showWindow(nil)
        controller.restoreSession()

        sync = SyncCoordinator(database: database)
        controller.onModelChange = { [weak self] in self?.sync.setNeedsSync() }
        sync.start(with: controller)

        let early = pendingURLs
        pendingURLs = []
        if !early.isEmpty { open(early) }
        NSApp.activate()
    }

    // MARK: Links from other apps and Little Wau

    /// Links clicked in other apps (when Wau is the default browser) and
    /// HTML files opened with Wau.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !Self.isRunningTests else { return }
        guard windowControllers.first != nil else {
            pendingURLs += urls
            return
        }
        open(urls)
    }

    private func open(_ urls: [URL]) {
        for url in urls {
            let isWebLink = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            if isWebLink, Preferences.shared.openLinksInLittleWau {
                openLittleWau(url: url)
            } else {
                openInMainWindow(url)
            }
        }
    }

    private func openInMainWindow(_ url: URL) {
        guard let controller = windowControllers.first else { return }
        controller.model.open(url: url)
        controller.showWindow(nil)
        NSApp.activate()
    }

    // MARK: Blank and incognito windows

    /// ⌃⌘N: an empty window, in the current Space's colours. Its tabs go
    /// when it closes; history is still recorded.
    @objc func newBlankWindow(_ sender: Any?) {
        openExtraWindow(.blank)
    }

    /// ⇧⌘N: a private window. Nothing it does is saved: no history, and its
    /// cookies, logins and caches live only in memory until it closes.
    @objc func newIncognitoWindow(_ sender: Any?) {
        openExtraWindow(.incognito)
    }

    @discardableResult
    private func openExtraWindow(
        _ kind: BrowserWindowController.Kind, themeID: String? = nil, profileID: UUID? = nil, startEmpty: Bool = true
    ) -> BrowserWindowController? {
        guard database != nil else { return nil }
        let themeID = themeID ?? windowControllers.first?.model.currentSpace.themeID
        let controller = BrowserWindowController(
            database: database, favicons: favicons, easels: easels, kind: kind, themeID: themeID, profileID: profileID
        )
        controller.onClose = { [weak self, weak controller] in
            self?.extraWindows.removeAll { $0 === controller }
        }
        connect(controller)
        extraWindows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if startEmpty { controller.newTab(nil) }
        NSApp.activate()
        return controller
    }

    /// Lets a window's tabs be dragged out of it and into other windows.
    private func connect(_ controller: BrowserWindowController) {
        controller.onTearOff = { [weak self, weak controller] tab, point in
            guard let controller else { return }
            self?.tearOff(tab, from: controller, at: point)
        }
        controller.findTab = { [weak self] id in
            guard let self else { return nil }
            for window in windowControllers + extraWindows {
                if let tab = window.model.allTabs.first(where: { $0.id == id }) { return (tab, window) }
            }
            return nil
        }
        // Every window's pages take a dragged tab, not only its own window's.
        controller.onTabDragChanged = { [weak self] dragging in
            guard let self else { return }
            for window in windowControllers + extraWindows { window.content.isTabDragActive = dragging }
        }
    }

    /// A tab dragged out of a window onto the desktop moves to a new window
    /// there: a Blank Window, or an incognito one from an incognito window.
    /// It keeps its page, history and website data.
    private func tearOff(_ tab: Tab, from source: BrowserWindowController, at point: NSPoint) {
        let space = source.model.space(containing: tab)
        let kind: BrowserWindowController.Kind = source.kind == .incognito ? .incognito : .blank
        guard let window = openExtraWindow(kind, themeID: space?.themeID, profileID: space?.profileID, startEmpty: false)
        else { return }
        source.model.detach(tab)
        window.model.adopt(tab)
        source.closeIfEmptied() // its only tab left: the window moved, in effect
        // A bit smaller than the window it came from, its top left just
        // above and left of where the tab was let go.
        if let sourceFrame = source.window?.frame,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let frame = NSRect(
                x: 0, y: 0,
                width: max(min(sourceFrame.width * 0.8, 1280), 800),
                height: max(min(sourceFrame.height * 0.8, 860), 560)
            )
            window.window?.setContentSize(frame.size)
            var origin = NSPoint(x: point.x - 120, y: point.y + 16 - frame.height)
            origin.x = min(max(origin.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - frame.width)
            origin.y = min(max(origin.y, screen.visibleFrame.minY), screen.visibleFrame.maxY - frame.height)
            window.window?.setFrameOrigin(origin)
        }
    }

    @objc func newLittleWauWindow(_ sender: Any?) {
        openLittleWau(url: nil)
    }

    private func openLittleWau(url: URL?) {
        let little = LittleWauWindowController(url: url, favicons: favicons)
        little.onOpenInMainWindow = { [weak self] tab in
            guard let controller = self?.windowControllers.first else { return }
            controller.model.adopt(tab)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        little.onOpenTab = { [weak self] url, configuration in
            guard let controller = self?.windowControllers.first else { return nil }
            controller.showWindow(nil)
            return controller.model.open(url: url, configuration: configuration)
        }
        little.onPageLoaded = { [weak self] tab in
            self?.windowControllers.first?.recordVisit(tab)
        }
        little.onClose = { [weak self] closed in
            self?.littleWauWindows.removeAll { $0 === closed }
        }
        littleWauWindows.append(little)
        little.showWindow(nil)
        NSApp.activate()
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "A calm browser named after the wau bulan, the moon kite of Malaysia's east coast. Spaces, Split View, Easels and Little Wau, synced through your own Google Drive.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(sync: sync, preferences: .shared)
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowControllers.forEach { $0.saveSessionNow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// `~/Library/Application Support/Wau/wau.sqlite`. If it can't be opened,
    /// the app still runs, but nothing is saved.
    private static func openDatabase() -> AppDatabase {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            return try AppDatabase.open(at: support.appendingPathComponent("Wau/wau.sqlite"))
        } catch {
            logger.fault("Opening the database failed, running without saving: \(error)")
            // In-memory databases only fail if SQLite itself is unusable.
            return try! AppDatabase.inMemory()
        }
    }
}

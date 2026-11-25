import AppKit
import Core

/// Auto-archiving: stale ordinary tabs leave the sidebar but stay findable.
extension BrowserWindowController {
    /// Checks every minute, and right away when the app becomes active or
    /// the Mac wakes (a closed lid can skip many checks at once).
    func startArchiving() {
        archiveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.archiveStaleTabs()
            }
        }
        let center = NotificationCenter.default
        archiveObservers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.archiveStaleTabs() }
            },
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.archiveStaleTabs() }
            },
        ]
    }

    func stopArchiving() {
        archiveTask?.cancel()
        archiveTask = nil
        for observer in archiveObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        archiveObservers = []
    }

    func archiveStaleTabs() {
        let archived = model.archiveStaleTabs()
        guard !archived.isEmpty else { return }
        Task {
            do {
                try await database.archive(archived)
            } catch {
                Self.logger.error("Archiving tabs failed: \(error)")
            }
        }
    }

    /// Brings an archived tab back, with its history, into its Space.
    func restoreArchived(_ archived: ArchivedTab) {
        let tab = model.restoreArchived(archived.record)
        tab.favicon = favicons.cachedIcon(for: tab.url)
        do {
            try database.unarchive(id: archived.id)
        } catch {
            Self.logger.error("Removing a tab from the archive failed: \(error)")
        }
    }

    @objc func clearArchive(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear all archived tabs?"
        alert.informativeText = "Archived tabs can no longer be brought back. Your history is not affected."
        alert.addButton(withTitle: "Clear Archive")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try database.clearArchive()
            } catch {
                Self.logger.error("Clearing the archive failed: \(error)")
            }
        }
    }
}

/// History ▸ Archived Tabs: the most recently archived tabs, rebuilt each
/// time the menu opens.
@MainActor
final class ArchivedTabsMenu: NSObject, NSMenuDelegate {
    private let window: () -> BrowserWindowController?

    init(window: @escaping () -> BrowserWindowController?) {
        self.window = window
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller = window() else { return }
        let archived = (try? controller.database.recentArchivedTabs(limit: 20)) ?? []
        if archived.isEmpty {
            let empty = NSMenuItem(title: "No Archived Tabs", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        for tab in archived {
            let title = tab.record.title.isEmpty ? (tab.record.url?.absoluteString ?? "Untitled") : tab.record.title
            let item = ClosureMenuItem(title) { [weak controller] in controller?.restoreArchived(tab) }
            item.image = controller.favicons.cachedIcon(for: tab.record.url)
            item.toolTip = "Archived \(formatter.localizedString(for: tab.archivedAt, relativeTo: Date()))"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Clear Archive…", action: #selector(BrowserWindowController.clearArchive(_:)), keyEquivalent: ""))
    }
}

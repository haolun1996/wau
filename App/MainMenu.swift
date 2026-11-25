import AppKit
import Core

/// The menu bar. Browser shortcuts live here as menu key equivalents, so
/// they work even while a web page has keyboard focus.
@MainActor
enum MainMenu {
    static func make(archivedTabs: NSMenuDelegate, downloads: NSMenuDelegate) -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let menu = NSMenu()

        menu.addItem(submenu(appName, [
            item("About \(appName)", #selector(AppDelegate.showAbout(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        menu.addItem(submenu("File", [
            item("New Tab", #selector(BrowserWindowController.newTab(_:)), "t"),
            item("New Little Wau Window", #selector(AppDelegate.newLittleWauWindow(_:)), "n", [.command, .option]),
            item("Open in Wau", #selector(LittleWauWindowController.openInMainWindow(_:)), "o"),
            item("Open Location…", #selector(BrowserWindowController.openLocation(_:)), "l"),
            .separator(),
            item("Close Tab", #selector(BrowserWindowController.closeTab(_:)), "w"),
            item("Reopen Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "t", [.command, .shift]),
            .separator(),
            item("Pin Tab", #selector(BrowserWindowController.togglePinned(_:)), "d"),
            item("Copy Page Link", #selector(BrowserWindowController.copyPageLink(_:)), "c", [.command, .shift]),
            .separator(),
            item("New Easel", #selector(BrowserWindowController.newEasel(_:))),
            item("Capture to Easel", #selector(BrowserWindowController.captureToEasel(_:)), "2", [.command, .shift]),
            item("Add Page to Easel", #selector(BrowserWindowController.addPageToEasel(_:))),
        ]))

        menu.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find in Page…", #selector(BrowserWindowController.findInPage(_:)), "f"),
            item("Find Next", #selector(BrowserWindowController.findNext(_:)), "g"),
            item("Find Previous", #selector(BrowserWindowController.findPrevious(_:)), "g", [.command, .shift]),
        ]))

        menu.addItem(submenu("View", [
            item("Hide Sidebar", #selector(BrowserWindowController.toggleBrowserSidebar(_:)), "s"),
            submenu("Theme", SpaceTheme.all.map(themeItem)),
            .separator(),
            item("Split View with New Tab…", #selector(BrowserWindowController.addSplitView(_:)), "=", [.control, .shift]),
            item("Remove Tab from Split View", #selector(BrowserWindowController.removeFromSplitView(_:)), "-", [.control, .shift]),
            item("Rotate Split View", #selector(BrowserWindowController.rotateSplitView(_:))),
            .separator(),
            item("Reload Page", #selector(BrowserWindowController.reloadPage(_:)), "r"),
            .separator(),
            item("Actual Size", #selector(BrowserWindowController.actualSizePage(_:)), "0"),
            item("Zoom In", #selector(BrowserWindowController.zoomInPage(_:)), "="),
            item("Zoom Out", #selector(BrowserWindowController.zoomOutPage(_:)), "-"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        menu.addItem(submenu("History", [
            item("Back", #selector(BrowserWindowController.goBack(_:)), "["),
            item("Forward", #selector(BrowserWindowController.goForward(_:)), "]"),
            .separator(),
            {
                let archive = NSMenuItem(title: "Archived Tabs", action: nil, keyEquivalent: "")
                archive.submenu = NSMenu(title: "Archived Tabs")
                archive.submenu?.delegate = archivedTabs
                return archive
            }(),
            .separator(),
            item("Clear History…", #selector(BrowserWindowController.clearHistory(_:))),
        ]))

        var spaceItems: [NSMenuItem] = [
            item("New Space…", #selector(BrowserWindowController.newSpace(_:))),
            item("Edit Space…", #selector(BrowserWindowController.editSpace(_:))),
            item("Delete Space…", #selector(BrowserWindowController.deleteSpace(_:))),
            .separator(),
            item("Next Space", #selector(BrowserWindowController.nextSpace(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]),
            item("Previous Space", #selector(BrowserWindowController.previousSpace(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option]),
            .separator(),
        ]
        // Titled with each Space's name when the menu is shown; unused ones hide.
        for number in 1...9 {
            let spaceItem = item("Space \(number)", #selector(BrowserWindowController.switchToSpaceNumber(_:)), "\(number)", .control)
            spaceItem.tag = number
            spaceItems.append(spaceItem)
        }
        menu.addItem(submenu("Spaces", spaceItems))

        var tabItems: [NSMenuItem] = [
            item("Next Tab", #selector(BrowserWindowController.nextTab(_:)), "\t", .control),
            item("Previous Tab", #selector(BrowserWindowController.previousTab(_:)), "\t", [.control, .shift]),
            .separator(),
        ]
        for number in 1...9 {
            let tabItem = item(number == 9 ? "Last Tab" : "Tab \(number)", #selector(BrowserWindowController.selectTabNumber(_:)), "\(number)")
            tabItem.tag = number
            tabItems.append(tabItem)
        }
        menu.addItem(submenu("Tabs", tabItems))

        let windowMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            {
                let item = NSMenuItem(title: "Downloads", action: nil, keyEquivalent: "")
                item.submenu = NSMenu(title: "Downloads")
                item.submenu?.delegate = downloads
                return item
            }(),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        menu.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu

        return menu
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        items.forEach(submenu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func themeItem(_ theme: SpaceTheme) -> NSMenuItem {
        let item = item(theme.name, #selector(BrowserWindowController.selectTheme(_:)))
        item.representedObject = theme.id
        item.image = theme.swatch()
        item.toolTip = theme.inspiration
        return item
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

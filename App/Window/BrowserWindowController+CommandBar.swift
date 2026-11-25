import AppKit
import Core

/// The command bar: showing it, what it suggests, and acting on the choice.
extension BrowserWindowController {
    func showCommandBar(mode: CommandBarView.Mode, query: String) {
        dismissCommandBar()
        let bar = CommandBarView(
            mode: mode,
            accent: NSColor(model.currentSpace.theme.accent),
            suggestions: { [weak self] query in self?.suggestions(for: query) ?? [] },
            iconForURL: { [weak self] url in self?.favicons.cachedIcon(for: url) }
        )
        bar.onCommit = { [weak self] item in self?.commit(item, mode: mode) }
        bar.onDismiss = { [weak self] in self?.dismissCommandBar() }
        bar.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(bar) // added last, so it sits above the page
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            bar.topAnchor.constraint(equalTo: background.topAnchor),
            bar.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        commandBar = bar
        bar.activate(query: query)
    }

    func dismissCommandBar() {
        guard let bar = commandBar else { return }
        commandBar = nil
        bar.removeFromSuperview()
        if let webView = model.selected?.webView {
            window?.makeFirstResponder(webView)
        }
    }

    private func commit(_ item: CommandBarView.Item, mode: CommandBarView.Mode) {
        dismissCommandBar()
        let destination: URL
        switch item {
        case .open(let url), .search(_, let url, _):
            destination = url
        case .history(let entry):
            destination = entry.url
        case .switchTab(let tab):
            if mode == .split, model.canSplit(tab) {
                model.addToSplit(tab)
            } else {
                model.select(tab)
            }
            return
        case .archived(let archived):
            restoreArchived(archived)
            return
        case .command(let command):
            command.run()
            return
        }
        switch mode {
        case .currentTab:
            if let tab = model.selected {
                tab.load(destination)
                window?.makeFirstResponder(tab.webView)
            } else {
                model.open(url: destination)
            }
        case .split:
            let tab = model.open(url: destination, select: false)
            if !model.addToSplit(tab) { model.select(tab) }
        case .newTab:
            model.open(url: destination)
        }
    }

    /// Command bar results for `rawQuery`: what was typed (as an address or
    /// search), then matching commands, open tabs and history.
    private func suggestions(for rawQuery: String) -> [CommandBarView.Item] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let space = model.currentSpace
        guard !query.isEmpty else {
            return (space.pinned + space.tabs).prefix(8).map(CommandBarView.Item.switchTab)
        }
        let needle = query.lowercased()

        var typed: CommandBarView.Item?
        switch URLInput.destination(for: query, searchEngine: searchEngine) {
        case .url(let url): typed = .open(url)
        case .search(let text, let url): typed = .search(query: text, url: url, engineName: searchEngine.name)
        case nil: break
        }

        let commands = availableCommands()
            .compactMap { command in command.score(for: query).map { (command, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map { CommandBarView.Item.command($0.0) }

        // Tabs in every Space; choosing one in another Space switches to it.
        let matchingTabs = model.allTabs.filter { tab in
            tab.title.lowercased().contains(needle)
                || (tab.url?.absoluteString.lowercased().contains(needle) ?? false)
        }
        let tabs = matchingTabs.prefix(4).map(CommandBarView.Item.switchTab)

        let openURLs = Set(model.allTabs.compactMap(\.url))
        let tokens = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        let candidates = (try? database.historyCandidates(matching: tokens)) ?? []
        let ranked = HistoryRanking.rank(candidates, query: query).filter { !openURLs.contains($0.url) }
        var historyItems = ranked.prefix(6).map(CommandBarView.Item.history)
        let archived = ((try? database.archivedTabs(matching: tokens, limit: 10)) ?? [])
            .filter { tab in !openURLs.contains { $0 == tab.record.url } }
            .prefix(3)
            .map(CommandBarView.Item.archived)

        // When the best history match starts with what's typed (e.g. "git"
        // → github.com), it is almost certainly where the user wants to go.
        var results: [CommandBarView.Item] = []
        if let best = ranked.first, HistoryRanking.displayAddress(best.url).hasPrefix(needle) {
            results.append(historyItems.removeFirst())
        }
        if let typed { results.append(typed) }
        return results + commands + tabs + archived + historyItems
    }

    /// Everything the command bar can do, beyond opening pages.
    private func availableCommands() -> [BrowserCommand] {
        let selected = model.selected
        var commands = [
            BrowserCommand(title: "Close Tab", symbol: "xmark.square", shortcut: "⌘W", keywords: ["remove"]) { [weak self] in
                self?.closeTab(nil)
            },
            BrowserCommand(title: "Reopen Closed Tab", symbol: "arrow.uturn.backward", shortcut: "⇧⌘T", keywords: ["undo close", "restore"]) { [weak self] in
                self?.reopenClosedTab(nil)
            },
            BrowserCommand(title: "Reload Page", symbol: "arrow.clockwise", shortcut: "⌘R", keywords: ["refresh"]) { [weak self] in
                self?.reloadPage(nil)
            },
            BrowserCommand(title: "Copy Page Link", symbol: "link", shortcut: "⇧⌘C", keywords: ["copy url", "share"]) { [weak self] in
                self?.copyPageLink(nil)
            },
            BrowserCommand(title: isSidebarVisible ? "Hide Sidebar" : "Show Sidebar", symbol: "sidebar.left", shortcut: "⌘S", keywords: ["toggle sidebar"]) { [weak self] in
                self?.toggleBrowserSidebar(nil)
            },
            BrowserCommand(title: "Clear History…", symbol: "trash", keywords: ["delete history", "erase"]) { [weak self] in
                self?.clearHistory(nil)
            },
            BrowserCommand(title: "New Space…", symbol: "plus.square.on.square", keywords: ["create space", "workspace"]) { [weak self] in
                self?.newSpace(nil)
            },
            BrowserCommand(title: "Edit Space…", symbol: "pencil", keywords: ["rename space", "space settings"]) { [weak self] in
                self?.editSpace(nil)
            },
        ]

        if let selected, !model.isFavorite(selected) {
            if model.visibleSplit?.isFull != true {
                commands.append(BrowserCommand(title: "Split View with New Tab…", symbol: "rectangle.split.2x1", shortcut: "⌃⇧=", keywords: ["split view", "side by side"]) { [weak self] in
                    self?.addSplitView(nil)
                })
            }
            if model.visibleSplit != nil {
                commands.append(BrowserCommand(title: "Remove Tab from Split View", symbol: "rectangle", shortcut: "⌃⇧-", keywords: ["unsplit", "split view"]) { [weak self] in
                    self?.removeFromSplitView(nil)
                })
                commands.append(BrowserCommand(title: "Rotate Split View", symbol: "rectangle.split.1x2", keywords: ["split view", "stack", "vertical", "horizontal"]) { [weak self] in
                    self?.rotateSplitView(nil)
                })
            }
            let pinned = model.isPinned(selected)
            commands.append(BrowserCommand(title: pinned ? "Unpin Tab" : "Pin Tab", symbol: pinned ? "pin.slash" : "pin", shortcut: "⌘D") { [weak self] in
                self?.togglePinned(nil)
            })
            commands.append(BrowserCommand(title: "Add to Favorites", symbol: "star", keywords: ["favourite", "bookmark"]) { [weak self] in
                self?.model.setFavorite(selected, true)
            })
            for space in model.spaces where space !== model.space(containing: selected) {
                commands.append(BrowserCommand(title: "Move Tab to \(space.name)", symbol: "arrow.right.square", keywords: ["move to space", space.icon]) { [weak self] in
                    self?.model.moveTab(selected, toSpace: space)
                })
            }
        } else if let selected {
            commands.append(BrowserCommand(title: "Remove from Favorites", symbol: "star.slash", keywords: ["unfavourite"]) { [weak self] in
                self?.model.setFavorite(selected, false)
            })
        }

        commands.append(BrowserCommand(title: "New Easel", symbol: "rectangle.on.rectangle.angled", keywords: ["canvas", "board", "clippings"]) { [weak self] in
            self?.newEasel(nil)
        })
        if !model.visibleTabs.isEmpty {
            commands.append(BrowserCommand(title: "Capture to Easel", symbol: "camera.viewfinder", shortcut: "⇧⌘2", keywords: ["clip", "screenshot", "snip"]) { [weak self] in
                self?.captureToEasel(nil)
            })
        }
        if selected?.url != nil {
            commands.append(BrowserCommand(title: "Add Page to Easel", symbol: "link.badge.plus", keywords: ["save link", "clip"]) { [weak self] in
                self?.addPageToEasel(nil)
            })
        }
        for easel in easels.easels(in: model.currentSpaceID) {
            commands.append(BrowserCommand(title: "Open Easel: \(easel.title)", symbol: "rectangle.on.rectangle.angled", keywords: ["easel", "canvas"]) { [weak self] in
                self?.showEasel(easel.id)
            })
        }

        for (number, space) in model.spaces.enumerated() where space.id != model.currentSpaceID {
            commands.append(BrowserCommand(
                title: "Switch to \(space.icon) \(space.name)",
                symbol: "square.stack",
                shortcut: number < 9 ? "⌃\(number + 1)" : nil,
                keywords: ["space", "go to space"]
            ) { [weak self] in
                self?.model.switchToSpace(space)
            })
        }

        for theme in SpaceTheme.all where theme.id != model.currentSpace.themeID {
            commands.append(BrowserCommand(title: "Theme: \(theme.name)", symbol: "paintpalette", keywords: ["colour", "color", theme.inspiration]) { [weak self] in
                self?.setTheme(theme)
            })
        }
        return commands
    }
}

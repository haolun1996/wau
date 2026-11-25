import AppKit
import Core

/// The ⌘T / ⌘L launcher: a blurred panel floating over the page.
/// It covers the whole window so a click outside the panel dismisses it.
/// What it lists comes from `suggestions`, supplied by the window.
@MainActor
final class CommandBarView: NSView, NSTextFieldDelegate {
    enum Mode {
        /// ⌘T: results open in a new tab.
        case newTab
        /// ⌘L: results replace the current tab's page.
        case currentTab
        /// ⌃⇧=: results open as a new Split View pane.
        case split
    }

    enum Item {
        case open(URL)
        case search(query: String, url: URL, engineName: String)
        case switchTab(Tab)
        case history(HistoryEntry)
        case archived(ArchivedTab)
        case command(BrowserCommand)
    }

    var onCommit: ((Item) -> Void)?
    var onDismiss: (() -> Void)?

    private let mode: Mode
    private let accent: NSColor
    private let suggestions: (String) -> [Item]
    private let iconForURL: (URL?) -> NSImage?
    private let container = PanelContainer()
    private let field = NSTextField()
    private let separator = NSBox()
    private let resultsStack = NSStackView()
    private var topConstraint: NSLayoutConstraint!
    private var items: [Item] = []
    private var rows: [CommandBarRow] = []
    private var highlighted = 0

    /// - Parameters:
    ///   - accent: highlights the selected result; it comes from the theme.
    ///   - suggestions: the results for what's typed so far.
    ///   - iconForURL: a site icon for history results, if one is known.
    init(
        mode: Mode,
        accent: NSColor,
        suggestions: @escaping (String) -> [Item],
        iconForURL: @escaping (URL?) -> NSImage?
    ) {
        self.mode = mode
        self.accent = accent
        self.suggestions = suggestions
        self.iconForURL = iconForURL
        super.init(frame: .zero)
        buildViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Fills in `query`, selects it and moves keyboard focus to the field.
    func activate(query: String) {
        field.stringValue = query
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        updateResults()
    }

    private func buildViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor

        // `.withinWindow` blurs whatever is under the panel in this window,
        // including the web page.
        let panel = NSVisualEffectView()
        panel.material = .popover
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 14
        panel.layer?.cornerCurve = .continuous
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 0.5
        panel.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false

        container.wantsLayer = true
        container.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 30
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            return shadow
        }()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(panel)
        addSubview(container)

        let symbol = switch mode {
        case .newTab: "magnifyingglass"
        case .currentTab: "arrow.right.circle"
        case .split: "rectangle.split.2x1"
        }
        let searchIcon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))!)
        searchIcon.contentTintColor = .secondaryLabelColor

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.placeholderString = mode == .split
            ? "Open in Split View: search, enter URL, or pick a tab…"
            : "Search, enter URL, or type a command…"
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = self

        let fieldRow = NSStackView(views: [searchIcon, field])
        fieldRow.spacing = 10
        fieldRow.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)

        separator.boxType = .separator

        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = 2

        let body = NSStackView(views: [fieldRow, separator, resultsStack])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.edgeInsets = NSEdgeInsets(top: 14, left: 10, bottom: 10, right: 10)
        body.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(body)

        topConstraint = container.topAnchor.constraint(equalTo: topAnchor, constant: 120)
        let preferredWidth = container.widthAnchor.constraint(equalToConstant: 660)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topConstraint,
            preferredWidth,
            container.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -80),
            container.centerXAnchor.constraint(equalTo: centerXAnchor),

            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            body.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            body.topAnchor.constraint(equalTo: panel.topAnchor),
            body.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            fieldRow.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -20),
            separator.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -20),
            resultsStack.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -20),
            field.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    override func layout() {
        super.layout()
        // Sit in the upper part of the window, like Arc.
        topConstraint.constant = max(60, bounds.height * 0.16)
    }

    // MARK: Results

    private func updateResults() {
        items = suggestions(field.stringValue)
        rows.forEach { $0.removeFromSuperview() }
        rows = items.enumerated().map { index, item in
            let row = CommandBarRow(item: item, accent: accent, iconForURL: iconForURL)
            row.onClick = { [weak self] in self?.commit(index) }
            resultsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
            return row
        }
        separator.isHidden = rows.isEmpty
        resultsStack.isHidden = rows.isEmpty
        highlighted = 0
        updateHighlight()
    }

    private func updateHighlight() {
        for (index, row) in rows.enumerated() {
            row.isHighlighted = index == highlighted
        }
    }

    private func commit(_ index: Int) {
        guard items.indices.contains(index) else { return }
        onCommit?(items[index])
    }

    // MARK: Keyboard and mouse

    func controlTextDidChange(_ notification: Notification) {
        updateResults()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if !rows.isEmpty { highlighted = (highlighted + 1) % rows.count }
            updateHighlight()
        case #selector(NSResponder.moveUp(_:)):
            if !rows.isEmpty { highlighted = (highlighted - 1 + rows.count) % rows.count }
            updateHighlight()
        case #selector(NSResponder.insertNewline(_:)):
            commit(highlighted)
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss?()
        default:
            return false
        }
        return true
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// A click on the dimmed area outside the panel.
    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }
}

/// Holds the panel; swallows clicks so they don't reach the dimmed backdrop.
private final class PanelContainer: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
}

/// One result: icon, title, an optional subtitle and what Enter will do.
private final class CommandBarRow: NSView {
    var onClick: (() -> Void)?
    var isHighlighted = false {
        didSet { needsDisplay = true; applyColors() }
    }

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let accent: NSColor
    /// Site icons keep their colors; only symbols follow the text color.
    private var iconIsSymbol = true

    init(item: CommandBarView.Item, accent: NSColor, iconForURL: (URL?) -> NSImage?) {
        self.accent = accent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous

        var siteIcon: NSImage?
        let symbol: String
        switch item {
        case .open(let url):
            symbol = "globe"
            siteIcon = iconForURL(url)
            title.stringValue = url.absoluteString
            detail.stringValue = "Open"
        case .search(let query, _, let engineName):
            symbol = "magnifyingglass"
            title.stringValue = query
            detail.stringValue = "Search \(engineName)"
        case .switchTab(let tab):
            symbol = "square.on.square"
            siteIcon = tab.favicon
            title.stringValue = tab.title
            subtitle.stringValue = tab.displayHost
            detail.stringValue = "Switch to Tab"
        case .history(let entry):
            symbol = "clock"
            siteIcon = iconForURL(entry.url)
            title.stringValue = entry.title.isEmpty ? entry.url.absoluteString : entry.title
            subtitle.stringValue = HistoryRanking.displayAddress(entry.url)
            detail.stringValue = "History"
        case .archived(let archived):
            symbol = "archivebox"
            siteIcon = iconForURL(archived.record.url)
            title.stringValue = archived.record.title
            subtitle.stringValue = archived.record.url.map(HistoryRanking.displayAddress) ?? ""
            detail.stringValue = "Archived"
        case .command(let command):
            symbol = command.symbol
            title.stringValue = command.title
            detail.stringValue = command.shortcut ?? "Command"
        }
        if let siteIcon {
            icon.image = siteIcon
            iconIsSymbol = false
        } else {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }

        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        subtitle.isHidden = subtitle.stringValue.isEmpty
        detail.font = .systemFont(ofSize: 12)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = NSStackView(views: [title, subtitle])
        text.spacing = 8
        text.alignment = .firstBaseline
        for view in [icon, text, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = isHighlighted ? accent.cgColor : nil
    }

    private func applyColors() {
        title.textColor = isHighlighted ? .white : .labelColor
        subtitle.textColor = isHighlighted ? .white.withAlphaComponent(0.75) : .tertiaryLabelColor
        detail.textColor = isHighlighted ? .white.withAlphaComponent(0.8) : .secondaryLabelColor
        if iconIsSymbol {
            icon.contentTintColor = isHighlighted ? .white : .secondaryLabelColor
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

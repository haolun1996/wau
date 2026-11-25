import AppKit
import Core
import WebKit

/// Little Wau: a compact window for a quick look at one page, such as a link
/// opened from another app. "Open in Wau" moves the page into the main
/// window as a regular tab.
@MainActor
final class LittleWauWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// Moves the tab into the main window; the window then closes.
    var onOpenInMainWindow: ((Tab) -> Void)?
    /// Links the page opens in new windows go to the main window.
    var onOpenTab: ((URL?, WKWebViewConfiguration?) -> Tab?)?
    var onClose: ((LittleWauWindowController) -> Void)?
    /// A page finished loading (for history).
    var onPageLoaded: ((Tab) -> Void)?

    private let tab: Tab
    private var handedOff = false
    private let addressField = NSTextField()
    private let content = WebContentView()
    private let favicons: FaviconService
    private var titlebarDoubleClick: TitlebarDoubleClick?

    init(url: URL?, favicons: FaviconService) {
        self.favicons = favicons
        tab = Tab(configuration: WebViewConfiguration.make())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 420, height: 320)
        super.init(window: window)
        window.delegate = self
        buildLayout(in: window)
        wireTab()
        titlebarDoubleClick = TitlebarDoubleClick(window: window, height: 32)
        cascade(window)
        if let url {
            tab.load(url)
            window.makeFirstResponder(tab.webView)
        } else {
            window.makeFirstResponder(addressField)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildLayout(in window: NSWindow) {
        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        window.contentView = background

        addressField.placeholderString = "Search or enter URL"
        addressField.font = .systemFont(ofSize: 12)
        addressField.alignment = .center
        addressField.isBordered = false
        addressField.drawsBackground = false
        addressField.focusRingType = .none
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.cell?.usesSingleLineMode = true
        addressField.textColor = .secondaryLabelColor
        addressField.delegate = self

        let copyButton = Self.button("link", "Copy Link", #selector(copyLink))
        let openButton = Self.button("arrow.up.forward.app", "Open in Wau (⌘O)", #selector(openInMainWindow(_:)))
        copyButton.target = self
        openButton.target = self
        let buttons = NSStackView(views: [copyButton, openButton])
        buttons.spacing = 4

        content.progressColor = NSColor(SpaceTheme.default.accent)
        content.display([tab.webView])

        for view in [addressField, buttons, content] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            // The address sits in the title bar, between the traffic lights and the buttons.
            addressField.centerYAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            addressField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 90),
            addressField.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -12),
            buttons.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),

            content.topAnchor.constraint(equalTo: background.topAnchor, constant: 32),
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
        ])
    }

    private func wireTab() {
        tab.onChange = { [weak self] tab in
            guard let self else { return }
            window?.title = tab.title
            if addressField.currentEditor() == nil {
                addressField.stringValue = tab.displayHost
                addressField.toolTip = tab.url?.absoluteString
            }
        }
        tab.onFinishLoading = { [weak self] tab in
            self?.onPageLoaded?(tab)
            self?.favicons.refresh(tab) { _, icon in tab.favicon = icon }
        }
        tab.onOpenTab = { [weak self] configuration, url, _ in
            self?.onOpenTab?(url, configuration)
        }
        tab.onRequestClose = { [weak self] _ in self?.close() }
        tab.onDownload = { DownloadManager.shared.start($0) }
    }

    /// Opens each new Little Wau window a little offset from the previous one.
    private func cascade(_ window: NSWindow) {
        if let other = NSApp.windows.last(where: { $0 !== window && $0.isVisible && $0.windowController is LittleWauWindowController }) {
            window.setFrameTopLeftPoint(NSPoint(x: other.frame.minX + 24, y: other.frame.maxY - 24))
        } else {
            window.center()
        }
    }

    // MARK: Actions

    @objc func openInMainWindow(_ sender: Any?) {
        handedOff = true
        tab.onChange = nil
        tab.onFinishLoading = nil
        tab.onOpenTab = nil
        tab.onRequestClose = nil
        tab.webView.removeFromSuperview()
        onOpenInMainWindow?(tab)
        close()
    }

    @objc private func copyLink() {
        guard let url = tab.url else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc func reloadPage(_ sender: Any?) { tab.webView.reload() }
    @objc func goBack(_ sender: Any?) { tab.webView.goBack() }
    @objc func goForward(_ sender: Any?) { tab.webView.goForward() }
    @objc func closeTab(_ sender: Any?) { close() }

    @objc func openLocation(_ sender: Any?) {
        window?.makeFirstResponder(addressField)
        addressField.stringValue = tab.url?.absoluteString ?? ""
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc func copyPageLink(_ sender: Any?) { copyLink() }

    // MARK: Address field

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            guard let destination = URLInput.destination(for: addressField.stringValue, searchEngine: Preferences.shared.searchEngine) else { return true }
            tab.load(destination.url)
            window?.makeFirstResponder(tab.webView)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            addressField.stringValue = tab.displayHost
            window?.makeFirstResponder(tab.webView)
            return true
        default:
            return false
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        addressField.stringValue = tab.url?.absoluteString ?? ""
    }

    // MARK: Closing

    func windowWillClose(_ notification: Notification) {
        titlebarDoubleClick?.invalidate()
        if !handedOff { tab.tearDown() }
        onClose?(self)
    }

    private static func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))!,
            target: nil,
            action: action
        )
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        return button
    }
}

extension LittleWauWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): tab.canGoBack
        case #selector(goForward(_:)): tab.canGoForward
        case #selector(copyPageLink(_:)): tab.url != nil
        default: true
        }
    }
}

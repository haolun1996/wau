import AppKit
import Core
import UniformTypeIdentifiers

/// An Easel shown in the page area: a rounded card with a title bar and a
/// zoomable, scrollable canvas of clippings, link cards and labels.
@MainActor
final class EaselCanvasView: NSView, NSTextFieldDelegate {
    /// Open a link or a clipping's source page in a tab.
    var onOpenURL: ((URL) -> Void)?

    private let store: EaselStore
    private(set) var easelID: UUID?
    private let titleField = NSTextField()
    private let scrollView = NSScrollView()
    private let document = EaselDocumentView()

    init(store: EaselStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = WebContentView.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        buildViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    private func buildViews() {
        titleField.font = .systemFont(ofSize: 17, weight: .semibold)
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.placeholderString = "Easel"
        titleField.delegate = self

        let addText = Self.toolButton("textformat", "Add Label", #selector(addLabel))
        let zoomOut = Self.toolButton("minus.magnifyingglass", "Zoom Out", #selector(zoomOut))
        let zoomIn = Self.toolButton("plus.magnifyingglass", "Zoom In", #selector(zoomIn))
        let fit = Self.toolButton("arrow.up.left.and.down.right.magnifyingglass", "Actual Size", #selector(actualSize))
        for button in [addText, zoomOut, zoomIn, fit] { button.target = self }
        let hint = NSTextField(labelWithString: "Paste or drop images and links · ⇧⌘2 clips part of a page")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [titleField, hint, NSView(), addText, zoomOut, zoomIn, fit])
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)

        let separator = NSBox()
        separator.boxType = .separator

        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 3
        scrollView.drawsBackground = false

        document.store = store
        document.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }

        for view in [bar, separator, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: bar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Shows an Easel (or refreshes the one shown).
    func show(_ easel: Easel) {
        let isNew = easel.id != easelID
        easelID = easel.id
        if titleField.currentEditor() == nil { titleField.stringValue = easel.title }
        document.easelID = easel.id
        document.reload()
        if isNew {
            scrollView.magnification = 1
            document.scroll(.zero)
            window?.makeFirstResponder(document)
        }
    }

    /// The point at the middle of what's visible, in canvas coordinates.
    var visibleCenter: CGPoint {
        let visible = document.visibleRect
        return CGPoint(x: visible.midX, y: visible.midY)
    }

    func reloadItems() {
        document.reload()
    }

    // MARK: Toolbar

    @objc private func addLabel() {
        guard let easelID else { return }
        let item = store.addText("Label", to: easelID, center: visibleCenter)
        document.beginEditing(item.id)
    }

    @objc private func zoomIn() { scrollView.animator().magnification = min(scrollView.magnification * 1.25, 3) }
    @objc private func zoomOut() { scrollView.animator().magnification = max(scrollView.magnification / 1.25, 0.25) }
    @objc private func actualSize() { scrollView.animator().magnification = 1 }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let easelID else { return }
        store.rename(easelID, to: titleField.stringValue)
        window?.makeFirstResponder(document)
    }

    private static func toolButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        return button
    }
}

// MARK: - Canvas

/// The large canvas holding the items. Flipped, so y grows downward like
/// the stored coordinates.
private final class EaselDocumentView: NSView {
    static let canvasSize = NSSize(width: 3200, height: 2400)

    weak var store: EaselStore?
    var easelID: UUID?
    var onOpenURL: ((URL) -> Void)?
    private var selectedID: UUID?

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Self.canvasSize))
        registerForDraggedTypes([.fileURL, .URL, .png, .tiff, .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// A faint dot grid, so the canvas reads as a surface.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        let spacing: CGFloat = 24
        var y = (dirtyRect.minY / spacing).rounded(.down) * spacing
        while y <= dirtyRect.maxY {
            var x = (dirtyRect.minX / spacing).rounded(.down) * spacing
            while x <= dirtyRect.maxX {
                NSRect(x: x, y: y, width: 1.5, height: 1.5).fill()
                x += spacing
            }
            y += spacing
        }
    }

    func reload() {
        subviews.forEach { $0.removeFromSuperview() }
        guard let store, let easelID else { return }
        for item in store.items(in: easelID) {
            let view = EaselItemView(item: item, store: store)
            view.isSelected = item.id == selectedID
            view.onSelect = { [weak self] view in self?.select(view.item.id) }
            view.onChanged = { [weak self] item in self?.store?.update(item) }
            view.onOpen = { [weak self] url in self?.onOpenURL?(url) }
            addSubview(view)
        }
    }

    func beginEditing(_ id: UUID) {
        select(id)
        (subviews.first { ($0 as? EaselItemView)?.item.id == id } as? EaselItemView)?.beginEditing()
    }

    private func select(_ id: UUID?) {
        selectedID = id
        for case let view as EaselItemView in subviews {
            view.isSelected = view.item.id == id
        }
        if let id { store?.bringToFront(id) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        select(nil)
    }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func deleteBackward(_ sender: Any?) {
        guard let selectedID else { NSSound.beep(); return }
        self.selectedID = nil
        store?.remove(selectedID)
    }

    override func deleteForward(_ sender: Any?) {
        deleteBackward(sender)
    }

    // MARK: Paste and drop

    @objc func paste(_ sender: Any?) {
        let visible = visibleRect
        add(from: .general, at: CGPoint(x: visible.midX, y: visible.midY))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        add(from: sender.draggingPasteboard, at: convert(sender.draggingLocation, from: nil))
    }

    /// Adds the first usable thing on the pasteboard: an image, then a web
    /// link, then text.
    @discardableResult
    private func add(from pasteboard: NSPasteboard, at point: CGPoint) -> Bool {
        guard let store, let easelID else { return false }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let file = urls.first, let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
           let image = NSImage(contentsOf: file), let png = image.pngData {
            store.addImage(png, to: easelID, caption: file.deletingPathExtension().lastPathComponent, center: point)
            return true
        }
        if let image = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first, let png = image.pngData {
            store.addImage(png, to: easelID, center: point)
            return true
        }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first(where: { ["http", "https"].contains($0.scheme ?? "") }) {
            store.addLink(url, title: url.host() ?? url.absoluteString, to: easelID, center: point)
            return true
        }
        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if let url = URL(string: text), ["http", "https"].contains(url.scheme ?? ""), url.host() != nil {
                store.addLink(url, title: url.host() ?? text, to: easelID, center: point)
            } else {
                store.addText(String(text.prefix(500)), to: easelID, center: point)
            }
            return true
        }
        NSSound.beep()
        return false
    }
}

// MARK: - Items

/// One item on the canvas. Drag to move, drag the bottom-right corner to
/// resize, double-click to open a link or edit a label.
private final class EaselItemView: NSView, NSTextFieldDelegate {
    private static let handleSize: CGFloat = 16

    private(set) var item: EaselItem
    var onSelect: ((EaselItemView) -> Void)?
    var onChanged: ((EaselItem) -> Void)?
    var onOpen: ((URL) -> Void)?
    var isSelected = false {
        didSet { updateBorder() }
    }

    private let label = NSTextField(wrappingLabelWithString: "")
    private var dragStart: NSPoint = .zero
    private var startFrame: NSRect = .zero
    private var isResizing = false
    private var didDrag = false

    init(item: EaselItem, store: EaselStore) {
        self.item = item
        super.init(frame: NSRect(x: item.x, y: item.y, width: item.width, height: item.height))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(item.kind == .text ? 0 : 0.2)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return shadow
        }()
        toolTip = item.url?.absoluteString

        switch item.kind {
        case .image:
            let imageView = NSImageView()
            imageView.image = item.imageHash.flatMap(store.image(for:))
                ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "Image not downloaded yet")
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 8
            imageView.layer?.masksToBounds = true
            fill(with: imageView)
        case .link:
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1
            let icon = NSImageView(image: NSImage(systemSymbolName: "link", accessibilityDescription: nil)!)
            icon.contentTintColor = .secondaryLabelColor
            let title = NSTextField(labelWithString: item.text.isEmpty ? (item.url?.absoluteString ?? "Link") : item.text)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.lineBreakMode = .byTruncatingTail
            let host = NSTextField(labelWithString: item.url.map(HistoryRanking.displayAddress) ?? "")
            host.font = .systemFont(ofSize: 11)
            host.textColor = .secondaryLabelColor
            host.lineBreakMode = .byTruncatingTail
            let text = NSStackView(views: [title, host])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            let row = NSStackView(views: [icon, text])
            row.spacing = 10
            row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            fill(with: row)
        case .text:
            label.stringValue = item.text
            label.font = .systemFont(ofSize: 18, weight: .medium)
            label.isEditable = false
            label.isSelectable = false
            label.isBordered = false
            label.drawsBackground = false
            label.focusRingType = .none
            label.delegate = self
            fill(with: label)
        }
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private func fill(with view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func updateBorder() {
        if item.kind == .link {
            layer?.borderColor = (isSelected ? NSColor.controlAccentColor : .separatorColor).cgColor
            layer?.borderWidth = isSelected ? 2 : 1
        } else {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = isSelected ? 2 : 0
        }
    }

    /// Clicks go to the item itself, not the views inside it (except while
    /// a label is being edited).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return label.isEditable && hit.isDescendant(of: label) ? hit : self
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(self)
        if event.clickCount == 2 {
            if item.kind == .text { beginEditing() } else if let url = item.url { onOpen?(url) }
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        isResizing = local.x > bounds.width - Self.handleSize && local.y > bounds.height - Self.handleSize
        dragStart = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        startFrame = frame
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        let dx = point.x - dragStart.x
        let dy = point.y - dragStart.y
        didDrag = true
        if isResizing {
            let width = max(60, startFrame.width + dx)
            // Pictures keep their shape; cards and labels stretch freely.
            let height = item.kind == .image
                ? width * startFrame.height / max(startFrame.width, 1)
                : max(30, startFrame.height + dy)
            setFrameSize(NSSize(width: width, height: height))
        } else {
            setFrameOrigin(NSPoint(x: max(0, startFrame.minX + dx), y: max(0, startFrame.minY + dy)))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard didDrag else { return }
        item.x = frame.minX
        item.y = frame.minY
        item.width = frame.width
        item.height = frame.height
        onChanged?(item)
    }

    override func resetCursorRects() {
        let handle = NSRect(x: bounds.width - Self.handleSize, y: bounds.height - Self.handleSize, width: Self.handleSize, height: Self.handleSize)
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(handle, cursor: .crosshair)
    }

    // MARK: Editing labels

    func beginEditing() {
        guard item.kind == .text else { return }
        label.isEditable = true
        label.isSelectable = true
        window?.makeFirstResponder(label)
        label.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        label.isEditable = false
        label.isSelectable = false
        let text = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != item.text else { return }
        item.text = text.isEmpty ? "Label" : text
        onChanged?(item)
    }
}

extension NSImage {
    /// PNG data for this image, at its full pixel size.
    var pngData: Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        return rep.representation(using: .png, properties: [:])
    }
}

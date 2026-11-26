import AppKit
import Core
import UniformTypeIdentifiers

/// An Easel shown in the page area: a rounded grey card holding a zoomable,
/// scrollable canvas of clippings, link cards, labels, shapes and drawings,
/// with a floating toolbar along the bottom.
@MainActor
final class EaselCanvasView: NSView {
    /// Light grey in light mode; in dark mode a medium grey, light enough
    /// to set the canvas apart from the dark sidebar and window.
    static let canvasColor = NSColor(name: "EaselCanvas") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.37, green: 0.38, blue: 0.4, alpha: 1)
            : NSColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1)
    }

    /// Open a link or a clipping's source page in a tab.
    var onOpenURL: ((URL) -> Void)?
    /// Clip part of a page onto this Easel.
    var onCapture: ((UUID) -> Void)?

    private let store: EaselStore
    private(set) var easelID: UUID?
    private let scrollView = NSScrollView()
    private let document = EaselDocumentView()
    private let toolbar = EaselToolbar()
    /// Keeps the scrolling area below the title bar (see `viewDidMoveToWindow`).
    private var belowTitlebar: NSLayoutConstraint?

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
        layer?.backgroundColor = Self.canvasColor.cgColor
    }

    private func buildViews() {
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
        document.onToolChange = { [weak self] tool in self?.toolbar.tool = tool }
        document.onShownColorChange = { [weak self] color in self?.toolbar.color = color }
        toolbar.onPickColor = { [weak self] color in
            guard let self else { return }
            document.applyColor(color)
            window?.makeFirstResponder(document)
        }
        toolbar.onSelectTool = { [weak self] tool in
            guard let self else { return }
            document.tool = tool
            window?.makeFirstResponder(document)
        }
        toolbar.onAddImage = { [weak self] in self?.chooseImages() }
        toolbar.onCapture = { [weak self] in
            guard let self, let easelID else { return }
            document.tool = .select
            onCapture?(easelID)
        }

        for view in [scrollView, toolbar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            {
                let top = scrollView.topAnchor.constraint(equalTo: topAnchor)
                top.priority = .defaultHigh
                return top
            }(),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            toolbar.centerXAnchor.constraint(equalTo: centerXAnchor),
            toolbar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    /// A scroll view under the transparent title bar gets a blurred edge
    /// strip from macOS, which looks like a header; starting the canvas just
    /// below the title bar avoids it. The card is the same grey above.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        belowTitlebar?.isActive = false
        belowTitlebar = nil
        guard let guide = window?.contentLayoutGuide as? NSLayoutGuide else { return }
        belowTitlebar = scrollView.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor)
        belowTitlebar?.isActive = true
    }

    /// Shows an Easel (or refreshes the one shown).
    func show(_ easel: Easel) {
        let isNew = easel.id != easelID
        easelID = easel.id
        document.easelID = easel.id
        document.reload()
        if isNew {
            document.tool = .select
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

    /// Takes keyboard focus, for tool shortcuts and deleting items.
    func focusCanvas() {
        window?.makeFirstResponder(document)
    }

    // MARK: Toolbar

    /// Puts pictures chosen in an Open panel on the canvas.
    private func chooseImages() {
        guard let window, let easelID else { return }
        document.tool = .select
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose pictures to put on the Easel"
        panel.prompt = "Add"
        let center = visibleCenter
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            for (index, url) in panel.urls.enumerated() {
                guard let image = NSImage(contentsOf: url), let png = image.pngData else { continue }
                let offset = CGFloat(index) * 24
                store.addImage(png, to: easelID, caption: url.deletingPathExtension().lastPathComponent,
                               center: CGPoint(x: center.x + offset, y: center.y + offset))
            }
            window.makeFirstResponder(document)
        }
    }

    // MARK: Zoom (⌘+, ⌘-, ⌘0 and pinching)

    func zoomIn() { scrollView.animator().magnification = min(scrollView.magnification * 1.25, scrollView.maxMagnification) }
    func zoomOut() { scrollView.animator().magnification = max(scrollView.magnification / 1.25, scrollView.minMagnification) }
    func actualSize() { scrollView.animator().magnification = 1 }
}

// MARK: - Canvas

/// The canvas holding the items. Flipped, so y grows downward like the
/// stored coordinates. It is exactly the visible area, so it doesn't scroll,
/// until items sit beyond that; then it grows to reach them.
private final class EaselDocumentView: NSView {
    /// Room past the furthest item once the canvas has to grow.
    private static let overflowMargin: CGFloat = 40
    private var clipObservers: [NSObjectProtocol] = []

    weak var store: EaselStore?
    var easelID: UUID?
    var onOpenURL: ((URL) -> Void)?
    var onToolChange: ((EaselTool) -> Void)?
    /// The colour the toolbar should show: the selected item's, or else the
    /// one new things are drawn in.
    var onShownColorChange: ((String?) -> Void)?
    private var selectedID: UUID?
    /// The colour new labels, shapes and strokes get (nil: Automatic).
    private var drawingColor: String?

    var tool: EaselTool = .select {
        didSet {
            guard tool != oldValue else { return }
            if tool != .select { select(nil) }
            window?.invalidateCursorRects(for: self)
            onToolChange?(tool)
        }
    }

    /// Beside the selected label: change its text size.
    private let textSizeControl = EaselTextSizeControl()

    /// The shape being dragged out, and the points it has passed through.
    private var draft: EaselShapeView?
    private var draftPoints: [CGPoint] = []

    override init(frame: NSRect) {
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .URL, .png, .tiff, .string])
        textSizeControl.onBigger = { [weak self] in
            self?.changeLabelSize { EaselLabelLayout.step(from: $0, bigger: true) }
        }
        textSizeControl.onSmaller = { [weak self] in
            self?.changeLabelSize { EaselLabelLayout.step(from: $0, bigger: false) }
        }
        textSizeControl.onFit = { [weak self] in self?.changeLabelSize { _ in nil } }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// While drawing, every click lands on the canvas, even over items.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if tool != .select { return frame.contains(point) ? self : nil }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        if tool != .select { addCursorRect(visibleRect, cursor: tool == .text ? .iBeam : .crosshair) }
    }

    override func draw(_ dirtyRect: NSRect) {
        EaselCanvasView.canvasColor.setFill()
        dirtyRect.fill()
    }

    func reload() {
        subviews.forEach { $0.removeFromSuperview() }
        draft = nil
        defer { fitToContent() }
        guard let store, let easelID else { return }
        for item in store.items(in: easelID) {
            let view = EaselItemView(item: item, store: store)
            view.isSelected = item.id == selectedID
            view.onSelect = { [weak self] view in self?.select(view.item.id) }
            // Saved once the click is over: saving rebuilds the canvas, which
            // mid-click would swap out the item being dragged.
            view.onClickEnded = { [weak self] view in self?.store?.bringToFront(view.item.id) }
            view.onChanged = { [weak self] item in self?.store?.update(item) }
            view.onOpen = { [weak self] url in self?.onOpenURL?(url) }
            addSubview(view)
        }
        updateTextSizeControl()
    }

    // MARK: Size

    /// Resizing the window or zooming changes the visible area.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        clipObservers.forEach(NotificationCenter.default.removeObserver)
        clipObservers = []
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        let refit: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.fitToContent() }
        }
        clipObservers = [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: clip, queue: .main, using: refit)
        }
        fitToContent()
    }

    /// The visible area, grown to take in any item beyond it.
    func fitToContent() {
        guard let clip = superview as? NSClipView else { return }
        let visible = clip.bounds.size
        var extent = CGSize.zero
        for view in subviews where view is EaselItemView {
            extent.width = max(extent.width, view.frame.maxX)
            extent.height = max(extent.height, view.frame.maxY)
        }
        let size = NSSize(
            width: extent.width > visible.width ? extent.width + Self.overflowMargin : visible.width,
            height: extent.height > visible.height ? extent.height + Self.overflowMargin : visible.height
        )
        // No rubber-banding along an axis with nothing to scroll to.
        enclosingScrollView?.horizontalScrollElasticity = size.width > visible.width ? .automatic : .none
        enclosingScrollView?.verticalScrollElasticity = size.height > visible.height ? .automatic : .none
        if size != frame.size { setFrameSize(size) }
    }

    func beginEditing(_ id: UUID) {
        select(id)
        (subviews.first { ($0 as? EaselItemView)?.item.id == id } as? EaselItemView)?.beginEditing()
    }

    func select(_ id: UUID?) {
        selectedID = id
        for case let view as EaselItemView in subviews {
            view.isSelected = view.item.id == id
        }
        updateTextSizeControl()
        if let item = selectedColorableItem {
            onShownColorChange?(item.color)
        } else {
            onShownColorChange?(drawingColor)
        }
    }

    // MARK: Colour

    private var selectedColorableItem: EaselItem? {
        guard let selectedID, let item = store?.snapshot.items.first(where: { $0.id == selectedID }),
              EaselPalette.isColorable(item.kind)
        else { return nil }
        return item
    }

    /// Recolours the selected item, and draws new things in this colour.
    func applyColor(_ color: String?) {
        drawingColor = color
        if var item = selectedColorableItem {
            item.color = color
            store?.update(item)
        }
        onShownColorChange?(color)
    }

    // MARK: Label text size

    /// Shows the size pop-up beside the selected label, on its left, or on
    /// its right when there's no room.
    private func updateTextSizeControl() {
        guard tool == .select, let selectedID,
              let view = subviews.first(where: { ($0 as? EaselItemView)?.item.id == selectedID }) as? EaselItemView,
              view.item.kind == .text
        else {
            hideTextSizeControl()
            return
        }
        let size = textSizeControl.frame.size
        let gap: CGFloat = 8
        let left = view.frame.minX - gap - size.width
        textSizeControl.pointsRight = left >= 0
        textSizeControl.setFrameOrigin(NSPoint(
            x: left >= 0 ? left : view.frame.maxX + gap,
            y: max(0, view.frame.midY - size.height / 2)
        ))
        if textSizeControl.superview !== self { addSubview(textSizeControl) }
    }

    func hideTextSizeControl() {
        textSizeControl.removeFromSuperview()
    }

    /// Gives the selected label a new text size (nil: fill the box again),
    /// growing the box if the text would no longer fit.
    private func changeLabelSize(_ newSize: (CGFloat) -> CGFloat?) {
        // Finish any typing first, so the new text is what gets measured.
        window?.makeFirstResponder(self)
        guard let store, let selectedID,
              var item = store.snapshot.items.first(where: { $0.id == selectedID }), item.kind == .text
        else { return }
        let inset = EaselLabelLayout.inset
        let current = item.fontSize.map { CGFloat($0) }
            ?? EaselLabelLayout.fontSize(for: item.text, in: CGSize(width: item.width - inset * 2, height: item.height - inset * 2))
        if let size = newSize(current) {
            item.fontSize = Double(size)
            let needed = EaselLabelLayout.boxSize(for: item.text, fontSize: size, width: item.width)
            item.width = max(item.width, needed.width)
            item.height = max(item.height, needed.height)
        } else {
            item.fontSize = nil
        }
        store.update(item)
    }

    // MARK: Tools

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = clamped(convert(event.locationInWindow, from: nil))
        switch tool {
        case .select:
            select(nil)
        case .text:
            tool = .select
            guard let store, let easelID else { return }
            let item = store.addText("Label", to: easelID, center: point, color: drawingColor)
            beginEditing(item.id)
        case .ellipse, .rectangle, .arrow, .pen:
            guard let kind = tool.drawnKind else { return }
            draftPoints = [point]
            let shape = EaselShapeView(kind: kind, points: [], color: drawingColor)
            addSubview(shape)
            draft = shape
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let draft else { return }
        var point = clamped(convert(event.locationInWindow, from: nil))
        if tool == .pen {
            if let last = draftPoints.last, hypot(point.x - last.x, point.y - last.y) < 2 { return }
            draftPoints.append(point)
        } else {
            // Shift draws a circle or square.
            if event.modifierFlags.contains(.shift), tool != .arrow, let start = draftPoints.first {
                let side = max(abs(point.x - start.x), abs(point.y - start.y))
                point = CGPoint(x: start.x + (point.x < start.x ? -side : side), y: start.y + (point.y < start.y ? -side : side))
            }
            draftPoints = [draftPoints[0], point]
        }
        let geometry = EaselShapeView.geometry(for: draft.kind, through: draftPoints)
        draft.frame = geometry.frame
        draft.points = geometry.points
        draft.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let draft else { return }
        draft.removeFromSuperview()
        self.draft = nil
        guard let store, let easelID, let start = draftPoints.first, let end = draftPoints.last else { return }
        var geometry = EaselShapeView.geometry(for: draft.kind, through: draftPoints)
        switch draft.kind {
        case .ellipse, .rectangle:
            // A click without a drag makes a shape of a standard size.
            if geometry.frame.width < 8, geometry.frame.height < 8 {
                let size = draft.kind == .ellipse ? CGSize(width: 110, height: 110) : CGSize(width: 160, height: 110)
                geometry.frame = CGRect(x: start.x - size.width / 2, y: start.y - size.height / 2, width: size.width, height: size.height)
            }
        case .arrow:
            guard hypot(end.x - start.x, end.y - start.y) >= 8 else { return }
        default:
            guard draftPoints.count >= 2 else { return }
        }
        let item = store.addShape(draft.kind, frame: geometry.frame, points: geometry.points, color: drawingColor, to: easelID)
        // The pen stays out for the next stroke; other tools hand back to Select.
        if tool != .pen {
            tool = .select
            select(item.id)
        }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
           let tool = EaselTool.allCases.first(where: { $0.shortcut == key }) {
            self.tool = tool
            return
        }
        interpretKeyEvents([event])
    }

    /// Esc puts the tool down.
    override func cancelOperation(_ sender: Any?) {
        if tool != .select { tool = .select } else { select(nil) }
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

/// One item on the canvas. Drag to move, drag any edge or corner to
/// resize, double-click to open a link or edit a label.
private final class EaselItemView: NSView, NSTextFieldDelegate {
    private(set) var item: EaselItem
    var onSelect: ((EaselItemView) -> Void)?
    var onChanged: ((EaselItem) -> Void)?
    var onOpen: ((URL) -> Void)?
    var onClickEnded: ((EaselItemView) -> Void)?
    var isSelected = false {
        didSet { updateBorder() }
    }

    private let label = NSTextField(wrappingLabelWithString: "")
    private var dragStart: NSPoint = .zero
    private var startFrame: NSRect = .zero
    /// The edges being dragged; empty while moving the item.
    private var resizeEdges: EaselResize.Edges = []
    private var didDrag = false

    init(item: EaselItem, store: EaselStore) {
        self.item = item
        super.init(frame: NSRect(x: item.x, y: item.y, width: item.width, height: item.height))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        shadow = {
            let shadow = NSShadow()
            let isFlat = item.kind == .text || item.kind.usesPoints || item.kind == .ellipse || item.kind == .rectangle
            shadow.shadowColor = NSColor.black.withAlphaComponent(isFlat ? 0 : 0.2)
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
            label.textColor = EaselPalette.color(for: item.color)
            label.font = .systemFont(ofSize: 18, weight: .medium)
            label.isEditable = false
            label.isSelectable = false
            label.isBordered = false
            label.drawsBackground = false
            label.focusRingType = .none
            label.delegate = self
            fill(with: label, inset: EaselLabelLayout.inset)
        case .ellipse, .rectangle, .arrow, .drawing:
            fill(with: EaselShapeView(kind: item.kind, points: item.points, color: item.color))
        }
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private func fill(with view: NSView, inset: CGFloat = 0) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }

    // MARK: Label size

    /// Label text has the size picked in the pop-up, or else is made as
    /// large as fits its box.
    override func layout() {
        super.layout()
        if item.kind == .text { fitLabelText() }
    }

    private func fitLabelText() {
        let size = item.fontSize.map { CGFloat($0) }
            ?? EaselLabelLayout.fontSize(for: label.stringValue, in: label.bounds.size)
        if label.font?.pointSize != size { label.font = EaselLabelLayout.font(ofSize: size) }
    }

    /// Layer colours don't follow light and dark mode on their own.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    private func applyColors() {
        if item.kind == .link {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
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
        // Arrows and strokes are picked up near the line, not anywhere in
        // their box, so they don't cover what's beneath them.
        if item.kind.usesPoints, !isSelected, !isOnLine(convert(point, from: superview)) { return nil }
        return label.isEditable && hit.isDescendant(of: label) ? hit : self
    }

    /// Whether `point` (in this view) is near an arrow's or stroke's line.
    private func isOnLine(_ point: CGPoint) -> Bool {
        EaselShapeView.path(kind: item.kind, points: item.points, in: bounds).cgPath
            .copy(strokingWithWidth: 16, lineCap: .round, lineJoin: .round, miterLimit: 10)
            .contains(point)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // In front straight away; the new order is saved on mouse-up.
        if let superview, superview.subviews.last { $0 is EaselItemView } !== self {
            superview.addSubview(self, positioned: .above, relativeTo: superview.subviews.last { $0 is EaselItemView })
        }
        onSelect?(self)
        if event.clickCount == 2 {
            if item.kind == .text { beginEditing() } else if let url = item.url { onOpen?(url) }
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        resizeEdges = EaselResize.edges(at: local, in: bounds.size)
        dragStart = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        startFrame = frame
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        let dx = point.x - dragStart.x
        let dy = point.y - dragStart.y
        if !didDrag { (superview as? EaselDocumentView)?.hideTextSizeControl() }
        didDrag = true
        if !resizeEdges.isEmpty {
            let isShape = item.kind.usesPoints || item.kind == .ellipse || item.kind == .rectangle
            // Pictures keep their shape; cards, labels and shapes stretch freely.
            frame = EaselResize.frame(
                from: startFrame, edges: resizeEdges, dx: dx, dy: dy,
                minimum: isShape ? CGSize(width: 20, height: 20) : CGSize(width: 60, height: 30),
                keepAspect: item.kind == .image
            )
            EaselResize.cursor(for: resizeEdges).set()
        } else {
            setFrameOrigin(NSPoint(x: max(0, startFrame.minX + dx), y: max(0, startFrame.minY + dy)))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { onClickEnded?(self) }
        guard didDrag else { return }
        item.x = frame.minX
        item.y = frame.minY
        item.width = frame.width
        item.height = frame.height
        // A label with a chosen text size never ends up too small to show it.
        if item.kind == .text, let size = item.fontSize {
            let needed = EaselLabelLayout.boxSize(for: item.text, fontSize: CGFloat(size), width: item.width)
            item.width = max(item.width, needed.width)
            item.height = max(item.height, needed.height)
        }
        onChanged?(item)
    }

    // MARK: Cursor

    // Worked out from the pointer's position each time it moves, since the
    // resize zones overlap the area that moves the item.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(for: event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(for: event) }

    /// A resize arrow over an edge or corner, an open hand elsewhere.
    private func updateCursor(for event: NSEvent) {
        // Drawing tools have their own cursor; a label being edited has the I-beam.
        if let canvas = superview as? EaselDocumentView, canvas.tool != .select { return }
        if label.isEditable { return }
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return }
        if item.kind.usesPoints, !isSelected, !isOnLine(local) {
            NSCursor.arrow.set()
            return
        }
        let edges = EaselResize.edges(at: local, in: bounds.size)
        (edges.isEmpty ? NSCursor.openHand : EaselResize.cursor(for: edges)).set()
    }

    // MARK: Editing labels

    func beginEditing() {
        guard item.kind == .text else { return }
        label.isEditable = true
        label.isSelectable = true
        window?.makeFirstResponder(label)
        label.currentEditor()?.selectAll(nil)
    }

    /// The text grows or shrinks to fit as you type.
    func controlTextDidChange(_ notification: Notification) {
        fitLabelText()
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

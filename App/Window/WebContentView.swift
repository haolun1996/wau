import AppKit
import Core
import WebKit

extension NSPasteboard.PasteboardType {
    /// A tab dragged out of the sidebar; the value is its ID.
    static let wauTab = NSPasteboard.PasteboardType("dev.wau.tab")
}

/// The page area: one rounded card per pane on screen (a page, or an Easel
/// in a split). A single tab fills it; a split shows two to four cards with
/// draggable gaps between them, and the focused one outlined.
@MainActor
final class WebContentView: NSView, NSSplitViewDelegate {
    static let cornerRadius: CGFloat = 8
    static let gap: CGFloat = 8

    /// Color of loading bars and the focused pane's outline; from the theme.
    var progressColor: NSColor = .controlAccentColor {
        didSet { panes.forEach { $0.accent = progressColor } }
    }
    /// A click landed in the pane at this index.
    var onFocusPane: ((Int) -> Void)?
    /// The user dragged a divider; the new share of each pane.
    var onFractionsChanged: (([Double]) -> Void)?
    /// A sidebar tab is dragged over the pane at this index: may it go
    /// before it (false) or after it (true)?
    var canDropTab: ((UUID, Int, Bool) -> Bool)?
    /// The tab was dropped beside that pane.
    var onDropTab: ((UUID, Int, Bool) -> Bool)?

    private let splitView = PaneSplitView()
    private let placeholder = NSTextField(labelWithString: "Press ⌘T to open a tab")
    private var panes: [PaneView] = []
    private var pendingFractions: [Double]?
    private var isUserDragging = false
    private var clickMonitor: Any?
    private let dropHighlight = DropHighlightView()
    private lazy var dropCatcher = DropCatcherView(owner: self)

    init() {
        super.init(frame: .zero)
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 15, weight: .medium)
        addSubview(placeholder)
        dropCatcher.isHidden = true
        addSubview(dropCatcher) // above the pages
        dropHighlight.isHidden = true
        addSubview(dropHighlight)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            dropCatcher.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropCatcher.trailingAnchor.constraint(equalTo: trailingAnchor),
            dropCatcher.topAnchor.constraint(equalTo: topAnchor),
            dropCatcher.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `views` (pages or Easels) as panes along `axis`, sized by
    /// `fractions`, with the pane at `focused` outlined when there is more
    /// than one.
    func display(_ views: [NSView], focused: Int = 0, axis: SplitAxis = .horizontal, fractions: [Double] = []) {
        let sameViews = panes.map(\.content).elementsEqual(views, by: ===)
        let vertical = axis == .horizontal // NSSplitView's "vertical" means vertical dividers
        if !sameViews || splitView.isVertical != vertical {
            panes.forEach { $0.detach() }
            splitView.arrangedSubviews.forEach { $0.removeFromSuperview() }
            splitView.isVertical = vertical
            panes = views.map { view in
                let pane = PaneView(content: view)
                pane.accent = progressColor
                splitView.addArrangedSubview(pane)
                return pane
            }
            pendingFractions = fractions.count == views.count ? fractions : nil
            needsLayout = true
        } else if fractions.count == panes.count, !isUserDragging, fractions != currentFractions() {
            pendingFractions = fractions
            needsLayout = true
        }
        for (index, pane) in panes.enumerated() {
            pane.isFocused = panes.count > 1 && index == focused
        }
        placeholder.isHidden = !views.isEmpty
    }

    override func layout() {
        super.layout()
        guard let fractions = pendingFractions, fractions.count == panes.count, panes.count > 1 else { return }
        pendingFractions = nil
        // Size the panes directly. Moving dividers instead goes wrong for new
        // panes: they start with no size, so every position is out of range.
        let sideBySide = splitView.isVertical
        let bounds = splitView.bounds
        let thickness = splitView.dividerThickness
        let total = sideBySide ? bounds.width : bounds.height
        let length = total - thickness * CGFloat(panes.count - 1)
        guard length > 0 else { return }
        var offset: CGFloat = 0
        for (index, pane) in panes.enumerated() {
            let size = index == panes.count - 1 ? total - offset : (length * fractions[index]).rounded()
            pane.frame = sideBySide
                ? NSRect(x: offset, y: 0, width: size, height: bounds.height)
                : NSRect(x: 0, y: offset, width: bounds.width, height: size) // the split view is flipped
            offset += size + thickness
        }
    }

    private func currentFractions() -> [Double] {
        let sizes = panes.map { splitView.isVertical ? $0.frame.width : $0.frame.height }
        let total = sizes.reduce(0, +)
        return total > 0 ? sizes.map { Double($0 / total) } : []
    }

    // MARK: Clicks focus a pane

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard window != nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.noteClick(at: event.locationInWindow, in: event.window) }
            return event
        }
    }

    private func noteClick(at location: NSPoint, in eventWindow: NSWindow?) {
        guard eventWindow === window, panes.count > 1 else { return }
        for (index, pane) in panes.enumerated() where pane.bounds.contains(pane.convert(location, from: nil)) {
            if !pane.isFocused { onFocusPane?(index) }
            return
        }
    }

    // MARK: Drop a sidebar tab to split

    /// A tab is being dragged out of the sidebar. A page claims every drag
    /// that passes over it, whatever it carries, so while this is on a clear
    /// view covers the pages and takes the drag instead.
    var isTabDragActive = false {
        didSet {
            dropCatcher.isHidden = !isTabDragActive
            if !isTabDragActive { showDropZone(nil) }
        }
    }

    /// Where a dragged tab would land: beside which pane, on which side, and
    /// the half of that pane to light up. Side by side (or a single page)
    /// uses left and right; a stacked split uses top and bottom.
    func dropTarget(at point: NSPoint) -> (pane: Int, after: Bool, zone: NSRect)? {
        let frames = panes.map { convert($0.bounds, from: $0) }
        guard !frames.isEmpty else { return nil }
        // Over a gap, the nearest pane.
        let index = frames.indices.min { distance(from: point, to: frames[$0]) < distance(from: point, to: frames[$1]) }!
        let frame = frames[index]
        var zone = frame
        let after: Bool
        if panes.count < 2 || splitView.isVertical {
            after = point.x >= frame.midX
            zone.size.width = frame.width / 2
            if after { zone.origin.x = frame.midX }
        } else {
            after = point.y < frame.midY // this view isn't flipped: lower is later
            zone.size.height = frame.height / 2
            if !after { zone.origin.y = frame.midY }
        }
        return (index, after, zone.insetBy(dx: 6, dy: 6))
    }

    private func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private func draggedTab(_ info: any NSDraggingInfo) -> UUID? {
        info.draggingPasteboard.string(forType: .wauTab).flatMap(UUID.init(uuidString:))
    }

    /// Lights up where the tab would go; nil hides the highlight.
    func showDropZone(_ zone: NSRect?) {
        guard let zone else {
            dropHighlight.isHidden = true
            return
        }
        let wasHidden = dropHighlight.isHidden
        dropHighlight.isHidden = false
        if wasHidden {
            dropHighlight.frame = zone
        } else if dropHighlight.frame != zone {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                dropHighlight.animator().frame = zone
            }
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let tab = draggedTab(sender),
              let target = dropTarget(at: convert(sender.draggingLocation, from: nil)),
              canDropTab?(tab, target.pane, target.after) == true
        else {
            showDropZone(nil)
            return []
        }
        showDropZone(target.zone)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        showDropZone(nil)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        showDropZone(nil)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        showDropZone(nil)
        guard let tab = draggedTab(sender),
              let target = dropTarget(at: convert(sender.draggingLocation, from: nil))
        else { return false }
        return onDropTab?(tab, target.pane, target.after) ?? false
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        isUserDragging = true
        return proposed + 160
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        proposed - 160
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard isUserDragging else { return }
        // Report while dragging; the drag ends when the mouse button is up.
        onFractionsChanged?(currentFractions())
        if NSEvent.pressedMouseButtons == 0 { isUserDragging = false }
    }
}

/// A split view whose dividers are invisible gaps between the cards.
private final class PaneSplitView: NSSplitView {
    override var dividerThickness: CGFloat { WebContentView.gap }
    override func drawDivider(in rect: NSRect) {}
}

/// A clear cover over the pages during a sidebar tab drag. It passes the
/// drag to the page area, which works out where the tab would go.
private final class DropCatcherView: NSView {
    private weak var owner: WebContentView?

    init(owner: WebContentView) {
        self.owner = owner
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([.wauTab])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        owner?.draggingEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        owner?.draggingUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        owner?.draggingExited(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        owner?.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        owner?.performDragOperation(sender) ?? false
    }
}

/// Where a dragged tab would go to make a split: half of a page, or half
/// of a sidebar row. Always light blue, the usual colour for "drop here",
/// whatever the Space's theme.
final class DropHighlightView: NSView {
    static let color = NSColor(srgbRed: 0.45, green: 0.76, blue: 1, alpha: 1)

    private let fillAlpha: CGFloat
    private let borderColor: NSColor

    /// A stronger fill and a white outline show up over a selected sidebar
    /// row, which macOS turns bright blue during a drag.
    init(cornerRadius: CGFloat = WebContentView.cornerRadius, fillAlpha: CGFloat = 0.22, borderColor: NSColor = DropHighlightView.color) {
        self.fillAlpha = fillAlpha
        self.borderColor = borderColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = Self.color.withAlphaComponent(fillAlpha).cgColor
        layer?.borderColor = borderColor.cgColor
    }
}

/// One pane: a shadowed, rounded card holding a page and its loading bar,
/// or an Easel.
private final class PaneView: NSView {
    let content: NSView
    var accent: NSColor = .controlAccentColor {
        didSet {
            progressBar.color = accent
            updateBorder()
        }
    }
    var isFocused = false {
        didSet { updateBorder() }
    }

    private let card = CardView()
    private let progressBar = ProgressBar()
    private var observations: [NSKeyValueObservation] = []

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        for view in [card, content, progressBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(card)
        card.addSubview(content)
        card.addSubview(progressBar) // above the page
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            progressBar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: card.topAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2.5),
        ])

        guard let webView = content as? WKWebView else { return } // an Easel: no loading bar
        progressBar.reset(loading: webView.isLoading, progress: webView.estimatedProgress)
        let update: @Sendable (WKWebView) -> Void = { [weak self] webView in
            MainActor.assumeIsolated {
                self?.progressBar.update(loading: webView.isLoading, progress: webView.estimatedProgress)
            }
        }
        observations = [
            webView.observe(\.estimatedProgress) { webView, _ in update(webView) },
            webView.observe(\.isLoading) { webView, _ in update(webView) },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Releases the page or Easel so it can be shown somewhere else.
    func detach() {
        observations.forEach { $0.invalidate() }
        observations = []
        content.removeFromSuperview()
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: WebContentView.cornerRadius,
            cornerHeight: WebContentView.cornerRadius,
            transform: nil
        )
    }

    private func updateBorder() {
        card.layer?.borderWidth = isFocused ? 2 : 0
        card.layer?.borderColor = accent.cgColor
    }
}

/// Clips the page to rounded corners and paints a background that follows
/// light and dark mode.
private final class CardView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = WebContentView.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
}

/// A bar that grows with page load progress, then fills and fades out.
private final class ProgressBar: NSView {
    var color: NSColor = .controlAccentColor {
        didSet { fill.backgroundColor = color.cgColor }
    }

    private let fill = CALayer()
    private var progress: Double = 0
    private var isLoading = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(fill)
        fill.backgroundColor = color.cgColor
        fill.anchorPoint = .zero
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // never block clicks on the page

    override func layout() {
        super.layout()
        layoutFill(animated: false)
    }

    /// Jumps straight to the given state, e.g. when switching tabs.
    func reset(loading: Bool, progress: Double) {
        isLoading = loading
        self.progress = loading ? progress : 0
        alphaValue = loading ? 1 : 0
        layoutFill(animated: false)
    }

    func update(loading: Bool, progress newProgress: Double) {
        if loading {
            if !isLoading { progress = 0; layoutFill(animated: false) } // a new load starts empty
            isLoading = true
            progress = max(progress, newProgress)
            alphaValue = 1
            layoutFill(animated: true)
        } else if isLoading {
            isLoading = false
            progress = 1
            layoutFill(animated: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                animator().alphaValue = 0
            }
        }
    }

    private func layoutFill(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.2)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
        CATransaction.commit()
    }
}

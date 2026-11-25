import AppKit
import Core
import WebKit

/// The page area: one rounded card per visible tab. A single tab fills it;
/// a split shows two to four cards with draggable gaps between them, and the
/// focused one outlined.
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

    private let splitView = PaneSplitView()
    private let placeholder = NSTextField(labelWithString: "Press ⌘T to open a tab")
    private var panes: [PaneView] = []
    private var pendingFractions: [Double]?
    private var isUserDragging = false
    private var clickMonitor: Any?

    init() {
        super.init(frame: .zero)
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 15, weight: .medium)
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `webViews` as panes along `axis`, sized by `fractions`, with
    /// the pane at `focused` outlined when there is more than one.
    func display(_ webViews: [WKWebView], focused: Int = 0, axis: SplitAxis = .horizontal, fractions: [Double] = []) {
        let sameViews = panes.map(\.webView).elementsEqual(webViews, by: ===)
        let vertical = axis == .horizontal // NSSplitView's "vertical" means vertical dividers
        if !sameViews || splitView.isVertical != vertical {
            panes.forEach { $0.detach() }
            splitView.arrangedSubviews.forEach { $0.removeFromSuperview() }
            splitView.isVertical = vertical
            panes = webViews.map { webView in
                let pane = PaneView(webView: webView)
                pane.accent = progressColor
                splitView.addArrangedSubview(pane)
                return pane
            }
            pendingFractions = fractions.count == webViews.count ? fractions : nil
            needsLayout = true
        } else if fractions.count == panes.count, !isUserDragging, fractions != currentFractions() {
            pendingFractions = fractions
            needsLayout = true
        }
        for (index, pane) in panes.enumerated() {
            pane.isFocused = panes.count > 1 && index == focused
        }
        placeholder.isHidden = !webViews.isEmpty
    }

    override func layout() {
        super.layout()
        guard let fractions = pendingFractions, fractions.count == panes.count, panes.count > 1 else { return }
        pendingFractions = nil
        let length = (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height)
            - splitView.dividerThickness * CGFloat(panes.count - 1)
        guard length > 0 else { return }
        var position: CGFloat = 0
        for (index, fraction) in fractions.dropLast().enumerated() {
            position += length * fraction
            splitView.setPosition(position + splitView.dividerThickness * CGFloat(index), ofDividerAt: index)
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

/// One pane: a shadowed, rounded card holding a page and its loading bar.
private final class PaneView: NSView {
    let webView: WKWebView
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

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        for view in [card, webView, progressBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(card)
        card.addSubview(webView)
        card.addSubview(progressBar) // above the page
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            webView.topAnchor.constraint(equalTo: card.topAnchor),
            webView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            progressBar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: card.topAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2.5),
        ])

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

    /// Releases the page so it can be shown somewhere else.
    func detach() {
        observations.forEach { $0.invalidate() }
        observations = []
        webView.removeFromSuperview()
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

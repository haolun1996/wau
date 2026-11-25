import AppKit
import Core

/// What a click or drag on an Easel's canvas does.
enum EaselTool: CaseIterable {
    case select, text, ellipse, rectangle, arrow, pen

    var title: String {
        switch self {
        case .select: "Select"
        case .text: "Text"
        case .ellipse: "Circle"
        case .rectangle: "Rectangle"
        case .arrow: "Arrow"
        case .pen: "Draw"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .text: "character"
        case .ellipse: "circle"
        case .rectangle: "square"
        case .arrow: "arrow.up.right"
        case .pen: "scribble"
        }
    }

    /// The key that picks the tool while the canvas has focus.
    var shortcut: String {
        switch self {
        case .select: "v"
        case .text: "t"
        case .ellipse: "o"
        case .rectangle: "r"
        case .arrow: "a"
        case .pen: "p"
        }
    }

    /// The item a drag with this tool makes.
    var drawnKind: EaselItemKind? {
        switch self {
        case .select, .text: nil
        case .ellipse: .ellipse
        case .rectangle: .rectangle
        case .arrow: .arrow
        case .pen: .drawing
        }
    }
}

// MARK: - Colours

/// The colours offered for label text, shapes, arrows and strokes.
enum EaselPalette {
    /// nil is Automatic: the usual text colour for light or dark mode.
    static let colors: [(name: String, hex: String?)] = [
        ("Automatic", nil),
        ("Red", "#E5484D"),
        ("Orange", "#F76B15"),
        ("Yellow", "#F5B800"),
        ("Green", "#30A46C"),
        ("Blue", "#3E8CF0"),
        ("Purple", "#8E4EC6"),
        ("Pink", "#D6409F"),
    ]

    /// Items whose colour can be changed (not pictures or link cards).
    static func isColorable(_ kind: EaselItemKind) -> Bool {
        switch kind {
        case .text, .ellipse, .rectangle, .arrow, .drawing: true
        case .image, .link: false
        }
    }

    static func color(for hex: String?) -> NSColor {
        hex.flatMap(parse) ?? .labelColor
    }

    /// `#RRGGBB` as a colour.
    static func parse(_ hex: String) -> NSColor? {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// A round swatch; Automatic is half white, half black.
    static func swatch(for hex: String?, diameter: CGFloat = 16) -> NSImage {
        let fill = hex.flatMap(parse)
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if let fill {
                fill.setFill()
                circle.fill()
            } else {
                NSColor.white.setFill()
                circle.fill()
                NSGraphicsContext.saveGraphicsState()
                circle.addClip()
                NSColor.black.setFill()
                let half = NSBezierPath()
                half.move(to: NSPoint(x: rect.maxX, y: rect.minY))
                half.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
                half.line(to: NSPoint(x: rect.minX, y: rect.minY))
                half.close()
                half.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            NSColor.white.withAlphaComponent(0.6).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
        return image
    }
}

// MARK: - Labels

/// Label text either fills its box or has a size the user picked.
enum EaselLabelLayout {
    /// Space between a label's box and its text.
    static let inset: CGFloat = 6
    /// The sizes − and + step through.
    static let steps: [CGFloat] = [12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 56, 64, 72, 88, 104, 128, 160, 200, 256, 320, 400]

    /// The next size up or down from `size`.
    static func step(from size: CGFloat, bigger: Bool) -> CGFloat {
        bigger
            ? steps.first { $0 > size + 0.5 } ?? steps.last!
            : steps.last { $0 < size - 0.5 } ?? steps.first!
    }

    static func font(ofSize size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .medium)
    }

    /// The smallest box that shows `text` at `size` when the box is at
    /// least `width` wide: wider if a single word needs it, taller if the
    /// wrapped lines need it.
    static func boxSize(for text: String, fontSize size: CGFloat, width: CGFloat) -> CGSize {
        let sample = text.isEmpty ? "Label" : text
        let attributes: [NSAttributedString.Key: Any] = [.font: font(ofSize: size)]
        let padding = inset * 2 + 6
        let longestWord = sample.split(whereSeparator: \.isWhitespace)
            .map { (String($0) as NSString).size(withAttributes: attributes).width }
            .max() ?? 0
        let boxWidth = max(width, ceil(longestWord) + padding)
        let lines = (sample as NSString).boundingRect(
            with: NSSize(width: boxWidth - padding, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes
        )
        return CGSize(width: boxWidth, height: ceil(lines.height) + inset * 2)
    }

    /// The largest font size (12–400pt) at which `text`, wrapped, fits in `box`.
    static func fontSize(for text: String, in box: CGSize) -> CGFloat {
        // The text field keeps a little padding of its own on each side.
        let width = box.width - 6
        guard width > 0, box.height > 0 else { return 12 }
        let sample = text.isEmpty ? "Label" : text
        func fits(_ size: CGFloat) -> Bool {
            let attributes: [NSAttributedString.Key: Any] = [.font: font(ofSize: size)]
            // A single word can't wrap, so it must fit across on its own.
            let words = sample.split(whereSeparator: \.isWhitespace)
            if words.contains(where: { (String($0) as NSString).size(withAttributes: attributes).width > width }),
               sample.contains(where: \.isWhitespace) {
                return false
            }
            let needed = (sample as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes
            )
            return ceil(needed.height) <= box.height
        }
        var low: CGFloat = 12, high: CGFloat = 400
        guard fits(low) else { return low }
        while high - low > 0.5 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        return low.rounded(.down)
    }
}

// MARK: - Resizing items

/// Resizing an item from any edge or corner. Coordinates are flipped: y
/// grows downward, so "top" is the smaller y.
enum EaselResize {
    struct Edges: OptionSet, Hashable {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let top = Edges(rawValue: 1 << 2)
        static let bottom = Edges(rawValue: 1 << 3)
    }

    /// The grab zones of an item this size: corners first, then edges.
    /// Small items get thinner zones so there's still room to move them.
    static func zones(in size: CGSize) -> [(rect: CGRect, edges: Edges)] {
        let bandX = min(8, size.width / 4), bandY = min(8, size.height / 4)
        let cornerX = min(14, size.width / 3), cornerY = min(14, size.height / 3)
        let w = size.width, h = size.height
        return [
            (CGRect(x: 0, y: 0, width: cornerX, height: cornerY), [.top, .left]),
            (CGRect(x: w - cornerX, y: 0, width: cornerX, height: cornerY), [.top, .right]),
            (CGRect(x: 0, y: h - cornerY, width: cornerX, height: cornerY), [.bottom, .left]),
            (CGRect(x: w - cornerX, y: h - cornerY, width: cornerX, height: cornerY), [.bottom, .right]),
            (CGRect(x: 0, y: 0, width: w, height: bandY), .top),
            (CGRect(x: 0, y: h - bandY, width: w, height: bandY), .bottom),
            (CGRect(x: 0, y: 0, width: bandX, height: h), .left),
            (CGRect(x: w - bandX, y: 0, width: bandX, height: h), .right),
        ]
    }

    /// The edges grabbed at `point`, or none to move the item instead.
    static func edges(at point: CGPoint, in size: CGSize) -> Edges {
        zones(in: size).first { $0.rect.contains(point) }?.edges ?? []
    }

    /// `start` with the grabbed edges moved by the drag, never smaller than
    /// `minimum` or past the canvas's top-left. With `keepAspect` (pictures)
    /// the other side follows so the shape stays the same.
    static func frame(from start: CGRect, edges: Edges, dx: CGFloat, dy: CGFloat, minimum: CGSize, keepAspect: Bool) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if edges.contains(.left) { minX = max(0, min(start.minX + dx, start.maxX - minimum.width)) }
        if edges.contains(.right) { maxX = max(start.maxX + dx, start.minX + minimum.width) }
        if edges.contains(.top) { minY = max(0, min(start.minY + dy, start.maxY - minimum.height)) }
        if edges.contains(.bottom) { maxY = max(start.maxY + dy, start.minY + minimum.height) }
        guard keepAspect, start.width > 0, start.height > 0 else {
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        let ratio = start.width / start.height
        if edges.contains(.left) || edges.contains(.right) {
            // The width leads; the height follows from the opposite edge.
            let height = (maxX - minX) / ratio
            if edges.contains(.top) { minY = maxY - height } else { maxY = minY + height }
        } else {
            let width = (maxY - minY) * ratio
            maxX = minX + width
        }
        return CGRect(x: minX, y: max(0, minY), width: maxX - minX, height: maxY - minY)
    }

    /// The macOS resize arrow for an edge or corner.
    @MainActor
    static func cursor(for edges: Edges) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch edges {
            case [.top, .left]: .topLeft
            case [.top, .right]: .topRight
            case [.bottom, .left]: .bottomLeft
            case [.bottom, .right]: .bottomRight
            case .top: .top
            case .bottom: .bottom
            case .left: .left
            default: .right
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        return horizontal && vertical ? .crosshair : horizontal ? .resizeLeftRight : .resizeUpDown
    }
}

// MARK: - Label size pop-up

/// A small dark pop-up beside a selected label: + and − change the text
/// size, Aa goes back to filling the box.
final class EaselTextSizeControl: NSView {
    static let bodySize = NSSize(width: 44, height: 96)
    static let pointerLength: CGFloat = 7

    var onBigger: (() -> Void)?
    var onSmaller: (() -> Void)?
    var onFit: (() -> Void)?
    /// Which side the pointer is on: toward the label.
    var pointsRight = true {
        didSet { layoutBody(); needsDisplay = true }
    }

    private let stack: NSStackView

    init() {
        let size = NSSize(width: Self.bodySize.width, height: Self.bodySize.height / 3)
        let bigger = EaselToolButton(symbol: "plus", label: "Bigger Text", shortcut: nil, pointSize: 14, size: size) {}
        let fit = EaselToolButton(title: "Aa", label: "Fit Text to Box", pointSize: 17, size: size) {}
        let smaller = EaselToolButton(symbol: "minus", label: "Smaller Text", shortcut: nil, pointSize: 14, size: size) {}
        stack = NSStackView(views: [bigger, fit, smaller])
        stack.orientation = .vertical
        stack.spacing = 0
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.bodySize.width + Self.pointerLength, height: Self.bodySize.height)))
        appearance = NSAppearance(named: .darkAqua)
        bigger.handler = { [weak self] in self?.onBigger?() }
        fit.handler = { [weak self] in self?.onFit?() }
        smaller.handler = { [weak self] in self?.onSmaller?() }
        stack.translatesAutoresizingMaskIntoConstraints = true
        addSubview(stack)
        layoutBody()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The rounded body is on the side away from the pointer.
    private var bodyRect: NSRect {
        NSRect(x: pointsRight ? 0 : Self.pointerLength, y: 0, width: Self.bodySize.width, height: Self.bodySize.height)
    }

    private func layoutBody() {
        stack.frame = bodyRect
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.03, green: 0.04, blue: 0.05, alpha: 0.97).setFill()
        NSBezierPath(roundedRect: bodyRect, xRadius: 10, yRadius: 10).fill()
        let pointer = NSBezierPath()
        let middle = bounds.midY
        if pointsRight {
            pointer.move(to: NSPoint(x: bodyRect.maxX, y: middle - 7))
            pointer.line(to: NSPoint(x: bounds.maxX, y: middle))
            pointer.line(to: NSPoint(x: bodyRect.maxX, y: middle + 7))
        } else {
            pointer.move(to: NSPoint(x: bodyRect.minX, y: middle - 7))
            pointer.line(to: NSPoint(x: bounds.minX, y: middle))
            pointer.line(to: NSPoint(x: bodyRect.minX, y: middle + 7))
        }
        pointer.close()
        pointer.fill()
    }
}

// MARK: - Drawing shapes

/// Draws an outline, arrow or freehand stroke filling its bounds: used both
/// for items on the canvas and for the preview while dragging.
final class EaselShapeView: NSView {
    static let lineWidth: CGFloat = 3

    var kind: EaselItemKind
    var points: [EaselPoint]
    /// `#RRGGBB`, or nil for the usual text colour.
    var color: String?

    init(kind: EaselItemKind, points: [EaselPoint], color: String? = nil) {
        self.kind = kind
        self.points = points
        self.color = color
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        (color.flatMap(EaselPalette.parse) ?? NSColor.labelColor.withAlphaComponent(0.85)).setStroke()
        Self.path(kind: kind, points: points, in: bounds).stroke()
    }

    /// The outline for `kind` in `rect` (flipped coordinates).
    static func path(kind: EaselItemKind, points: [EaselPoint], in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        func place(_ point: EaselPoint) -> CGPoint {
            CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        }
        switch kind {
        case .ellipse:
            path.appendOval(in: inset)
        case .rectangle:
            path.appendRoundedRect(inset, xRadius: 6, yRadius: 6)
        case .arrow:
            guard points.count >= 2 else { break }
            let start = place(points[0]), end = place(points[1])
            path.move(to: start)
            path.line(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head: CGFloat = 14
            for side in [CGFloat.pi * 0.8, -CGFloat.pi * 0.8] {
                path.move(to: end)
                path.line(to: CGPoint(x: end.x + head * cos(angle + side), y: end.y + head * sin(angle + side)))
            }
        case .drawing:
            // Curves through the midpoints between samples smooth out the jitter.
            let placed = points.map(place)
            guard let first = placed.first else { break }
            path.move(to: first)
            if placed.count < 3 {
                placed.dropFirst().forEach(path.line(to:))
                break
            }
            for index in 1..<placed.count - 1 {
                let mid = CGPoint(x: (placed[index].x + placed[index + 1].x) / 2, y: (placed[index].y + placed[index + 1].y) / 2)
                path.curve(to: mid, controlPoint: placed[index])
            }
            path.line(to: placed[placed.count - 1])
        case .image, .link, .text:
            break
        }
        return path
    }

    /// The frame and frame-relative points for a shape drawn through
    /// `points` (canvas coordinates). Rectangles and circles span the first
    /// and last point; arrows and strokes get room for the line and head.
    static func geometry(for kind: EaselItemKind, through points: [CGPoint]) -> (frame: CGRect, points: [EaselPoint]) {
        guard let first = points.first, let last = points.last else { return (.zero, []) }
        switch kind {
        case .ellipse, .rectangle:
            return (CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)), [])
        default:
            let padding: CGFloat = kind == .arrow ? 12 : lineWidth + 1
            let xs = points.map(\.x), ys = points.map(\.y)
            let frame = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                .insetBy(dx: -padding, dy: -padding)
            let relative = points.map {
                EaselPoint(x: Double(($0.x - frame.minX) / frame.width), y: Double(($0.y - frame.minY) / frame.height))
            }
            return (frame, relative)
        }
    }
}

// MARK: - Toolbar

/// The dark floating toolbar along the bottom of an Easel.
final class EaselToolbar: NSView {
    var onSelectTool: ((EaselTool) -> Void)?
    var onAddImage: (() -> Void)?
    var onCapture: (() -> Void)?
    /// A colour was picked from the palette (nil: Automatic).
    var onPickColor: ((String?) -> Void)?

    /// The colour shown on the colour button.
    var color: String? {
        didSet { colorButton.image = EaselPalette.swatch(for: color, diameter: 20) }
    }
    private var colorButton: EaselToolButton!

    var tool: EaselTool = .select {
        didSet { highlightTool() }
    }

    private var toolButtons: [EaselTool: EaselToolButton] = [:]

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.05, green: 0.07, blue: 0.09, alpha: 0.96).cgColor
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            return shadow
        }()

        func toolButton(_ tool: EaselTool) -> EaselToolButton {
            let button = EaselToolButton(symbol: tool.symbol, label: "\(tool.title) (\(tool.shortcut.uppercased()))", shortcut: tool.shortcut) { [weak self] in
                self?.onSelectTool?(tool)
            }
            toolButtons[tool] = button
            return button
        }
        let image = EaselToolButton(symbol: "photo", label: "Add Image…", shortcut: nil) { [weak self] in self?.onAddImage?() }
        let capture = EaselToolButton(symbol: "plus.square.on.square", label: "Clip Part of a Page", shortcut: nil) { [weak self] in
            self?.onCapture?()
        }
        colorButton = EaselToolButton(symbol: nil, label: "Colour", shortcut: nil) {}
        colorButton.image = EaselPalette.swatch(for: nil, diameter: 20)
        colorButton.handler = { [weak self] in self?.showPalette() }
        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = NSColor.white.withAlphaComponent(0.15)
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let row = NSStackView(views: [
            toolButton(.select), image, toolButton(.text), toolButton(.ellipse), toolButton(.rectangle),
            toolButton(.arrow), toolButton(.pen), colorButton, divider, capture,
        ])
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // didSet doesn't run for assignments in init, so highlight here.
        highlightTool()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    /// The palette, as a menu just above the colour button.
    private func showPalette() {
        let menu = NSMenu(title: "Colour")
        for entry in EaselPalette.colors {
            let item = ClosureMenuItem(entry.name) { [weak self] in self?.onPickColor?(entry.hex) }
            item.image = EaselPalette.swatch(for: entry.hex)
            item.state = entry.hex == color ? .on : .off
            menu.addItem(item)
        }
        let top = colorButton.isFlipped ? 0 : colorButton.bounds.height
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: top), in: colorButton)
    }

    private func highlightTool() {
        for (tool, button) in toolButtons { button.isActive = tool == self.tool }
    }
}

/// One toolbar button: a white symbol, a blue tile when its tool is active,
/// and the tool's key in the corner while active.
final class EaselToolButton: NSButton {
    var handler: () -> Void
    private let shortcutLabel: NSTextField

    var isActive = false {
        didSet {
            layer?.backgroundColor = isActive ? NSColor(srgbRed: 0.29, green: 0.42, blue: 0.6, alpha: 1).cgColor : nil
            shortcutLabel.isHidden = !isActive
        }
    }

    /// A button showing text instead of a symbol.
    convenience init(title: String, label: String, pointSize: CGFloat, size: NSSize, handler: @escaping () -> Void) {
        self.init(symbol: nil, label: label, shortcut: nil, pointSize: pointSize, size: size, handler: handler)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont(name: "Times New Roman", size: pointSize) ?? .systemFont(ofSize: pointSize),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ])
    }

    init(
        symbol: String?, label: String, shortcut: String?,
        pointSize: CGFloat = 18, size: NSSize = NSSize(width: 44, height: 40), handler: @escaping () -> Void
    ) {
        self.handler = handler
        shortcutLabel = NSTextField(labelWithString: shortcut ?? "")
        super.init(frame: .zero)
        title = ""
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: label) }?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        isBordered = false
        contentTintColor = NSColor.white.withAlphaComponent(0.92)
        toolTip = label
        target = self
        action = #selector(run)
        refusesFirstResponder = true
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        shortcutLabel.font = .systemFont(ofSize: 10, weight: .bold)
        shortcutLabel.textColor = .white
        shortcutLabel.isHidden = true
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            shortcutLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func run() { handler() }
}

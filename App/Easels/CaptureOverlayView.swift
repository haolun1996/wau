import AppKit

/// Covers the page while clipping: the user drags a box around what to
/// capture; Esc or a click without dragging cancels.
@MainActor
final class CaptureOverlayView: NSView {
    /// The chosen area, in this view's coordinates; nil when cancelled.
    var onFinish: ((NSRect?) -> Void)?

    private var start: NSPoint?
    private var selection: NSRect = .zero
    private let hint = NSTextField(labelWithString: "Drag over part of the page to clip it to an Easel · Esc to cancel")

    override init(frame: NSRect) {
        super.init(frame: frame)
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = .white
        hint.alignment = .center
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        hint.layer?.cornerRadius = 8
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.topAnchor.constraint(equalTo: topAnchor, constant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dim everything except the selection.
        let path = NSBezierPath(rect: bounds)
        if !selection.isEmpty {
            path.append(NSBezierPath(rect: selection))
            path.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.3).setFill()
        path.fill()
        if !selection.isEmpty {
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.setLineDash([5, 3], count: 2, phase: 0)
            outline.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = .zero
        hint.isHidden = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = NSRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y)
        ).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let chosen = selection
        guard chosen.width > 8, chosen.height > 8 else {
            onFinish?(nil)
            return
        }
        onFinish?(chosen)
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish?(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) } // Esc
    }
}

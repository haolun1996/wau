import AppKit

/// A thin strip along the sidebar's right edge; dragging it changes the
/// sidebar's width.
@MainActor
final class SidebarResizeHandle: NSView {
    /// The current width, read when a drag starts.
    var currentWidth: (() -> CGFloat)?
    /// Asked to apply a new width while dragging.
    var onResize: ((CGFloat) -> Void)?
    /// Called once the drag ends, to save the width.
    var onResizeEnded: (() -> Void)?

    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }
    // Resizing works even when the window isn't in front yet.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // The page underneath may also set the cursor, so set it on every update.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        dragStartWidth = currentWidth?() ?? 0
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        onResize?(dragStartWidth + event.locationInWindow.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        onResizeEnded?()
    }
}

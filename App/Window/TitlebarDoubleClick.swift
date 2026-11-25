import AppKit
import WebKit

/// Double-clicking the top strip of a window whose content runs under a
/// transparent title bar. The sidebar and backgrounds sit where the title
/// bar would be, so the click never reaches it; this does what the title bar
/// would: zoom or minimize, as chosen in System Settings ▸ Desktop & Dock.
@MainActor
final class TitlebarDoubleClick {
    private var monitor: Any?

    /// - Parameter height: how far down from the top of the window counts as the title bar.
    init(window: NSWindow, height: CGFloat = 36) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
            let handled = MainActor.assumeIsolated {
                guard let window else { return false }
                return Self.handle(event, in: window, height: height)
            }
            return handled ? nil : event
        }
    }

    func invalidate() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func handle(_ event: NSEvent, in window: NSWindow, height: CGFloat) -> Bool {
        guard event.window === window, event.clickCount == 2, let content = window.contentView else { return false }
        let point = content.convert(event.locationInWindow, from: nil)
        let distanceFromTop = content.isFlipped ? point.y : content.bounds.height - point.y
        guard distanceFromTop >= 0, distanceFromTop <= height else { return false }
        // Buttons, text fields and pages keep their own double-click.
        var view = content.hitTest(point)
        while let current = view {
            if current is NSControl || current is NSText || current is WKWebView { return false }
            view = current.superview
        }
        performSystemAction(on: window)
        return true
    }

    /// The user's choice for double-clicking a title bar (default: zoom).
    private static func performSystemAction(on window: NSWindow) {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            window.performMiniaturize(nil)
        case "None":
            break
        case "Maximize", "Fill":
            window.performZoom(nil)
        default:
            if defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") {
                window.performMiniaturize(nil)
            } else {
                window.performZoom(nil)
            }
        }
    }
}

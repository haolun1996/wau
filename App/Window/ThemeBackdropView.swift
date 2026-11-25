import AppKit
import Core

/// Tints the frosted window background with the theme's gradient, the way
/// Arc colors each Space.
@MainActor
final class ThemeBackdropView: NSView {
    /// How strongly the tint covers the frosted background.
    static let lightModeAlpha = 0.5
    static let darkModeAlpha = 0.55
    /// Approximate frosted background colors the tint is laid over.
    private static let lightBase = ThemeColor(0xE8E8E8)
    private static let darkBase = ThemeColor(0x262626)

    var theme: SpaceTheme = .default {
        didSet { needsDisplay = true }
    }

    /// Called when light/dark mode changes, so dependent colors can update.
    var onAppearanceChange: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer {
        let gradient = CAGradientLayer()
        // AppKit layers are not flipped: y = 1 is the top.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        return gradient
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = [NSColor(theme.top).cgColor, NSColor(theme.bottom).cgColor]
        gradient.opacity = Float(isDark ? Self.darkModeAlpha : Self.lightModeAlpha)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        onAppearanceChange?()
    }

    override var mouseDownCanMoveWindow: Bool { true }

    /// Whether text drawn over the tinted background should be light.
    var needsLightText: Bool {
        isDark
            ? theme.needsLightText(over: Self.darkBase, alpha: Self.darkModeAlpha)
            : theme.needsLightText(over: Self.lightBase, alpha: Self.lightModeAlpha)
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension NSColor {
    convenience init(_ color: ThemeColor, alpha: CGFloat = 1) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: alpha)
    }
}

extension SpaceTheme {
    /// A small gradient dot for menus and pickers.
    func swatch(diameter: CGFloat = 14) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            NSGradient(starting: NSColor(top), ending: NSColor(bottom))?.draw(in: circle, angle: -90)
            NSColor.black.withAlphaComponent(0.15).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
    }
}

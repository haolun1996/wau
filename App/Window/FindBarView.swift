import AppKit

/// Find in page (⌘F): a small floating bar over the top-right of the page.
@MainActor
final class FindBarView: NSVisualEffectView, NSSearchFieldDelegate {
    /// Search for the text, forwards or backwards.
    var onFind: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?

    let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        field.placeholderString = "Find in page"
        field.sendsSearchStringImmediately = false
        field.delegate = self
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let previous = Self.button("chevron.up", "Previous (⇧⌘G)", #selector(previousMatch))
        let next = Self.button("chevron.down", "Next (⌘G)", #selector(nextMatch))
        let done = Self.button("xmark", "Done (Esc)", #selector(close))
        for button in [previous, next, done] { button.target = self }

        let row = NSStackView(views: [field, status, previous, next, done])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 200),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func showResult(found: Bool) {
        status.stringValue = found || field.stringValue.isEmpty ? "" : "Not found"
        status.textColor = found ? .secondaryLabelColor : .systemRed
    }

    @objc func nextMatch() { search(backwards: false) }
    @objc func previousMatch() { search(backwards: true) }
    @objc func close() { onClose?() }

    private func search(backwards: Bool) {
        let text = field.stringValue
        guard !text.isEmpty else { return }
        onFind?(text, backwards)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            search(backwards: NSEvent.modifierFlags.contains(.shift))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    private static func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        return button
    }
}

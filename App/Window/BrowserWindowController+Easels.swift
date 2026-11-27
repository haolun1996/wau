import AppKit
import Core
import WebKit

/// Easels in the window: showing one in the page area, clipping parts of
/// pages onto them, and adding links.
extension BrowserWindowController {
    func showEasel(_ id: UUID) {
        guard let easel = easels.easel(withID: id) else { return }
        dismissCommandBar()
        // An Easel in a split shows as its pane, with the split.
        if model.split(containing: id) != nil {
            hideEasel()
            model.focusEasel(id)
            return
        }
        shownEaselID = id
        easelCanvas.show(easel)
        easelCanvas.isHidden = false
        content.isHidden = true
        window?.title = easel.title
        sidebar.reloadTabs()
    }

    func hideEasel() {
        guard shownEaselID != nil else { return }
        shownEaselID = nil
        easelCanvas.isHidden = true
        content.isHidden = false
        window?.title = model.selected?.title ?? model.currentSpace.name
        if let webView = model.selected?.webView { window?.makeFirstResponder(webView) }
        sidebar.reloadTabs()
    }

    func bindEasels() {
        easels.onChange = { [weak self] in
            guard let self else { return }
            for (id, canvas) in paneCanvases {
                if let easel = easels.easel(withID: id) { canvas.show(easel) }
            }
            // Deleted Easels leave their splits.
            model.easelsChanged()
            if let canvas = focusedPaneCanvas {
                window?.title = canvas.easelID.flatMap { easels.easel(withID: $0)?.title } ?? "Easel"
            }
            if let shown = shownEaselID {
                if let easel = easels.easel(withID: shown) {
                    easelCanvas.show(easel)
                    window?.title = easel.title
                } else {
                    hideEasel()
                }
            }
            sidebar.reloadTabs()
        }
        easels.onItemsChange = { [weak self] id in
            guard let self else { return }
            if shownEaselID == id { easelCanvas.reloadItems() }
            paneCanvases[id]?.reloadItems()
        }
        wire(easelCanvas)
    }

    /// A canvas for an Easel shown as a pane of a split.
    func makeEaselCanvas() -> EaselCanvasView {
        let canvas = EaselCanvasView(store: easels)
        wire(canvas)
        return canvas
    }

    private func wire(_ canvas: EaselCanvasView) {
        canvas.onOpenURL = { [weak self] url in
            self?.hideEasel()
            self?.model.open(url: url)
        }
        canvas.onCapture = { [weak self] easelID in self?.startCapture(into: easelID) }
    }

    // MARK: Actions

    @objc func newEasel(_ sender: Any?) {
        guard kind == .main else { NSSound.beep(); return }
        let count = easels.easels(in: model.currentSpaceID).count
        let easel = easels.createEasel(in: model.currentSpaceID, title: count == 0 ? "Easel" : "Easel \(count + 1)")
        showEasel(easel.id)
    }

    /// ⇧⌘2: drag a box over the page to clip it onto an Easel.
    @objc func captureToEasel(_ sender: Any?) {
        startCapture(into: nil)
    }

    /// Shows the page with a box to drag over it. With `target`, the clipping
    /// goes onto that Easel, which comes back when done; otherwise the user
    /// picks an Easel if there are several.
    func startCapture(into target: UUID?) {
        guard captureOverlay == nil, !model.visibleTabs.isEmpty else {
            if target != nil { showToast("Open a page in a tab first, then clip part of it") } else { NSSound.beep() }
            return
        }
        hideEasel()
        dismissCommandBar()
        let overlay = CaptureOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: content.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        overlay.onFinish = { [weak self, weak overlay] rect in
            guard let self, let overlay else { return }
            captureOverlay = nil
            defer { overlay.removeFromSuperview() }
            guard let rect else {
                if let target { showEasel(target) }
                return
            }
            clip(rect, from: overlay, into: target)
        }
        captureOverlay = overlay
        window?.makeFirstResponder(overlay)
    }

    /// Snapshots the part of the page under `rect` and puts it on an Easel.
    private func clip(_ rect: NSRect, from overlay: NSView, into target: UUID?) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        // The pane under the middle of the box is the one being clipped.
        guard let tab = model.visibleTabs.first(where: { tab in
            let frame = tab.webView.convert(tab.webView.bounds, to: overlay)
            return frame.contains(center)
        }) else {
            NSSound.beep()
            if let target { showEasel(target) }
            return
        }
        let webView = tab.webView
        let area = webView.convert(rect, from: overlay).intersection(webView.bounds)
        guard !area.isEmpty else {
            if let target { showEasel(target) }
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = area
        let title = tab.title
        let source = tab.url
        Task { [weak self] in
            do {
                let image = try await webView.takeSnapshot(configuration: configuration)
                guard let png = image.pngData, let self else { return }
                if let target {
                    easels.addImage(png, to: target, caption: title, source: source)
                    showEasel(target)
                    return
                }
                chooseEasel { [weak self] easelID in
                    guard let self, easels.addImage(png, to: easelID, caption: title, source: source) != nil else { return }
                    showToast("Clipped to “\(easels.easel(withID: easelID)?.title ?? "Easel")”")
                }
            } catch {
                Self.logger.error("Clipping failed: \(error)")
                NSSound.beep()
                if let target { self?.showEasel(target) }
            }
        }
    }

    @objc func addPageToEasel(_ sender: Any?) {
        guard let tab = model.selected, let url = tab.url else { NSSound.beep(); return }
        let title = tab.title
        chooseEasel { [weak self] easelID in
            guard let self else { return }
            easels.addLink(url, title: title, to: easelID)
            showToast("Added to “\(easels.easel(withID: easelID)?.title ?? "Easel")”")
        }
    }

    /// Picks the Easel to add to: the only one, a new one if there are none,
    /// or a menu at the pointer when the Space has several.
    private func chooseEasel(_ completion: @escaping (UUID) -> Void) {
        let available = easels.easels(in: model.currentSpaceID)
        if available.isEmpty {
            completion(easels.createEasel(in: model.currentSpaceID).id)
            return
        }
        if available.count == 1 {
            completion(available[0].id)
            return
        }
        guard let window, let contentView = window.contentView else { return }
        let menu = NSMenu(title: "Add to Easel")
        let header = NSMenuItem(title: "Add to Easel", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for easel in available {
            menu.addItem(ClosureMenuItem(easel.title) { completion(easel.id) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("New Easel") { [weak self] in
            guard let self else { return }
            completion(easels.createEasel(in: model.currentSpaceID, title: "Easel \(available.count + 1)").id)
        })
        let location = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: location, in: contentView)
    }

    func rename(_ easel: Easel) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Easel"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: easel.title)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.easels.rename(easel.id, to: field.stringValue)
        }
    }

    func confirmDelete(_ easel: Easel) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(easel.title)”?"
        alert.informativeText = "Everything on this Easel will be removed, on every Mac it syncs to."
        alert.addButton(withTitle: "Delete Easel")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.easels.delete(easel.id)
        }
    }

    /// A brief message near the bottom of the window, optionally with a button.
    func showToast(_ message: String, action: (title: String, run: () -> Void)? = nil) {
        let toast = NSVisualEffectView()
        toast.material = .hudWindow
        toast.blendingMode = .withinWindow
        toast.state = .active
        toast.wantsLayer = true
        toast.layer?.cornerRadius = 10
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        var views: [NSView] = [label]
        if let action {
            views.append(ClosureButton(title: action.title, handler: action.run))
        }
        let row = NSStackView(views: views)
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        toast.addSubview(row)
        toast.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(toast)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: toast.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: toast.bottomAnchor, constant: -6),
            toast.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(action == nil ? 2 : 5))
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                toast.animator().alphaValue = 0
            }
            toast.removeFromSuperview()
        }
    }
}

/// A small button that runs a closure.
final class ClosureButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.handler = handler
        bezelStyle = .push
        controlSize = .small
        target = self
        action = #selector(run)
    }

    @objc private func run() { handler?() }
}

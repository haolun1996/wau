import AppKit
import WebKit

/// Find in page, page zoom, keyboard tab switching and notices.
extension BrowserWindowController {
    // MARK: Find in page

    @objc func findInPage(_ sender: Any?) {
        guard model.selected != nil else { NSSound.beep(); return }
        if let findBar {
            window?.makeFirstResponder(findBar.field)
            return
        }
        let bar = FindBarView()
        bar.onFind = { [weak self] text, backwards in self?.find(text, backwards: backwards) }
        bar.onClose = { [weak self] in self?.closeFindBar() }
        bar.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
        ])
        findBar = bar
        window?.makeFirstResponder(bar.field)
    }

    @objc func findNext(_ sender: Any?) {
        guard let findBar else { findInPage(sender); return }
        findBar.nextMatch()
    }

    @objc func findPrevious(_ sender: Any?) {
        guard let findBar else { findInPage(sender); return }
        findBar.previousMatch()
    }

    func closeFindBar() {
        findBar?.removeFromSuperview()
        findBar = nil
        if let webView = model.selected?.webView {
            webView.evaluateJavaScript("window.getSelection().removeAllRanges()", completionHandler: nil)
            window?.makeFirstResponder(webView)
        }
    }

    private func find(_ text: String, backwards: Bool) {
        guard let webView = model.selected?.webView else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        Task { [weak self] in
            let found = (try? await webView.find(text, configuration: configuration))?.matchFound ?? false
            self?.findBar?.showResult(found: found)
        }
    }

    // MARK: Page zoom

    private static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    @objc func zoomInPage(_ sender: Any?) {
        if shownEaselID != nil { easelCanvas.zoomIn(); return }
        guard let webView = model.selected?.webView else { return }
        webView.pageZoom = Self.zoomSteps.first { $0 > webView.pageZoom + 0.01 } ?? Self.zoomSteps.last!
    }

    @objc func zoomOutPage(_ sender: Any?) {
        if shownEaselID != nil { easelCanvas.zoomOut(); return }
        guard let webView = model.selected?.webView else { return }
        webView.pageZoom = Self.zoomSteps.last { $0 < webView.pageZoom - 0.01 } ?? Self.zoomSteps.first!
    }

    @objc func actualSizePage(_ sender: Any?) {
        if shownEaselID != nil { easelCanvas.actualSize(); return }
        model.selected?.webView.pageZoom = 1
    }

    // MARK: Switching tabs from the keyboard

    /// ⌘1…⌘8 pick that tab in the current Space; ⌘9 picks the last one.
    @objc func selectTabNumber(_ sender: Any?) {
        guard let number = (sender as? NSMenuItem)?.tag else { return }
        let tabs = model.currentSpace.pinned + model.currentSpace.tabs
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { NSSound.beep(); return }
        hideEasel()
        model.select(tabs[index])
    }

    @objc func nextTab(_ sender: Any?) { cycleTabs(by: 1) }
    @objc func previousTab(_ sender: Any?) { cycleTabs(by: -1) }

    private func cycleTabs(by offset: Int) {
        let tabs = model.currentSpace.pinned + model.currentSpace.tabs
        guard tabs.count > 1 else { return }
        let current = tabs.firstIndex { $0 === model.selected } ?? 0
        hideEasel()
        model.select(tabs[((current + offset) % tabs.count + tabs.count) % tabs.count])
    }
}

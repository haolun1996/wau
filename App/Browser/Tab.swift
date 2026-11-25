import AppKit
import Core
import WebKit

/// One browser tab: a web view plus the state the sidebar shows for it.
@MainActor
final class Tab: NSObject {
    let id: UUID
    let webView: WKWebView
    private(set) var title = "New Tab"
    private(set) var url: URL?
    var lastActiveAt = Date()
    /// For pinned tabs and favorites: the page they return to when closed.
    var pinnedURL: URL?
    /// The site icon; `nil` shows a generic globe.
    var favicon: NSImage? {
        didSet { if favicon !== oldValue { onChange?(self) } }
    }

    /// Called whenever title, URL, icon or navigation state changes.
    var onChange: ((Tab) -> Void)?
    /// Called when a page finishes loading (used to fetch its icon).
    var onFinishLoading: ((Tab) -> Void)?
    /// Asks the owner to open a tab. `configuration` is set when WebKit
    /// requests a new window (it must be used as-is); `url` is set for
    /// links the browser decides to open in a new tab.
    var onOpenTab: ((_ configuration: WKWebViewConfiguration?, _ url: URL?, _ inBackground: Bool) -> Tab?)?
    var onRequestClose: ((Tab) -> Void)?
    /// A link or response turned into a file download.
    var onDownload: ((WKDownload) -> Void)?

    /// A restored tab doesn't load until it is first shown, so relaunching
    /// with many tabs stays fast. This holds what to load then.
    private var pendingRestore: (url: URL?, sessionState: Data?)?
    private var observations: [NSKeyValueObservation] = []

    /// Creates a tab. With `record`, the tab shows the saved title and URL
    /// but loads nothing until `activateIfNeeded()`.
    init(configuration: WKWebViewConfiguration, restoring record: TabRecord? = nil) {
        id = record?.id ?? UUID()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // Right-click ▸ Inspect Element, for web developers.
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self

        if let record {
            title = record.title
            url = record.url
            lastActiveAt = record.lastActiveAt
            pinnedURL = record.pinnedURL
            pendingRestore = (record.url, record.sessionState)
        }

        let sync: @Sendable (WKWebView) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.syncFromWebView() }
        }
        observations = [
            webView.observe(\.title) { webView, _ in sync(webView) },
            webView.observe(\.url) { webView, _ in sync(webView) },
            webView.observe(\.canGoBack) { webView, _ in sync(webView) },
            webView.observe(\.canGoForward) { webView, _ in sync(webView) },
            webView.observe(\.isLoading) { webView, _ in sync(webView) },
        ]
    }

    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }
    var isLoading: Bool { webView.isLoading }

    /// Host without `www.`, shown in the sidebar's address pill.
    var displayHost: String {
        guard let host = url?.host() else { return url?.absoluteString ?? "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The tab as saved to the database.
    var record: TabRecord {
        TabRecord(
            id: id,
            pinnedURL: pinnedURL,
            url: url,
            title: title,
            lastActiveAt: lastActiveAt,
            sessionState: pendingRestore.map(\.sessionState) ?? (webView.interactionState as? Data)
        )
    }

    func load(_ url: URL) {
        pendingRestore = nil
        webView.load(URLRequest(url: url))
    }

    /// Loads a restored tab's page and history the first time it is shown.
    func activateIfNeeded() {
        guard let pending = pendingRestore else { return }
        pendingRestore = nil
        if let state = pending.sessionState {
            webView.interactionState = state
        }
        // Session state from another WebKit version can be rejected silently.
        if webView.url == nil, let url = pending.url {
            webView.load(URLRequest(url: url))
        }
    }

    /// Stops the page and detaches it; the tab must not be used afterwards.
    func tearDown() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        onChange = nil
        onFinishLoading = nil
        onOpenTab = nil
        onRequestClose = nil
        onDownload = nil
    }

    private func syncFromWebView() {
        url = webView.url ?? url
        let pageTitle = webView.title ?? ""
        title = pageTitle.isEmpty ? (url?.host() ?? "New Tab") : pageTitle
        onChange?(self)
    }
}

extension Tab: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        // ⌘-click opens the link in a background tab, as in Safari and Arc.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url {
            _ = onOpenTab?(nil, url, true)
            return .cancel
        }
        return .allow
    }

    /// Files the page can't show (zips, installers, …) are downloaded.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        onDownload?(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        onDownload?(download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinishLoading?(self)
    }

    /// `target="_blank"` links and `window.open`: WebKit loads the request
    /// into the web view we return, which must use its configuration.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        onOpenTab?(configuration, nil, false)?.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        onRequestClose?(self)
    }
}

@MainActor
enum WebViewConfiguration {
    /// - Parameter profileID: a Space's separate profile, or nil for the shared one.
    static func make(profileID: UUID? = nil) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Profiles.dataStore(for: profileID)
        // Without a Safari token some sites serve a reduced page to WKWebView.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }
}

/// Website data stores (cookies, logins, local storage, cache), one per
/// profile. Spaces with a separate profile get their own.
@MainActor
enum Profiles {
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    static func dataStore(for profileID: UUID?) -> WKWebsiteDataStore {
        guard let profileID else { return .default() }
        if let store = stores[profileID] { return store }
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        stores[profileID] = store
        return store
    }

    /// Permanently erases a profile's data, after its Space is deleted.
    static func erase(_ profileID: UUID) async {
        stores[profileID] = nil
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: profileID)
        } catch {
            // WebKit refuses while a web view still uses the store; it is
            // only left on disk, and nothing will open it again.
        }
    }
}

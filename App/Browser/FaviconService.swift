import AppKit
import Core
import OSLog
import Storage
import WebKit

/// Finds, downloads and remembers site icons, one per host.
@MainActor
final class FaviconService {
    private static let logger = Logger(subsystem: "dev.wau.Wau", category: "Favicons")
    /// Stored and drawn at 64px: sharp at 16pt on 2× and 3× screens.
    private static let pixelSize = 64
    private static let maxDownloadBytes = 1_000_000

    private let database: AppDatabase
    private var memory: [String: NSImage] = [:]
    /// Hosts known to have no stored icon, to skip repeated lookups.
    private var noStoredIcon: Set<String> = []
    /// Hosts already fetched this launch; icons rarely change, once is enough.
    private var fetchedThisLaunch: Set<String> = []
    private var inFlight: Set<String> = []

    init(database: AppDatabase) {
        self.database = database
    }

    static func host(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url.host()?.lowercased()
    }

    /// The remembered icon for `url`'s site, if any.
    func cachedIcon(for url: URL?) -> NSImage? {
        guard let host = Self.host(of: url) else { return nil }
        if let image = memory[host] { return image }
        if noStoredIcon.contains(host) { return nil }
        if let data = try? database.favicon(host: host), let image = Self.icon(fromPNG: data) {
            memory[host] = image
            return image
        }
        noStoredIcon.insert(host)
        return nil
    }

    /// Shows the remembered icon on `tab` and, once per site per launch,
    /// fetches a fresh one from the page. `onUpdate` receives the host and
    /// new icon so every tab on that site can be updated.
    func refresh(_ tab: Tab, onUpdate: @escaping (String, NSImage) -> Void) {
        guard let pageURL = tab.webView.url, let host = Self.host(of: pageURL) else { return }
        if let cached = cachedIcon(for: pageURL) { tab.favicon = cached }
        guard !fetchedThisLaunch.contains(host), !inFlight.contains(host) else { return }
        inFlight.insert(host)
        fetchedThisLaunch.insert(host)

        let webView = tab.webView
        Task {
            defer { inFlight.remove(host) }
            let links = await Self.iconLinks(in: webView)
            for candidate in FaviconCandidates.rank(links, pageURL: pageURL) {
                guard let png = await Self.downloadPNG(from: candidate),
                      let image = Self.icon(fromPNG: png)
                else { continue }
                memory[host] = image
                noStoredIcon.remove(host)
                do {
                    try database.saveFavicon(host: host, png: png)
                } catch {
                    Self.logger.error("Saving icon for \(host, privacy: .public) failed: \(error)")
                }
                onUpdate(host, image)
                return
            }
        }
    }

    /// Reads the page's `<link rel=icon>` elements. Runs in Wau's own script
    /// world, so page scripts can't see or interfere with it.
    private static func iconLinks(in webView: WKWebView) async -> [IconLink] {
        let script = """
        JSON.stringify(Array.from(document.querySelectorAll('link[rel]')).map(l => ({
            href: l.href, rel: l.rel || '', sizes: l.getAttribute('sizes') || '', type: l.type || ''
        })))
        """
        do {
            guard let json = try await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) as? String,
                  let data = json.data(using: .utf8)
            else { return [] }
            return try JSONDecoder().decode([IconLink].self, from: data)
        } catch {
            return []
        }
    }

    /// Downloads an image and re-encodes it as a small PNG; nil if it isn't
    /// a usable image.
    private static func downloadPNG(from url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              data.count <= maxDownloadBytes,
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let image = NSImage(data: data), image.isValid, image.size.width > 0
        else { return nil }
        return thumbnailPNG(of: image)
    }

    private static func thumbnailPNG(of image: NSImage) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
            from: .zero, operation: .copy, fraction: 1
        )
        return rep.representation(using: .png, properties: [:])
    }

    private static func icon(fromPNG data: Data) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

import Foundation

/// A `<link>` element that may point at a site icon.
public struct IconLink: Decodable, Equatable, Sendable {
    public var href: String
    public var rel: String
    public var sizes: String
    public var type: String

    public init(href: String, rel: String, sizes: String = "", type: String = "") {
        self.href = href
        self.rel = rel
        self.sizes = sizes
        self.type = type
    }
}

/// Orders a page's icon links from best to worst for a sidebar icon.
public enum FaviconCandidates {
    /// Icons are shown at 16pt, so 32–64px looks sharp on Retina screens.
    static let idealSize = 64

    /// Best-first icon URLs to try, ending with `/favicon.ico` as a fallback.
    public static func rank(_ links: [IconLink], pageURL: URL) -> [URL] {
        let scored: [(url: URL, score: Int)] = links.compactMap { link in
            let rels = Set(link.rel.lowercased().split(separator: " ").map(String.init))
            let isAppleTouch = rels.contains("apple-touch-icon") || rels.contains("apple-touch-icon-precomposed")
            guard rels.contains("icon") || isAppleTouch,
                  let url = URL(string: link.href, relativeTo: pageURL)?.absoluteURL,
                  ["http", "https", "data"].contains(url.scheme?.lowercased() ?? ""),
                  !isSVG(link, url)
            else { return nil }
            return (url, score(size: largestSize(link.sizes), isAppleTouch: isAppleTouch))
        }

        var seen = Set<URL>()
        var ranked = scored
            .enumerated()
            .sorted { ($0.element.score, $0.offset) < ($1.element.score, $1.offset) }
            .map(\.element.url)
            .filter { seen.insert($0).inserted }

        if let origin = originURL(of: pageURL),
           let fallback = URL(string: "/favicon.ico", relativeTo: origin)?.absoluteURL,
           !seen.contains(fallback) {
            ranked.append(fallback)
        }
        return ranked
    }

    /// Lower is better.
    private static func score(size: Int?, isAppleTouch: Bool) -> Int {
        // Apple touch icons are typically 180px when they don't say.
        let size = size ?? (isAppleTouch ? 180 : nil)
        guard let size else { return 200 } // unknown, often a small .ico
        if size < 32 { return 300 + (32 - size) } // blurry when scaled up
        if size < idealSize { return idealSize - size }
        // Larger icons scale down cleanly; only the extra download costs.
        return (size - idealSize) / 4
    }

    /// `"16x16 32x32"` → 32. `"any"` or malformed → nil.
    static func largestSize(_ sizes: String) -> Int? {
        sizes.lowercased()
            .split(separator: " ")
            .compactMap { token -> Int? in
                let parts = token.split(separator: "x")
                guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
                return max(width, height)
            }
            .max()
    }

    /// AppKit can't reliably draw SVG favicons, so skip them.
    private static func isSVG(_ link: IconLink, _ url: URL) -> Bool {
        link.type.lowercased().contains("svg")
            || url.pathExtension.lowercased() == "svg"
            || link.rel.lowercased().contains("mask-icon")
    }

    private static func originURL(of url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host()
        else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.url
    }
}

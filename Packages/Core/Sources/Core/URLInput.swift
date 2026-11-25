import Foundation

/// Where text typed into the command bar should take the user.
public enum Destination: Equatable, Sendable {
    /// The text is an address to open directly.
    case url(URL)
    /// The text is a search query, to be sent to the search engine at `url`.
    case search(query: String, url: URL)

    public var url: URL {
        switch self {
        case .url(let url): url
        case .search(_, let url): url
        }
    }
}

public struct SearchEngine: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// A URL with `{query}` where the percent-encoded query goes.
    public let template: String

    public init(id: String? = nil, name: String, template: String) {
        self.id = id ?? name.lowercased()
        self.name = name
        self.template = template
    }

    public static let google = SearchEngine(id: "google", name: "Google", template: "https://www.google.com/search?q={query}")
    public static let duckDuckGo = SearchEngine(id: "duckduckgo", name: "DuckDuckGo", template: "https://duckduckgo.com/?q={query}")
    public static let bing = SearchEngine(id: "bing", name: "Bing", template: "https://www.bing.com/search?q={query}")
    public static let brave = SearchEngine(id: "brave", name: "Brave Search", template: "https://search.brave.com/search?q={query}")
    public static let ecosia = SearchEngine(id: "ecosia", name: "Ecosia", template: "https://www.ecosia.org/search?q={query}")

    public static let all = [google, duckDuckGo, bing, brave, ecosia]

    public static func engine(withID id: String) -> SearchEngine? {
        all.first { $0.id == id }
    }

    public func url(for query: String) -> URL? {
        // Encode everything that would end or split a query value.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: template.replacingOccurrences(of: "{query}", with: encoded))
    }
}

/// Decides whether command bar input is an address or a search.
public enum URLInput {
    private static let explicitSchemes: Set<String> = ["http", "https", "file", "about"]

    public static func destination(
        for raw: String,
        searchEngine: SearchEngine = .google
    ) -> Destination? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        let hasWhitespace = input.contains(where: \.isWhitespace)
        if !hasWhitespace {
            if let url = explicitURL(input) ?? implicitURL(input) {
                return .url(url)
            }
        }
        guard let url = searchEngine.url(for: input) else { return nil }
        return .search(query: input, url: url)
    }

    /// `https://example.com`, `about:blank`, `file:///tmp/a.html`.
    private static func explicitURL(_ input: String) -> URL? {
        guard let colon = input.firstIndex(of: ":") else { return nil }
        let scheme = input[..<colon].lowercased()
        guard explicitSchemes.contains(scheme), let url = URL(string: input) else { return nil }
        if scheme == "http" || scheme == "https" {
            guard input[input.index(after: colon)...].hasPrefix("//"),
                  let host = url.host(), !host.isEmpty
            else { return nil }
        }
        return url
    }

    /// `example.com/path`, `localhost:3000`, `192.168.1.1`.
    private static func implicitURL(_ input: String) -> URL? {
        let authorityEnd = input.firstIndex(where: { "/?#".contains($0) }) ?? input.endIndex
        let authority = input[..<authorityEnd]

        var host = authority
        if let colon = authority.lastIndex(of: ":") {
            host = authority[..<colon]
            guard isValidPort(authority[authority.index(after: colon)...]) else { return nil }
        }

        let lowerHost = host.lowercased()
        let scheme: String
        if lowerHost == "localhost" || isIPv4(lowerHost) {
            scheme = "http"
        } else if isDomain(lowerHost) {
            scheme = "https"
        } else {
            return nil
        }
        return URL(string: "\(scheme)://\(input)")
    }

    private static func isValidPort(_ port: Substring) -> Bool {
        guard (1...5).contains(port.count), port.allSatisfy(\.isASCIIDigit),
              let value = Int(port)
        else { return false }
        return (1...65535).contains(value)
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && UInt8($0) != nil }
    }

    private static func isDomain(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter)
        else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63
                && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

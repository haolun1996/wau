import Foundation
import Testing
@testable import Core

@Suite("URLInput")
struct URLInputTests {
    @Test("Addresses open directly", arguments: [
        ("https://example.com", "https://example.com"),
        ("http://example.com/a?b=c", "http://example.com/a?b=c"),
        ("HTTPS://Example.com", "HTTPS://Example.com"),
        ("about:blank", "about:blank"),
        ("file:///tmp/index.html", "file:///tmp/index.html"),
        ("example.com", "https://example.com"),
        ("news.ycombinator.com/item?id=1", "https://news.ycombinator.com/item?id=1"),
        ("sub-domain.example.co.uk", "https://sub-domain.example.co.uk"),
        ("example.com:8443/path", "https://example.com:8443/path"),
        ("localhost", "http://localhost"),
        ("localhost:3000", "http://localhost:3000"),
        ("localhost:3000/api", "http://localhost:3000/api"),
        ("192.168.1.10", "http://192.168.1.10"),
        ("10.0.0.1:8080", "http://10.0.0.1:8080"),
        ("  example.com  ", "https://example.com"),
    ])
    func opensAddress(input: String, expected: String) {
        #expect(URLInput.destination(for: input) == .url(URL(string: expected)!))
    }

    @Test("Everything else is a search", arguments: [
        "swift concurrency",
        "hello",
        "1.5",
        "what is example.com",
        "example.com:notaport",
        "localhost:99999",
        "-bad.com",
        "example.",
        ".com",
        "256.1.1.1x",
        "https://",
        "http:example.com",
    ])
    func searches(input: String) {
        guard case .search(let query, _) = URLInput.destination(for: input) else {
            Issue.record("expected a search for \(input)")
            return
        }
        #expect(query == input.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func emptyInputHasNoDestination() {
        #expect(URLInput.destination(for: "") == nil)
        #expect(URLInput.destination(for: "   \n") == nil)
    }

    @Test func searchQueryIsEncoded() {
        let destination = URLInput.destination(for: "a&b = c?#")
        #expect(destination?.url.absoluteString == "https://www.google.com/search?q=a%26b%20%3D%20c%3F%23")
    }

    @Test func customSearchEngine() {
        let engine = SearchEngine(name: "DuckDuckGo", template: "https://duckduckgo.com/?q={query}")
        let destination = URLInput.destination(for: "rust gpui", searchEngine: engine)
        #expect(destination == .search(query: "rust gpui", url: URL(string: "https://duckduckgo.com/?q=rust%20gpui")!))
    }
}

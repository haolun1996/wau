import Foundation
import Testing
@testable import Core

@Suite("FaviconCandidates")
struct FaviconCandidatesTests {
    let page = URL(string: "https://www.example.com/docs/page.html")!

    @Test func noLinksFallsBackToFaviconICO() {
        #expect(FaviconCandidates.rank([], pageURL: page) == [URL(string: "https://www.example.com/favicon.ico")!])
    }

    @Test func prefersSizesNearSixtyFourAndRelativeURLsResolve() {
        let links = [
            IconLink(href: "/tiny.png", rel: "icon", sizes: "16x16"),
            IconLink(href: "big.png", rel: "icon", sizes: "512x512"),
            IconLink(href: "/good.png", rel: "icon", sizes: "64x64"),
            IconLink(href: "/touch.png", rel: "apple-touch-icon"),
            IconLink(href: "/plain.ico", rel: "shortcut icon"),
        ]
        #expect(FaviconCandidates.rank(links, pageURL: page).map(\.absoluteString) == [
            "https://www.example.com/good.png",
            "https://www.example.com/touch.png", // assumed 180px
            "https://www.example.com/docs/big.png", // 512px scales down fine
            "https://www.example.com/plain.ico", // unknown size
            "https://www.example.com/tiny.png", // too small, blurry
            "https://www.example.com/favicon.ico",
        ])
    }

    @Test func skipsSVGMaskIconsAndOtherRels() {
        let links = [
            IconLink(href: "/a.svg", rel: "icon", type: "image/svg+xml"),
            IconLink(href: "/b.svg", rel: "icon"),
            IconLink(href: "/mask.png", rel: "mask-icon"),
            IconLink(href: "/style.css", rel: "stylesheet"),
            IconLink(href: "javascript:alert(1)", rel: "icon"),
        ]
        #expect(FaviconCandidates.rank(links, pageURL: page) == [URL(string: "https://www.example.com/favicon.ico")!])
    }

    @Test func duplicatesAreRemovedAndFallbackNotRepeated() {
        let links = [
            IconLink(href: "/favicon.ico", rel: "icon"),
            IconLink(href: "https://www.example.com/favicon.ico", rel: "shortcut icon"),
        ]
        #expect(FaviconCandidates.rank(links, pageURL: page) == [URL(string: "https://www.example.com/favicon.ico")!])
    }

    @Test func portIsKeptInFallback() {
        let local = URL(string: "http://localhost:3000/app")!
        #expect(FaviconCandidates.rank([], pageURL: local) == [URL(string: "http://localhost:3000/favicon.ico")!])
    }

    @Test("Size lists", arguments: [
        ("16x16", 16), ("16x16 32x32", 32), ("48X48", 48), ("192x96", 192),
    ])
    func largestSize(sizes: String, expected: Int) {
        #expect(FaviconCandidates.largestSize(sizes) == expected)
    }

    @Test func unparseableSizes() {
        #expect(FaviconCandidates.largestSize("") == nil)
        #expect(FaviconCandidates.largestSize("any") == nil)
        #expect(FaviconCandidates.largestSize("axb") == nil)
    }
}

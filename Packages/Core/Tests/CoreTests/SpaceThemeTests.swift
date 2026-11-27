import Testing
@testable import Core

@Suite("SpaceTheme")
struct SpaceThemeTests {
    @Test func hexRoundTrip() {
        #expect(ThemeColor(hex: "#2B3A73") == ThemeColor(0x2B3A73))
        #expect(ThemeColor(hex: "2b3a73") == ThemeColor(0x2B3A73))
        #expect(ThemeColor(0x2B3A73).hexString == "#2B3A73")
    }

    @Test("Malformed hex is rejected", arguments: ["", "#", "#12345", "#1234567", "GGGGGG", "#12 456"])
    func rejectsBadHex(text: String) {
        #expect(ThemeColor(hex: text) == nil)
    }

    @Test func luminanceEndpoints() {
        #expect(ThemeColor(0x000000).relativeLuminance == 0)
        #expect(abs(ThemeColor(0xFFFFFF).relativeLuminance - 1) < 1e-9)
    }

    @Test func blendingAtFullAndZeroAlpha() {
        let red = ThemeColor(0xFF0000)
        let white = ThemeColor(0xFFFFFF)
        #expect(red.blended(over: white, alpha: 1) == red)
        #expect(red.blended(over: white, alpha: 0) == white)
    }

    @Test func themeIDsAreUniqueAndLookupWorks() {
        let ids = SpaceTheme.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for theme in SpaceTheme.all {
            #expect(SpaceTheme.theme(withID: theme.id) == theme)
        }
        #expect(SpaceTheme.theme(withID: "nope") == nil)
        #expect(SpaceTheme.all.contains(SpaceTheme.default))
        // Incognito windows' theme is found but not offered for Spaces.
        #expect(SpaceTheme.theme(withID: SpaceTheme.incognito.id) == .incognito)
        #expect(!SpaceTheme.all.contains(.incognito))
        #expect(!ids.contains(SpaceTheme.incognito.id))
    }

    /// The accent is the highlight behind white text in the command bar, so it
    /// must stay dark enough for white text to read (WCAG 3:1 for UI text).
    @Test("Accent keeps white text readable", arguments: SpaceTheme.all)
    func accentContrast(theme: SpaceTheme) {
        let contrast = 1.05 / (theme.accent.relativeLuminance + 0.05)
        #expect(contrast >= 3, "\(theme.name) accent \(theme.accent.hexString) contrast \(contrast)")
    }

    @Test func darkThemesAskForLightText() {
        let darkWindow = ThemeColor(0x1E1E1E)
        let lightWindow = ThemeColor(0xECECEC)
        #expect(SpaceTheme.songket.needsLightText(over: lightWindow, alpha: 0.75))
        #expect(SpaceTheme.songket.needsLightText(over: darkWindow, alpha: 0.75))
        #expect(!SpaceTheme.nyonya.needsLightText(over: lightWindow, alpha: 0.75))
    }
}

import Foundation

/// An sRGB color with components from 0 to 1.
public struct ThemeColor: Equatable, Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `ThemeColor(0x2B3A73)`
    public init(_ hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Parses `#2B3A73` or `2B3A73`; used for themes stored or synced as text.
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(value)
    }

    public var hexString: String {
        let components = [red, green, blue].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", components[0], components[1], components[2])
    }

    /// This color laid over `base` at `alpha` opacity.
    public func blended(over base: ThemeColor, alpha: Double) -> ThemeColor {
        ThemeColor(
            red: red * alpha + base.red * (1 - alpha),
            green: green * alpha + base.green * (1 - alpha),
            blue: blue * alpha + base.blue * (1 - alpha)
        )
    }

    /// WCAG relative luminance: 0 for black, 1 for white.
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// The colors of a Space: a top-to-bottom gradient tinting the window, and
/// an accent for highlights. Themes are inspired by Malaysian places and crafts.
public struct SpaceTheme: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// One line on what the colors come from, shown in the theme picker.
    public let inspiration: String
    public let top: ThemeColor
    public let bottom: ThemeColor
    public let accent: ThemeColor

    public init(id: String, name: String, inspiration: String, top: ThemeColor, bottom: ThemeColor, accent: ThemeColor) {
        self.id = id
        self.name = name
        self.inspiration = inspiration
        self.top = top
        self.bottom = bottom
        self.accent = accent
    }

    /// The gradient's midpoint, used to judge contrast.
    public var midpoint: ThemeColor {
        top.blended(over: bottom, alpha: 0.5)
    }

    /// Whether text over this theme's tint should be light. `base` is the
    /// window background the tint is laid over at `alpha`.
    public func needsLightText(over base: ThemeColor, alpha: Double) -> Bool {
        midpoint.blended(over: base, alpha: alpha).relativeLuminance < 0.36
    }

    public static func theme(withID id: String) -> SpaceTheme? {
        (all + [incognito]).first { $0.id == id }
    }

    /// Incognito windows only; not offered for Spaces.
    public static let incognito = SpaceTheme(
        id: "incognito",
        name: "Incognito",
        inspiration: "A kite flown after dark, lit only by the stars",
        top: ThemeColor(0x2E2A3A), bottom: ThemeColor(0x14121A), accent: ThemeColor(0x8E7CC3)
    )

    public static let bulan = SpaceTheme(
        id: "bulan",
        name: "Wau Bulan",
        inspiration: "A moonlit night sky and the gold of the wau's crescent tail",
        top: ThemeColor(0x2B3A73), bottom: ThemeColor(0x3E7A9A), accent: ThemeColor(0xB07812)
    )

    public static let langkawi = SpaceTheme(
        id: "langkawi",
        name: "Langkawi",
        inspiration: "Turquoise Andaman shallows fading into deep water",
        top: ThemeColor(0x3CC3C8), bottom: ThemeColor(0x0E5A78), accent: ThemeColor(0x14899A)
    )

    public static let cameron = SpaceTheme(
        id: "cameron",
        name: "Cameron",
        inspiration: "Rolling tea plantations under highland mist",
        top: ThemeColor(0xA3C98F), bottom: ThemeColor(0x3E6B48), accent: ThemeColor(0x4E8A55)
    )

    public static let melaka = SpaceTheme(
        id: "melaka",
        name: "Melaka",
        inspiration: "The terracotta red of Melaka's Dutch Square",
        top: ThemeColor(0xD0654F), bottom: ThemeColor(0x8A2C25), accent: ThemeColor(0xB23A2E)
    )

    public static let kinabalu = SpaceTheme(
        id: "kinabalu",
        name: "Kinabalu",
        inspiration: "Dawn breaking over the peak of Mount Kinabalu",
        top: ThemeColor(0x6C5B9E), bottom: ThemeColor(0xF2A07B), accent: ThemeColor(0x7A5FB0)
    )

    public static let songket = SpaceTheme(
        id: "songket",
        name: "Songket",
        inspiration: "Deep maroon silk woven with gold thread",
        top: ThemeColor(0x7A2142), bottom: ThemeColor(0x3E0F22), accent: ThemeColor(0xB8862A)
    )

    public static let batik = SpaceTheme(
        id: "batik",
        name: "Batik",
        inspiration: "Hand-drawn hibiscus florals in magenta and teal dyes",
        top: ThemeColor(0xC2407A), bottom: ThemeColor(0x2A8C8C), accent: ThemeColor(0xB8336D)
    )

    public static let nyonya = SpaceTheme(
        id: "nyonya",
        name: "Nyonya",
        inspiration: "Pastel pink and jade of Peranakan kuih and tiles",
        top: ThemeColor(0xF0A6C1), bottom: ThemeColor(0x6CC4B0), accent: ThemeColor(0xC94F86)
    )

    /// Every built-in theme, in picker order.
    public static let all: [SpaceTheme] = [bulan, langkawi, cameron, melaka, kinabalu, songket, batik, nyonya]

    public static let `default` = bulan
}

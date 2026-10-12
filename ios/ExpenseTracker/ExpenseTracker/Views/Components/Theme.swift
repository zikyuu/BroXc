import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: String) { self.init(uiColor: UIColor(hex: hex)) }

    static func dynamic(light: String, dark: String) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    /// Mixes `self` into the surface colour, the way a tinted tile sits softly on a card.
    func tint(_ amount: Double) -> Color { self.opacity(amount) }
}

extension Color {
    /// "#rrggbb" for a colour the user picked.
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

/// The BroXc look: warm cream paper, sage green, blush pink, butter yellow and a soft hand-drawn brown, matching the mascot.
enum Theme {
    static let bg = Color.dynamic(light: "fbf4e8", dark: "1c1612")
    static let surface = Color.dynamic(light: "fffdf8", dark: "2a211b")
    static let text = Color.dynamic(light: "4a3326", dark: "f4ebe0")
    static let muted = Color.dynamic(light: "8c7867", dark: "b0a090")
    static let line = Color.dynamic(light: "eee3d0", dark: "3a2f27")
    static let mutedLine = Color.dynamic(light: "d4c6b0", dark: "5e5043")
    static let accent = Color.dynamic(light: "6d8c5a", dark: "a9c893")
    /// Text and icons that sit on the accent colour: white on the deep green, deep brown on the light green of dark mode.
    static let onAccent = Color.dynamic(light: "ffffff", dark: "2a1f17")
    static let accentSoft = Color.dynamic(light: "e5ecd9", dark: "2c3a24")
    static let good = Color.dynamic(light: "6fa070", dark: "8dc08a")
    static let bad = Color.dynamic(light: "d9695b", dark: "ff8f80")
    static let warn = Color.dynamic(light: "e0a63f", dark: "f0c261")
    static let blueBg = Color.dynamic(light: "eaf0e0", dark: "26301f")       // pale sage
    static let orangeBg = Color.dynamic(light: "fbeccb", dark: "3b2d14")     // butter
    static let warmBg = Color.dynamic(light: "fcebdc", dark: "33261a")        // blush
    static let greenBg = Color.dynamic(light: "e3eedb", dark: "22301f")
    static let segBg = Color.dynamic(light: "f1e6d4", dark: "33291f")
    static let orangeInk = Color.dynamic(light: "a6691a", dark: "f0c261")
    static let miscColor = Color(hex: "b3a595")

    static let radius: CGFloat = 20
    static let paceColors: [PaceStatus: Color] = [.good: Color(hex: "8db27a"), .watch: Color(hex: "efc060"),
                                                  .over: Color(hex: "e8806d"), .neutral: Color(hex: "9a8b7a")]
}

extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .rounded) }
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = 16
    var background: Color = Theme.surface
    var bordered = true
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay { if bordered { RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line, lineWidth: 1) } }
    }
}

extension View {
    func card(padding: CGFloat = 16, background: Color = Theme.surface, bordered: Bool = true) -> some View {
        modifier(CardStyle(padding: padding, background: background, bordered: bordered))
    }

    /// A list of rows inside one rounded card, separated by hairlines.
    func flushCard() -> some View {
        self.background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line, lineWidth: 1) }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    func screenBackground() -> some View { self.background(Theme.bg.ignoresSafeArea()) }
}

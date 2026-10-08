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

/// Soft, friendly, colourful - and the same palette as the web build so the two read as one product.
enum Theme {
    static let bg = Color.dynamic(light: "fbf6ef", dark: "161412")
    static let surface = Color.dynamic(light: "ffffff", dark: "211e1b")
    static let text = Color.dynamic(light: "2a2420", dark: "f3ede5")
    static let muted = Color.dynamic(light: "857c72", dark: "a59c91")
    static let line = Color.dynamic(light: "eee6dc", dark: "332e29")
    static let mutedLine = Color.dynamic(light: "cfc6ba", dark: "5a5249")
    static let accent = Color.dynamic(light: "4b86f2", dark: "7aa5ff")
    static let accentSoft = Color.dynamic(light: "e6eeff", dark: "22304d")
    static let good = Color.dynamic(light: "2fb383", dark: "4fd1a5")
    static let bad = Color.dynamic(light: "e2574a", dark: "ff7b6e")
    static let warn = Color.dynamic(light: "f2a03d", dark: "f5b25c")
    static let blueBg = Color.dynamic(light: "eaf1ff", dark: "1f2b44")
    static let orangeBg = Color.dynamic(light: "fff0dc", dark: "3b2a14")
    static let warmBg = Color.dynamic(light: "fff4e8", dark: "33261a")
    static let greenBg = Color.dynamic(light: "e6f7ef", dark: "163127")
    static let segBg = Color.dynamic(light: "f0e9df", dark: "2b2723")
    static let orangeInk = Color.dynamic(light: "b9700f", dark: "f5b25c")
    static let miscColor = Color(hex: "a9a39a")

    static let radius: CGFloat = 20
    static let paceColors: [PaceStatus: Color] = [.good: Color(hex: "34c38f"), .watch: Color(hex: "f5a623"),
                                                  .over: Color(hex: "ef6b5b"), .neutral: Color(hex: "8a8177")]
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

import SwiftUI
import UIKit

/// Luna's colour roles (see docs/LUNA_BRAND.md), each with a light and a
/// dark value. Views use roles, never raw colours, so contrast holds in both
/// appearances. Lime is a fill: text and icons that need an accent use `accent`.
enum LunaColor {
    /// Screen ground.
    static let background = Color(light: 0xF4F4EF, dark: 0x10120F)
    /// Cards and rows.
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C201A)
    /// Controls on a surface, icon pucks, unselected chips.
    static let raised = Color(light: 0xE9EBE3, dark: 0x2A3025)
    /// Near-black cards that need attention ("Needs your OK").
    static let emphasis = Color(light: 0x181C17, dark: 0x050705)
    static let text = Color(light: 0x181C17, dark: 0xF6F7EF)
    static let secondaryText = Color(light: 0x5A6254, dark: 0xAFB8A5)
    static let separator = Color(light: 0xD4D8CE, dark: 0x343B2F)

    /// The electric lime: the main action, live states, highlights. Fill only.
    static let lime = Color(lunaHex: 0xD4F53C)
    /// Text and icons on lime (never white).
    static let onLime = Color(lunaHex: 0x181C17)
    /// Text on the emphasis card.
    static let onEmphasis = Color(lunaHex: 0xF6F7EF)
    static let onEmphasisSecondary = Color(lunaHex: 0xAFB8A5)

    /// A readable accent for text, icons and tints: deep olive in light, lime in dark.
    static let accent = Color(light: 0x4B6A00, dark: 0xD4F53C)
    /// In progress, informational. Same as the accent: one accent only.
    static let info = accent
    /// Done, connected, saved.
    static let success = Color(light: 0x32623C, dark: 0xACD4AD)
    /// Needs attention, waiting, retry available.
    static let warning = Color(light: 0x735200, dark: 0xE9C77B)
    /// Failed, recording, destructive.
    static let danger = Color(light: 0xA43432, dark: 0xFFADA5)
}

/// Luna's spacing and corner radii.
enum LunaMetrics {
    static let gutter: CGFloat = 20
    static let cardGap: CGFloat = 12
    static let cardPadding: CGFloat = 20
    static let cardRadius: CGFloat = 30
    static let rowRadius: CGFloat = 22
    static let pillHeight: CGFloat = 56
}

/// Luna's type scale. Every style is a Dynamic Type text style, so all text
/// scales with the user's size setting. SF Pro throughout; New York only for
/// Luna's own short lines.
extension Font {
    /// Greetings and screen titles ("Hi there", "Library").
    static let lunaDisplay = Font.system(.largeTitle, weight: .bold)
    /// Titles inside a screen.
    static let lunaTitle = Font.system(.title, weight: .bold)
    /// Card titles.
    static let lunaCardTitle = Font.system(.title2, weight: .bold)
    /// Section headings.
    static let lunaHeading = Font.system(.title3, weight: .bold)
    /// Luna's own spoken status ("Ready when you are").
    static let lunaLine = Font.system(.title2, design: .serif)
    /// Button labels.
    static let lunaButton = Font.system(.headline, weight: .bold)
    /// Emphasised labels (row titles, chips).
    static let lunaLabel = Font.subheadline.weight(.semibold)
    /// Small all-caps badges.
    static let lunaBadge = Font.system(.caption2, weight: .bold)
    /// Large decorative symbols inside illustrations and empty states.
    static let lunaSymbolLarge = Font.system(.largeTitle, weight: .regular)
    /// Symbols inside buttons and pucks.
    static let lunaSymbol = Font.system(.title3, weight: .semibold)
}

extension Color {
    /// A colour that resolves per appearance, from 0xRRGGBB values.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

// MARK: - Surfaces

/// The screen ground.
struct LunaBackground: View {
    var body: some View {
        LunaColor.background.ignoresSafeArea()
    }
}

private struct LunaCardModifier: ViewModifier {
    let radius: CGFloat
    let fill: Color
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.04), radius: 16, y: 3)
    }
}

private struct LunaEmphasisModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, .dark)
            .foregroundStyle(LunaColor.onEmphasis)
            .background(LunaColor.emphasis, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                // On the dark ground the card needs an edge to stay a card.
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                }
            }
    }
}

struct LunaPageChromeModifier: ViewModifier {
    var form = false

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(form ? .hidden : .automatic)
            .background(LunaBackground())
            .tint(LunaColor.accent)
            .toolbarBackground(LunaColor.background, for: .navigationBar)
    }
}

extension View {
    /// A white (dark: graphite) card, 30 pt corners.
    func lunaCard(radius: CGFloat = LunaMetrics.cardRadius, fill: Color = LunaColor.surface) -> some View {
        modifier(LunaCardModifier(radius: radius, fill: fill))
    }

    /// A list row surface, 22 pt corners.
    func lunaRow() -> some View {
        modifier(LunaCardModifier(radius: LunaMetrics.rowRadius, fill: LunaColor.surface))
    }

    /// The near-black attention card; content inside renders in dark appearance.
    func lunaEmphasisCard(radius: CGFloat = LunaMetrics.cardRadius) -> some View {
        modifier(LunaEmphasisModifier(radius: radius))
    }

    /// Ground, tint and bar colours for a pushed or tab screen.
    func lunaPageChrome() -> some View {
        modifier(LunaPageChromeModifier())
    }

    /// Same for `Form` and `List` screens.
    func lunaFormChrome() -> some View {
        modifier(LunaPageChromeModifier(form: true))
    }
}

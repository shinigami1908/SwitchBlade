import SwiftUI

// MARK: - Appearance

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

// MARK: - Palette
//
// Every colour below resolves through UITraitCollection, so a single definition
// serves both themes. Dark is the design target; light is a legible counterpart
// rather than a straight inversion.

extension Color {
    private static func adaptive(dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    /// Page background.
    static let appBackground = adaptive(
        dark: (0.043, 0.047, 0.055),
        light: (0.965, 0.965, 0.973)
    )

    /// Cards and grouped rows sitting on `appBackground`.
    static let appSurface = adaptive(
        dark: (0.086, 0.094, 0.110),
        light: (1.0, 1.0, 1.0)
    )

    /// Controls and chips sitting on `appSurface`.
    static let appSurfaceElevated = adaptive(
        dark: (0.129, 0.141, 0.161),
        light: (0.937, 0.941, 0.953)
    )

    /// Hairline separators and card borders.
    static let appBorder = adaptive(
        dark: (0.180, 0.192, 0.220),
        light: (0.878, 0.882, 0.898)
    )

    /// Primary accent — a muted periwinkle. Deliberately low-saturation: it
    /// carries interaction affordance without colouring the whole screen.
    static let appAccent = adaptive(
        dark: (0.565, 0.639, 0.914),
        light: (0.243, 0.325, 0.706)
    )

    /// Quieter companion for the accent, used where a second tint is genuinely
    /// needed rather than for decoration.
    static let appAccentAlt = adaptive(
        dark: (0.502, 0.741, 0.729),
        light: (0.129, 0.451, 0.443)
    )

    static let appPositive = adaptive(
        dark: (0.475, 0.769, 0.573),
        light: (0.145, 0.522, 0.278)
    )

    static let appWarning = adaptive(
        dark: (0.882, 0.706, 0.400),
        light: (0.639, 0.451, 0.078)
    )

    static let appNegative = adaptive(
        dark: (0.878, 0.478, 0.478),
        light: (0.702, 0.196, 0.196)
    )
}

// MARK: - Metrics

enum Metrics {
    /// Horizontal page gutter. 20pt reads well on the 393pt-wide 15 Pro.
    static let gutter: CGFloat = 20
    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 12
    static let sectionSpacing: CGFloat = 28
    static let hairline: CGFloat = 1
}

// MARK: - Reusable surfaces

/// Standard card chrome: surface fill, hairline border, rounded corners.
struct CardBackground: ViewModifier {
    var radius: CGFloat = Metrics.cardRadius
    var fill: Color = .appSurface

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: Metrics.hairline)
            )
    }
}

extension View {
    func cardSurface(radius: CGFloat = Metrics.cardRadius, fill: Color = .appSurface) -> some View {
        modifier(CardBackground(radius: radius, fill: fill))
    }

    /// Section heading treatment used across the app.
    func sectionTitleStyle() -> some View {
        self
            .font(.system(.title3, design: .serif, weight: .semibold))
    }

    /// Small all-caps label above a block of content. Secondary by default —
    /// these are signposts, not highlights.
    func eyebrowStyle(_ color: Color = .secondary) -> some View {
        self
            .font(.caption2.weight(.semibold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

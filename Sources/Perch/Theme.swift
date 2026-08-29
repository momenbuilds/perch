import SwiftUI

/// Every size, colour, font and spring the island uses. One file so the whole look can
/// be retuned without hunting through views.
enum Theme {

    // MARK: Geometry

    static let collapsedSize = CGSize(width: 404, height: 46)
    static let expandedSize  = CGSize(width: 848, height: 472)

    /// The body is welded to the top bezel: near-square on top, deep curve below.
    static let shoulder: CGFloat = 11
    static let collapsedBottomRadius: CGFloat = 23
    static let expandedBottomRadius: CGFloat = 32

    static let traceInset: CGFloat = 3.5
    static let traceWidth: CGFloat = 3

    static let cardRadius: CGFloat = 16
    static let rowRadius: CGFloat = 12

    // MARK: Surfaces

    /// A hair of light at the top so the black body has a horizon instead of reading flat.
    static let bodyGradient = LinearGradient(
        colors: [Color(white: 0.08), Color(white: 0.015), .black],
        startPoint: .top, endPoint: .bottom
    )
    static let bodyEdge = LinearGradient(
        colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
        startPoint: .top, endPoint: .bottom
    )

    static let card       = Color.white.opacity(0.045)
    static let cardHi     = Color.white.opacity(0.075)
    static let cardStroke = Color.white.opacity(0.07)
    static let row        = Color.white.opacity(0.055)
    static let rowHover   = Color.white.opacity(0.10)

    // MARK: Text

    static let text1 = Color.white
    static let text2 = Color.white.opacity(0.58)
    static let text3 = Color.white.opacity(0.34)

    // MARK: Accents

    static let focusAccent = Color(red: 0.04, green: 0.52, blue: 1.00)   // #0A84FF

    /// Focus-session accents the user can choose between.
    static let accents: [Color] = [
        Color(red: 0.04, green: 0.52, blue: 1.00),   // Blue
        Color(red: 0.37, green: 0.36, blue: 0.90),   // Indigo
        Color(red: 0.18, green: 0.75, blue: 0.80),   // Teal
        Color(red: 1.00, green: 0.62, blue: 0.04),   // Amber
        Color(red: 1.00, green: 0.25, blue: 0.42),   // Rose
        Color(red: 0.20, green: 0.82, blue: 0.62)    // Mint
    ]
    static let accentNames = ["Blue", "Indigo", "Teal", "Amber", "Rose", "Mint"]

    static func accent(_ index: Int) -> Color {
        accents[max(0, min(index, accents.count - 1))]
    }

    /// Dot colours for task groups.
    static let groupPalette: [Color] = [
        Color(red: 0.42, green: 0.62, blue: 0.98),
        Color(red: 0.36, green: 0.80, blue: 0.55),
        Color(red: 0.90, green: 0.62, blue: 0.28),
        Color(red: 0.78, green: 0.45, blue: 0.92),
        Color(red: 0.95, green: 0.42, blue: 0.50),
        Color(red: 0.45, green: 0.78, blue: 0.85)
    ]

    static func groupColor(_ index: Int) -> Color {
        groupPalette[max(0, min(index, groupPalette.count - 1))]
    }
    static let shortAccent = Color(red: 0.19, green: 0.82, blue: 0.35)   // #30D158
    static let longAccent  = Color(red: 0.75, green: 0.35, blue: 0.95)   // #BF5AF2
    static let danger      = Color(red: 1.00, green: 0.23, blue: 0.19)   // #FF3B30
    static let gold        = Color(red: 1.00, green: 0.80, blue: 0.20)

    static let emptyCell = Color.white.opacity(0.055)

    /// Blue ramp for the streak grid: 0 sessions → empty, 4+ → full accent.
    static func heat(_ sessions: Int, accent: Color) -> Color {
        switch sessions {
        case ...0: return emptyCell
        case 1:    return accent.opacity(0.30)
        case 2:    return accent.opacity(0.55)
        case 3:    return accent.opacity(0.78)
        default:   return accent
        }
    }

    // MARK: Type

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: Motion

    static let openSpring    = Animation.spring(response: 0.40, dampingFraction: 0.80)
    static let contentSpring = Animation.spring(response: 0.30, dampingFraction: 0.85)
    static let snappy        = Animation.spring(response: 0.22, dampingFraction: 0.72)
}

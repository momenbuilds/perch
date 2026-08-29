import SwiftUI

// MARK: - Card

struct CardBackground: ViewModifier {
    var radius: CGFloat = Theme.cardRadius
    var fill: Color = Theme.card

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    func card(radius: CGFloat = Theme.cardRadius, fill: Color = Theme.card) -> some View {
        modifier(CardBackground(radius: radius, fill: fill))
    }
}

// MARK: - Buttons

/// Small circular glyph button used throughout the panel.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 26
    var glyph: CGFloat = 11
    var tint: Color = Theme.text2
    var background: Color = Color.white.opacity(0.06)
    var help: String = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(hovering ? background.opacity(1.8) : background)
                    .frame(width: size, height: size)
                Image(systemName: symbol)
                    .font(.system(size: glyph, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.text1 : tint)
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .scaleEffect(hovering ? 1.08 : 1)
        .animation(Theme.snappy, value: hovering)
        .onHover { hovering = $0 }
    }
}

/// The big transport control in the middle of the timer card.
struct PlayButton: View {
    let isRunning: Bool
    let accent: Color
    var size: CGFloat = 46
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRunning ? Theme.danger : accent)
                    .frame(width: size, height: size)
                    .shadow(color: (isRunning ? Theme.danger : accent).opacity(0.55),
                            radius: hovering ? 14 : 8)
                Image(systemName: isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.34, weight: .black))
                    .foregroundStyle(.white)
                    .offset(x: isRunning ? 0 : 1.5)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.06 : 1)
        .animation(Theme.snappy, value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Segmented control

struct SegmentedPills<T: Hashable & Identifiable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    var accent: Color = Theme.focusAccent

    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let active = item == selection
                Button {
                    withAnimation(Theme.snappy) { selection = item }
                } label: {
                    Text(label(item))
                        .font(Theme.ui(11.5, .semibold))
                        .foregroundStyle(active ? Theme.text1 : Theme.text2)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background {
                            if active {
                                Capsule()
                                    .fill(accent.opacity(0.28))
                                    .overlay(Capsule().strokeBorder(accent.opacity(0.55), lineWidth: 1))
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.05), in: Capsule())
    }
}

/// Icon-only tab strip for the lower right card.
struct TabStrip: View {
    @Binding var selection: PanelTab
    var accent: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                let active = tab == selection
                Button {
                    withAnimation(Theme.snappy) { selection = tab }
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(active ? accent : Theme.text3)
                        .frame(width: 24, height: 20)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(accent.opacity(0.16))
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Readouts

struct StatTile: View {
    let value: String
    let caption: String
    var symbol: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(tint)
                Text(caption.uppercased())
                    .font(Theme.ui(9, .bold))
                    .kerning(0.6)
                    .foregroundStyle(Theme.text3)
            }
            Text(value)
                .font(Theme.mono(20, .bold))
                .foregroundStyle(Theme.text1)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .card(radius: 12, fill: Theme.cardHi)
    }
}

/// Header used by every card in the panel.
struct CardHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    var tint: Color = Theme.text1
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(Theme.ui(13, .semibold))
                .foregroundStyle(Theme.text1)
            Spacer(minLength: 6)
            trailing
        }
    }
}

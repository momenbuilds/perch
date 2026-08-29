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

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(background)
                    .frame(width: size, height: size)
                Image(systemName: symbol)
                    .font(.system(size: glyph, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The big transport control in the middle of the timer card.
struct PlayButton: View {
    let isRunning: Bool
    let accent: Color
    var size: CGFloat = 46
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRunning ? Theme.danger : accent)
                    .frame(width: size, height: size)
                    .shadow(color: Theme.captureMode ? .clear
                                : (isRunning ? Theme.danger : accent).opacity(0.55),
                            radius: 8)
                Image(systemName: isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.34, weight: .black))
                    .foregroundStyle(.white)
                    .offset(x: isRunning ? 0 : 1.5)
            }
        }
        .buttonStyle(.plain)
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

// MARK: - Meters

/// Circular load gauge with the reading in the middle.
struct Gauge: View {
    let value: Double          // 0…1
    let caption: String
    let tint: Color
    var diameter: CGFloat = 74
    var thickness: CGFloat = 7

    /// Calm at rest, warm under pressure — the colour says as much as the number.
    private var stroke: Color {
        if value >= 0.85 { return Theme.danger }
        if value >= 0.65 { return Theme.gold }
        return tint
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.07), lineWidth: thickness)
                Circle()
                    .trim(from: 0, to: max(value, 0.001))
                    .stroke(
                        AngularGradient(colors: [stroke.opacity(0.55), stroke],
                                        center: .center,
                                        startAngle: .degrees(0),
                                        endAngle: .degrees(360 * max(value, 0.001))),
                        style: StrokeStyle(lineWidth: thickness, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Theme.captureMode ? .clear : stroke.opacity(0.5), radius: 5)
                    // Only the ring animates: crossfading the digits ghosts them.
                    .animation(Theme.contentSpring, value: value)

                VStack(spacing: -1) {
                    Text("\(Int((value * 100).rounded()))")
                        .font(Theme.mono(20, .bold))
                        .foregroundStyle(Theme.text1)
                    Text("%")
                        .font(Theme.ui(9, .bold))
                        .foregroundStyle(Theme.text3)
                }
            }
            .frame(width: diameter, height: diameter)

            Text(caption.uppercased())
                .font(Theme.ui(9, .bold))
                .kerning(0.7)
                .foregroundStyle(Theme.text3)
        }
    }
}

/// Recent history behind a gauge.
struct Sparkline: View {
    let samples: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let points = samples.suffix(40)
            if points.count > 1 {
                let step = geo.size.width / CGFloat(points.count - 1)
                let scaled = points.enumerated().map { index, value in
                    CGPoint(x: CGFloat(index) * step,
                            y: geo.size.height * (1 - CGFloat(min(max(value, 0), 1))))
                }

                Path { path in
                    path.move(to: scaled[0])
                    for point in scaled.dropFirst() { path.addLine(to: point) }
                }
                .stroke(tint.opacity(0.9),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height))
                    for point in scaled { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: scaled[scaled.count - 1].x, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
            } else {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                }
                .stroke(tint.opacity(0.35), lineWidth: 1.5)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Horizontal meter used for the secondary readouts.
struct MeterRow: View {
    let symbol: String
    let label: String
    let detail: String
    var fraction: Double?
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 13)

            Text(label)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.text2)
                .frame(width: 52, alignment: .leading)

            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule()
                            .fill(LinearGradient(colors: [tint.opacity(0.7), tint],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
                    }
                }
                .frame(height: 5)
            } else {
                Spacer(minLength: 0)
            }

            Text(detail)
                .font(Theme.mono(10.5, .semibold))
                .foregroundStyle(Theme.text1)
                .frame(minWidth: 78, alignment: .trailing)
        }
        .animation(Theme.contentSpring, value: fraction ?? 0)
    }
}

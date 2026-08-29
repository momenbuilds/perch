import SwiftUI

/// The island: a black body welded to the top bezel that grows from a timer pill into a
/// full panel, with the current phase traced in colour around its inner edge.
struct IslandView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var ui: UIState

    private var size: CGSize { ui.size }
    private var bottomRadius: CGFloat {
        ui.isExpanded ? Theme.expandedBottomRadius : Theme.collapsedBottomRadius
    }
    private var shape: IslandShape {
        IslandShape(shoulder: Theme.shoulder, bottomRadius: bottomRadius)
    }

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var island: some View {
        ZStack {
            shape
                .fill(Theme.bodyGradient)
                .overlay(shape.stroke(Theme.bodyEdge, lineWidth: 1))
                // Shadows are cast downward only: a halo above the top edge would
                // break the illusion that the island is part of the bezel.
                .shadow(color: .black.opacity(0.5), radius: 14, y: 10)
                .shadow(color: store.isRunning ? store.accent.opacity(0.30) : .clear,
                        radius: 22, y: 10)

            content
                .padding(.horizontal, 16)
                .padding(.vertical, ui.isExpanded ? 16 : 0)
                // Pin the content to the top and clip it: an oversized pane must never
                // be free to re-centre and crop the whole panel.
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)

            ConfettiBurst(trigger: store.celebration, accent: store.accent)
                .clipShape(shape)

            trace
        }
        .frame(width: size.width, height: size.height)
        .contentShape(shape)
        .animation(Theme.openSpring, value: ui.isExpanded)
        .onChange(of: store.isRunning) { running in
            // Starting a session gets the panel out of the way, if the user wants that.
            if running, store.settings.collapseOnStart {
                withAnimation(Theme.openSpring) { ui.collapse() }
            }
        }
    }

    // MARK: Phase hairline

    private var trace: some View {
        ProgressTrace(shoulder: Theme.shoulder,
                      bottomRadius: bottomRadius - Theme.traceInset)
            .trim(from: 0, to: max(store.progress, 0.0001))
            .stroke(
                LinearGradient(colors: [store.accent.opacity(0.75), store.accent],
                               startPoint: .leading, endPoint: .trailing),
                style: StrokeStyle(lineWidth: Theme.traceWidth, lineCap: .round, lineJoin: .round)
            )
            .shadow(color: store.accent.opacity(0.7), radius: 7)
            .padding(Theme.traceInset)
            .opacity(store.progress > 0.0005 ? 1 : 0)
            .animation(.linear(duration: 0.4), value: store.progress)
            .animation(Theme.contentSpring, value: store.phase)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if ui.isExpanded {
            ExpandedPanel(store: store, ui: ui)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        } else {
            CollapsedPill(store: store)
                .transition(.opacity)
        }
    }
}

// MARK: - Collapsed

private struct CollapsedPill: View {
    @ObservedObject var store: AppStore
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(store.accent.opacity(0.18))
                    .frame(width: 26, height: 26)
                    .scaleEffect(store.isRunning && pulse ? 1.18 : 1)
                    .opacity(store.isRunning && pulse ? 0.4 : 1)
                Image(systemName: store.phase.symbol)
                    .font(Theme.ui(12, .semibold))
                    .foregroundStyle(store.accent)
            }
            .animation(store.isRunning
                       ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                       : .default,
                       value: pulse)

            Text(store.clockText)
                .font(Theme.mono(22, .semibold))
                .foregroundStyle(Theme.text1)

            Spacer(minLength: 10)

            Text(store.toast ?? store.subtitle)
                .font(Theme.ui(13.5))
                .foregroundStyle(store.toast != nil ? store.accent : Theme.text2)
                .lineLimit(1)
                .truncationMode(.tail)

            CycleDots(position: store.cyclePosition % max(store.settings.sessionsPerCycle, 1),
                      total: store.settings.sessionsPerCycle,
                      accent: store.accent)
        }
        // The top edge is flat and the bottom is deeply curved, so content centred in
        // the raw frame reads top-heavy. Nudge it into the optical centre.
        .padding(.top, 8)
        .onAppear { pulse = true }
    }
}

/// Four dots showing where you are in the current long-break cycle.
struct CycleDots: View {
    let position: Int
    let total: Int
    let accent: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(total, 1), id: \.self) { index in
                Circle()
                    .fill(index < position ? accent : Color.white.opacity(0.18))
                    .frame(width: 5, height: 5)
            }
        }
        .animation(Theme.snappy, value: position)
    }
}

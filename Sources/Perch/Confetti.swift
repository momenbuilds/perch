import SwiftUI

/// A short burst of confetti fired when a focus session lands. Purely decorative and
/// self-cancelling: it renders nothing between bursts.
struct ConfettiBurst: View {
    /// Incrementing this fires a new burst.
    var trigger: Int
    var accent: Color

    @State private var pieces: [Piece] = []
    @State private var flying = false

    struct Piece: Identifiable {
        let id = UUID()
        let x: CGFloat
        let drop: CGFloat
        let drift: CGFloat
        let spin: Double
        let delay: Double
        let scale: CGFloat
        let color: Color
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                ForEach(pieces) { piece in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(piece.color)
                        .frame(width: 5 * piece.scale, height: 9 * piece.scale)
                        .rotationEffect(.degrees(flying ? piece.spin : 0))
                        .offset(x: piece.x * geo.size.width + (flying ? piece.drift : 0),
                                y: flying ? piece.drop * geo.size.height : -14)
                        .opacity(flying ? 0 : 1)
                        .animation(.easeOut(duration: 1.5).delay(piece.delay), value: flying)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _ in fire() }
    }

    private func fire() {
        guard trigger > 0 else { return }
        let palette = [accent, Theme.gold, Theme.shortAccent, .white, Theme.longAccent]
        pieces = (0..<26).map { _ in
            Piece(x: CGFloat.random(in: 0.08...0.92),
                  drop: CGFloat.random(in: 0.55...1.05),
                  drift: CGFloat.random(in: -40...40),
                  spin: Double.random(in: 180...900),
                  delay: Double.random(in: 0...0.22),
                  scale: CGFloat.random(in: 0.7...1.4),
                  color: palette.randomElement() ?? accent)
        }
        flying = false
        DispatchQueue.main.async { flying = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if flying { pieces = [] }
        }
    }
}

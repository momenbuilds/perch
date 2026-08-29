import SwiftUI

/// The island body.
///
/// The top edge runs the full width, flush with the bezel, and flares inward through a
/// pair of concave shoulders before dropping to a deeply rounded bottom. That inversion
/// is what makes the shape read as carved out of the display rather than as a floating
/// rounded rectangle parked near the top of the screen.
struct IslandShape: Shape {
    /// Radius of the concave fillets joining the body to the top edge.
    var shoulder: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottomRadius) }
        set { shoulder = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(0, min(shoulder, rect.width / 2, rect.height / 2))
        let b = max(0, min(bottomRadius, rect.width / 2 - s, rect.height - s))

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Concave flare down into the right-hand side.
        p.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.minY + s),
                       control: CGPoint(x: rect.maxX - s, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - s - b, y: rect.maxY),
                       control: CGPoint(x: rect.maxX - s, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + s + b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.maxY - b),
                       control: CGPoint(x: rect.minX + s, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + s, y: rect.minY + s))
        // Concave flare back up into the left-hand side.
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                       control: CGPoint(x: rect.minX + s, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// The phase hairline: the body outline with the top edge removed, running from the
/// left shoulder down, across the bottom and back up the right, so a trimmed stroke
/// reads as progress wrapping the island.
struct ProgressTrace: Shape {
    var shoulder: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottomRadius) }
        set { shoulder = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(0, min(shoulder, rect.width / 2, rect.height / 2))
        let b = max(0, min(bottomRadius, rect.width / 2 - s, rect.height - s))

        var p = Path()
        p.move(to: CGPoint(x: rect.minX + s, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + s + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + s, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - s - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - s, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY))
        return p
    }
}

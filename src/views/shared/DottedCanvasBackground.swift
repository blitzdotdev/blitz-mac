import SwiftUI

/// A subtle dotted grid background inspired by Nani.app's canvas pattern.
/// Uses a radial-gradient-style dot tile with a radial fade mask at the edges.
struct DottedCanvasBackground: View {
    var dotRadius: CGFloat = 1
    var spacing: CGFloat = 20
    var dotColor: Color = .primary.opacity(0.25)

    var body: some View {
        Canvas { context, size in
            let cols = Int(size.width / spacing) + 1
            let rows = Int(size.height / spacing) + 1
            let centerX = size.width / 2
            let centerY = size.height / 2
            let maxDist = hypot(centerX, centerY)

            for row in 0..<rows {
                for col in 0..<cols {
                    let x = CGFloat(col) * spacing + spacing / 2
                    let y = CGFloat(row) * spacing + spacing / 2
                    let dist = hypot(x - centerX, y - centerY)
                    let fade = max(0, 1 - (dist / (maxDist * 0.85)))

                    context.opacity = fade
                    let rect = CGRect(
                        x: x - dotRadius,
                        y: y - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    )
                    context.fill(Circle().path(in: rect), with: .color(dotColor))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

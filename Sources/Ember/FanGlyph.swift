import SwiftUI

struct FanGlyph: View {
    let spinning: Bool
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        SmoothSymbol(name: "fanblades.fill", pointSize: 23,
                     color: NSColor(spinning ? Palette.amber : Palette.muted),
                     rotating: spinning && animated && !reduceMotion)
            .accessibilityLabel(spinning ? "Fan spinning" : "Fan idle")
    }
}

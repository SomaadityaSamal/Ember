import SwiftUI

struct FanGlyph: View {
    let spinning: Bool
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !spinning || !animated || reduceMotion)) { context in
            let angle = spinning && animated && !reduceMotion ? context.date.timeIntervalSinceReferenceDate * 180 : 0
            Image(systemName: "fanblades.fill")
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(spinning ? Palette.amber : Palette.muted)
                .rotationEffect(.degrees(angle))
        }.accessibilityLabel(spinning ? "Fan spinning" : "Fan idle")
    }
}

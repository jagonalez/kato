import SwiftUI

/// Collapsed face of the floating panel: the animated 2D mascot sprite with
/// a badge count. Falls back to the old gradient orb when the artwork is
/// missing. State/mood changes swap the artwork with a 0.3 s crossfade.
struct OrbView: View {
    let count: Int
    /// Artwork name (e.g. "kato-idle-sleep") — drives the sprite.
    let imageName: String
    let state: MascotState
    /// Increments on each fresh event — the mascot moves on every bump.
    let tick: Int
    /// True while Spotify/Apple Music is playing — the mascot dances.
    let dancing: Bool

    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            mascot
                .frame(width: 216, height: 216)
            if count > 0 {
                Text("\(min(count, 99))")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .padding(9)
                    .background(Circle().fill(.red))
                    .offset(x: 10, y: -10)
            }
        }
        .frame(width: 240, height: 240)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityLabel("Kato, \(count) events")
    }

    private var mascot: some View {
        Group {
            if AssetLoader.image(named: imageName) != nil {
                Mascot2DView(imageName: imageName, state: state,
                             hovered: hovered, activityTick: tick,
                             dancing: dancing)
            } else {
                fallbackOrb
            }
        }
    }

    private var fallbackOrb: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [.indigo, .purple],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.white)
                    .font(.title3)
            }
    }
}

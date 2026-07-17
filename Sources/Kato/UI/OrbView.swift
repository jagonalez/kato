import SwiftUI

/// Collapsed face of the floating panel: the mascot with a badge count.
/// The mascot image reflects `state` (idle / alert / success) with a smooth
/// crossfade when it changes; falls back to the old gradient orb if the
/// artwork can't be found.
struct OrbView: View {
    let count: Int
    let state: MascotState

    var body: some View {
        ZStack(alignment: .topTrailing) {
            mascot
                .frame(width: 56, height: 56)
            if count > 0 {
                Text("\(min(count, 99))")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Circle().fill(.red))
                    .offset(x: 6, y: -6)
            }
        }
        .frame(width: 64, height: 64)
        .contentShape(Rectangle())
        .accessibilityLabel("Kato, \(count) events")
    }

    private var mascot: some View {
        Group {
            if let image = AssetLoader.image(named: state.imageName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                fallbackOrb
            }
        }
        // Crossfade (~0.3 s) when the state image changes.
        .id(state)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.3), value: state)
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

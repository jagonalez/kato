import SwiftUI

/// Collapsed face of the floating panel: the live 3D mascot with a badge
/// count. Falls back to the static PNG artwork (and then the old gradient
/// orb) if SceneKit is unavailable. State/mood changes animate inside the
/// scene; the static path keeps the 0.3 s crossfade.
struct OrbView: View {
    let count: Int
    /// Artwork name (e.g. "kato-idle-sleep") — drives the 3D mood and the
    /// static fallback image.
    let imageName: String
    let state: MascotState

    var body: some View {
        ZStack(alignment: .topTrailing) {
            mascot
                .frame(width: 168, height: 168)
            if count > 0 {
                Text("\(min(count, 99))")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .padding(9)
                    .background(Circle().fill(.red))
                    .offset(x: 10, y: -10)
            }
        }
        .frame(width: 192, height: 192)
        .contentShape(Rectangle())
        .accessibilityLabel("Kato, \(count) events")
    }

    private var mascot: some View {
        Group {
            if Mascot3DView.isAvailable {
                Mascot3DView(state: state, mood: MascotMood(imageName: imageName))
            } else if let image = AssetLoader.image(named: imageName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    // Crossfade (~0.3 s) when the static artwork swaps.
                    .id(imageName)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: imageName)
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

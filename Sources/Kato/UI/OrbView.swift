import SwiftUI

/// Collapsed face of the floating panel: the mascot with a badge count.
/// The mascot image reflects the current artwork (idle / alert / success /
/// idle variants) with a smooth crossfade when it changes; falls back to the
/// old gradient orb if the artwork can't be found.
struct OrbView: View {
    let count: Int
    /// Artwork to render (e.g. "kato-idle-sleep") — includes idle variants.
    let imageName: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            mascot
                .frame(width: 224, height: 224)
            if count > 0 {
                Text("\(min(count, 99))")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Circle().fill(.red))
                    .offset(x: 14, y: -14)
            }
        }
        .frame(width: 256, height: 256)
        .contentShape(Rectangle())
        .accessibilityLabel("Kato, \(count) events")
    }

    private var mascot: some View {
        Group {
            if let image = AssetLoader.image(named: imageName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                fallbackOrb
            }
        }
        // Crossfade (~0.3 s) when the artwork swaps (state or idle variant).
        .id(imageName)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.3), value: imageName)
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

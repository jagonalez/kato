import SwiftUI

/// Collapsed face of the floating panel: a small orb with a badge count.
struct OrbView: View {
    let count: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.indigo, .purple],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.white)
                        .font(.title3)
                }
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
}

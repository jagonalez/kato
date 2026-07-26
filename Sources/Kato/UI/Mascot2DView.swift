import SwiftUI

/// 2D mascot sprite (the Assets/Mascot PNG artwork) with slight procedural
/// motion: a continuous gentle bob, a soft state-colored glow behind the
/// sprite (cyan idle / pulsing orange alert / green success), a small
/// spring hop on every fresh event, and a subtle hover lift. Callers fall
/// back to the gradient orb when the artwork is missing.
struct Mascot2DView: View {
    /// Artwork name (e.g. "kato-idle-sleep") — swaps crossfade.
    let imageName: String
    let state: MascotState
    /// Mouse is over the orb.
    let hovered: Bool
    /// Increments on each fresh event — the mascot hops on every bump.
    let activityTick: Int

    @State private var bobUp = false
    @State private var hopOffset: CGFloat = 0
    @State private var glowPulse = false
    /// First observed tick (launch / persisted restore) stays silent.
    @State private var lastTick: Int?
    /// Artwork actually on screen — swaps are animated explicitly so idle
    /// variants drift (slow crossfade) while state changes pop (squash
    /// and spring in), masking the pose jump between unrelated poses.
    @State private var displayedName = ""
    @State private var gentleSwap = true

    private var glowColor: Color {
        switch state {
        case .alert: return .orange
        case .success: return .green
        case .idle: return .cyan
        }
    }

    private var glowOpacity: Double {
        switch state {
        case .alert: return glowPulse ? 0.55 : 0.30
        case .success: return 0.45
        case .idle: return 0.18
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [glowColor.opacity(glowOpacity), .clear],
                                     center: .center, startRadius: 12, endRadius: 84))
                .animation(.easeInOut(duration: 0.4), value: state)
            if let image = AssetLoader.image(named: displayedName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .id(displayedName)
                    .transition(gentleSwap
                        ? .opacity
                        : .scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .offset(y: (bobUp ? -3 : 3) + hopOffset)
        .scaleEffect(hovered ? 1.04 : 1.0)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: hovered)
        .onAppear {
            displayedName = imageName
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                bobUp = true
            }
            startAlertPulseIfNeeded()
        }
        .onChange(of: imageName) { _, newName in
            // Slow drift between idle variants; pop on a real state change.
            gentleSwap = newName.hasPrefix("kato-idle")
                && displayedName.hasPrefix("kato-idle")
            withAnimation(gentleSwap
                ? .easeInOut(duration: 1.0)
                : .spring(response: 0.35, dampingFraction: 0.6)) {
                displayedName = newName
            }
        }
        .onChange(of: state) { _, _ in
            glowPulse = false
            startAlertPulseIfNeeded()
        }
        .onChange(of: activityTick) { _, newTick in
            defer { lastTick = newTick }
            guard let last = lastTick, last != newTick else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { hopOffset = -16 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { hopOffset = 0 }
            }
        }
    }

    private func startAlertPulseIfNeeded() {
        guard state == .alert else { return }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            glowPulse = true
        }
    }
}

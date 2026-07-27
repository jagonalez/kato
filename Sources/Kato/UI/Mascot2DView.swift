import SwiftUI

/// 2D mascot sprite (the Assets/Mascot PNG artwork) with procedural motion:
/// a continuous breathing squash-and-stretch plus gentle sway, a soft
/// state-colored glow behind the sprite (cyan idle / pulsing orange alert /
/// green success), an alert tremble, floating "Zzz" on the sleep variant,
/// sparkles on success, a spring hop with landing squash on every fresh
/// event, and a subtle hover lift. Callers fall back to the gradient orb
/// when the artwork is missing.
struct Mascot2DView: View {
    /// Artwork name (e.g. "kato-idle-sleep") — swaps crossfade.
    let imageName: String
    let state: MascotState
    /// Mouse is over the orb.
    let hovered: Bool
    /// Increments on each fresh event — the mascot hops on every bump.
    let activityTick: Int
    /// True while music is playing — the mascot dances (flipbook dance
    /// artwork when present, procedural bop otherwise).
    let dancing: Bool

    @State private var bobUp = false
    @State private var breathing = false
    @State private var swaying = false
    @State private var trembling = false
    @State private var hopOffset: CGFloat = 0
    @State private var landingSquash = false
    @State private var glowPulse = false
    /// Dancing phase: alternates every beat while `dancing` is true.
    /// Mirrored into state (not read from the `dancing` let) so the
    /// recursive beat loop always sees the current value.
    @State private var isDancing = false
    @State private var danceUp = false
    /// Alternates the kato-dance-a / kato-dance-b flipbook frame each beat.
    @State private var danceFrameB = false
    /// First observed tick (launch / persisted restore) stays silent.
    @State private var lastTick: Int?
    /// Artwork actually on screen — swaps are animated explicitly so idle
    /// variants drift (slow crossfade) while state changes pop (squash
    /// and spring in), masking the pose jump between unrelated poses.
    @State private var displayedName = ""
    @State private var gentleSwap = true
    /// Briefly true while a blink frame is shown (~120 ms). Blink artwork
    /// is optional: `Assets/Mascot/<pose>-blink.png` (same pose, eyes
    /// closed). When the file is missing the mascot simply never blinks.
    @State private var blinking = false

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

    private var isSleeping: Bool { displayedName == "kato-idle-sleep" }

    /// Both flipbook dance frames exist in the bundle.
    private var hasDanceArt: Bool {
        AssetLoader.image(named: "kato-dance-a") != nil
            && AssetLoader.image(named: "kato-dance-b") != nil
    }

    /// Artwork to draw right now: the flipbook dance frame while dancing
    /// (when those assets exist), the eyes-closed frame during a blink
    /// (when that asset exists), else the current pose.
    private var frameName: String {
        if isDancing, hasDanceArt {
            return danceFrameB ? "kato-dance-b" : "kato-dance-a"
        }
        let blinkName = "\(displayedName)-blink"
        if blinking, AssetLoader.image(named: blinkName) != nil {
            return blinkName
        }
        return displayedName
    }

    /// Breathing pace: sleepy and slow on the sleep variant, quick and
    /// shallow while alerting, calm otherwise.
    private var breathDuration: Double {
        if isSleeping { return 4.2 }
        switch state {
        case .alert: return 1.1
        case .success: return 2.2
        case .idle: return 2.6
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [glowColor.opacity(glowOpacity), .clear],
                                     center: .center, startRadius: 12, endRadius: 84))
                .animation(.easeInOut(duration: 0.4), value: state)
            if let image = AssetLoader.image(named: frameName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    // Blink swaps are instant (no animation transaction);
                    // pose swaps keep their crossfade/pop transitions.
                    .id(frameName)
                    .transition(gentleSwap
                        ? .opacity
                        : .scale(scale: 0.8).combined(with: .opacity))
            }
            if isSleeping, !isDancing {
                SleepZsView()
                    .transition(.opacity)
            }
            if isDancing {
                MusicNotesView()
                    .transition(.opacity)
            }
            if state == .success {
                SuccessSparklesView()
                    .transition(.opacity)
            }
        }
        .offset(x: trembling ? 2 : (isDancing ? (danceUp ? 5 : -5) : -2),
                y: (isDancing ? (danceUp ? -8 : 2) : (bobUp ? -3 : 3)) + hopOffset)
        .scaleEffect(x: 1.0, y: isDancing ? (danceUp ? 1.05 : 0.93) : (breathing ? 1.018 : 0.99), anchor: .bottom)
        .scaleEffect(x: landingSquash ? 1.06 : 1.0,
                     y: landingSquash ? 0.92 : 1.0, anchor: .bottom)
        .rotationEffect(.degrees(isDancing ? (danceUp ? 7 : -7) : (swaying ? 1.4 : -1.4)), anchor: .bottom)
        .scaleEffect(hovered ? 1.04 : 1.0)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: hovered)
        .onAppear {
            displayedName = imageName
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                bobUp = true
            }
            withAnimation(.easeInOut(duration: breathDuration).repeatForever(autoreverses: true)) {
                breathing = true
            }
            withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) {
                swaying = true
            }
            startAlertPulseIfNeeded()
            scheduleBlink()
            isDancing = dancing
            if dancing { startDanceLoop() }
        }
        .onChange(of: dancing) { _, nowDancing in
            // Pop between the dance pose and the regular artwork.
            gentleSwap = false
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                isDancing = nowDancing
            }
            if nowDancing { startDanceLoop() }
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
                // Squash on landing, then recover.
                withAnimation(.easeOut(duration: 0.12)) { landingSquash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.45)) {
                        landingSquash = false
                    }
                }
            }
        }
    }

    /// Random-interval blink loop: eyes closed for ~120 ms every 1.2–3 s.
    /// No-ops for poses without a `<pose>-blink.png` asset and while the
    /// sleep variant is showing (its eyes are already closed). Recursion is
    /// tied to the view's lifecycle via `displayedName` being non-empty.
    private func scheduleBlink() {
        let delay = Double.random(in: 1.2...3.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard !displayedName.isEmpty else { return }
            guard !isSleeping, !isDancing,
                  AssetLoader.image(named: "\(displayedName)-blink") != nil else {
                scheduleBlink()
                return
            }
            // Plain state flip — no animation transaction, instant swap.
            blinking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                blinking = false
                scheduleBlink()
            }
        }
    }

    /// Beat loop (~1.25 steps/sec): flips the flipbook frame instantly and
    /// alternates the procedural hop/tilt/squash so even poses without
    /// dance artwork visibly bop. Recursion is tied to the view's
    /// lifecycle via `isDancing` (mirrored from the `dancing` input).
    private func startDanceLoop() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            guard isDancing else { return }
            danceFrameB.toggle()
            withAnimation(.easeInOut(duration: 0.35)) {
                danceUp.toggle()
            }
            startDanceLoop()
        }
    }

    private func startAlertPulseIfNeeded() {
        guard state == .alert else {
            trembling = false
            return
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            glowPulse = true
        }
        withAnimation(.easeInOut(duration: 0.09).repeatForever(autoreverses: true)) {
            trembling = true
        }
    }
}

/// Three "Z"s drifting up and fading in a staggered loop, anchored near the
/// sprite's head (upper trailing corner).
private struct SleepZsView: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                SleepZ(size: 12, delay: 0)
                SleepZ(size: 16, delay: 0.6)
                SleepZ(size: 21, delay: 1.2)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
            .offset(x: -geo.size.width * 0.08, y: geo.size.height * 0.10)
        }
        .allowsHitTesting(false)
    }
}

private struct SleepZ: View {
    let size: CGFloat
    let delay: Double
    @State private var rising = false

    var body: some View {
        Text("Z")
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .shadow(color: .cyan.opacity(0.5), radius: 3)
            .offset(x: rising ? 10 : 0, y: rising ? -26 : 0)
            .opacity(rising ? 0 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: 1.8)
                    .repeatForever(autoreverses: false)
                    .delay(delay)) {
                    rising = true
                }
            }
    }
}

/// Music notes drifting up and fading in a staggered loop while the
/// mascot dances, scattered across the top of the sprite.
private struct MusicNotesView: View {
    private let notes: [(symbol: String, size: CGFloat, x: CGFloat, delay: Double)] = [
        ("♪", 14, -0.32, 0.0),
        ("♫", 19, 0.30, 0.4),
        ("♪", 12, 0.02, 0.8),
    ]

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                MusicNote(symbol: note.symbol, size: note.size, delay: note.delay)
                    .position(x: geo.size.width * (0.5 + note.x),
                              y: geo.size.height * 0.16)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct MusicNote: View {
    let symbol: String
    let size: CGFloat
    let delay: Double
    @State private var rising = false

    var body: some View {
        Text(symbol)
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .foregroundStyle(.pink.opacity(0.9))
            .shadow(color: .purple.opacity(0.5), radius: 3)
            .offset(x: rising ? 6 : 0, y: rising ? -30 : 0)
            .opacity(rising ? 0 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: 1.2)
                    .repeatForever(autoreverses: false)
                    .delay(delay)) {
                    rising = true
                }
            }
    }
}

/// A few sparkles popping around the sprite while the success state lasts.
private struct SuccessSparklesView: View {
    private let spots: [(x: CGFloat, y: CGFloat, size: CGFloat, delay: Double)] = [
        (-0.32, 0.12, 12, 0.0),
        (0.30, 0.06, 15, 0.45),
        (0.36, 0.30, 10, 0.9),
        (-0.28, 0.34, 13, 1.35),
    ]

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(spots.enumerated()), id: \.offset) { _, spot in
                Sparkle(size: spot.size, delay: spot.delay)
                    .position(x: geo.size.width * (0.5 + spot.x),
                              y: geo.size.height * spot.y)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct Sparkle: View {
    let size: CGFloat
    let delay: Double
    @State private var lit = false

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.yellow)
            .shadow(color: .green.opacity(0.6), radius: 4)
            .scaleEffect(lit ? 1.0 : 0.2)
            .opacity(lit ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7)
                    .repeatForever(autoreverses: true)
                    .delay(delay)) {
                    lit = true
                }
            }
    }
}

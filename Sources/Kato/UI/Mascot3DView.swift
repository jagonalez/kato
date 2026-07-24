import AppKit
import SceneKit
import SwiftUI

/// Idle moods — the 3D successor of the static idle-PNG rotation
/// (driven by the same 45 s MascotIdleRotation cadence via the image name).
enum MascotMood {
    case idle
    case sleep
    case play
    case work

    init(imageName: String) {
        switch imageName {
        case "kato-idle-sleep": self = .sleep
        case "kato-idle-play": self = .play
        case "kato-idle-work": self = .work
        default: self = .idle
        }
    }
}

/// Live 3D mascot (chibi ninja — Kato by way of FFVI's Shadow: cowled head,
/// glowing eyes as the state beacon). Static PNGs remain the fallback (and
/// are still used in the expanded header / empty state). Playful
/// interactions: hover → arm wave + gentle excitement boost; every fresh
/// event → the eyes light up (glow flash + blink), alert pops softly,
/// success hops.
struct Mascot3DView: NSViewRepresentable {
    let state: MascotState
    let mood: MascotMood
    /// Mouse is over the orb.
    let hovered: Bool
    /// Increments on each fresh event — drives the notification movement.
    let activityTick: Int

    /// SceneKit is part of macOS; if a scene somehow can't be built, callers
    /// fall back to the static PNG path.
    static let isAvailable: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = MascotSCNView(frame: .zero)
        guard let scene = context.coordinator.makeScene() else {
            return view // empty view; caller's fallback covers total failure
        }
        view.scene = scene
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 30
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.isPlaying = true
        // Transparent background — only the ninja floats over the desktop.
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.apply(state: state, mood: mood)
        context.coordinator.applyHover(hovered)
        context.coordinator.applyActivityTick(activityTick)
    }

    static func dismantleNSView(_ nsView: SCNView, coordinator: Coordinator) {
        coordinator.stop()
    }
}

/// Pauses rendering when not attached to a window; non-opaque so the
/// desktop shows through behind the ninja.
final class MascotSCNView: SCNView {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isPlaying = window != nil
    }
}

extension Mascot3DView {
    /// Per-mood motion/glow parameters.
    private struct MoodParams {
        var bobAmplitude: CGFloat      // scene units
        var bobPeriod: TimeInterval    // seconds
        var swayAmplitude: CGFloat     // radians
        var headTiltAmplitude: CGFloat // radians (play)
        var leanX: CGFloat             // radians (work)
        var eyeIntensity: CGFloat
        var blinkRange: ClosedRange<TimeInterval>
        var sleepEyes: Bool

        static func forMood(_ mood: MascotMood) -> MoodParams {
            switch mood {
            case .idle:
                return MoodParams(bobAmplitude: 0.06, bobPeriod: 2.5, swayAmplitude: 0.07,
                                  headTiltAmplitude: 0, leanX: 0, eyeIntensity: 2.0,
                                  blinkRange: 3...7, sleepEyes: false)
            case .sleep:
                return MoodParams(bobAmplitude: 0.09, bobPeriod: 3.8, swayAmplitude: 0.04,
                                  headTiltAmplitude: 0, leanX: 0, eyeIntensity: 1.1,
                                  blinkRange: 6...10, sleepEyes: true)
            case .play:
                return MoodParams(bobAmplitude: 0.05, bobPeriod: 1.3, swayAmplitude: 0.10,
                                  headTiltAmplitude: 0.14, leanX: 0, eyeIntensity: 2.6,
                                  blinkRange: 2.5...5, sleepEyes: false)
            case .work:
                return MoodParams(bobAmplitude: 0.04, bobPeriod: 2.2, swayAmplitude: 0.05,
                                  headTiltAmplitude: 0, leanX: 0.10, eyeIntensity: 2.0,
                                  blinkRange: 5...9, sleepEyes: false)
            }
        }
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
        private var character: MascotCharacter?
        private var params = MoodParams.forMood(.idle)
        private(set) var currentState: MascotState = .idle
        private var currentMood: MascotMood = .idle
        private var blinkTimer: Timer?
        private var twitchTimer: Timer?
        private var didApplyInitialState = false
        /// Hover excitement: eased 0…1 blend on top of the mood params.
        private var hoverTarget: CGFloat = 0
        private var hoverBoost: CGFloat = 0
        /// Notification eye-flash: spikes on a fresh event, decays to 0.
        private var flashBoost: CGFloat = 0
        private var wasHovered = false
        private var lastRenderTime: TimeInterval?
        /// Last seen activity tick (notification movement one-shots).
        private var lastActivityTick = 0
        private var didSeeFirstTick = false

        // MARK: Scene construction

        func makeScene() -> SCNScene? {
            let character = MascotCharacter.build()
            self.character = character
            let scene = SCNScene()
            scene.rootNode.addChildNode(character.actionNode)

            // Camera — narrow FOV ≈ 35mm look. Framed to the standing
            // character's vertical span (feet y≈-1.2 … hood tip y≈+1.35,
            // center ≈ +0.1) with headroom for the success hop and the
            // hover wave, so nothing clips at the viewport edges.
            let cameraNode = SCNNode()
            let camera = SCNCamera()
            camera.fieldOfView = 30
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0.2, 6.0)
            let cameraTarget = SCNNode()
            cameraTarget.position = SCNVector3(0, 0.1, 0)
            scene.rootNode.addChildNode(cameraTarget)
            cameraNode.constraints = [SCNLookAtConstraint(target: cameraTarget)]
            scene.rootNode.addChildNode(cameraNode)

            // Lighting — key, cool rim from behind-left, soft ambient.
            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 750
            key.eulerAngles = SCNVector3(-0.7, 0.5, 0)
            scene.rootNode.addChildNode(key)

            let rim = SCNNode()
            rim.light = SCNLight()
            rim.light?.type = .directional
            rim.light?.color = NSColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1)
            rim.light?.intensity = 600
            rim.eulerAngles = SCNVector3(-0.4, -2.4, 0)
            scene.rootNode.addChildNode(rim)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.color = NSColor(red: 0.5, green: 0.55, blue: 0.7, alpha: 1)
            ambient.light?.intensity = 320
            scene.rootNode.addChildNode(ambient)

            scene.background.contents = nil
            scheduleBlink()
            scheduleTwitch()
            return scene
        }

        func stop() {
            blinkTimer?.invalidate()
            twitchTimer?.invalidate()
        }

        // MARK: - Hover / activity application

        /// Hover enter → the cat waves a paw; while hovered the renderer
        /// eases `hoverBoost` toward 1 (slightly livelier bob + glow).
        func applyHover(_ hovered: Bool) {
            hoverTarget = hovered ? 1 : 0
            if hovered && !wasHovered {
                wave()
            }
            wasHovered = hovered
        }

        /// Every fresh event bumps the tick → one-shot movement, even when
        /// the mascot state didn't change (e.g. second alert in a row).
        /// The first observed tick (launch / persisted restore) is silent.
        func applyActivityTick(_ tick: Int) {
            guard didSeeFirstTick else {
                lastActivityTick = tick
                didSeeFirstTick = true
                return
            }
            guard tick != lastActivityTick else { return }
            lastActivityTick = tick
            runNotificationAnimations()
        }

        // MARK: State / mood application (interruptible; alert always wins)

        func apply(state: MascotState, mood: MascotMood) {
            let stateChanged = state != currentState || !didApplyInitialState
            let moodChanged = mood != currentMood
            guard stateChanged || moodChanged else { return }
            didApplyInitialState = true
            currentState = state
            currentMood = mood
            params = MoodParams.forMood(mood)

            guard let character else { return }

            // Cancel one-shots so a new state (especially alert) interrupts.
            character.actionNode.removeAction(forKey: "hop")
            character.actionNode.removeAction(forKey: "pop")
            // Play mood owns the head's euler.z in the renderer; reset it so
            // a mood change never leaves a stale tilt behind.
            character.head.eulerAngles = SCNVector3(0, 0, 0)

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.3
            switch state {
            case .alert:
                character.eyeMaterial.emission.contents = MascotCharacter.alertOrange
            case .success:
                character.eyeMaterial.emission.contents = MascotCharacter.successGreen
            case .idle:
                character.eyeMaterial.emission.contents = MascotCharacter.cyan
            }
            SCNTransaction.commit()

            if state == .alert {
                runAlertAnimations()
            } else if state == .success, stateChanged {
                runSuccessAnimations()
                // Green flash settles back to cyan after ~2 s.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, let character = self.character,
                          self.currentState == .success else { return }
                    SCNTransaction.begin()
                    SCNTransaction.animationDuration = 0.3
                    character.eyeMaterial.emission.contents = MascotCharacter.cyan
                    SCNTransaction.commit()
                }
            }

            applySleepEyeBaseline()
            scheduleBlink()
        }

        // MARK: One-shot animations

        private func runAlertAnimations() {
            guard let character else { return }
            // Gentle attention pop + eye flash — a fast z-shake here read
            // as chaotic, so the state change is carried by the orange
            // glow and this single soft bounce.
            let pop = SCNAction.sequence([
                .scale(to: 1.08, duration: 0.12),
                .scale(to: 1.0, duration: 0.18),
            ])
            pop.timingMode = .easeOut
            character.actionNode.runAction(pop, forKey: "pop")
            flashBoost = max(flashBoost, 1.2)
        }

        private func runSuccessAnimations() {
            guard let character else { return }
            let up = SCNAction.moveBy(x: 0, y: 0.30, z: 0, duration: 0.28)
            up.timingMode = .easeOut
            let down = SCNAction.moveBy(x: 0, y: -0.30, z: 0, duration: 0.30)
            down.timingMode = .easeIn
            let squash = SCNAction.sequence([
                scaleYAction(from: 1.0, to: 0.88, duration: 0.08),
                scaleYAction(from: 0.88, to: 1.0, duration: 0.22),
            ])
            squash.timingMode = .easeInEaseOut
            character.actionNode.runAction(.sequence([up, down, squash]), forKey: "hop")
        }

        /// macOS SCNAction has no scaleY(to:duration:); animate scale.y manually.
        private func scaleYAction(from start: CGFloat, to end: CGFloat, duration: TimeInterval) -> SCNAction {
            SCNAction.customAction(duration: duration) { node, elapsed in
                let k = duration > 0 ? CGFloat(elapsed / duration) : 1
                node.scale.y = start + (end - start) * k
            }
        }

        /// New event arrived: the eyes light up (glow flash + blink).
        /// Alert keeps its soft pop, success its hop — no chaotic motion.
        private func runNotificationAnimations() {
            guard character != nil else { return }
            switch currentState {
            case .alert:
                runAlertAnimations()
            case .success:
                runSuccessAnimations()
                flashBoost = max(flashBoost, 0.8)
            case .idle:
                flashBoost = max(flashBoost, 1.6)
                blink()
            }
        }

        /// Hover greeting: the ninja raises his right arm and waves.
        private func wave() {
            guard let character else { return }
            let arm = character.armR
            arm.removeAction(forKey: "wave")
            // Arm pivot hangs at euler.z -0.12 (build); +2.3 swings it
            // up-out beside the head, wiggle, then back down.
            let raise = SCNAction.rotateBy(x: 0, y: 0, z: 2.3, duration: 0.22)
            raise.timingMode = .easeOut
            var steps: [SCNAction] = [raise]
            for _ in 0..<2 {
                let out = SCNAction.rotateBy(x: 0, y: 0, z: 0.35, duration: 0.12)
                out.timingMode = .easeInEaseOut
                let back = SCNAction.rotateBy(x: 0, y: 0, z: -0.35, duration: 0.12)
                back.timingMode = .easeInEaseOut
                steps.append(contentsOf: [out, back])
            }
            let lower = SCNAction.rotateBy(x: 0, y: 0, z: -2.3, duration: 0.28)
            lower.timingMode = .easeInEaseOut
            steps.append(lower)
            arm.runAction(.sequence(steps), forKey: "wave")
            blink()
        }

        // MARK: Blink / ear twitch

        private func applySleepEyeBaseline() {
            guard let character else { return }
            let target: CGFloat = params.sleepEyes ? 0.08 : 1.0
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.3
            character.eyeL.scale.y = target
            character.eyeR.scale.y = target
            SCNTransaction.commit()
        }

        private func scheduleBlink() {
            blinkTimer?.invalidate()
            let interval = TimeInterval.random(in: params.blinkRange)
            blinkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                self?.blink()
                self?.scheduleBlink()
            }
        }

        private func blink() {
            guard let character else { return }
            if params.sleepEyes {
                // Eyes stay near-closed; a brief sleepy "peek" instead.
                let peek = SCNAction.sequence([
                    scaleYAction(from: 0.08, to: 1.0, duration: 0.12),
                    .wait(duration: 0.4),
                    scaleYAction(from: 1.0, to: 0.08, duration: 0.12),
                ])
                for eye in [character.eyeL, character.eyeR] {
                    eye.runAction(peek, forKey: "blink")
                }
            } else {
                let blinkAction = SCNAction.sequence([
                    scaleYAction(from: 1.0, to: 0.05, duration: 0.075),
                    scaleYAction(from: 0.05, to: 1.0, duration: 0.075),
                ])
                for eye in [character.eyeL, character.eyeR] {
                    eye.runAction(blinkAction, forKey: "blink")
                }
            }
        }

        private func scheduleTwitch() {
            twitchTimer?.invalidate()
            let interval = TimeInterval.random(in: 6...12)
            twitchTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                self?.headWobble()
                self?.scheduleTwitch()
            }
        }

        /// Idle fidget: a small curious head tilt (skipped in play mood —
        /// the renderer's continuous head tilt owns the head there).
        private func headWobble() {
            guard let character, params.headTiltAmplitude == 0 else { return }
            let delta: CGFloat = Bool.random() ? -0.10 : 0.10
            let tilt = SCNAction.sequence([
                .rotateBy(x: 0, y: 0, z: delta, duration: 0.12),
                .rotateBy(x: 0, y: 0, z: -delta, duration: 0.16),
            ])
            tilt.timingMode = .easeInEaseOut
            character.head.runAction(tilt, forKey: "headwobble")
        }

        // MARK: Continuous motion (render-thread delegate)

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let character else { return }
            let p = params
            let sway = character.swayNode

            // Ease the hover excitement blend; decay the notification
            // eye-flash (~0.8 s back to baseline).
            if let last = lastRenderTime {
                let dt = CGFloat(min(time - last, 0.1))
                hoverBoost += (hoverTarget - hoverBoost) * min(1, 10 * dt)
                flashBoost = max(0, flashBoost - 1.8 * dt)
            }
            lastRenderTime = time
            let bobAmplitude = p.bobAmplitude * (1 + 0.35 * hoverBoost)
            let bobPeriod = p.bobPeriod / (1 + 0.2 * hoverBoost)

            // Hover bob + breathing + slow sway (+ mood lean).
            let bobPhase = 2 * Double.pi / bobPeriod
            sway.position.y = bobAmplitude * CGFloat(sin(bobPhase * time))
            let breathe = 1 + 0.015 * sin(time * 2 * Double.pi / (bobPeriod * 1.6))
            sway.scale = SCNVector3(breathe, breathe, breathe)
            let rotationZ = p.swayAmplitude * CGFloat(sin(time * 2 * Double.pi / (bobPeriod * 2.3)))
            sway.eulerAngles = SCNVector3(p.leanX, 0, rotationZ)
            // Play mood's head tilt lives on the head node; other moods
            // leave it alone so headWobble one-shots can own it.
            if p.headTiltAmplitude > 0 {
                character.head.eulerAngles =
                    SCNVector3(0, 0, p.headTiltAmplitude * CGFloat(sin(time * 2 * Double.pi / 1.1)))
            }

            // Eyes are the state beacon (slow flash while alerting).
            if currentState == .alert {
                let flash = 0.6 + 0.4 * sin(time * 2 * Double.pi * 1.3)
                character.eyeMaterial.emission.intensity =
                    p.eyeIntensity * (1.2 + flashBoost) * (0.85 + 0.15 * flash)
            } else {
                character.eyeMaterial.emission.intensity =
                    p.eyeIntensity * (1 + 0.25 * hoverBoost + flashBoost)
            }
        }
    }
}

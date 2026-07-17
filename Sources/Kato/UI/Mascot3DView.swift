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

/// Live 3D mascot orb. Static PNGs remain the fallback (and are still used
/// in the expanded header / empty state).
struct Mascot3DView: NSViewRepresentable {
    let state: MascotState
    let mood: MascotMood

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
        // Transparent background — only the cat floats over the desktop.
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.apply(state: state, mood: mood)
    }

    static func dismantleNSView(_ nsView: SCNView, coordinator: Coordinator) {
        coordinator.stop()
    }
}

/// Pauses rendering when not attached to a window; non-opaque so the
/// desktop shows through behind the cat.
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
        var antennaBase: CGFloat
        var antennaPulseDepth: CGFloat // 0 = steady, 1 = full pulse
        var eyeIntensity: CGFloat
        var blinkRange: ClosedRange<TimeInterval>
        var sleepEyes: Bool

        static func forMood(_ mood: MascotMood) -> MoodParams {
            switch mood {
            case .idle:
                return MoodParams(bobAmplitude: 0.06, bobPeriod: 2.5, swayAmplitude: 0.07,
                                  headTiltAmplitude: 0, leanX: 0, antennaBase: 1.8,
                                  antennaPulseDepth: 0.25, eyeIntensity: 2.0,
                                  blinkRange: 3...7, sleepEyes: false)
            case .sleep:
                return MoodParams(bobAmplitude: 0.09, bobPeriod: 3.8, swayAmplitude: 0.04,
                                  headTiltAmplitude: 0, leanX: 0, antennaBase: 0.5,
                                  antennaPulseDepth: 0.15, eyeIntensity: 1.1,
                                  blinkRange: 6...10, sleepEyes: true)
            case .play:
                return MoodParams(bobAmplitude: 0.05, bobPeriod: 1.3, swayAmplitude: 0.10,
                                  headTiltAmplitude: 0.14, leanX: 0, antennaBase: 2.0,
                                  antennaPulseDepth: 0.35, eyeIntensity: 2.6,
                                  blinkRange: 2.5...5, sleepEyes: false)
            case .work:
                return MoodParams(bobAmplitude: 0.04, bobPeriod: 2.2, swayAmplitude: 0.05,
                                  headTiltAmplitude: 0, leanX: 0.10, antennaBase: 2.0,
                                  antennaPulseDepth: 0.05, eyeIntensity: 2.0,
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

        // MARK: Scene construction

        func makeScene() -> SCNScene? {
            let character = MascotCharacter.build()
            self.character = character
            let scene = SCNScene()
            scene.rootNode.addChildNode(character.actionNode)

            // Camera — narrow FOV ≈ 35mm look. Framed to the character's
            // true vertical span (paws y≈-1.0 … antenna tip y≈+1.48, center
            // ≈ +0.25) with headroom for the hover bob and success hop, so
            // nothing clips at the viewport edges.
            let cameraNode = SCNNode()
            let camera = SCNCamera()
            camera.fieldOfView = 28
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0.35, 5.8)
            let cameraTarget = SCNNode()
            cameraTarget.position = SCNVector3(0, 0.25, 0)
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
            character.actionNode.removeAction(forKey: "shake")
            character.actionNode.removeAction(forKey: "pop")

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.3
            switch state {
            case .alert:
                character.eyeMaterial.emission.contents = MascotCharacter.alertOrange
                character.antennaTipMaterial.emission.contents = MascotCharacter.alertOrange
            case .success:
                character.eyeMaterial.emission.contents = MascotCharacter.successGreen
                character.antennaTipMaterial.emission.contents = MascotCharacter.successGreen
            case .idle:
                character.eyeMaterial.emission.contents = MascotCharacter.cyan
                character.antennaTipMaterial.emission.contents = MascotCharacter.cyan
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
                    character.antennaTipMaterial.emission.contents = MascotCharacter.cyan
                    SCNTransaction.commit()
                }
            }

            applySleepEyeBaseline()
            scheduleBlink()
        }

        // MARK: One-shot animations

        private func runAlertAnimations() {
            guard let character else { return }
            let wiggle = SCNAction.sequence([
                .rotateBy(x: 0, y: 0, z: 0.12, duration: 0.07),
                .rotateBy(x: 0, y: 0, z: -0.24, duration: 0.14),
                .rotateBy(x: 0, y: 0, z: 0.12, duration: 0.07),
            ])
            wiggle.timingMode = .easeInEaseOut
            character.actionNode.runAction(.repeat(wiggle, count: 3), forKey: "shake")
            let pop = SCNAction.sequence([
                .scale(to: 1.08, duration: 0.12),
                .scale(to: 1.0, duration: 0.18),
            ])
            pop.timingMode = .easeOut
            character.actionNode.runAction(pop, forKey: "pop")
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
                self?.twitchEar()
                self?.scheduleTwitch()
            }
        }

        private func twitchEar() {
            guard let character else { return }
            let left = Bool.random()
            let ear = left ? character.earL : character.earR
            let delta: CGFloat = left ? -0.15 : 0.15
            let twitch = SCNAction.sequence([
                .rotateBy(x: 0, y: 0, z: delta, duration: 0.07),
                .rotateBy(x: 0, y: 0, z: -delta, duration: 0.09),
            ])
            twitch.timingMode = .easeInEaseOut
            ear.runAction(twitch, forKey: "twitch")
        }

        // MARK: Continuous motion (render-thread delegate)

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let character else { return }
            let p = params
            let sway = character.swayNode

            // Hover bob + breathing + slow sway (+ mood lean/head-tilt).
            let bobPhase = 2 * Double.pi / p.bobPeriod
            sway.position.y = p.bobAmplitude * CGFloat(sin(bobPhase * time))
            let breathe = 1 + 0.015 * sin(time * 2 * Double.pi / (p.bobPeriod * 1.6))
            sway.scale = SCNVector3(breathe, breathe, breathe)
            var rotationZ = p.swayAmplitude * CGFloat(sin(time * 2 * Double.pi / (p.bobPeriod * 2.3)))
            if p.headTiltAmplitude > 0 {
                rotationZ += p.headTiltAmplitude * CGFloat(sin(time * 2 * Double.pi / 1.1))
            }
            sway.eulerAngles = SCNVector3(p.leanX, 0, rotationZ)

            // Antenna tip pulse (fast flash while alerting).
            if currentState == .alert {
                let flash = 0.6 + 0.4 * sin(time * 2 * Double.pi * 2.2)
                character.antennaTipMaterial.emission.intensity = p.antennaBase * 1.5 * flash
                character.eyeMaterial.emission.intensity = p.eyeIntensity * 1.2 * (0.85 + 0.15 * flash)
            } else {
                let pulse = 1 - p.antennaPulseDepth
                    + p.antennaPulseDepth * (0.5 + 0.5 * sin(time * 2 * Double.pi / 3))
                character.antennaTipMaterial.emission.intensity = p.antennaBase * pulse
                character.eyeMaterial.emission.intensity = p.eyeIntensity
            }
        }
    }
}

import AppKit
import SceneKit

/// Procedurally-built robot-cat matching the Assets/Mascot artwork:
/// glossy deep-navy orb body (~#0E1A33), emissive cyan (#40F2FF) accents
/// (eyes, inner ears, cheek stripes, antenna tip), tiny paws.
/// Pure SceneKit primitives — no external model files.
struct MascotCharacter {
    /// One-shot SCNActions run here (alert shake/pop, success hop/squash).
    let actionNode: SCNNode
    /// Continuous procedural motion (bob / breathe / sway / lean) — kept
    /// separate from actionNode so the two never fight over a transform.
    let swayNode: SCNNode
    let eyeL: SCNNode
    let eyeR: SCNNode
    let earL: SCNNode
    let earR: SCNNode
    let eyeMaterial: SCNMaterial
    /// Inner ears + cheek stripes.
    let accentMaterial: SCNMaterial
    /// Antenna tip — the state beacon.
    let antennaTipMaterial: SCNMaterial

    static let navy = NSColor(red: 0x0E / 255, green: 0x1A / 255, blue: 0x33 / 255, alpha: 1)
    static let cyan = NSColor(red: 0x40 / 255, green: 0xF2 / 255, blue: 0xFF / 255, alpha: 1)
    static let alertOrange = NSColor(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)
    static let successGreen = NSColor(red: 0x32 / 255, green: 0xD7 / 255, blue: 0x4B / 255, alpha: 1)

    private static func navyMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = navy
        material.roughness.contents = 0.25
        material.metalness.contents = 0.4
        return material
    }

    private static func emissiveMaterial(intensity: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor.black
        material.emission.contents = cyan
        material.emission.intensity = intensity
        return material
    }

    static func build() -> MascotCharacter {
        let navy = navyMaterial()
        let eyeMat = emissiveMaterial(intensity: 2.0)
        let accentMat = emissiveMaterial(intensity: 1.3)
        let tipMat = emissiveMaterial(intensity: 1.8)

        let actionNode = SCNNode()
        actionNode.name = "kato.action"
        let swayNode = SCNNode()
        swayNode.name = "kato.sway"
        actionNode.addChildNode(swayNode)

        // Body — sphere slightly flattened for the pebble look.
        let body = SCNNode(geometry: SCNSphere(radius: 1.0))
        body.geometry?.materials = [navy]
        body.scale = SCNVector3(1, 0.92, 0.95)
        swayNode.addChildNode(body)

        // Ears — navy cones tilted outward + smaller emissive inner cones.
        func makeEar(side: CGFloat) -> SCNNode {
            let ear = SCNNode(geometry: SCNCone(topRadius: 0.02, bottomRadius: 0.30, height: 0.62))
            ear.geometry?.materials = [navy]
            ear.position = SCNVector3(0.50 * side, 0.88, 0)
            ear.rotation = SCNVector4(0, 0, 1, -0.30 * side)
            swayNode.addChildNode(ear)

            let inner = SCNNode(geometry: SCNCone(topRadius: 0.01, bottomRadius: 0.16, height: 0.36))
            inner.geometry?.materials = [accentMat]
            inner.position = SCNVector3(0.48 * side, 0.90, 0.16)
            inner.rotation = SCNVector4(0, 0, 1, -0.30 * side)
            swayNode.addChildNode(inner)
            return ear
        }
        let earL = makeEar(side: -1)
        let earR = makeEar(side: 1)

        // Eyes — emissive spheres on the face.
        func makeEye(side: CGFloat) -> SCNNode {
            let eye = SCNNode(geometry: SCNSphere(radius: 0.13))
            eye.geometry?.materials = [eyeMat]
            eye.position = SCNVector3(0.36 * side, 0.16, 0.82)
            swayNode.addChildNode(eye)
            return eye
        }
        let eyeL = makeEye(side: -1)
        let eyeR = makeEye(side: 1)

        // Cheek stripes — thin emissive boxes, two per side.
        for side in [-1.0, 1.0] as [CGFloat] {
            for row in 0..<2 {
                let stripe = SCNNode(geometry: SCNBox(width: 0.24, height: 0.04, length: 0.03, chamferRadius: 0.015))
                stripe.geometry?.materials = [accentMat]
                stripe.position = SCNVector3(0.62 * side, -0.04 - 0.12 * CGFloat(row), 0.70)
                stripe.rotation = SCNVector4(0, 1, 0, -0.35 * side)
                swayNode.addChildNode(stripe)
            }
        }

        // Antenna — thin dark cylinder + emissive tip (state beacon).
        let antenna = SCNNode(geometry: SCNCylinder(radius: 0.035, height: 0.5))
        antenna.geometry?.materials = [navy]
        antenna.position = SCNVector3(0.10, 1.12, 0)
        antenna.rotation = SCNVector4(0, 0, 1, -0.10)
        swayNode.addChildNode(antenna)

        let tip = SCNNode(geometry: SCNSphere(radius: 0.10))
        tip.geometry?.materials = [tipMat]
        tip.position = SCNVector3(0.15, 1.38, 0)
        swayNode.addChildNode(tip)

        // Paws — two small navy spheres at the bottom front.
        for side in [-1.0, 1.0] as [CGFloat] {
            let paw = SCNNode(geometry: SCNSphere(radius: 0.20))
            paw.geometry?.materials = [navy]
            paw.position = SCNVector3(0.38 * side, -0.80, 0.55)
            swayNode.addChildNode(paw)
        }

        return MascotCharacter(
            actionNode: actionNode,
            swayNode: swayNode,
            eyeL: eyeL,
            eyeR: eyeR,
            earL: earL,
            earR: earR,
            eyeMaterial: eyeMat,
            accentMaterial: accentMat,
            antennaTipMaterial: tipMat
        )
    }
}

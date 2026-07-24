import AppKit
import SceneKit

/// Procedurally-built chibi ninja — Kato (Green Hornet sidekick) by way of
/// FFVI's Shadow: oversized cowled head with only the glowing eyes visible,
/// tiny gi body with a green sash, swept-back hood point, sheathed sword on
/// the back, stubby limbs. Pure SceneKit primitives — no external model
/// files. The emissive eyes are the state beacon (cyan idle / orange alert /
/// green success). (The static Assets/Mascot PNGs remain the old robot-cat
/// artwork; regenerate separately if the theme should match.)
struct MascotCharacter {
    /// One-shot SCNActions run here (alert pop, success hop/squash).
    let actionNode: SCNNode
    /// Continuous procedural motion (bob / breathe / sway) — kept separate
    /// from actionNode so the two never fight over a transform.
    let swayNode: SCNNode
    /// Head node — play-mood tilt + idle look-around fidget.
    let head: SCNNode
    let eyeL: SCNNode
    let eyeR: SCNNode
    /// Right-arm shoulder pivot — raised for the hover wave.
    let armR: SCNNode
    /// Eyes — the state beacon.
    let eyeMaterial: SCNMaterial

    static let navy = NSColor(red: 0x0E / 255, green: 0x1A / 255, blue: 0x33 / 255, alpha: 1)
    static let giNavy = NSColor(red: 0.10, green: 0.16, blue: 0.30, alpha: 1)
    static let cyan = NSColor(red: 0x40 / 255, green: 0xF2 / 255, blue: 0xFF / 255, alpha: 1)
    static let alertOrange = NSColor(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)
    static let successGreen = NSColor(red: 0x32 / 255, green: 0xD7 / 255, blue: 0x4B / 255, alpha: 1)
    static let hornetGreen = NSColor(red: 0.16, green: 0.65, blue: 0.35, alpha: 1)

    private static func clothMaterial(_ color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.roughness.contents = 0.55
        material.metalness.contents = 0.15
        return material
    }

    private static func emissiveEyeMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor.black
        material.emission.contents = cyan
        material.emission.intensity = 2.0
        return material
    }

    static func build() -> MascotCharacter {
        let cowl = clothMaterial(navy)
        let gi = clothMaterial(giNavy)
        let dark = clothMaterial(NSColor(red: 0.02, green: 0.025, blue: 0.05, alpha: 1))
        let eyeMat = emissiveEyeMaterial()
        let sashMat = SCNMaterial()
        sashMat.lightingModel = .physicallyBased
        sashMat.diffuse.contents = NSColor.black
        sashMat.emission.contents = hornetGreen
        sashMat.emission.intensity = 0.7

        let actionNode = SCNNode()
        actionNode.name = "kato.action"
        let swayNode = SCNNode()
        swayNode.name = "kato.sway"
        actionNode.addChildNode(swayNode)

        // Legs — stubby capsules, feet at y ≈ -1.2.
        for side in [-1.0, 1.0] as [CGFloat] {
            let leg = SCNNode(geometry: SCNCapsule(capRadius: 0.14, height: 0.42))
            leg.geometry?.materials = [dark]
            leg.position = SCNVector3(0.18 * side, -0.99, 0)
            swayNode.addChildNode(leg)
        }

        // Body — rounded gi capsule, waist sash in hornet green.
        let body = SCNNode(geometry: SCNCapsule(capRadius: 0.42, height: 0.95))
        body.geometry?.materials = [gi]
        body.position = SCNVector3(0, -0.55, 0)
        swayNode.addChildNode(body)
        let sash = SCNNode(geometry: SCNCylinder(radius: 0.435, height: 0.10))
        sash.geometry?.materials = [sashMat]
        sash.position = SCNVector3(0, -0.62, 0)
        swayNode.addChildNode(sash)

        // Arms — shoulder pivots (so the right arm can wave) with capsule
        // sleeves hanging down + sphere hands.
        var armR: SCNNode!
        for side in [-1.0, 1.0] as [CGFloat] {
            let pivot = SCNNode()
            pivot.position = SCNVector3(0.48 * side, -0.18, 0)
            swayNode.addChildNode(pivot)
            let sleeve = SCNNode(geometry: SCNCapsule(capRadius: 0.12, height: 0.38))
            sleeve.geometry?.materials = [gi]
            sleeve.position = SCNVector3(0, -0.22, 0)
            pivot.addChildNode(sleeve)
            let hand = SCNNode(geometry: SCNSphere(radius: 0.13))
            hand.geometry?.materials = [dark]
            hand.position = SCNVector3(0, -0.44, 0)
            pivot.addChildNode(hand)
            pivot.eulerAngles = SCNVector3(0, 0, -0.12 * side) // slight outward hang
            if side > 0 { armR = pivot }
        }

        // Head — oversized cowl sphere; only the eyes show.
        let head = SCNNode()
        head.name = "kato.head"
        head.position = SCNVector3(0, 0.62, 0)
        swayNode.addChildNode(head)
        let skull = SCNNode(geometry: SCNSphere(radius: 0.68))
        skull.geometry?.materials = [cowl]
        head.addChildNode(skull)

        // Eyes — emissive spheres set into the dark cowl.
        func makeEye(side: CGFloat) -> SCNNode {
            let eye = SCNNode(geometry: SCNSphere(radius: 0.11))
            eye.geometry?.materials = [eyeMat]
            eye.position = SCNVector3(0.24 * side, 0.05, 0.60)
            head.addChildNode(eye)
            return eye
        }
        let eyeL = makeEye(side: -1)
        let eyeR = makeEye(side: 1)

        // Hood point — swept-back cowl tip for the ninja silhouette.
        let hood = SCNNode(geometry: SCNCone(topRadius: 0.02, bottomRadius: 0.26, height: 0.48))
        hood.geometry?.materials = [cowl]
        hood.position = SCNVector3(0, 0.52, -0.28)
        hood.rotation = SCNVector4(1, 0, 0, -0.55)
        head.addChildNode(hood)

        // Sheathed sword over the right shoulder.
        let sheath = SCNNode(geometry: SCNCylinder(radius: 0.05, height: 0.85))
        sheath.geometry?.materials = [dark]
        sheath.position = SCNVector3(0.28, -0.15, -0.42)
        sheath.rotation = SCNVector4(0, 0, 1, 0.55)
        swayNode.addChildNode(sheath)
        let handle = SCNNode(geometry: SCNCylinder(radius: 0.04, height: 0.22))
        handle.geometry?.materials = [sashMat]
        handle.position = SCNVector3(0.52, 0.22, -0.42)
        handle.rotation = SCNVector4(0, 0, 1, 0.55)
        swayNode.addChildNode(handle)

        return MascotCharacter(
            actionNode: actionNode,
            swayNode: swayNode,
            head: head,
            eyeL: eyeL,
            eyeR: eyeR,
            armR: armR,
            eyeMaterial: eyeMat
        )
    }
}

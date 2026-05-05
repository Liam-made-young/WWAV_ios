import SwiftUI
import SceneKit
import simd

/// Real SceneKit 3D stem player.
///
/// • Taupe sphere lit Turrell-style (warm key + cool fill).
/// • Four cardinal arms (vox / bass / drum / synth), 4 LEDs per arm = 16 total.
/// • Drag anywhere on the sphere to physically rotate it on two axes; the
///   rotation persists (it's a physical object, not a snap-back gauge), with
///   inertia after release.
/// • Tap any LED to set that stem's level to that LED's index.
/// • Tap the centre disc to toggle play/pause.
struct StemPlayerWidget: View {
    @ObservedObject var engine: StemPlayerEngine
    var size: CGFloat = 320

    @Environment(\.theme) private var theme

    var body: some View {
        StemPlayerSceneView(engine: engine, palette: theme)
            .frame(width: size, height: size)
            // Glow wash behind the canvas — accent-tinted per active palette.
            .background(
                RadialGradient(
                    colors: [
                        theme.accent.opacity(0.35),
                        theme.accent.opacity(0.10),
                        .clear
                    ],
                    center: UnitPoint(x: 0.5, y: 0.55),
                    startRadius: 0,
                    endRadius: size * 0.7
                )
                .blur(radius: 28)
                .scaleEffect(1.25)
            )
    }
}

/// SCNView subclass that only "contains" a touch when there's a SceneKit
/// node beneath it. Touches that miss every node fall through to the
/// underlying view (so the circular waveform behind us can handle scrubs).
private final class PassThroughSCNView: SCNView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let hits = self.hitTest(point, options: [
            SCNHitTestOption.boundingBoxOnly: true,
        ])
        return !hits.isEmpty
    }
}

private struct StemPlayerSceneView: UIViewRepresentable {
    @ObservedObject var engine: StemPlayerEngine
    let palette: Palette

    func makeCoordinator() -> Coordinator { Coordinator(engine: engine, palette: palette) }

    func makeUIView(context: Context) -> SCNView {
        let view = PassThroughSCNView(frame: .zero, options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.isUserInteractionEnabled = true
        view.allowsCameraControl = false   // we drive rotation ourselves
        view.scene = context.coordinator.buildScene()
        view.delegate = context.coordinator
        view.isPlaying = true               // animation loop on

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
        context.coordinator.view = view

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.engine = engine
        context.coordinator.applyPalette(palette)
        context.coordinator.refreshLEDs()
    }

    // MARK: – Coordinator

    @MainActor
    final class Coordinator: NSObject, SCNSceneRendererDelegate, UIGestureRecognizerDelegate {
        var engine: StemPlayerEngine
        var palette: Palette
        weak var view: SCNView?

        let rootNode = SCNNode()                 // the spinnable container
        var ledNodes: [(StemKind, Int, SCNNode)] = []  // (stem, indexFromCenter, node)
        var sphereNode: SCNNode?
        var centerNode: SCNNode!

        // Spring-return rotation. The widget feels like a return-to-center
        // gimbal: yaw is anchored to vertical, pitch tilts a little, and on
        // release both ease back to the neutral pose.
        private var yaw: Float = 0           // around +Y (free during pan)
        private var pitch: Float = 0         // around +X (clamped tilt)
        private var isPanning: Bool = false
        private var lastUpdate: TimeInterval = 0
        private var lastPanTranslation: CGPoint = .zero
        private static let coinZScale: Float = 0.42      // gradual coin depth on z
        private static let maxPitch: Float = 0.32        // ~18° tilt
        private static let maxYawWhileResting: Float = 0.60   // ~34° — pulls back if user lets go past this
        private static let returnSpeed: Float = 6.5     // rad/s spring constant

        init(engine: StemPlayerEngine, palette: Palette) {
            self.engine = engine
            self.palette = palette
        }

        func applyPalette(_ p: Palette) {
            guard p.id != palette.id else { return }
            palette = p
            if let mat = sphereNode?.geometry?.firstMaterial {
                mat.diffuse.contents = UIColor(p.sphere)
                mat.emission.contents = UIColor(p.sphereEmissive).withAlphaComponent(0.08)
            }
        }

        // MARK: scene

        func buildScene() -> SCNScene {
            let scene = SCNScene()
            scene.background.contents = UIColor.clear

            // Camera
            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.fieldOfView = 35
            cameraNode.camera?.zNear = 0.1
            cameraNode.camera?.zFar = 50
            cameraNode.position = SCNVector3(0, 0, 4.2)
            scene.rootNode.addChildNode(cameraNode)

            // Lights — softer key from upper-left so the coin reads as lit by a
            // single source rather than spotlit. Slightly stronger ambient
            // pulls the silhouette out of shadow on the bottom half.
            let key = SCNLight()
            key.type = .directional
            key.color = UIColor(red: 0.82, green: 0.94, blue: 1.0, alpha: 1)
            key.intensity = 1100
            let keyNode = SCNNode()
            keyNode.light = key
            keyNode.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 5, 0)
            scene.rootNode.addChildNode(keyNode)

            let fill = SCNLight()
            fill.type = .directional
            fill.color = UIColor(red: 0.45, green: 0.55, blue: 0.65, alpha: 1)
            fill.intensity = 380
            let fillNode = SCNNode()
            fillNode.light = fill
            fillNode.eulerAngles = SCNVector3(Float.pi / 5, -Float.pi / 4, 0)
            scene.rootNode.addChildNode(fillNode)

            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.color = UIColor(red: 0.32, green: 0.40, blue: 0.48, alpha: 1)
            ambient.intensity = 380
            let ambientNode = SCNNode()
            ambientNode.light = ambient
            scene.rootNode.addChildNode(ambientNode)

            // Coin body — sphere flattened on the z axis. X/Y stay circular,
            // depth becomes a gradual ellipse so the silhouette reads as a coin.
            let sphereGeo = SCNSphere(radius: 1.0)
            sphereGeo.segmentCount = 96
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            mat.diffuse.contents = UIColor(palette.sphere)
            mat.emission.contents = UIColor(palette.sphereEmissive).withAlphaComponent(0.08)
            mat.metalness.contents = 0.0
            mat.roughness.contents = 0.55
            mat.specular.contents = UIColor(white: 1, alpha: 0.7)
            sphereGeo.firstMaterial = mat

            let sphereNode = SCNNode(geometry: sphereGeo)
            sphereNode.name = "sphere"
            sphereNode.scale = SCNVector3(1, 1, Coordinator.coinZScale)
            rootNode.addChildNode(sphereNode)
            self.sphereNode = sphereNode

            // LEDs — 4 cardinal arms × 4 leds, sitting just above the surface
            ledNodes.removeAll()
            let arms: [(StemKind, SIMD3<Float>)] = [
                (.vox,   SIMD3(0,  1, 0)),  // top arm
                (.bass,  SIMD3(1,  0, 0)),  // right arm
                (.drum,  SIMD3(0, -1, 0)),  // bottom arm
                (.synth, SIMD3(-1, 0, 0)),  // left arm
            ]
            let frontPole = SIMD3<Float>(0, 0, 1)

            for (kind, armDir) in arms {
                let axis = simd_normalize(simd_cross(frontPole, armDir))   // rotation axis
                for i in 0..<4 {
                    let t = Float(i) / 3.0                  // 0..1 along arm
                    // Spread arc wider so the bigger LEDs sit as discrete dots.
                    let angleDeg: Float = 16 + 25 * t       // 16°..91° arc from front pole
                    let angle = angleDeg * .pi / 180
                    let pos = rotate(vector: frontPole, axis: axis, angle: angle) * 1.020

                    let led = makeLED()
                    led.position = SCNVector3(pos.x, pos.y, pos.z)
                    // Counter-scale on z so each LED stays round on the coin's flattened surface.
                    led.scale = SCNVector3(1, 1, 1.0 / Coordinator.coinZScale)
                    led.name = "led:\(kind.rawValue):\(i)"
                    addHitCollider(to: led, radius: 0.16)
                    sphereNode.addChildNode(led)
                    ledNodes.append((kind, i, led))
                }
            }

            // Centre play disc — bigger, easier-to-press button.
            // Counter-scale on z so it doesn't get squashed with the coin body.
            let discGeo = SCNCylinder(radius: 0.18, height: 0.03)
            let discMat = SCNMaterial()
            discMat.lightingModel = .physicallyBased
            discMat.diffuse.contents = UIColor(red: 0.20, green: 0.30, blue: 0.42, alpha: 1)
            discMat.roughness.contents = 0.4
            discMat.metalness.contents = 0.0
            discGeo.firstMaterial = discMat
            let disc = SCNNode(geometry: discGeo)
            disc.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            disc.position = SCNVector3(0, 0, 1.005)
            disc.scale = SCNVector3(1, 1.0 / Coordinator.coinZScale, 1)
            disc.name = "center"
            addHitCollider(to: disc, radius: 0.30)
            sphereNode.addChildNode(disc)
            centerNode = disc

            // Glyph (play triangle) on the centre disc — separate emissive plane
            let glyph = SCNPlane(width: 0.11, height: 0.13)
            let glyphMat = SCNMaterial()
            glyphMat.diffuse.contents = playTriangleImage()
            glyphMat.transparent.contents = playTriangleImage()
            glyphMat.emission.contents = UIColor(red: 0.78, green: 0.91, blue: 1.0, alpha: 1)
            glyphMat.lightingModel = .constant
            glyph.firstMaterial = glyphMat
            let glyphNode = SCNNode(geometry: glyph)
            // Sit clearly above the disc surface so it isn't hidden inside.
            glyphNode.position = SCNVector3(0, 0, 1.10)
            glyphNode.scale = SCNVector3(1, 1, 1.0 / Coordinator.coinZScale)
            glyphNode.name = "centerGlyph"
            sphereNode.addChildNode(glyphNode)

            scene.rootNode.addChildNode(rootNode)
            refreshLEDs()
            return scene
        }

        private func makeLED() -> SCNNode {
            // Visual LED — kept moderate; the real tap target is an invisible
            // hit sphere added in `addHitCollider` below so dots don't visually
            // overlap each other while remaining easy to tap.
            let geo = SCNSphere(radius: 0.085)
            geo.segmentCount = 20
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = UIColor(red: 0.78, green: 0.93, blue: 1.0, alpha: 1)
            m.emission.contents = UIColor(red: 0.22, green: 0.34, blue: 0.45, alpha: 1)
            geo.firstMaterial = m
            let n = SCNNode(geometry: geo)
            return n
        }

        /// Adds an invisible child sphere whose bounding box becomes the
        /// effective tap target. Hit testing uses bounding boxes, so this
        /// gives every LED a fat, forgiving hitbox without bloating the
        /// visual dot. Must be called after the parent's name is set so the
        /// collider can mirror it.
        private func addHitCollider(to node: SCNNode, radius: Float) {
            let collider = SCNSphere(radius: CGFloat(radius))
            collider.segmentCount = 6
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor.clear
            mat.transparent.contents = UIColor.clear
            mat.writesToDepthBuffer = false
            mat.readsFromDepthBuffer = false
            collider.firstMaterial = mat
            let coll = SCNNode(geometry: collider)
            coll.name = node.name
            node.addChildNode(coll)
        }

        private func rotate(vector v: SIMD3<Float>, axis a: SIMD3<Float>, angle: Float) -> SIMD3<Float> {
            // Rodrigues' rotation formula
            let cosA = cos(angle)
            let sinA = sin(angle)
            return v * cosA + simd_cross(a, v) * sinA + a * simd_dot(a, v) * (1 - cosA)
        }

        private func playTriangleImage() -> UIImage {
            let size = CGSize(width: 64, height: 64)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { ctx in
                ctx.cgContext.setFillColor(UIColor.white.cgColor)
                ctx.cgContext.move(to: CGPoint(x: 16, y: 8))
                ctx.cgContext.addLine(to: CGPoint(x: 16, y: 56))
                ctx.cgContext.addLine(to: CGPoint(x: 56, y: 32))
                ctx.cgContext.closePath()
                ctx.cgContext.fillPath()
            }
        }

        // MARK: render loop — inertia + LED refresh

        nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            Task { @MainActor in self.tick(time: time) }
        }

        private func tick(time: TimeInterval) {
            if lastUpdate == 0 { lastUpdate = time }
            let dt = Float(min(0.05, time - lastUpdate))
            lastUpdate = time

            // When the user isn't actively dragging, spring both axes back to
            // the neutral pose. This is what gives the widget its "physical
            // device" feel — it always wants to be upright and front-facing.
            if !isPanning {
                let k = min(1.0, dt * Self.returnSpeed)
                yaw   += (0 - yaw)   * k
                pitch += (0 - pitch) * k
                if abs(yaw)   < 0.0005 { yaw   = 0 }
                if abs(pitch) < 0.0005 { pitch = 0 }
            }

            // Compose orientation: yaw (vertical axis) ∘ pitch (clamped tilt).
            let qy = simd_quatf(angle: yaw,   axis: SIMD3(0, 1, 0))
            let qp = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
            rootNode.simdOrientation = qy * qp

            refreshLEDs()
        }

        // MARK: gestures

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let v = view else { return }
            switch g.state {
            case .began:
                isPanning = true
                lastPanTranslation = .zero
            case .changed:
                let translation = g.translation(in: v)
                let dx = Float(translation.x - lastPanTranslation.x)
                let dy = Float(translation.y - lastPanTranslation.y)
                lastPanTranslation = translation

                // Horizontal drag = yaw, vertical drag = pitch. The yaw bias
                // toward 0 (during the spring-back tick) means horizontal
                // gestures behave like a return-to-center wheel; pitch is
                // hard-clamped so the coin never tips over.
                let scale: Float = 0.012
                yaw   += dx * scale
                pitch += dy * scale
                pitch = max(-Self.maxPitch, min(Self.maxPitch, pitch))
            case .ended, .cancelled:
                isPanning = false
                // If they parked yaw past the resting envelope, the spring
                // pulls it back through the shorter arc; we just normalize
                // to (-π, π] so the lerp doesn't take the long way around.
                yaw = atan2(sin(yaw), cos(yaw))
            default: break
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let v = view else { return }
            let p = g.location(in: v)
            let hits = v.hitTest(p, options: [SCNHitTestOption.boundingBoxOnly: true,
                                              SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue as NSNumber])
            guard let hit = hits.first else { return }
            let name = hit.node.name ?? ""

            if name == "center" || name == "centerGlyph" {
                engine.togglePlayPause()
                refreshLEDs()
                return
            }

            if name.hasPrefix("led:") {
                let parts = name.split(separator: ":")
                if parts.count == 3,
                   let kind = StemKind(rawValue: String(parts[1])),
                   let i = Int(parts[2]) {
                    // Discrete 4-level volume: innermost LED (i=0) mutes the
                    // stem, outermost (i=3) maxes it out, the middle two are
                    // even steps in between.
                    let level: Double
                    switch i {
                    case 0:  level = 0.0
                    case 1:  level = 1.0 / 3.0
                    case 2:  level = 2.0 / 3.0
                    default: level = 1.0
                    }
                    engine.setVolume(level, for: kind)
                    refreshLEDs()
                }
            }
        }

        // MARK: LED refresh

        func refreshLEDs() {
            for (kind, idx, node) in ledNodes {
                let level = engine.volume(for: kind)
                // VU-meter style with the new 4-step mapping (mute / 33 / 66 / max).
                // vol 0 → 0 lit · vol 1/3 → idx 0,1 · vol 2/3 → idx 0..2 · vol 1 → all 4.
                let litCount = level < 0.001 ? 0 : Int(round(level * 3.0)) + 1
                let lit = idx < litCount
                applyLED(node: node, lit: lit)
            }
            // Centre glyph swaps between play and pause look (we just modulate brightness).
            if let mat = centerNode?.geometry?.firstMaterial {
                mat.emission.contents = engine.isPlaying
                    ? UIColor(red: 0.30, green: 0.55, blue: 0.85, alpha: 1)
                    : UIColor.black
            }
        }

        private func applyLED(node: SCNNode, lit: Bool) {
            guard let mat = node.geometry?.firstMaterial else { return }
            mat.emission.contents = lit
                ? UIColor(red: 0.78, green: 0.93, blue: 1.0, alpha: 1)
                : UIColor(red: 0.14, green: 0.22, blue: 0.30, alpha: 1)
            mat.diffuse.contents = lit
                ? UIColor(red: 0.78, green: 0.93, blue: 1.0, alpha: 1)
                : UIColor(red: 0.22, green: 0.32, blue: 0.42, alpha: 1)
        }
    }
}

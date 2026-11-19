// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SceneKit
import SwiftUI

/// What the live RayNeo iO model acts out. Android's GlassesStage uses the same poses and motion constants.
enum GlassesPose: Equatable {
    /// Disconnected: temples folded, display dark.
    case resting
    /// Link in progress: temples unfold, the status light blinks and the lenses shimmer.
    case connecting
    /// Linked: open frame, lit display, a brief power-on flash on arrival.
    case connected
}

/// assets/models/rayneo-io.usdz rendered live with SceneKit over a soft contact shadow. It moves only when the
/// connection state changes or the user drags it; a flick spins it and it settles back to the resting angle.
struct GlassesModelView: View {
    var pose: GlassesPose
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Ellipse().fill(Token.illustrationShadow)
                    .frame(width: geometry.size.width * 0.58, height: geometry.size.height * 0.08)
                    .blur(radius: 7).opacity(0.7).offset(y: geometry.size.height * 0.33)
                GlassesSceneRepresentable(pose: pose)
            }
        }.accessibilityElement().accessibilityLabel("RayNeo iO 智能眼镜")
    }
}

private struct GlassesSceneRepresentable: NSViewRepresentable {
    var pose: GlassesPose
    func makeNSView(context: Context) -> GlassesSceneView { GlassesSceneView() }
    func updateNSView(_ view: GlassesSceneView, context: Context) { view.pose = pose }
}

/// Critically damped-ish spring stepped once per frame.
private struct Spring {
    var value: Float
    var velocity: Float = 0
    mutating func step(to target: Float, stiffness: Float, damping: Float = 1, dt: Float) {
        velocity += (stiffness * (target - value) - 2 * damping * stiffness.squareRoot() * velocity) * dt
        value += velocity * dt
    }
}

final class GlassesSceneView: SCNView, SCNSceneRendererDelegate {
    /// The first pose (and any set before the model loads) is shown directly; later changes animate.
    var pose = GlassesPose.resting {
        didSet {
            if !posed { posed = true; snapPending = true }
            else if pose == .connected && oldValue != .connected { flash = 1 }
            if pose != oldValue { wake() }
        }
    }
    private var visible = false
    private var active = true
    private var settledTicks = 0
    private var posed = false
    private var snapPending = true
    private var occlusionObserver: NSObjectProtocol?

    private let turntable = SCNNode()
    private var temples: [(node: SCNNode, foldedAngle: Float)] = []
    private var displays: [SCNNode] = []
    private var indicator: SCNMaterial?
    private let glowColor = NSColor(srgbRed: 0x7C / 255, green: 0xF5 / 255, blue: 0xC0 / 255, alpha: 1)

    private var fold = Spring(value: 1)
    private var glow = Spring(value: 0)
    private var yaw = Spring(value: GlassesMotion.restYaw)
    private var pitch = Spring(value: 0)
    private var flash: Float = 0
    private var clock: Float = 0
    private var lastTime: TimeInterval?
    private var dragging = false
    private var lastDrag: (point: NSPoint, time: TimeInterval)?
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init() {
        super.init(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        backgroundColor = .clear
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 60
        rendersContinuously = true
        isPlaying = true
        delegate = self

        let scene = SCNScene()
        scene.lightingEnvironment.contents = GlassesMotion.studioEnvironment()
        scene.lightingEnvironment.intensity = 1.6
        scene.rootNode.addChildNode(turntable)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera!.fieldOfView = 13.5
        camera.camera!.wantsHDR = true
        camera.camera!.wantsExposureAdaptation = false
        camera.position = SCNVector3(0, 1.05, 5.6)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)
        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 900
        key.eulerAngles = SCNVector3(-0.9, 0.5, 0)
        scene.rootNode.addChildNode(key)
        self.scene = scene
        pointOfView = camera
        loadModel()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func loadModel() {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("rayneo-io.usdz")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("assets/models/rayneo-io.usdz")
        let url = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? development
        DispatchQueue.global(qos: .userInitiated).async {
            let model = try! SCNScene(url: url).rootNode.childNode(withName: "RayNeo", recursively: false)!
            DispatchQueue.main.async { self.install(model) }
        }
    }

    /// Scales the frame to a width of 2 units, centres it, and finds the parts the animation drives.
    private func install(_ model: SCNNode) {
        let (low, high) = model.childNode(withName: "Front_assembly", recursively: false)!.boundingBox
        let front = (low: model.convertPosition(low, to: nil), high: model.convertPosition(high, to: nil))
        let scale = 2 / Float(abs(front.high.x - front.low.x))
        let center = SCNVector3((front.low.x + front.high.x) / 2, (front.low.y + front.high.y) / 2, (front.low.z + front.high.z) / 2)
        let holder = SCNNode()
        holder.scale = SCNVector3(scale, scale, scale)
        holder.position = SCNVector3(-center.x * CGFloat(scale), -center.y * CGFloat(scale), -center.z * CGFloat(scale) + 0.6)
        holder.addChildNode(model)
        turntable.addChildNode(holder)

        // Each temple pivots on its hinge knuckle about the model's vertical axis; signs fold both inward.
        let up = model.convertVector(SCNVector3(0, 1, 0), from: nil)
        for (side, angle) in [("R", -GlassesMotion.foldAngle), ("L", GlassesMotion.foldAngle - 0.06)] {
            let temple = model.childNode(withName: "\(side)_temple_assembly", recursively: false)!
            let (a, b) = temple.childNode(withName: "\(side)_hinge_knuckle", recursively: true)!.boundingBox
            let hinge = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
            temple.pivot = SCNMatrix4MakeTranslation(hinge.x, hinge.y, hinge.z)
            temple.position = hinge
            temple.rotation = SCNVector4(up.x, up.y, up.z, 0)
            temples.append((temple, angle))
        }
        // USD keeps an Xform and its mesh under the same name; the animation needs the mesh.
        func mesh(_ name: String) -> SCNNode { model.childNodes { node, _ in node.name == name && node.geometry != nil }.first! }
        // A waveguide image floats just in front of each lens, facing the viewer (model front is -y, up is +z).
        let hud = SCNMaterial()
        hud.lightingModel = .constant
        hud.diffuse.contents = GlassesMotion.displayImage()
        hud.blendMode = .alpha
        hud.writesToDepthBuffer = false
        for side in ["L", "R"] {
            let lens = mesh("\(side)_clear_lens")
            lens.geometry!.firstMaterial!.writesToDepthBuffer = false
            let (a, b) = lens.boundingBox
            let plane = SCNPlane(width: (b.x - a.x) * 0.62, height: (b.z - a.z) * 0.36)
            plane.materials = [hud]
            let display = SCNNode(geometry: plane)
            display.position = SCNVector3((a.x + b.x) / 2, a.y - 0.0008, (a.z + b.z) / 2 + (b.z - a.z) * 0.08)
            display.eulerAngles.x = .pi / 2
            display.opacity = 0
            display.renderingOrder = 10
            lens.parent!.addChildNode(display)
            displays.append(display)
        }
        indicator = mesh("R_status_indicator").geometry!.firstMaterial
        indicator!.diffuse.contents = NSColor(white: 0.08, alpha: 1)
        indicator!.emission.contents = glowColor
        indicator!.emission.intensity = 0
    }

    /// SceneKit calls this on its render thread; all animation state lives on the main thread with the mouse.
    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        DispatchQueue.main.async { self.tick(time) }
    }

    private func tick(_ time: TimeInterval) {
        let dt = Float(min(time - (lastTime ?? time), 1 / 30))
        lastTime = time
        clock += dt
        guard !temples.isEmpty else { return }
        let target = GlassesMotion.target(pose, clock: reduceMotion ? 0 : clock)
        if snapPending {
            snapPending = false
            fold.value = target.fold; glow.value = target.glow
        }
        if reduceMotion {
            fold.value = target.fold; glow.value = target.glow; flash = 0
        } else {
            fold.step(to: target.fold, stiffness: 26, damping: 0.9, dt: dt)
            glow.step(to: target.glow, stiffness: 60, dt: dt)
            flash = max(0, flash - dt * 2.2)
        }
        // Settle on the nearest full turn of the resting angle so a flick spins and lands cleanly.
        let turn = 2 * Float.pi
        let rest = GlassesMotion.restYaw + turn * ((yaw.value - GlassesMotion.restYaw) / turn).rounded()
        if !dragging {
            yaw.step(to: rest, stiffness: reduceMotion ? 60 : 9, damping: 0.75, dt: dt)
            pitch.step(to: 0, stiffness: 18, damping: 0.8, dt: dt)
        }
        let settled = !dragging && pose != .connecting && flash == 0
            && [fold.value - target.fold, glow.value - target.glow, yaw.value - rest, pitch.value,
                fold.velocity, glow.velocity, yaw.velocity, pitch.velocity].allSatisfy { abs($0) < 0.0005 }
        if settled {
            fold = Spring(value: target.fold); glow = Spring(value: target.glow)
            yaw = Spring(value: GlassesMotion.restYaw); pitch = Spring(value: 0)
        }
        let eased = min(1, max(0, fold.value))
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        for temple in temples { temple.node.rotation.w = CGFloat(temple.foldedAngle * eased) }
        turntable.eulerAngles = SCNVector3(CGFloat(pitch.value), CGFloat(yaw.value), 0)
        // The display opens like a CRT on power-on: a thin bright line that expands to the full panel.
        for display in displays {
            display.opacity = CGFloat(min(1, max(0, glow.value)))
            display.scale = SCNVector3(1, CGFloat(1 - 0.85 * flash * flash), 1)
        }
        indicator?.emission.intensity = CGFloat(target.indicator) * 3
        SCNTransaction.commit()
        // Once everything rests, stop the render loop until the pose changes or the user grabs the model.
        settledTicks = settled ? settledTicks + 1 : 0
        if settledTicks >= 2 { active = false; updateLoop() }
    }

    private func wake() {
        settledTicks = 0
        guard !active else { return }
        active = true
        updateLoop()
    }

    /// Rendering runs only while the window is on screen; `isPlaying` alone does not stop a continuous SCNView.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        occlusionObserver.map(NotificationCenter.default.removeObserver)
        occlusionObserver = nil
        setRendering(window?.occlusionState.contains(.visible) ?? false)
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                                   queue: .main) { [weak self, weak window] _ in
            self?.setRendering(window?.occlusionState.contains(.visible) ?? false)
        }
    }

    private func setRendering(_ visible: Bool) {
        self.visible = visible
        updateLoop()
    }

    private func updateLoop() {
        let running = visible && active
        if running && !rendersContinuously { lastTime = nil }
        rendersContinuously = running
        isPlaying = running
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand) }

    override func mouseDown(with event: NSEvent) {
        wake()
        dragging = true
        lastDrag = (convert(event.locationInWindow, from: nil), event.timestamp)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let last = lastDrag else { return }
        let dt = Float(max(event.timestamp - last.time, 1 / 240))
        let dx = Float(point.x - last.point.x) * 0.012, dy = Float(point.y - last.point.y) * 0.008
        yaw.value += dx; yaw.velocity = dx / dt
        pitch.value = min(0.45, max(-0.45, pitch.value - dy)); pitch.velocity = -dy / dt
        lastDrag = (point, event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        lastDrag = nil
        window?.invalidateCursorRects(for: self)
    }
}

/// Motion targets and lighting shared in spirit with Android's GlassesStage (same constants, same studio).
enum GlassesMotion {
    static let restYaw: Float = -0.55
    static let foldAngle: Float = 1.48

    /// The model never moves on its own: it holds the resting angle and only state changes animate. Connecting is
    /// the one ongoing signal (blinking status light, flickering display) while the link is being set up.
    struct Target { var fold: Float; var glow: Float; var indicator: Float }

    static func target(_ pose: GlassesPose, clock t: Float) -> Target {
        switch pose {
        case .resting: return Target(fold: 1, glow: 0, indicator: 0)
        case .connecting: return Target(fold: 0, glow: 0.4 + 0.3 * sin(t * 3.2), indicator: sin(t * 7) > 0 ? 1 : 0.15)
        case .connected: return Target(fold: 0, glow: 1, indicator: 1)
        }
    }

    /// The waveguide image: lines of phosphor "text" and a status dot on a dark lens panel, transparent elsewhere.
    /// (Additive blending would wash out over the view's transparent background.)
    static func displayImage() -> NSImage {
        NSImage(size: NSSize(width: 240, height: 120), flipped: true) { _ in
            let phosphor = NSColor(srgbRed: 0x7C / 255, green: 0xF5 / 255, blue: 0xC0 / 255, alpha: 1)
            NSColor(srgbRed: 0x0B / 255, green: 0x0F / 255, blue: 0x0D / 255, alpha: 0.72).setFill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 6, width: 228, height: 108), xRadius: 18, yRadius: 18).fill()
            phosphor.withAlphaComponent(0.35).setStroke()
            NSBezierPath(roundedRect: NSRect(x: 7, y: 7, width: 226, height: 106), xRadius: 17, yRadius: 17).stroke()
            phosphor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 30, y: 34, width: 120, height: 14), xRadius: 7, yRadius: 7).fill()
            NSBezierPath(ovalIn: NSRect(x: 186, y: 32, width: 18, height: 18)).fill()
            phosphor.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: NSRect(x: 30, y: 66, width: 176, height: 12), xRadius: 6, yRadius: 6).fill()
            NSBezierPath(roundedRect: NSRect(x: 30, y: 88, width: 92, height: 12), xRadius: 6, yRadius: 6).fill()
            return true
        }
    }

    /// Soft studio: dark floor, bright overhead softbox, a key strip on the left and a rim strip behind right.
    static func radiance(_ d: SIMD3<Float>) -> SIMD3<Float> {
        func lobe(_ center: SIMD3<Float>, _ width: Float) -> Float {
            exp(-(1 - simd_dot(d, simd_normalize(center))) / (width * width))
        }
        let horizon = min(1, max(0, (d.y + 0.25) / 0.9))
        let base = 0.05 + 0.3 * horizon * horizon
        let light = 3.2 * lobe([0, 0.9, 0.45], 0.42) + 2.2 * lobe([-0.85, 0.25, 0.45], 0.28) + 1.6 * lobe([0.8, 0.35, -0.5], 0.3)
        return SIMD3(repeating: base + light) * SIMD3(1, 1, 1.03)
    }

    /// Equirectangular float image of `radiance`, used as SceneKit's lighting environment.
    static func studioEnvironment() -> CGImage {
        let width = 256, height = 128
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            let theta = Float.pi * (Float(y) + 0.5) / Float(height)
            for x in 0..<width {
                let phi = 2 * Float.pi * (Float(x) + 0.5) / Float(width) - Float.pi
                let c = radiance([sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi)])
                let i = (y * width + x) * 4
                pixels[i] = c.x; pixels[i + 1] = c.y; pixels[i + 2] = c.z
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        return CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
                       space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

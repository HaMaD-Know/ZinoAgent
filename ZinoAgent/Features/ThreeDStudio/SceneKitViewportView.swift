import SwiftUI
import SceneKit
import UIKit

/// Metal-backed interactive 3D viewport supporting orbit, zoom, pan, tap-to-select objects,
/// live lighting/environment controls, wireframe mode, ground reference grid, and camera reset.
public struct SceneKitViewportView: UIViewRepresentable {
    public let loadedModel: LoadedThreeDModel?
    public let lightingPreset: ThreeDLightingPreset
    public let environmentPreset: ThreeDEnvironmentPreset
    public let lightIntensity: Double
    public let isWireframe: Bool
    public let showGrid: Bool
    public let resetCameraToken: UUID
    public let selectedNodeID: String?
    public let onSelectNode: (String?) -> Void

    public func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.backgroundColor = environmentPreset.backgroundColor

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.scnView = view
        return view
    }

    public func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.backgroundColor = environmentPreset.backgroundColor
        context.coordinator.onSelectNode = onSelectNode

        if context.coordinator.currentScene !== loadedModel?.scene {
            context.coordinator.currentScene = loadedModel?.scene
            if let model = loadedModel {
                let scene = model.scene
                uiView.scene = scene
                configureCameraAndLights(in: scene, modelRoot: model.modelRootNode)
                frameCamera(in: uiView, modelRoot: model.modelRootNode)
                context.coordinator.lastResetToken = resetCameraToken
            } else {
                uiView.scene = nil
            }
        }

        guard let scene = uiView.scene, let model = loadedModel else { return }

        if context.coordinator.lastResetToken != resetCameraToken {
            context.coordinator.lastResetToken = resetCameraToken
            frameCamera(in: uiView, modelRoot: model.modelRootNode)
        }

        updateLighting(in: scene, preset: lightingPreset, intensityMultiplier: lightIntensity)
        updateGrid(in: scene, modelRoot: model.modelRootNode, visible: showGrid)
        updateWireframe(root: model.modelRootNode, wireframe: isWireframe)
        highlightSelection(nodeMap: model.nodeMap, selectedID: selectedNodeID)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onSelectNode: onSelectNode)
    }

    public final class Coordinator: NSObject {
        weak var scnView: SCNView?
        weak var currentScene: SCNScene?
        var lastResetToken = UUID()
        var onSelectNode: (String?) -> Void

        init(onSelectNode: @escaping (String?) -> Void) {
            self.onSelectNode = onSelectNode
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = scnView else { return }
            let location = gesture.location(in: view)
            let hits = view.hitTest(location, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue])
            if let hitNode = hits.first?.node {
                var cursor: SCNNode? = hitNode
                while let c = cursor {
                    if let name = c.name, name.hasPrefix("node_") || name.hasPrefix("mdl_node_") {
                        onSelectNode(name)
                        return
                    }
                    cursor = c.parent
                }
            }
            onSelectNode(nil)
        }
    }

    // MARK: - Scene Rigging

    private func configureCameraAndLights(in scene: SCNScene, modelRoot: SCNNode) {
        if scene.rootNode.childNode(withName: "__zino_camera", recursively: false) == nil {
            let cameraNode = SCNNode()
            cameraNode.name = "__zino_camera"
            let cam = SCNCamera()
            cam.automaticallyAdjustsZRange = true
            cam.fieldOfView = 45
            cam.wantsHDR = true
            cameraNode.camera = cam
            scene.rootNode.addChildNode(cameraNode)
        }

        if scene.rootNode.childNode(withName: "__zino_light_rig", recursively: false) == nil {
            let rig = SCNNode()
            rig.name = "__zino_light_rig"

            let key = SCNNode()
            key.name = "__key_light"
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.castsShadow = true
            key.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
            rig.addChildNode(key)

            let fill = SCNNode()
            fill.name = "__fill_light"
            fill.light = SCNLight()
            fill.light?.type = .directional
            fill.eulerAngles = SCNVector3(-Float.pi / 6, -Float.pi * 0.65, 0)
            rig.addChildNode(fill)

            let rim = SCNNode()
            rim.name = "__rim_light"
            rim.light = SCNLight()
            rim.light?.type = .directional
            rim.eulerAngles = SCNVector3(-Float.pi / 8, Float.pi, 0)
            rig.addChildNode(rim)

            let ambient = SCNNode()
            ambient.name = "__ambient_light"
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            rig.addChildNode(ambient)

            scene.rootNode.addChildNode(rig)
        }
    }

    private func frameCamera(in view: SCNView, modelRoot: SCNNode) {
        guard let cameraNode = view.scene?.rootNode.childNode(withName: "__zino_camera", recursively: false) else { return }
        let (minB, maxB) = modelRoot.boundingBox
        let center = SCNVector3(
            (minB.x + maxB.x) * 0.5,
            (minB.y + maxB.y) * 0.5,
            (minB.z + maxB.z) * 0.5
        )
        let dx = maxB.x - minB.x
        let dy = maxB.y - minB.y
        let dz = maxB.z - minB.z
        let radius = max(0.5, sqrt(dx * dx + dy * dy + dz * dz) * 0.5)
        let distance = radius * 2.4

        cameraNode.position = SCNVector3(center.x + distance * 0.55, center.y + distance * 0.4, center.z + distance * 0.85)
        cameraNode.look(at: center)
        view.pointOfView = cameraNode
        view.defaultCameraController.target = center
    }

    private func updateLighting(in scene: SCNScene, preset: ThreeDLightingPreset, intensityMultiplier: Double) {
        guard let rig = scene.rootNode.childNode(withName: "__zino_light_rig", recursively: false) else { return }
        let key = rig.childNode(withName: "__key_light", recursively: false)?.light
        let fill = rig.childNode(withName: "__fill_light", recursively: false)?.light
        let rim = rig.childNode(withName: "__rim_light", recursively: false)?.light
        let ambient = rig.childNode(withName: "__ambient_light", recursively: false)?.light
        let m = CGFloat(max(0.1, intensityMultiplier))

        switch preset {
        case .studio:
            key?.intensity = 1000 * m
            key?.color = UIColor(white: 1.0, alpha: 1.0)
            fill?.intensity = 450 * m
            fill?.color = UIColor(red: 0.90, green: 0.94, blue: 1.0, alpha: 1.0)
            rim?.intensity = 550 * m
            rim?.color = UIColor(white: 1.0, alpha: 1.0)
            ambient?.intensity = 320 * m
            ambient?.color = UIColor(white: 0.85, alpha: 1.0)
        case .daylight:
            key?.intensity = 1350 * m
            key?.color = UIColor(red: 1.0, green: 0.98, blue: 0.92, alpha: 1.0)
            fill?.intensity = 550 * m
            fill?.color = UIColor(red: 0.78, green: 0.88, blue: 1.0, alpha: 1.0)
            rim?.intensity = 250 * m
            rim?.color = UIColor.white
            ambient?.intensity = 500 * m
            ambient?.color = UIColor(red: 0.85, green: 0.92, blue: 1.0, alpha: 1.0)
        case .dramatic:
            key?.intensity = 1400 * m
            key?.color = UIColor(red: 1.0, green: 0.92, blue: 0.84, alpha: 1.0)
            fill?.intensity = 120 * m
            fill?.color = UIColor(red: 0.55, green: 0.68, blue: 0.95, alpha: 1.0)
            rim?.intensity = 950 * m
            rim?.color = UIColor(red: 0.70, green: 0.85, blue: 1.0, alpha: 1.0)
            ambient?.intensity = 110 * m
            ambient?.color = UIColor(white: 0.4, alpha: 1.0)
        case .soft:
            key?.intensity = 650 * m
            key?.color = UIColor.white
            fill?.intensity = 550 * m
            fill?.color = UIColor.white
            rim?.intensity = 400 * m
            rim?.color = UIColor.white
            ambient?.intensity = 650 * m
            ambient?.color = UIColor(white: 0.95, alpha: 1.0)
        }
    }

    private func updateGrid(in scene: SCNScene, modelRoot: SCNNode, visible: Bool) {
        let existing = scene.rootNode.childNode(withName: "__zino_grid", recursively: false)
        if !visible {
            existing?.isHidden = true
            return
        }
        if let existing {
            existing.isHidden = false
            return
        }

        let (minB, maxB) = modelRoot.boundingBox
        let extent = max(2.0, max(maxB.x - minB.x, maxB.z - minB.z) * 1.6)
        let half = extent * 0.5
        let steps = 10
        let stepSize = extent / Float(steps)
        let y = minB.y

        var vertices: [SCNVector3] = []
        for i in 0...steps {
            let offset = -half + Float(i) * stepSize
            vertices.append(SCNVector3(-half, y, offset))
            vertices.append(SCNVector3(half, y, offset))
            vertices.append(SCNVector3(offset, y, -half))
            vertices.append(SCNVector3(offset, y, half))
        }
        let indices: [Int32] = (0..<Int32(vertices.count)).map { $0 }
        let src = SCNGeometrySource(vertices: vertices)
        let elem = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geom = SCNGeometry(sources: [src], elements: [elem])
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor.gray.withAlphaComponent(0.35)
        geom.materials = [mat]

        let gridNode = SCNNode(geometry: geom)
        gridNode.name = "__zino_grid"
        scene.rootNode.addChildNode(gridNode)
    }

    private func updateWireframe(root: SCNNode, wireframe: Bool) {
        let targetMode: SCNFillMode = wireframe ? .lines : .fill
        root.enumerateHierarchy { node, _ in
            guard let mats = node.geometry?.materials else { return }
            for mat in mats where mat.fillMode != targetMode {
                mat.fillMode = targetMode
            }
        }
    }

    private func highlightSelection(nodeMap: [String: SCNNode], selectedID: String?) {
        for (id, node) in nodeMap {
            let isSelected = (id == selectedID)
            node.enumerateHierarchy { sub, _ in
                if let name = sub.name, name != id, nodeMap[name] != nil { return }
                guard let mats = sub.geometry?.materials else { return }
                for mat in mats {
                    if isSelected {
                        mat.emission.intensity = 0.35
                        if mat.emission.contents == nil || (mat.emission.contents as? UIColor) == UIColor.black {
                            mat.emission.contents = UIColor.systemBlue.withAlphaComponent(0.45)
                        }
                    } else if let col = mat.emission.contents as? UIColor, col == UIColor.systemBlue.withAlphaComponent(0.45) {
                        mat.emission.contents = UIColor.black
                        mat.emission.intensity = 1.0
                    }
                }
            }
        }
    }
}

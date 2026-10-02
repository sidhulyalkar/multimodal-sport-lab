import MotionOSAppleCapture
import SceneKit
import SwiftUI
import UIKit
import simd

enum GhostSceneViewpoint: String, CaseIterable, Identifiable {
    case front = "Front"
    case side = "Side"
    case orbit = "3D"

    var id: String { rawValue }
}

struct GhostPoseScene3D: UIViewRepresentable {
    let current: BodyMovementFrame
    let reference: BodyMovementFrame
    let viewpoint: GhostSceneViewpoint

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(
        context: Context
    ) -> SCNView {
        let view = SCNView(frame: .zero)
        context.coordinator.configure(view)
        return view
    }

    func updateUIView(
        _ view: SCNView,
        context: Context
    ) {
        context.coordinator.update(
            view: view,
            current: current,
            reference: reference,
            viewpoint: viewpoint
        )
    }

    @MainActor
    final class Coordinator {
        private let scene = SCNScene()
        private let currentRoot = SCNNode()
        private let referenceRoot = SCNNode()
        private let cameraNode = SCNNode()
        private let groundNode = SCNNode()

        private var currentJoints: [String: SCNNode] = [:]
        private var currentBones: [String: SCNNode] = [:]
        private var referenceJoints: [String: SCNNode] = [:]
        private var referenceBones: [String: SCNNode] = [:]
        private var lastViewpoint: GhostSceneViewpoint?

        func configure(
            _ view: SCNView
        ) {
            scene.background.contents = UIColor.clear
            scene.rootNode.addChildNode(referenceRoot)
            scene.rootNode.addChildNode(currentRoot)

            configureLights()
            configureGround()

            let camera = SCNCamera()
            camera.fieldOfView = 42
            camera.zNear = 0.01
            camera.zFar = 20
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)

            view.scene = scene
            view.pointOfView = cameraNode
            view.backgroundColor = .clear
            view.antialiasingMode = .multisampling4X
            view.preferredFramesPerSecond = 60
            view.rendersContinuously = false
            view.autoenablesDefaultLighting = false
            view.allowsCameraControl = true
        }

        func update(
            view: SCNView,
            current: BodyMovementFrame,
            reference: BodyMovementFrame,
            viewpoint: GhostSceneViewpoint
        ) {
            updateSkeleton(
                frame: reference,
                root: referenceRoot,
                jointNodes: &referenceJoints,
                boneNodes: &referenceBones,
                color: .systemIndigo,
                opacity: 0.26,
                jointRadius: 0.018,
                boneRadius: 0.009
            )
            updateSkeleton(
                frame: current,
                root: currentRoot,
                jointNodes: &currentJoints,
                boneNodes: &currentBones,
                color: .systemCyan,
                opacity: 0.92,
                jointRadius: 0.021,
                boneRadius: 0.011
            )

            let floorY = min(
                inferredFloorY(current),
                inferredFloorY(reference)
            )
            groundNode.position.y = Float(
                floorY - 0.008
            )

            if lastViewpoint != viewpoint {
                positionCamera(
                    viewpoint: viewpoint,
                    current: current,
                    reference: reference
                )
                lastViewpoint = viewpoint
            }

            view.allowsCameraControl =
                viewpoint == .orbit
            view.setNeedsDisplay()
        }

        private func configureLights() {
            let ambient = SCNNode()
            let ambientLight = SCNLight()
            ambientLight.type = .ambient
            ambientLight.intensity = 650
            ambientLight.color = UIColor(
                white: 0.88,
                alpha: 1
            )
            ambient.light = ambientLight
            scene.rootNode.addChildNode(ambient)

            let key = SCNNode()
            let keyLight = SCNLight()
            keyLight.type = .directional
            keyLight.intensity = 900
            keyLight.castsShadow = false
            key.light = keyLight
            key.eulerAngles = SCNVector3(
                -Float.pi / 4,
                Float.pi / 4,
                0
            )
            scene.rootNode.addChildNode(key)
        }

        private func configureGround() {
            let plane = SCNPlane(
                width: 3.5,
                height: 3.5
            )
            let material = SCNMaterial()
            material.diffuse.contents =
                UIColor.secondarySystemFill
                    .withAlphaComponent(0.16)
            material.isDoubleSided = true
            plane.materials = [material]

            groundNode.geometry = plane
            groundNode.eulerAngles.x =
                -Float.pi / 2
            groundNode.position.y = -0.9
            scene.rootNode.addChildNode(
                groundNode
            )
        }

        private func updateSkeleton(
            frame: BodyMovementFrame,
            root: SCNNode,
            jointNodes: inout [String: SCNNode],
            boneNodes: inout [String: SCNNode],
            color: UIColor,
            opacity: CGFloat,
            jointRadius: CGFloat,
            boneRadius: CGFloat
        ) {
            let map = frame.jointMap
            let visibleJoints = Set(map.keys)
            var visibleBones = Set<String>()

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.10

            for joint in frame.joints {
                let node: SCNNode
                if let existing = jointNodes[joint.id] {
                    node = existing
                } else {
                    node = sphereNode(
                        radius: normalized(joint.id)
                            .contains("head")
                            ? jointRadius * 2.3
                            : jointRadius,
                        color: color,
                        opacity: opacity
                    )
                    node.name = joint.id
                    jointNodes[joint.id] = node
                    root.addChildNode(node)
                }

                node.isHidden = false
                node.simdPosition = vector(
                    joint.position
                )

                guard let parentID = joint.parentID,
                      let parent = map[parentID]
                else {
                    continue
                }

                let id = parentID + "->" + joint.id
                visibleBones.insert(id)

                let bone: SCNNode
                if let existing = boneNodes[id] {
                    bone = existing
                } else {
                    bone = cylinderNode(
                        radius: boneRadius,
                        color: color,
                        opacity: opacity
                    )
                    bone.name = id
                    boneNodes[id] = bone
                    root.addChildNode(bone)
                }

                positionCylinder(
                    bone,
                    from: parent.position,
                    to: joint.position
                )
            }

            for (id, node) in jointNodes {
                node.isHidden =
                    !visibleJoints.contains(id)
            }
            for (id, node) in boneNodes {
                node.isHidden =
                    !visibleBones.contains(id)
            }

            SCNTransaction.commit()
        }

        private func positionCamera(
            viewpoint: GhostSceneViewpoint,
            current: BodyMovementFrame,
            reference: BodyMovementFrame
        ) {
            let points =
                current.joints.map(\.position)
                    + reference.joints.map(\.position)

            guard let first = points.first else {
                return
            }

            var minX = first.x
            var minY = first.y
            var minZ = first.z
            var maxX = first.x
            var maxY = first.y
            var maxZ = first.z

            for point in points.dropFirst() {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                minZ = min(minZ, point.z)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
                maxZ = max(maxZ, point.z)
            }

            let center = SIMD3<Float>(
                Float((minX + maxX) / 2),
                Float((minY + maxY) / 2),
                Float((minZ + maxZ) / 2)
            )
            let span = max(
                1.0,
                Float(
                    max(
                        maxX - minX,
                        max(
                            maxY - minY,
                            maxZ - minZ
                        )
                    )
                )
            )
            let distance = max(
                2.2,
                span * 1.65
            )

            switch viewpoint {
            case .front:
                cameraNode.simdPosition =
                    center
                    + SIMD3<Float>(
                        0,
                        0.04,
                        distance
                    )
            case .side:
                cameraNode.simdPosition =
                    center
                    + SIMD3<Float>(
                        distance,
                        0.04,
                        0
                    )
            case .orbit:
                cameraNode.simdPosition =
                    center
                    + SIMD3<Float>(
                        distance * 0.72,
                        distance * 0.22,
                        distance * 0.82
                    )
            }

            cameraNode.look(
                at: SCNVector3(
                    center.x,
                    center.y,
                    center.z
                )
            )
        }

        private func sphereNode(
            radius: CGFloat,
            color: UIColor,
            opacity: CGFloat
        ) -> SCNNode {
            let sphere = SCNSphere(
                radius: radius
            )
            sphere.segmentCount = 16
            sphere.materials = [
                material(
                    color: color,
                    opacity: opacity
                )
            ]
            return SCNNode(
                geometry: sphere
            )
        }

        private func cylinderNode(
            radius: CGFloat,
            color: UIColor,
            opacity: CGFloat
        ) -> SCNNode {
            let cylinder = SCNCylinder(
                radius: radius,
                height: 0.1
            )
            cylinder.radialSegmentCount = 12
            cylinder.materials = [
                material(
                    color: color,
                    opacity: opacity
                )
            ]
            return SCNNode(
                geometry: cylinder
            )
        }

        private func material(
            color: UIColor,
            opacity: CGFloat
        ) -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = color
            material.roughness.contents = 0.58
            material.transparency = opacity
            material.isDoubleSided = true
            return material
        }

        private func positionCylinder(
            _ node: SCNNode,
            from start: MotionVector3,
            to end: MotionVector3
        ) {
            let a = vector(start)
            let b = vector(end)
            let delta = b - a
            let length = simd_length(delta)

            guard length > 0.0001 else {
                node.isHidden = true
                return
            }

            node.isHidden = false
            node.simdPosition = (a + b) / 2
            node.simdOrientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: simd_normalize(delta)
            )

            if let cylinder =
                node.geometry as? SCNCylinder {
                cylinder.height =
                    CGFloat(length)
            }
        }

        private func inferredFloorY(
            _ frame: BodyMovementFrame
        ) -> Double {
            if let support =
                frame.supportPoints.map(\.y).min() {
                return support
            }

            return frame.joints
                .map { $0.position.y }
                .min() ?? -0.9
        }

        private func vector(
            _ value: MotionVector3
        ) -> SIMD3<Float> {
            SIMD3<Float>(
                Float(value.x),
                Float(value.y),
                Float(value.z)
            )
        }

        private func normalized(
            _ value: String
        ) -> String {
            value.lowercased().filter {
                $0.isLetter || $0.isNumber
            }
        }
    }
}

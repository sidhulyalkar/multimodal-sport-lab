import MotionOSAppleCapture
import SceneKit
import SwiftUI
import simd

enum BodySceneViewpoint: String, CaseIterable, Identifiable {
    case front = "Front"
    case side = "Side"
    case orbit = "3D"

    var id: String { rawValue }
}

struct BodyMovementSceneCard: View {
    @EnvironmentObject private var camera: CameraCaptureController

    @State private var viewpoint: BodySceneViewpoint = .orbit
    @State private var showSupport = true
    @State private var showMuscles = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Picker("Body view", selection: $viewpoint) {
                ForEach(BodySceneViewpoint.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("3D body viewpoint")

            ZStack(alignment: .topLeading) {
                BodyMovementScene3D(
                    frame: displayFrame,
                    viewpoint: viewpoint,
                    showSupport: showSupport,
                    showMuscles: showMuscles && hasMuscleModel,
                    isReference: isReferenceFrame
                )
                .frame(height: 310)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 20,
                        style: .continuous
                    )
                )

                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    sceneBadge(at: context.date)
                        .padding(10)
                }
            }

            layerControls
            interpretation

            Text(claimBoundary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            MotionOSSectionHeader(
                title: "Body movement",
                subtitle: isReferenceFrame
                    ? "Reference pose · awaiting Vision 3D"
                    : "Vision 3D pose · root-relative meters",
                systemImage: "figure.arms.open",
                accent: .cyan
            )

            Spacer(minLength: 4)

            if let bodyHeight = camera.latestPoseFrame?.bodyHeightM {
                Text(String(format: "%.2f m", bodyHeight))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func sceneBadge(
        at date: Date
    ) -> some View {
        let freshness = camera.latestPoseReceivedAt.map {
            max(0, date.timeIntervalSince($0))
        }

        let title: String
        let symbol: String
        let color: Color

        if isReferenceFrame {
            title = "REFERENCE"
            symbol = "person.crop.rectangle"
            color = .secondary
        } else if camera.phase == .recording,
                  (freshness ?? .infinity) <= 1.5 {
            title = "VISION 3D"
            symbol = "dot.radiowaves.left.and.right"
            color = .green
        } else if camera.phase == .recording {
            title = "REACQUIRING"
            symbol = "viewfinder"
            color = .yellow
        } else {
            title = "LAST FRAME"
            symbol = "pause.fill"
            color = .secondary
        }

        return Label(title, systemImage: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                .ultraThinMaterial,
                in: Capsule()
            )
    }

    private var layerControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Toggle("Support", isOn: $showSupport)
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)

                Toggle("Muscles", isOn: $showMuscles)
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)
                    .disabled(!hasMuscleModel)

                Spacer(minLength: 0)

                legend
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle("Support", isOn: $showSupport)
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)

                    Toggle("Muscles", isOn: $showMuscles)
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                        .disabled(!hasMuscleModel)
                }

                legend
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem("Left", color: .cyan)
            legendItem("Right", color: .indigo)
            legendItem("Pelvis", color: .orange)
        }
        .font(.caption2)
    }

    private func legendItem(
        _ title: String,
        color: Color
    ) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
        }
    }

    private var interpretation: some View {
        VStack(alignment: .leading, spacing: 7) {
            interpretationRow(
                title: "Pose",
                value: isReferenceFrame
                    ? "Reference geometry"
                    : "\(displayFrame.joints.count) Vision joints",
                symbol: "figure.stand"
            )

            interpretationRow(
                title: "Support",
                value: displayFrame.supportPoints.count >= 2
                    ? "Foot / ankle support estimate"
                    : "Unavailable",
                symbol: "rectangle.bottomthird.inset.filled"
            )

            interpretationRow(
                title: "Body center",
                value: bodyCenterLabel,
                symbol: "scope"
            )

            interpretationRow(
                title: "Muscle load",
                value: hasMuscleModel
                    ? "Model estimate available"
                    : "Not estimated",
                symbol: "figure.strengthtraining.traditional"
            )
        }
    }

    private func interpretationRow(
        title: String,
        value: String,
        symbol: String
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.caption.weight(.semibold))

            Spacer(minLength: 8)

            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var bodyCenterLabel: String {
        if let center = displayFrame.centerOfMass {
            return center.provenance == .measured
                ? "Measured center of mass"
                : "Estimated center of mass"
        }
        if displayFrame.pelvisReference != nil {
            return "Pelvis proxy · not COM"
        }
        return "Unavailable"
    }

    private var claimBoundary: String {
        if isReferenceFrame {
            return "The body shown is a neutral reference pose, not a measurement. "
                + "Start the iPhone Vision capture to replace it with detected 3D joints."
        }

        if hasMuscleModel {
            return "Skeleton geometry comes from Vision 3D. Support is an ankle/foot "
                + "geometry estimate. Muscle shading is model-estimated and is not EMG."
        }

        return "Skeleton geometry comes from Vision 3D. The orange marker is a pelvis "
            + "reference, not center of mass. Support is an ankle/foot geometry estimate. "
            + "No muscle activation is inferred unless an explicit model supplies it."
    }

    private var displayFrame: BodyMovementFrame {
        camera.latestPoseFrame ?? Self.referenceFrame
    }

    private var isReferenceFrame: Bool {
        camera.latestPoseFrame == nil
    }

    private var hasMuscleModel: Bool {
        camera.latestPoseFrame?.hasModelEstimatedMuscleActivity == true
    }

    private static let referenceFrame: BodyMovementFrame = {
        let joints: [BodyJoint3D] = [
            .init(
                id: "root",
                parentID: nil,
                position: MotionVector3(0, 0, 0)
            ),
            .init(
                id: "spine",
                parentID: "root",
                position: MotionVector3(0, 0.30, 0)
            ),
            .init(
                id: "centerShoulder",
                parentID: "spine",
                position: MotionVector3(0, 0.62, 0)
            ),
            .init(
                id: "topHead",
                parentID: "centerShoulder",
                position: MotionVector3(0, 0.88, 0)
            ),
            .init(
                id: "leftShoulder",
                parentID: "centerShoulder",
                position: MotionVector3(-0.22, 0.60, 0)
            ),
            .init(
                id: "leftElbow",
                parentID: "leftShoulder",
                position: MotionVector3(-0.40, 0.36, 0)
            ),
            .init(
                id: "leftWrist",
                parentID: "leftElbow",
                position: MotionVector3(-0.47, 0.12, 0)
            ),
            .init(
                id: "rightShoulder",
                parentID: "centerShoulder",
                position: MotionVector3(0.22, 0.60, 0)
            ),
            .init(
                id: "rightElbow",
                parentID: "rightShoulder",
                position: MotionVector3(0.40, 0.36, 0)
            ),
            .init(
                id: "rightWrist",
                parentID: "rightElbow",
                position: MotionVector3(0.47, 0.12, 0)
            ),
            .init(
                id: "leftHip",
                parentID: "root",
                position: MotionVector3(-0.14, -0.04, 0)
            ),
            .init(
                id: "leftKnee",
                parentID: "leftHip",
                position: MotionVector3(-0.15, -0.45, 0)
            ),
            .init(
                id: "leftAnkle",
                parentID: "leftKnee",
                position: MotionVector3(-0.15, -0.86, 0)
            ),
            .init(
                id: "rightHip",
                parentID: "root",
                position: MotionVector3(0.14, -0.04, 0)
            ),
            .init(
                id: "rightKnee",
                parentID: "rightHip",
                position: MotionVector3(0.15, -0.45, 0)
            ),
            .init(
                id: "rightAnkle",
                parentID: "rightKnee",
                position: MotionVector3(0.15, -0.86, 0)
            ),
        ]

        return BodyMovementFrame(
            sessionID: "reference",
            sequence: 0,
            deviceTimeNS: 0,
            source: "motionos_reference_pose",
            coordinateFrame: "reference_root_relative_meters",
            bodyHeightM: 1.75,
            joints: joints,
            pelvisReference: MovementEstimate3D(
                position: MotionVector3(0, 0, 0),
                provenance: .geometricProxy,
                label: "Pelvis reference · not center of mass"
            ),
            supportPoints: [
                MotionVector3(-0.15, -0.86, 0),
                MotionVector3(0.15, -0.86, 0),
            ]
        )
    }()
}

private struct BodyMovementScene3D: UIViewRepresentable {
    let frame: BodyMovementFrame
    let viewpoint: BodySceneViewpoint
    let showSupport: Bool
    let showMuscles: Bool
    let isReference: Bool

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
            frame: frame,
            viewpoint: viewpoint,
            showSupport: showSupport,
            showMuscles: showMuscles,
            isReference: isReference
        )
    }

    final class Coordinator {
        private let scene = SCNScene()
        private let surfaceRoot = SCNNode()
        private let bodyRoot = SCNNode()
        private let supportRoot = SCNNode()
        private let muscleRoot = SCNNode()
        private let markerRoot = SCNNode()
        private let cameraNode = SCNNode()
        private let groundNode = SCNNode()

        private var jointNodes: [String: SCNNode] = [:]
        private var boneNodes: [String: SCNNode] = [:]
        private var surfaceNodes: [String: SCNNode] = [:]
        private var lastViewpoint: BodySceneViewpoint?
        private var lastSessionID: String?
        private var lastSequence: UInt64?

        func configure(
            _ view: SCNView
        ) {
            scene.background.contents = UIColor.clear
            scene.rootNode.addChildNode(surfaceRoot)
            scene.rootNode.addChildNode(bodyRoot)
            scene.rootNode.addChildNode(supportRoot)
            scene.rootNode.addChildNode(muscleRoot)
            scene.rootNode.addChildNode(markerRoot)

            configureLights()
            configureGround()

            let camera = SCNCamera()
            camera.fieldOfView = 42
            camera.zNear = 0.01
            camera.zFar = 20
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)

            view.scene = scene
            view.backgroundColor = .clear
            view.antialiasingMode = .multisampling4X
            view.preferredFramesPerSecond = 60
            view.rendersContinuously = false
            view.autoenablesDefaultLighting = false
            view.allowsCameraControl = true
            view.pointOfView = cameraNode
        }

        func update(
            view: SCNView,
            frame: BodyMovementFrame,
            viewpoint: BodySceneViewpoint,
            showSupport: Bool,
            showMuscles: Bool,
            isReference: Bool
        ) {
            if lastSessionID != frame.sessionID {
                jointNodes.values.forEach { $0.removeFromParentNode() }
                boneNodes.values.forEach { $0.removeFromParentNode() }
                surfaceNodes.values.forEach { $0.removeFromParentNode() }
                jointNodes.removeAll()
                boneNodes.removeAll()
                surfaceNodes.removeAll()
                lastSequence = nil
                lastSessionID = frame.sessionID
            }

            if lastSequence != frame.sequence
                || lastSequence == nil {
                updateBodySurface(
                    frame,
                    isReference: isReference
                )
                updateSkeleton(
                    frame,
                    isReference: isReference
                )
                updateMarkers(
                    frame,
                    showSupport: showSupport,
                    isReference: isReference
                )
                updateMuscles(
                    frame,
                    visible: showMuscles,
                    isReference: isReference
                )
                lastSequence = frame.sequence
            } else {
                supportRoot.isHidden = !showSupport
                muscleRoot.isHidden = !showMuscles
            }

            if lastViewpoint != viewpoint {
                positionCamera(
                    for: viewpoint,
                    frame: frame
                )
                lastViewpoint = viewpoint
            }

            view.allowsCameraControl = viewpoint == .orbit
            view.setNeedsDisplay()
        }

        private func configureLights() {
            let ambient = SCNNode()
            let ambientLight = SCNLight()
            ambientLight.type = .ambient
            ambientLight.intensity = 550
            ambientLight.color = UIColor(
                white: 0.86,
                alpha: 1
            )
            ambient.light = ambientLight
            scene.rootNode.addChildNode(ambient)

            let key = SCNNode()
            let keyLight = SCNLight()
            keyLight.type = .directional
            keyLight.intensity = 950
            keyLight.castsShadow = true
            keyLight.shadowRadius = 5
            keyLight.shadowColor = UIColor.black.withAlphaComponent(0.18)
            key.light = keyLight
            key.eulerAngles = SCNVector3(
                -.pi / 4,
                .pi / 4,
                0
            )
            scene.rootNode.addChildNode(key)

            let fill = SCNNode()
            let fillLight = SCNLight()
            fillLight.type = .omni
            fillLight.intensity = 420
            fillLight.color = UIColor.systemTeal.withAlphaComponent(0.65)
            fill.light = fillLight
            fill.position = SCNVector3(-1.5, 1.5, 2)
            scene.rootNode.addChildNode(fill)
        }

        private func configureGround() {
            let plane = SCNPlane(
                width: 3.8,
                height: 3.8
            )
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.secondarySystemFill
                .withAlphaComponent(0.18)
            material.isDoubleSided = true
            plane.materials = [material]

            groundNode.geometry = plane
            groundNode.name = "ground"
            groundNode.eulerAngles.x = -.pi / 2
            groundNode.position.y = -0.88
            scene.rootNode.addChildNode(groundNode)
        }

        private func updateBodySurface(
            _ frame: BodyMovementFrame,
            isReference: Bool
        ) {
            let map = frame.jointMap
            var present = Set<String>()

            SCNTransaction.begin()
            SCNTransaction.animationDuration = isReference ? 0 : 0.12

            for joint in frame.joints {
                guard let parentID = joint.parentID,
                      let parent = map[parentID],
                      let radius = surfaceRadius(
                        for: joint.id
                      )
                else {
                    continue
                }

                let id = "surface:\(parentID)->\(joint.id)"
                present.insert(id)

                let node: SCNNode
                if let existing = surfaceNodes[id] {
                    node = existing
                } else {
                    node = cylinderNode(
                        radius: radius,
                        color: .secondaryLabel,
                        opacity: isReference ? 0.09 : 0.15
                    )
                    node.name = id
                    surfaceNodes[id] = node
                    surfaceRoot.addChildNode(node)
                }

                node.isHidden = false
                positionCylinder(
                    node,
                    from: parent.position,
                    to: joint.position
                )
            }

            if let head = frame.joints.first(where: {
                normalize($0.id).contains("head")
            }) {
                let id = "surface:head"
                present.insert(id)

                let node: SCNNode
                if let existing = surfaceNodes[id] {
                    node = existing
                } else {
                    node = sphere(
                        radius: 0.095,
                        color: .secondaryLabel,
                        opacity: isReference ? 0.10 : 0.16
                    )
                    node.name = id
                    surfaceNodes[id] = node
                    surfaceRoot.addChildNode(node)
                }

                node.isHidden = false
                node.simdPosition = vector(head.position)
            }

            if let pelvis = frame.pelvisReference?.position {
                let id = "surface:pelvis"
                present.insert(id)

                let node: SCNNode
                if let existing = surfaceNodes[id] {
                    node = existing
                } else {
                    let geometry = SCNSphere(radius: 0.115)
                    geometry.segmentCount = 20
                    geometry.materials = [
                        material(
                            color: .secondaryLabel,
                            opacity: isReference ? 0.08 : 0.13
                        )
                    ]
                    node = SCNNode(geometry: geometry)
                    node.scale = SCNVector3(1.25, 0.75, 0.82)
                    node.name = id
                    surfaceNodes[id] = node
                    surfaceRoot.addChildNode(node)
                }

                node.isHidden = false
                node.simdPosition = vector(pelvis)
            }

            for (id, node) in surfaceNodes {
                node.isHidden = !present.contains(id)
            }

            SCNTransaction.commit()
        }

        private func surfaceRadius(
            for jointID: String
        ) -> CGFloat? {
            let id = normalize(jointID)

            if id.contains("head") {
                return nil
            }
            if id.contains("centershoulder")
                || id.contains("spine") {
                return 0.090
            }
            if id.contains("hip") {
                return 0.070
            }
            if id.contains("knee") {
                return 0.055
            }
            if id.contains("ankle")
                || id.contains("foot") {
                return 0.040
            }
            if id.contains("shoulder") {
                return 0.048
            }
            if id.contains("elbow") {
                return 0.038
            }
            if id.contains("wrist")
                || id.contains("hand") {
                return 0.028
            }

            return 0.042
        }

        private func updateSkeleton(
            _ frame: BodyMovementFrame,
            isReference: Bool
        ) {
            let map = frame.jointMap
            let presentIDs = Set(map.keys)

            for (id, node) in jointNodes {
                node.isHidden = !presentIDs.contains(id)
            }

            var presentBoneIDs = Set<String>()

            SCNTransaction.begin()
            SCNTransaction.animationDuration = isReference ? 0 : 0.12

            for joint in frame.joints {
                let node = jointNode(
                    for: joint.id,
                    isReference: isReference
                )
                node.isHidden = false
                node.simdPosition = vector(joint.position)

                guard let parentID = joint.parentID,
                      let parent = map[parentID]
                else {
                    continue
                }

                let boneID = "\(parentID)->\(joint.id)"
                presentBoneIDs.insert(boneID)
                let bone = boneNode(
                    for: boneID,
                    childID: joint.id,
                    isReference: isReference
                )
                bone.isHidden = false
                positionCylinder(
                    bone,
                    from: parent.position,
                    to: joint.position
                )
            }

            for (id, node) in boneNodes {
                node.isHidden = !presentBoneIDs.contains(id)
            }

            SCNTransaction.commit()
        }

        private func updateMarkers(
            _ frame: BodyMovementFrame,
            showSupport: Bool,
            isReference: Bool
        ) {
            markerRoot.childNodes.forEach {
                $0.removeFromParentNode()
            }
            supportRoot.childNodes.forEach {
                $0.removeFromParentNode()
            }
            supportRoot.isHidden = !showSupport

            let floorY = inferredFloorY(frame)
            groundNode.position.y = Float(floorY - 0.006)

            if let pelvis = frame.pelvisReference {
                let marker = sphere(
                    radius: 0.035,
                    color: .systemOrange,
                    opacity: isReference ? 0.55 : 0.92
                )
                marker.simdPosition = vector(pelvis.position)
                markerRoot.addChildNode(marker)

                if showSupport {
                    let projected = MotionVector3(
                        pelvis.position.x,
                        floorY + 0.008,
                        pelvis.position.z
                    )
                    let drop = cylinderNode(
                        radius: 0.004,
                        color: .systemOrange,
                        opacity: isReference ? 0.20 : 0.36
                    )
                    positionCylinder(
                        drop,
                        from: pelvis.position,
                        to: projected
                    )
                    markerRoot.addChildNode(drop)

                    let footprint = SCNCylinder(
                        radius: 0.045,
                        height: 0.006
                    )
                    let material = material(
                        color: .systemOrange,
                        opacity: isReference ? 0.18 : 0.34
                    )
                    footprint.materials = [material]
                    let node = SCNNode(geometry: footprint)
                    node.simdPosition = vector(projected)
                    markerRoot.addChildNode(node)
                }
            }

            if let center = frame.centerOfMass {
                let marker = sphere(
                    radius: 0.042,
                    color: .systemPink,
                    opacity: 0.95
                )
                marker.simdPosition = vector(center.position)
                markerRoot.addChildNode(marker)
            }

            guard showSupport,
                  frame.supportPoints.count >= 2
            else {
                return
            }

            let a = frame.supportPoints[0]
            let b = frame.supportPoints[1]

            for point in [a, b] {
                let foot = SCNCylinder(
                    radius: 0.055,
                    height: 0.009
                )
                foot.materials = [
                    material(
                        color: .systemGreen,
                        opacity: isReference ? 0.20 : 0.42
                    )
                ]
                let node = SCNNode(geometry: foot)
                node.simdPosition = SIMD3<Float>(
                    Float(point.x),
                    Float(floorY + 0.006),
                    Float(point.z)
                )
                supportRoot.addChildNode(node)
            }

            addSupportBase(
                a: a,
                b: b,
                floorY: floorY,
                isReference: isReference
            )
        }

        private func addSupportBase(
            a: MotionVector3,
            b: MotionVector3,
            floorY: Double,
            isReference: Bool
        ) {
            let dx = b.x - a.x
            let dz = b.z - a.z
            let distance = max(
                0.12,
                sqrt(dx * dx + dz * dz)
            )

            let box = SCNBox(
                width: CGFloat(distance + 0.16),
                height: 0.008,
                length: 0.20,
                chamferRadius: 0.025
            )
            box.materials = [
                material(
                    color: .systemGreen,
                    opacity: isReference ? 0.10 : 0.22
                )
            ]

            let node = SCNNode(geometry: box)
            node.position = SCNVector3(
                Float((a.x + b.x) / 2),
                Float(floorY + 0.003),
                Float((a.z + b.z) / 2)
            )
            node.eulerAngles.y = Float(
                atan2(dz, dx)
            )
            supportRoot.addChildNode(node)
        }

        private func updateMuscles(
            _ frame: BodyMovementFrame,
            visible: Bool,
            isReference: Bool
        ) {
            muscleRoot.childNodes.forEach {
                $0.removeFromParentNode()
            }
            muscleRoot.isHidden = !visible

            guard visible,
                  !isReference,
                  !frame.muscleActivations.isEmpty
            else {
                return
            }

            let map = frame.jointMap

            for activation in frame.muscleActivations {
                guard let pair = jointPair(
                    for: activation.region,
                    map: map
                )
                else {
                    continue
                }

                let radius =
                    0.021 + (0.018 * activation.intensity)
                let opacity =
                    0.12 + (0.55 * activation.intensity)
                let node = cylinderNode(
                    radius: CGFloat(radius),
                    color: .systemRed,
                    opacity: CGFloat(opacity)
                )
                positionCylinder(
                    node,
                    from: pair.0.position,
                    to: pair.1.position
                )
                muscleRoot.addChildNode(node)
            }
        }

        private func jointNode(
            for id: String,
            isReference: Bool
        ) -> SCNNode {
            if let existing = jointNodes[id] {
                return existing
            }

            let normalized = normalize(id)
            let radius: CGFloat =
                normalized.contains("head") ? 0.055 : 0.022
            let color = semanticColor(id)
            let node = sphere(
                radius: radius,
                color: color,
                opacity: isReference ? 0.44 : 0.95
            )
            node.name = id
            jointNodes[id] = node
            bodyRoot.addChildNode(node)
            return node
        }

        private func boneNode(
            for id: String,
            childID: String,
            isReference: Bool
        ) -> SCNNode {
            if let existing = boneNodes[id] {
                return existing
            }

            let node = cylinderNode(
                radius: 0.012,
                color: semanticColor(childID),
                opacity: isReference ? 0.32 : 0.80
            )
            node.name = id
            boneNodes[id] = node
            bodyRoot.addChildNode(node)
            return node
        }

        private func sphere(
            radius: CGFloat,
            color: UIColor,
            opacity: CGFloat
        ) -> SCNNode {
            let geometry = SCNSphere(radius: radius)
            geometry.segmentCount = 20
            geometry.materials = [
                material(
                    color: color,
                    opacity: opacity
                )
            ]
            return SCNNode(geometry: geometry)
        }

        private func cylinderNode(
            radius: CGFloat,
            color: UIColor,
            opacity: CGFloat
        ) -> SCNNode {
            let geometry = SCNCylinder(
                radius: radius,
                height: 0.1
            )
            geometry.radialSegmentCount = 14
            geometry.materials = [
                material(
                    color: color,
                    opacity: opacity
                )
            ]
            return SCNNode(geometry: geometry)
        }

        private func material(
            color: UIColor,
            opacity: CGFloat
        ) -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = color
            material.roughness.contents = 0.62
            material.metalness.contents = 0.03
            material.transparency = opacity
            material.isDoubleSided = true
            return material
        }

        private func positionCylinder(
            _ node: SCNNode,
            from a: MotionVector3,
            to b: MotionVector3
        ) {
            let start = vector(a)
            let end = vector(b)
            let direction = end - start
            let length = simd_length(direction)

            guard length > 0.0001 else {
                node.isHidden = true
                return
            }

            node.isHidden = false
            node.simdPosition = (start + end) / 2
            node.simdOrientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: simd_normalize(direction)
            )

            if let cylinder = node.geometry as? SCNCylinder {
                cylinder.height = CGFloat(length)
            }
        }

        private func positionCamera(
            for viewpoint: BodySceneViewpoint,
            frame: BodyMovementFrame
        ) {
            let bounds = bodyBounds(frame)
            let center = SIMD3<Float>(
                Float((bounds.min.x + bounds.max.x) / 2),
                Float((bounds.min.y + bounds.max.y) / 2),
                Float((bounds.min.z + bounds.max.z) / 2)
            )
            let xSpan = Float(bounds.max.x - bounds.min.x)
            let ySpan = Float(bounds.max.y - bounds.min.y)
            let zSpan = Float(bounds.max.z - bounds.min.z)
            let bodySpan = max(
                1.0,
                max(xSpan, max(ySpan, zSpan))
            )
            let heightHint = Float(frame.bodyHeightM ?? 0)
            let fitSpan = max(bodySpan, min(2.4, heightHint))
            let distance = max(
                2.25,
                fitSpan * 1.45
            )

            switch viewpoint {
            case .front:
                cameraNode.simdPosition = center
                    + SIMD3<Float>(0, 0.06, distance)
            case .side:
                cameraNode.simdPosition = center
                    + SIMD3<Float>(distance, 0.06, 0)
            case .orbit:
                cameraNode.simdPosition = center
                    + SIMD3<Float>(
                        distance * 0.72,
                        distance * 0.20,
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

        private func bodyBounds(
            _ frame: BodyMovementFrame
        ) -> (
            min: MotionVector3,
            max: MotionVector3
        ) {
            guard let first = frame.joints.first else {
                return (
                    MotionVector3(-0.5, -0.9, -0.5),
                    MotionVector3(0.5, 0.9, 0.5)
                )
            }

            var minX = first.position.x
            var minY = first.position.y
            var minZ = first.position.z
            var maxX = first.position.x
            var maxY = first.position.y
            var maxZ = first.position.z

            for joint in frame.joints.dropFirst() {
                minX = min(minX, joint.position.x)
                minY = min(minY, joint.position.y)
                minZ = min(minZ, joint.position.z)
                maxX = max(maxX, joint.position.x)
                maxY = max(maxY, joint.position.y)
                maxZ = max(maxZ, joint.position.z)
            }

            return (
                MotionVector3(minX, minY, minZ),
                MotionVector3(maxX, maxY, maxZ)
            )
        }

        private func inferredFloorY(
            _ frame: BodyMovementFrame
        ) -> Double {
            if let floor = frame.supportPoints
                .map(\.y)
                .min() {
                return floor
            }

            return frame.joints
                .map { $0.position.y }
                .min() ?? -0.88
        }

        private func jointPair(
            for region: MuscleRegion,
            map: [String: BodyJoint3D]
        ) -> (BodyJoint3D, BodyJoint3D)? {
            let aliases: ([String], [String])

            switch region {
            case .core:
                aliases = (
                    ["root", "pelvis", "hips"],
                    ["spine", "centerShoulder", "center_shoulder"]
                )
            case .leftShoulder:
                aliases = (
                    ["centerShoulder", "center_shoulder", "spine"],
                    ["leftShoulder", "left_shoulder"]
                )
            case .rightShoulder:
                aliases = (
                    ["centerShoulder", "center_shoulder", "spine"],
                    ["rightShoulder", "right_shoulder"]
                )
            case .leftUpperArm:
                aliases = (
                    ["leftShoulder", "left_shoulder"],
                    ["leftElbow", "left_elbow"]
                )
            case .rightUpperArm:
                aliases = (
                    ["rightShoulder", "right_shoulder"],
                    ["rightElbow", "right_elbow"]
                )
            case .leftForearm:
                aliases = (
                    ["leftElbow", "left_elbow"],
                    ["leftWrist", "left_wrist"]
                )
            case .rightForearm:
                aliases = (
                    ["rightElbow", "right_elbow"],
                    ["rightWrist", "right_wrist"]
                )
            case .leftGlute:
                aliases = (
                    ["root", "pelvis", "hips"],
                    ["leftHip", "left_hip"]
                )
            case .rightGlute:
                aliases = (
                    ["root", "pelvis", "hips"],
                    ["rightHip", "right_hip"]
                )
            case .leftThigh:
                aliases = (
                    ["leftHip", "left_hip"],
                    ["leftKnee", "left_knee"]
                )
            case .rightThigh:
                aliases = (
                    ["rightHip", "right_hip"],
                    ["rightKnee", "right_knee"]
                )
            case .leftCalf:
                aliases = (
                    ["leftKnee", "left_knee"],
                    ["leftAnkle", "left_ankle", "leftFoot", "left_foot"]
                )
            case .rightCalf:
                aliases = (
                    ["rightKnee", "right_knee"],
                    ["rightAnkle", "right_ankle", "rightFoot", "right_foot"]
                )
            }

            guard let a = findJoint(
                    aliases.0,
                    map: map
                  ),
                  let b = findJoint(
                    aliases.1,
                    map: map
                  )
            else {
                return nil
            }

            return (a, b)
        }

        private func findJoint(
            _ aliases: [String],
            map: [String: BodyJoint3D]
        ) -> BodyJoint3D? {
            for alias in aliases {
                if let exact = map[alias] {
                    return exact
                }

                let target = normalize(alias)
                if let match = map.values.first(where: {
                    normalize($0.id) == target
                }) {
                    return match
                }
            }
            return nil
        }

        private func semanticColor(
            _ jointID: String
        ) -> UIColor {
            let normalized = normalize(jointID)
            if normalized.contains("left") {
                return .systemTeal
            }
            if normalized.contains("right") {
                return .systemIndigo
            }
            return .label
        }

        private func normalize(
            _ value: String
        ) -> String {
            value
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
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
    }
}

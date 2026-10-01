import SceneKit
import SwiftUI
import UIKit

enum BodyInsightMode: String, CaseIterable, Identifiable {
    case movement = "Movement"
    case muscles = "Muscles"
    case balance = "Balance"
    case sources = "Sources"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .movement:
            "waveform.path.ecg"
        case .muscles:
            "figure.strengthtraining.traditional"
        case .balance:
            "scope"
        case .sources:
            "sensor.tag.radiowaves.forward"
        }
    }
}

struct BodyInsightSnapshot {
    struct MuscleGroupInsight: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let displayWeight: Double
        let regionKey: String
    }

    let run: ProductRunRecord?
    let motionIntensity: Double
    let rotationIntensity: Double
    let movementLabel: String
    let cameraEvidencePresent: Bool
    let externalVideoPresent: Bool
    let watchEvidencePresent: Bool
    let syncComplete: Bool
    let sourceCount: Int
    let expectedSourceCount: Int

    init(run: ProductRunRecord?) {
        self.run = run

        if let summary = run?.watchSummary {
            let acceleration = summary.motion.userAccelerationRMSG ?? 0
            let rotation = summary.motion.rotationRateRMSRadS ?? 0

            motionIntensity = Self.clamp(acceleration / 0.8)
            rotationIntensity = Self.clamp(rotation / 3.0)

            if acceleration < 0.12 {
                movementLabel = "Low wrist motion"
            } else if acceleration < 0.35 {
                movementLabel = "Moderate wrist motion"
            } else {
                movementLabel = "High wrist motion"
            }
        } else {
            motionIntensity = 0.18
            rotationIntensity = 0.15
            movementLabel = "Awaiting a sealed Watch session"
        }

        cameraEvidencePresent = run?.cameraVideoURL != nil
        externalVideoPresent = run?.externalVideoURL != nil
        watchEvidencePresent = run?.watchJournalURL != nil
        syncComplete = run?.syncComplete ?? false
        sourceCount = run?.sourceCount ?? 0
        expectedSourceCount = run?.expectedSourceCount ?? 3
    }

    var muscleGroups: [MuscleGroupInsight] {
        [
            .init(
                id: "core",
                title: "Core stabilizers",
                subtitle: "Task-model prior · not directly measured",
                displayWeight: 0.88,
                regionKey: "core"
            ),
            .init(
                id: "glutes",
                title: "Glutes",
                subtitle: "Task-model prior · not directly measured",
                displayWeight: 0.78,
                regionKey: "glutes"
            ),
            .init(
                id: "quads",
                title: "Quadriceps",
                subtitle: "Task-model prior · not directly measured",
                displayWeight: 0.68,
                regionKey: "quads"
            ),
            .init(
                id: "calves",
                title: "Calves",
                subtitle: "Task-model prior · not directly measured",
                displayWeight: 0.70,
                regionKey: "calves"
            ),
            .init(
                id: "shoulders",
                title: "Shoulders",
                subtitle: "Task-model prior · not directly measured",
                displayWeight: 0.38,
                regionKey: "shoulders"
            ),
            .init(
                id: "forearms",
                title: "Forearms",
                subtitle: "Task-model prior · not directly measured",
                displayWeight: 0.32,
                regionKey: "forearms"
            ),
        ]
    }

    var latestSessionLabel: String {
        guard let date = run?.startedAt ?? run?.sealedAt else {
            return "No sealed product session yet"
        }
        return "Latest sealed session · "
            + date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

struct BodyIntelligenceView: View {
    @EnvironmentObject private var library: ProductRunLibrary
    @State private var mode: BodyInsightMode = .movement

    private var latestRun: ProductRunRecord? {
        library.runs.first {
            $0.outcome == .completed
        } ?? library.runs.first
    }

    private var snapshot: BodyInsightSnapshot {
        BodyInsightSnapshot(run: latestRun)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                header
                bodyStage
                modeDetail
                provenanceCard
                productDirection
            }
            .motionOSPageWidth()
            .padding(.horizontal, MotionOSDesign.pageHorizontalPadding)
            .padding(.top, 10)
            .padding(.bottom, 36)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Body")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            library.refresh()
        }
        .refreshable {
            library.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Body Intelligence")
                        .font(.largeTitle.weight(.bold))
                    Text(
                        "A spatial view of what MotionOS observed, what its models "
                            + "estimate, and what still needs richer sensors."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                MotionOSStatusBadge(
                    title: snapshot.run == nil ? "PREVIEW" : "SESSION",
                    systemImage: snapshot.run == nil
                        ? "sparkles"
                        : "checkmark.seal.fill",
                    color: snapshot.run == nil ? .purple : .green
                )
            }

            Text(snapshot.latestSessionLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    private var bodyStage: some View {
        VStack(spacing: 14) {
            Picker("Body visualization mode", selection: $mode) {
                ForEach(BodyInsightMode.allCases) { item in
                    Label(item.rawValue, systemImage: item.systemImage)
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)

            ZStack(alignment: .topLeading) {
                BodySceneView(
                    mode: mode,
                    snapshot: snapshot
                )
                .frame(height: 430)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 20,
                        style: .continuous
                    )
                )
                .accessibilityLabel(
                    "Interactive three-dimensional MotionOS body model"
                )

                VStack(alignment: .leading, spacing: 6) {
                    sourceBadge(
                        "Observed",
                        systemImage: "applewatch",
                        color: .green
                    )
                    if mode == .muscles {
                        sourceBadge(
                            "Task model",
                            systemImage: "brain.head.profile",
                            color: .orange
                        )
                    }
                    if mode == .balance {
                        sourceBadge(
                            "Needs pose + pressure",
                            systemImage: "scope",
                            color: .yellow
                        )
                    }
                }
                .padding(12)
            }

            HStack(spacing: 8) {
                statTile(
                    title: "WATCH",
                    value: snapshot.watchEvidencePresent ? "Observed" : "Pending",
                    detail: snapshot.movementLabel,
                    accent: snapshot.watchEvidencePresent ? .green : .secondary
                )
                statTile(
                    title: "VISION",
                    value: snapshot.cameraEvidencePresent ? "Captured" : "Pending",
                    detail: snapshot.cameraEvidencePresent
                        ? "Pose derivation next"
                        : "Add iPhone video",
                    accent: snapshot.cameraEvidencePresent ? .cyan : .secondary
                )
                statTile(
                    title: "BALANCE",
                    value: "Not measured",
                    detail: "Pressure / validated COM",
                    accent: .yellow
                )
            }
        }
        .cardStyle(padding: 12)
    }

    @ViewBuilder
    private var modeDetail: some View {
        switch mode {
        case .movement:
            movementDetail
        case .muscles:
            musclesDetail
        case .balance:
            balanceDetail
        case .sources:
            sourcesDetail
        }
    }

    private var movementDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Observed movement",
                subtitle: "Watch-derived motion stays attached to the body region that actually produced it",
                systemImage: "waveform.path.ecg",
                accent: .green
            )

            HStack(spacing: 9) {
                insightMetric(
                    title: "Motion",
                    value: snapshot.movementLabel,
                    source: "Watch IMU",
                    color: .green
                )
                insightMetric(
                    title: "Rotation",
                    value: rotationLabel,
                    source: "Watch gyro",
                    color: .cyan
                )
            }

            Label {
                Text(
                    "The wrist is highlighted because that is the body region "
                        + "directly observed by the current wearable. MotionOS "
                        + "does not silently paint wrist motion onto the whole body."
                )
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var musclesDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Muscle involvement",
                subtitle: "Exercise-specific anatomy can be layered onto the same body model without pretending it came from the Watch",
                systemImage: "figure.strengthtraining.traditional",
                accent: .orange
            )

            ForEach(snapshot.muscleGroups) { group in
                HStack(spacing: 10) {
                    Circle()
                        .fill(
                            Color.orange.opacity(
                                0.22 + (0.58 * group.displayWeight)
                            )
                        )
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                        Text(group.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Text(involvementLabel(group.displayWeight))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            Label {
                Text(
                    "For production, this layer should graduate from a task prior "
                        + "to a model estimated from 3D pose + personalized anatomy, "
                        + "with optional EMG for direct muscle-activity calibration."
                )
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var balanceDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Balance model",
                subtitle: "Keep center-of-mass, center-of-pressure, and support geometry separate",
                systemImage: "scope",
                accent: .yellow
            )

            balanceRow(
                title: "Body pose / COM proxy",
                value: snapshot.cameraEvidencePresent
                    ? "Video captured · derivation pending"
                    : "Needs calibrated video",
                symbol: "video.fill",
                color: snapshot.cameraEvidencePresent ? .cyan : .secondary
            )
            balanceRow(
                title: "Center of pressure",
                value: "Needs bilateral pressure insoles or force plate",
                symbol: "shoeprints.fill",
                color: .secondary
            )
            balanceRow(
                title: "Board pose",
                value: snapshot.externalVideoPresent
                    ? "Multiview evidence present"
                    : "Camera markers / equipment IMU",
                symbol: "rectangle.split.3x1",
                color: snapshot.externalVideoPresent ? .green : .secondary
            )

            Text(
                "The reticle under the avatar is a spatial reference, not a "
                    + "measured pressure point. Once pressure and pose streams are "
                    + "qualified, the same scene can animate COP, COM projection, "
                    + "support polygon, sway path, and recovery events."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private var sourcesDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Evidence coverage",
                subtitle: "Every body overlay should reveal exactly which sensors support it",
                systemImage: "point.3.connected.trianglepath.dotted",
                accent: .purple
            )

            HStack(spacing: 8) {
                evidenceTile(
                    "Watch",
                    present: snapshot.watchEvidencePresent,
                    symbol: "applewatch"
                )
                evidenceTile(
                    "iPhone",
                    present: snapshot.cameraEvidencePresent,
                    symbol: "iphone"
                )
                evidenceTile(
                    "Action 4",
                    present: snapshot.externalVideoPresent,
                    symbol: "video.fill"
                )
                evidenceTile(
                    "Sync",
                    present: snapshot.syncComplete,
                    symbol: "waveform.path"
                )
            }

            ProgressView(
                value: Double(snapshot.sourceCount),
                total: Double(max(1, snapshot.expectedSourceCount))
            )
            .tint(.purple)

            Text(
                "\(snapshot.sourceCount) of \(snapshot.expectedSourceCount) expected evidence sources "
                    + "are attached to the latest product run."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var provenanceCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            MotionOSSectionHeader(
                title: "Three truth levels",
                subtitle: "A visual language that scales from prototype to research-grade interpretation",
                systemImage: "checkmark.seal.fill",
                accent: .indigo
            )

            truthRow(
                title: "Observed",
                detail: "Directly supported by a captured sensor stream",
                color: .green,
                symbol: "dot.radiowaves.left.and.right"
            )
            truthRow(
                title: "Model-estimated",
                detail: "Derived from calibrated pose, anatomy, biomechanics, or learned models",
                color: .orange,
                symbol: "brain.head.profile"
            )
            truthRow(
                title: "Unavailable",
                detail: "The product tells the user what additional evidence is required",
                color: .secondary,
                symbol: "circle.dashed"
            )
        }
        .cardStyle()
    }

    private var productDirection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "From dashboard to movement twin",
                systemImage: "cube.transparent"
            )
            .font(.headline)

            Text(
                "This is the product shape I would build toward: each person gets "
                    + "a persistent movement twin. Every sport, exercise, rehab "
                    + "protocol, and equipment session updates the same body model, "
                    + "while sport-specific lenses decide which features matter."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            FlowLayout(spacing: 7) {
                capabilityChip("3D pose", "figure.walk.motion")
                capabilityChip("Muscle model", "figure.strengthtraining.traditional")
                capabilityChip("Balance", "scope")
                capabilityChip("Asymmetry", "arrow.left.and.right")
                capabilityChip("Equipment", "sensor.tag.radiowaves.forward")
                capabilityChip("Recovery", "heart.text.square")
            }
        }
        .cardStyle()
    }

    private var rotationLabel: String {
        if snapshot.rotationIntensity < 0.25 {
            return "Low angular motion"
        }
        if snapshot.rotationIntensity < 0.60 {
            return "Moderate angular motion"
        }
        return "High angular motion"
    }

    private func sourceBadge(
        _ title: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                .ultraThinMaterial,
                in: Capsule()
            )
    }

    private func statTile(
        title: String,
        value: String,
        detail: String,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private func insightMetric(
        title: String,
        value: String,
        source: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Text(source)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            color.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private func involvementLabel(_ weight: Double) -> String {
        if weight >= 0.78 { return "Primary prior" }
        if weight >= 0.60 { return "Stabilizing prior" }
        return "Supporting prior"
    }

    private func balanceRow(
        title: String,
        value: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private func evidenceTile(
        _ title: String,
        present: Bool,
        symbol: String
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: present ? symbol : "circle.dashed")
                .font(.title3)
                .foregroundStyle(present ? .green : .secondary)
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            (present ? Color.green : Color.primary).opacity(0.05),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
    }

    private func truthRow(
        title: String,
        detail: String,
        color: Color,
        symbol: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private func capabilityChip(
        _ title: String,
        _ symbol: String
    ) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Color.primary.opacity(0.045),
                in: Capsule()
            )
    }
}

private struct BodySceneView: UIViewRepresentable {
    let mode: BodyInsightMode
    let snapshot: BodyInsightSnapshot

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        configure(view)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        configure(uiView)
    }

    private func configure(_ view: SCNView) {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        let rig = BodySceneFactory.build(
            mode: mode,
            snapshot: snapshot
        )
        scene.rootNode.addChildNode(rig)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 38
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = 100
        cameraNode.position = SCNVector3(0, 0.1, 7.7)
        cameraNode.look(at: SCNVector3(0, 0.1, 0))
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 980
        key.light?.temperature = 5_400
        key.position = SCNVector3(-3.2, 4.2, 4.4)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .omni
        fill.light?.intensity = 620
        fill.light?.temperature = 7_200
        fill.position = SCNVector3(3.4, 1.8, 2.4)
        scene.rootNode.addChildNode(fill)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .omni
        rim.light?.intensity = 520
        rim.position = SCNVector3(0, 2.4, -3.2)
        scene.rootNode.addChildNode(rim)

        scene.rootNode.addChildNode(BodySceneFactory.floorNode())
        view.scene = scene
        view.pointOfView = cameraNode
    }
}

private enum BodySceneFactory {
    static func build(
        mode: BodyInsightMode,
        snapshot: BodyInsightSnapshot
    ) -> SCNNode {
        let root = SCNNode()
        root.position = SCNVector3(0, -0.25, 0)

        let neutral = UIColor(
            red: 0.72,
            green: 0.76,
            blue: 0.82,
            alpha: 1
        )
        let joint = UIColor(
            red: 0.60,
            green: 0.66,
            blue: 0.75,
            alpha: 1
        )
        let observed = UIColor.systemGreen
        let model = UIColor.systemOrange
        let pending = UIColor.systemYellow

        root.addChildNode(
            capsule(
                name: "torso",
                radius: 0.56,
                height: 1.65,
                position: SCNVector3(0, 1.25, 0),
                color: mode == .muscles
                    ? mix(neutral, model, 0.20)
                    : neutral
            )
        )
        root.addChildNode(
            sphere(
                name: "head",
                radius: 0.37,
                position: SCNVector3(0, 2.62, 0),
                color: neutral
            )
        )
        root.addChildNode(
            capsule(
                name: "pelvis",
                radius: 0.46,
                height: 0.66,
                position: SCNVector3(0, 0.32, 0),
                color: mode == .muscles
                    ? mix(neutral, model, 0.42)
                    : neutral
            )
        )

        let leftShoulder = SCNVector3(-0.56, 1.88, 0)
        let rightShoulder = SCNVector3(0.56, 1.88, 0)
        let leftElbow = SCNVector3(-0.88, 1.12, 0.05)
        let rightElbow = SCNVector3(0.88, 1.12, 0.05)
        let leftWrist = SCNVector3(-0.92, 0.38, 0.10)
        let rightWrist = SCNVector3(0.92, 0.38, 0.10)

        let leftHip = SCNVector3(-0.28, 0.18, 0)
        let rightHip = SCNVector3(0.28, 0.18, 0)
        let leftKnee = SCNVector3(-0.34, -1.00, 0.05)
        let rightKnee = SCNVector3(0.34, -1.00, 0.05)
        let leftAnkle = SCNVector3(-0.38, -2.08, 0.08)
        let rightAnkle = SCNVector3(0.38, -2.08, 0.08)

        addLimb(
            root,
            name: "left-upper-arm",
            from: leftShoulder,
            to: leftElbow,
            radius: 0.16,
            color: mode == .muscles
                ? mix(neutral, model, 0.28)
                : neutral
        )
        addLimb(
            root,
            name: "right-upper-arm",
            from: rightShoulder,
            to: rightElbow,
            radius: 0.16,
            color: mode == .muscles
                ? mix(neutral, model, 0.30)
                : neutral
        )
        addLimb(
            root,
            name: "left-forearm",
            from: leftElbow,
            to: leftWrist,
            radius: 0.13,
            color: mode == .muscles
                ? mix(neutral, model, 0.32)
                : neutral
        )
        addLimb(
            root,
            name: "right-forearm",
            from: rightElbow,
            to: rightWrist,
            radius: 0.13,
            color: mode == .movement
                ? snapshot.watchEvidencePresent
                    ? mix(neutral, observed, 0.45 + 0.45 * snapshot.motionIntensity)
                    : mix(neutral, pending, 0.18)
                : mode == .muscles
                    ? mix(neutral, model, 0.34)
                    : neutral
        )

        addLimb(
            root,
            name: "left-thigh",
            from: leftHip,
            to: leftKnee,
            radius: 0.22,
            color: mode == .muscles
                ? mix(neutral, model, 0.70)
                : neutral
        )
        addLimb(
            root,
            name: "right-thigh",
            from: rightHip,
            to: rightKnee,
            radius: 0.22,
            color: mode == .muscles
                ? mix(neutral, model, 0.70)
                : neutral
        )
        addLimb(
            root,
            name: "left-calf",
            from: leftKnee,
            to: leftAnkle,
            radius: 0.17,
            color: mode == .muscles
                ? mix(neutral, model, 0.64)
                : neutral
        )
        addLimb(
            root,
            name: "right-calf",
            from: rightKnee,
            to: rightAnkle,
            radius: 0.17,
            color: mode == .muscles
                ? mix(neutral, model, 0.64)
                : neutral
        )

        for (index, point) in [
            leftShoulder,
            rightShoulder,
            leftElbow,
            rightElbow,
            leftHip,
            rightHip,
            leftKnee,
            rightKnee,
        ].enumerated() {
            root.addChildNode(
                sphere(
                    name: "joint-\(index)",
                    radius: 0.12,
                    position: point,
                    color: joint
                )
            )
        }

        root.addChildNode(
            sphere(
                name: "watch",
                radius: 0.15,
                position: rightWrist,
                color: mode == .movement
                    ? snapshot.watchEvidencePresent ? observed : pending
                    : joint
            )
        )

        addFoot(
            root,
            name: "left-foot",
            at: leftAnkle,
            color: mode == .balance ? pending : neutral
        )
        addFoot(
            root,
            name: "right-foot",
            at: rightAnkle,
            color: mode == .balance ? pending : neutral
        )

        if mode == .balance {
            root.addChildNode(balanceReticle())
        }

        if mode == .sources {
            addSourceRings(root, snapshot: snapshot)
        }

        return root
    }

    static func floorNode() -> SCNNode {
        let plane = SCNPlane(width: 5.5, height: 5.5)
        plane.cornerRadius = 0.22
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(
            white: 0.50,
            alpha: 0.055
        )
        material.isDoubleSided = true
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.position = SCNVector3(0, -2.47, 0)
        return node
    }

    private static func addLimb(
        _ root: SCNNode,
        name: String,
        from: SCNVector3,
        to: SCNVector3,
        radius: CGFloat,
        color: UIColor
    ) {
        root.addChildNode(
            cylinderBetween(
                name: name,
                from: from,
                to: to,
                radius: radius,
                color: color
            )
        )
    }

    private static func addFoot(
        _ root: SCNNode,
        name: String,
        at ankle: SCNVector3,
        color: UIColor
    ) {
        let box = SCNBox(
            width: 0.34,
            height: 0.18,
            length: 0.70,
            chamferRadius: 0.11
        )
        box.materials = [material(color)]
        let node = SCNNode(geometry: box)
        node.name = name
        node.position = SCNVector3(
            ankle.x,
            ankle.y - 0.17,
            ankle.z + 0.19
        )
        root.addChildNode(node)
    }

    private static func balanceReticle() -> SCNNode {
        let root = SCNNode()
        root.name = "balance-reticle"
        root.position = SCNVector3(0, -2.35, 0.08)

        let rings: [(CGFloat, UIColor)] = [
            (0.44, UIColor.systemYellow.withAlphaComponent(0.28)),
            (0.78, UIColor.systemYellow.withAlphaComponent(0.15)),
            (1.18, UIColor.systemYellow.withAlphaComponent(0.08)),
        ]

        for (radius, color) in rings {
            let torus = SCNTorus(
                ringRadius: radius,
                pipeRadius: 0.012
            )
            torus.materials = [material(color)]
            let node = SCNNode(geometry: torus)
            node.eulerAngles.x = .pi / 2
            root.addChildNode(node)
        }

        let center = SCNSphere(radius: 0.07)
        center.materials = [
            material(
                UIColor.systemYellow.withAlphaComponent(0.80)
            )
        ]
        let centerNode = SCNNode(geometry: center)
        root.addChildNode(centerNode)

        return root
    }

    private static func addSourceRings(
        _ root: SCNNode,
        snapshot: BodyInsightSnapshot
    ) {
        let values: [(Float, Bool, UIColor)] = [
            (2.08, snapshot.watchEvidencePresent, .systemGreen),
            (2.28, snapshot.cameraEvidencePresent, .systemCyan),
            (2.48, snapshot.externalVideoPresent, .systemPurple),
        ]

        for (y, present, color) in values {
            let torus = SCNTorus(
                ringRadius: 0.78,
                pipeRadius: 0.018
            )
            torus.materials = [
                material(
                    color.withAlphaComponent(present ? 0.72 : 0.12)
                )
            ]
            let node = SCNNode(geometry: torus)
            node.position = SCNVector3(0, y, 0)
            node.eulerAngles.x = .pi / 2
            root.addChildNode(node)
        }
    }

    private static func capsule(
        name: String,
        radius: CGFloat,
        height: CGFloat,
        position: SCNVector3,
        color: UIColor
    ) -> SCNNode {
        let geometry = SCNCapsule(
            capRadius: radius,
            height: height
        )
        geometry.materials = [material(color)]
        let node = SCNNode(geometry: geometry)
        node.name = name
        node.position = position
        return node
    }

    private static func sphere(
        name: String,
        radius: CGFloat,
        position: SCNVector3,
        color: UIColor
    ) -> SCNNode {
        let geometry = SCNSphere(radius: radius)
        geometry.segmentCount = 40
        geometry.materials = [material(color)]
        let node = SCNNode(geometry: geometry)
        node.name = name
        node.position = position
        return node
    }

    private static func cylinderBetween(
        name: String,
        from: SCNVector3,
        to: SCNVector3,
        radius: CGFloat,
        color: UIColor
    ) -> SCNNode {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let dz = to.z - from.z
        let length = sqrt(dx * dx + dy * dy + dz * dz)

        let cylinder = SCNCylinder(
            radius: radius,
            height: CGFloat(length)
        )
        cylinder.radialSegmentCount = 28
        cylinder.materials = [material(color)]

        let node = SCNNode(geometry: cylinder)
        node.name = name
        node.position = SCNVector3(
            (from.x + to.x) / 2,
            (from.y + to.y) / 2,
            (from.z + to.z) / 2
        )

        node.look(
            at: to,
            up: SCNVector3(0, 1, 0),
            localFront: SCNVector3(0, 1, 0)
        )

        return node
    }

    private static func material(
        _ color: UIColor
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.metalness.contents = 0.18
        material.roughness.contents = 0.47
        return material
    }

    private static func mix(
        _ a: UIColor,
        _ b: UIColor,
        _ amount: Double
    ) -> UIColor {
        let t = CGFloat(min(1, max(0, amount)))
        var ar: CGFloat = 0
        var ag: CGFloat = 0
        var ab: CGFloat = 0
        var aa: CGFloat = 0
        var br: CGFloat = 0
        var bg: CGFloat = 0
        var bb: CGFloat = 0
        var ba: CGFloat = 0

        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)

        return UIColor(
            red: ar + (br - ar) * t,
            green: ag + (bg - ag) * t,
            blue: ab + (bb - ab) * t,
            alpha: aa + (ba - aa) * t
        )
    }
}

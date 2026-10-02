import Foundation

public enum MovementEstimateProvenance: String, Codable, Sendable, Equatable {
    case measured
    case geometricProxy = "geometric_proxy"
    case modelEstimated = "model_estimated"
}

public struct MovementEstimate3D: Codable, Sendable, Equatable {
    public let position: MotionVector3
    public let provenance: MovementEstimateProvenance
    public let label: String

    public init(
        position: MotionVector3,
        provenance: MovementEstimateProvenance,
        label: String
    ) {
        self.position = position
        self.provenance = provenance
        self.label = label
    }
}

public struct BodyJoint3D: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let parentID: String?
    public let position: MotionVector3

    public init(
        id: String,
        parentID: String?,
        position: MotionVector3
    ) {
        self.id = id
        self.parentID = parentID
        self.position = position
    }
}

public struct BodyJoint2D: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let x: Double
    public let y: Double
    public let confidence: Double

    public init(
        id: String,
        x: Double,
        y: Double,
        confidence: Double
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.confidence = min(1, max(0, confidence))
    }
}

public struct NormalizedImageBounds: Codable, Sendable, Equatable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double

    public init(
        minX: Double,
        minY: Double,
        maxX: Double,
        maxY: Double
    ) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var width: Double { max(0, maxX - minX) }
    public var height: Double { max(0, maxY - minY) }
    public var centerX: Double { (minX + maxX) / 2 }
    public var centerY: Double { (minY + maxY) / 2 }
}

public struct BodyImageFraming: Codable, Sendable, Equatable {
    public let bounds: NormalizedImageBounds
    public let visibleJointCount: Int
    public let meanConfidence: Double
    public let visibleJointIDs: [String]
    public let coordinateFrame: String

    public init(
        bounds: NormalizedImageBounds,
        visibleJointCount: Int,
        meanConfidence: Double,
        visibleJointIDs: [String],
        coordinateFrame: String
    ) {
        self.bounds = bounds
        self.visibleJointCount = visibleJointCount
        self.meanConfidence = min(1, max(0, meanConfidence))
        self.visibleJointIDs = visibleJointIDs.sorted()
        self.coordinateFrame = coordinateFrame
    }
}

public enum MuscleRegion: String, Codable, CaseIterable, Sendable {
    case core
    case leftShoulder = "left_shoulder"
    case rightShoulder = "right_shoulder"
    case leftUpperArm = "left_upper_arm"
    case rightUpperArm = "right_upper_arm"
    case leftForearm = "left_forearm"
    case rightForearm = "right_forearm"
    case leftGlute = "left_glute"
    case rightGlute = "right_glute"
    case leftThigh = "left_thigh"
    case rightThigh = "right_thigh"
    case leftCalf = "left_calf"
    case rightCalf = "right_calf"
}

public struct MuscleActivationEstimate: Codable, Sendable, Equatable, Identifiable {
    public let region: MuscleRegion
    public let intensity: Double
    public let provenance: MovementEstimateProvenance
    public let modelID: String?

    public var id: String { region.rawValue }

    public init(
        region: MuscleRegion,
        intensity: Double,
        provenance: MovementEstimateProvenance,
        modelID: String? = nil
    ) {
        self.region = region
        self.intensity = min(1, max(0, intensity))
        self.provenance = provenance
        self.modelID = modelID
    }
}

public struct BodyMovementFrame: Codable, Sendable, Equatable {
    public static let schemaVersion = "motionos.body-frame.v1"

    public let schemaVersion: String
    public let sessionID: String
    public let sequence: UInt64
    public let deviceTimeNS: UInt64
    public let source: String
    public let coordinateFrame: String
    public let bodyHeightM: Double?
    public let joints: [BodyJoint3D]
    public let pelvisReference: MovementEstimate3D?
    public let centerOfMass: MovementEstimate3D?
    public let supportPoints: [MotionVector3]
    public let muscleActivations: [MuscleActivationEstimate]
    public let imageFraming: BodyImageFraming?
    public let imageJoints: [BodyJoint2D]?

    public init(
        schemaVersion: String = BodyMovementFrame.schemaVersion,
        sessionID: String,
        sequence: UInt64,
        deviceTimeNS: UInt64,
        source: String,
        coordinateFrame: String,
        bodyHeightM: Double?,
        joints: [BodyJoint3D],
        pelvisReference: MovementEstimate3D? = nil,
        centerOfMass: MovementEstimate3D? = nil,
        supportPoints: [MotionVector3] = [],
        muscleActivations: [MuscleActivationEstimate] = [],
        imageFraming: BodyImageFraming? = nil,
        imageJoints: [BodyJoint2D]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.sequence = sequence
        self.deviceTimeNS = deviceTimeNS
        self.source = source
        self.coordinateFrame = coordinateFrame
        self.bodyHeightM = bodyHeightM
        self.joints = joints
        self.pelvisReference = pelvisReference
        self.centerOfMass = centerOfMass
        self.supportPoints = supportPoints
        self.muscleActivations = muscleActivations
        self.imageFraming = imageFraming
        self.imageJoints = imageJoints
    }

    public var jointMap: [String: BodyJoint3D] {
        Dictionary(uniqueKeysWithValues: joints.map { ($0.id, $0) })
    }

    public var imageJointMap: [String: BodyJoint2D] {
        Dictionary(
            uniqueKeysWithValues: (imageJoints ?? []).map {
                ($0.id, $0)
            }
        )
    }

    public var hasModelEstimatedMuscleActivity: Bool {
        !muscleActivations.isEmpty
    }
}

public enum BodyMovementFrameParser {
    public static func parseVisionPose(
        payload: [String: JSONValue],
        sessionID: String,
        sequence: UInt64,
        deviceTimeNS: UInt64
    ) -> BodyMovementFrame? {
        guard case .object(let jointObject) =
                payload["joints_root_relative_m"],
              case .object(let parentObject) =
                payload["joint_parents"]
        else {
            return nil
        }

        var joints: [BodyJoint3D] = []
        joints.reserveCapacity(jointObject.count)

        for (jointID, value) in jointObject {
            guard let position = vector(value) else {
                continue
            }

            let parentID: String?
            if let rawParent = parentObject[jointID] {
                switch rawParent {
                case .string(let value):
                    parentID = value
                case .null:
                    parentID = nil
                default:
                    parentID = nil
                }
            } else {
                parentID = nil
            }

            joints.append(
                BodyJoint3D(
                    id: jointID,
                    parentID: parentID,
                    position: position
                )
            )
        }

        guard joints.count >= 6 else {
            return nil
        }

        joints.sort { $0.id < $1.id }
        let jointMap = Dictionary(
            uniqueKeysWithValues: joints.map { ($0.id, $0) }
        )

        let pelvis = pelvisReference(in: jointMap)
        let support = supportPoints(in: jointMap)

        let bodyHeight: Double?
        if case .number(let value) = payload["body_height_m"],
           value.isFinite,
           value > 0 {
            bodyHeight = value
        } else {
            bodyHeight = nil
        }

        let coordinateFrame: String
        if case .string(let value) = payload["joint_coordinate_frame"] {
            coordinateFrame = value
        } else {
            coordinateFrame = "vision_root_joint_relative_meters"
        }

        let source: String
        if case .string(let value) = payload["source"] {
            source = value
        } else {
            source = "vision_3d_pose_from_camera_frame"
        }

        return BodyMovementFrame(
            sessionID: sessionID,
            sequence: sequence,
            deviceTimeNS: deviceTimeNS,
            source: source,
            coordinateFrame: coordinateFrame,
            bodyHeightM: bodyHeight,
            joints: joints,
            pelvisReference: pelvis.map {
                MovementEstimate3D(
                    position: $0,
                    provenance: .geometricProxy,
                    label: "Pelvis reference · not center of mass"
                )
            },
            centerOfMass: parseCenterOfMass(payload),
            supportPoints: support,
            muscleActivations: parseMuscleActivations(payload),
            imageFraming: parseImageFraming(payload),
            imageJoints: parseImageJoints(payload)
        )
    }

    private static func vector(
        _ value: JSONValue
    ) -> MotionVector3? {
        guard case .array(let values) = value,
              values.count == 3
        else {
            return nil
        }

        var numbers: [Double] = []
        numbers.reserveCapacity(3)
        for value in values {
            guard case .number(let number) = value,
                  number.isFinite
            else {
                return nil
            }
            numbers.append(number)
        }

        return MotionVector3(numbers[0], numbers[1], numbers[2])
    }

    private static func pelvisReference(
        in joints: [String: BodyJoint3D]
    ) -> MotionVector3? {
        if let root = findJoint(
            aliases: ["root", "pelvis", "hips"],
            in: joints
        ) {
            return root.position
        }

        guard let left = findJoint(
                aliases: ["leftHip", "left_hip"],
                in: joints
              ),
              let right = findJoint(
                aliases: ["rightHip", "right_hip"],
                in: joints
              )
        else {
            return nil
        }

        return midpoint(left.position, right.position)
    }

    private static func supportPoints(
        in joints: [String: BodyJoint3D]
    ) -> [MotionVector3] {
        let aliases: [[String]] = [
            ["leftFoot", "left_foot", "leftAnkle", "left_ankle"],
            ["rightFoot", "right_foot", "rightAnkle", "right_ankle"],
        ]

        return aliases.compactMap { names in
            findJoint(aliases: names, in: joints)?.position
        }
    }

    private static func parseImageJoints(
        _ payload: [String: JSONValue]
    ) -> [BodyJoint2D]? {
        guard case .object(let object) =
                payload["body_pose_2d_joints"]
        else {
            return nil
        }

        let joints = object.compactMap { id, value -> BodyJoint2D? in
            guard case .array(let values) = value,
                  values.count >= 2,
                  case .number(let x) = values[0],
                  case .number(let y) = values[1],
                  x.isFinite,
                  y.isFinite
            else {
                return nil
            }

            let confidence: Double
            if values.count >= 3,
               case .number(let value) = values[2],
               value.isFinite {
                confidence = value
            } else {
                confidence = 1
            }

            guard confidence >= 0.25 else {
                return nil
            }

            return BodyJoint2D(
                id: id,
                x: x,
                y: y,
                confidence: confidence
            )
        }
        .sorted { $0.id < $1.id }

        return joints.isEmpty ? nil : joints
    }

    private static func parseImageFraming(
        _ payload: [String: JSONValue]
    ) -> BodyImageFraming? {
        guard case .array(let values) =
                payload["body_bbox_image_normalized"],
              values.count == 4
        else {
            return nil
        }

        var numbers: [Double] = []
        numbers.reserveCapacity(4)
        for value in values {
            guard case .number(let number) = value,
                  number.isFinite
            else {
                return nil
            }
            numbers.append(number)
        }

        let count: Int
        if case .number(let value) =
            payload["body_pose_2d_joint_count"] {
            count = max(0, Int(value.rounded()))
        } else {
            count = 0
        }

        let confidence: Double
        if case .number(let value) =
            payload["body_pose_2d_mean_confidence"],
           value.isFinite {
            confidence = value
        } else {
            confidence = 0
        }

        let visibleJointIDs: [String]
        if case .object(let joints) = payload["body_pose_2d_joints"] {
            visibleJointIDs = joints.keys.sorted()
        } else {
            visibleJointIDs = []
        }

        let coordinateFrame: String
        if case .string(let value) =
            payload["body_pose_2d_coordinate_frame"] {
            coordinateFrame = value
        } else {
            coordinateFrame =
                "vision_normalized_image_bottom_left_origin"
        }

        return BodyImageFraming(
            bounds: NormalizedImageBounds(
                minX: numbers[0],
                minY: numbers[1],
                maxX: numbers[2],
                maxY: numbers[3]
            ),
            visibleJointCount: count,
            meanConfidence: confidence,
            visibleJointIDs: visibleJointIDs,
            coordinateFrame: coordinateFrame
        )
    }

    private static func parseCenterOfMass(
        _ payload: [String: JSONValue]
    ) -> MovementEstimate3D? {
        guard let value = payload["center_of_mass_root_relative_m"],
              let position = vector(value)
        else {
            return nil
        }

        let provenance: MovementEstimateProvenance
        if case .string(let raw) = payload["center_of_mass_provenance"],
           let parsed = MovementEstimateProvenance(rawValue: raw) {
            provenance = parsed
        } else {
            provenance = .modelEstimated
        }

        return MovementEstimate3D(
            position: position,
            provenance: provenance,
            label: provenance == .measured
                ? "Center of mass"
                : "Estimated center of mass"
        )
    }

    private static func parseMuscleActivations(
        _ payload: [String: JSONValue]
    ) -> [MuscleActivationEstimate] {
        guard case .object(let object) = payload["muscle_activation"] else {
            return []
        }

        let modelID: String?
        if case .string(let value) = payload["muscle_activation_model_id"] {
            modelID = value
        } else {
            modelID = nil
        }

        return object.compactMap { key, value in
            guard let region = MuscleRegion(rawValue: key),
                  case .number(let intensity) = value,
                  intensity.isFinite
            else {
                return nil
            }

            return MuscleActivationEstimate(
                region: region,
                intensity: intensity,
                provenance: .modelEstimated,
                modelID: modelID
            )
        }
        .sorted { $0.region.rawValue < $1.region.rawValue }
    }

    private static func findJoint(
        aliases: [String],
        in joints: [String: BodyJoint3D]
    ) -> BodyJoint3D? {
        for alias in aliases {
            if let exact = joints[alias] {
                return exact
            }

            let normalizedAlias = normalize(alias)
            if let match = joints.values.first(where: {
                normalize($0.id) == normalizedAlias
            }) {
                return match
            }
        }
        return nil
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func midpoint(
        _ lhs: MotionVector3,
        _ rhs: MotionVector3
    ) -> MotionVector3 {
        MotionVector3(
            (lhs.x + rhs.x) / 2,
            (lhs.y + rhs.y) / 2,
            (lhs.z + rhs.z) / 2
        )
    }
}

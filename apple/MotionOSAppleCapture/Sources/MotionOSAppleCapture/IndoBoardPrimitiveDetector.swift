import Foundation

public enum IndoBoardPrimitiveKind:
    String,
    Codable,
    CaseIterable,
    Sendable {
    case neutralStance = "neutral_stance"
    case lateralShiftLeft = "lateral_shift_left"
    case lateralShiftRight = "lateral_shift_right"
    case partialSquat = "partial_squat"
    case singleLegCandidate = "single_leg_candidate"
    case largeArmRecovery = "large_arm_recovery"
    case unknown
}

public struct IndoBoardPrimitiveObservation:
    Codable,
    Equatable,
    Sendable {
    public let kind: IndoBoardPrimitiveKind
    public let confidence: Double
    public let sequence: UInt64
    public let deviceTimeNS: UInt64
    public let protocolBlockID: String?
    public let pelvisOffsetFromNeutral: Double?
    public let kneeFlexionDeg: Double?
    public let ankleHeightDifferenceBodyRatio: Double?
    public let armExcursionBodyRatio: Double?
    public let rollerAlongDeck: Double?
    public let boardStateConfidence: Double?
    public let boardStateProvenance:
        IndoBoardEquipmentProvenance?
    public let evidenceLabel: String

    public init(
        kind: IndoBoardPrimitiveKind,
        confidence: Double,
        sequence: UInt64,
        deviceTimeNS: UInt64,
        protocolBlockID: String?,
        pelvisOffsetFromNeutral: Double?,
        kneeFlexionDeg: Double?,
        ankleHeightDifferenceBodyRatio: Double?,
        armExcursionBodyRatio: Double?,
        rollerAlongDeck: Double? = nil,
        boardStateConfidence: Double? = nil,
        boardStateProvenance:
            IndoBoardEquipmentProvenance? = nil,
        evidenceLabel: String
    ) {
        self.kind = kind
        self.confidence = min(1, max(0, confidence))
        self.sequence = sequence
        self.deviceTimeNS = deviceTimeNS
        self.protocolBlockID = protocolBlockID
        self.pelvisOffsetFromNeutral = pelvisOffsetFromNeutral
        self.kneeFlexionDeg = kneeFlexionDeg
        self.ankleHeightDifferenceBodyRatio =
            ankleHeightDifferenceBodyRatio
        self.armExcursionBodyRatio = armExcursionBodyRatio
        self.rollerAlongDeck = rollerAlongDeck
        self.boardStateConfidence = boardStateConfidence
        self.boardStateProvenance =
            boardStateProvenance
        self.evidenceLabel = evidenceLabel
    }
}

@MainActor
public final class IndoBoardPrimitiveDetector {
    private var neutralPelvisSamples: [Double] = []
    private var neutralKneeSamples: [Double] = []

    public init() {}

    public func reset() {
        neutralPelvisSamples.removeAll(keepingCapacity: true)
        neutralKneeSamples.removeAll(keepingCapacity: true)
    }

    public func ingest(
        frame: BodyMovementFrame,
        protocolBlockID: String?
    ) -> IndoBoardPrimitiveObservation {
        guard let framing = frame.imageFraming,
              let imageJoints = frame.imageJoints,
              framing.bounds.width > 0.05,
              framing.bounds.height > 0.10
        else {
            return observation(
                kind: .unknown,
                confidence: 0.15,
                frame: frame,
                blockID: protocolBlockID
            )
        }

        let joints = Dictionary(
            uniqueKeysWithValues: imageJoints.map {
                (Self.normalize($0.id), $0)
            }
        )

        let leftHip = joint(
            aliases: ["leftHip", "left_hip"],
            in: joints
        )
        let rightHip = joint(
            aliases: ["rightHip", "right_hip"],
            in: joints
        )
        let leftKnee = joint(
            aliases: ["leftKnee", "left_knee"],
            in: joints
        )
        let rightKnee = joint(
            aliases: ["rightKnee", "right_knee"],
            in: joints
        )
        let leftAnkle = joint(
            aliases: [
                "leftAnkle",
                "left_ankle",
                "leftFoot",
                "left_foot",
            ],
            in: joints
        )
        let rightAnkle = joint(
            aliases: [
                "rightAnkle",
                "right_ankle",
                "rightFoot",
                "right_foot",
            ],
            in: joints
        )
        let leftShoulder = joint(
            aliases: ["leftShoulder", "left_shoulder"],
            in: joints
        )
        let rightShoulder = joint(
            aliases: ["rightShoulder", "right_shoulder"],
            in: joints
        )
        let leftWrist = joint(
            aliases: ["leftWrist", "left_wrist"],
            in: joints
        )
        let rightWrist = joint(
            aliases: ["rightWrist", "right_wrist"],
            in: joints
        )

        let pelvis = midpoint(leftHip, rightHip)
        let shoulders = midpoint(leftShoulder, rightShoulder)

        let flexions = [
            kneeFlexion(
                hip: leftHip,
                knee: leftKnee,
                ankle: leftAnkle
            ),
            kneeFlexion(
                hip: rightHip,
                knee: rightKnee,
                ankle: rightAnkle
            ),
        ].compactMap { $0 }
        let kneeFlexion = flexions.isEmpty
            ? nil
            : flexions.reduce(0, +) / Double(flexions.count)

        let pelvisX = pelvis?.x
        if protocolBlockID == "neutral-settle" {
            if let pelvisX {
                appendBounded(
                    pelvisX,
                    to: &neutralPelvisSamples
                )
            }
            if let kneeFlexion {
                appendBounded(
                    kneeFlexion,
                    to: &neutralKneeSamples
                )
            }
        }

        let neutralPelvis = median(neutralPelvisSamples)
        let neutralKnee = median(neutralKneeSamples)
        let pelvisOffset: Double? = {
            guard let pelvisX,
                  let neutralPelvis
            else {
                return nil
            }
            return (pelvisX - neutralPelvis)
                / framing.bounds.width
        }()

        let ankleHeightDifference: Double? = {
            guard let leftAnkle,
                  let rightAnkle
            else {
                return nil
            }
            return abs(leftAnkle.y - rightAnkle.y)
                / framing.bounds.height
        }()

        let armExcursion: Double? = {
            guard let shoulders else {
                return nil
            }

            let wrists = [leftWrist, rightWrist]
                .compactMap { $0 }
            guard !wrists.isEmpty else {
                return nil
            }

            return wrists
                .map {
                    distance($0, shoulders)
                        / framing.bounds.height
                }
                .reduce(0, +)
                / Double(wrists.count)
        }()

        let baseConfidence = min(
            0.95,
            max(
                0.15,
                framing.meanConfidence
                    * min(
                        1,
                        Double(framing.visibleJointCount) / 12
                    )
            )
        )

        if let ankleHeightDifference,
           ankleHeightDifference >= 0.10 {
            return observation(
                kind: .singleLegCandidate,
                confidence: baseConfidence * 0.72,
                frame: frame,
                blockID: protocolBlockID,
                pelvisOffset: pelvisOffset,
                kneeFlexion: kneeFlexion,
                ankleHeightDifference:
                    ankleHeightDifference,
                armExcursion: armExcursion
            )
        }

        if let kneeFlexion,
           let neutralKnee,
           kneeFlexion >= neutralKnee + 12 {
            return observation(
                kind: .partialSquat,
                confidence: baseConfidence * 0.88,
                frame: frame,
                blockID: protocolBlockID,
                pelvisOffset: pelvisOffset,
                kneeFlexion: kneeFlexion,
                ankleHeightDifference:
                    ankleHeightDifference,
                armExcursion: armExcursion
            )
        }

        if let pelvisOffset,
           pelvisOffset <= -0.075 {
            return observation(
                kind: .lateralShiftLeft,
                confidence: baseConfidence * 0.82,
                frame: frame,
                blockID: protocolBlockID,
                pelvisOffset: pelvisOffset,
                kneeFlexion: kneeFlexion,
                ankleHeightDifference:
                    ankleHeightDifference,
                armExcursion: armExcursion
            )
        }

        if let pelvisOffset,
           pelvisOffset >= 0.075 {
            return observation(
                kind: .lateralShiftRight,
                confidence: baseConfidence * 0.82,
                frame: frame,
                blockID: protocolBlockID,
                pelvisOffset: pelvisOffset,
                kneeFlexion: kneeFlexion,
                ankleHeightDifference:
                    ankleHeightDifference,
                armExcursion: armExcursion
            )
        }

        if let armExcursion,
           armExcursion >= 0.55,
           protocolBlockID != "neutral-settle" {
            return observation(
                kind: .largeArmRecovery,
                confidence: baseConfidence * 0.60,
                frame: frame,
                blockID: protocolBlockID,
                pelvisOffset: pelvisOffset,
                kneeFlexion: kneeFlexion,
                ankleHeightDifference:
                    ankleHeightDifference,
                armExcursion: armExcursion
            )
        }

        if neutralPelvis != nil,
           abs(pelvisOffset ?? 0) < 0.05 {
            return observation(
                kind: .neutralStance,
                confidence: baseConfidence * 0.85,
                frame: frame,
                blockID: protocolBlockID,
                pelvisOffset: pelvisOffset,
                kneeFlexion: kneeFlexion,
                ankleHeightDifference:
                    ankleHeightDifference,
                armExcursion: armExcursion
            )
        }

        return observation(
            kind: .unknown,
            confidence: baseConfidence * 0.45,
            frame: frame,
            blockID: protocolBlockID,
            pelvisOffset: pelvisOffset,
            kneeFlexion: kneeFlexion,
            ankleHeightDifference:
                ankleHeightDifference,
            armExcursion: armExcursion
        )
    }

    private func observation(
        kind: IndoBoardPrimitiveKind,
        confidence: Double,
        frame: BodyMovementFrame,
        blockID: String?,
        pelvisOffset: Double? = nil,
        kneeFlexion: Double? = nil,
        ankleHeightDifference: Double? = nil,
        armExcursion: Double? = nil
    ) -> IndoBoardPrimitiveObservation {
        let boardState = frame.indoBoardBalanceState
        let boardQualified =
            (boardState?.confidence ?? 0) >= 0.35

        return IndoBoardPrimitiveObservation(
            kind: kind,
            confidence: boardQualified
                ? min(
                    0.98,
                    max(
                        confidence,
                        boardState?.confidence ?? confidence
                    )
                )
                : confidence,
            sequence: frame.sequence,
            deviceTimeNS: frame.deviceTimeNS,
            protocolBlockID: blockID,
            pelvisOffsetFromNeutral: pelvisOffset,
            kneeFlexionDeg: kneeFlexion,
            ankleHeightDifferenceBodyRatio:
                ankleHeightDifference,
            armExcursionBodyRatio: armExcursion,
            rollerAlongDeck:
                boardQualified
                    ? boardState?.rollerAlongDeck
                    : nil,
            boardStateConfidence:
                boardQualified
                    ? boardState?.confidence
                    : nil,
            boardStateProvenance:
                boardQualified
                    ? boardState?.provenance
                    : nil,
            evidenceLabel:
                boardQualified
                    ? "camera_body_pose_plus_deck_roller_geometry"
                    : "camera_body_pose_proxy_board_state_pending"
        )
    }

    private func appendBounded(
        _ value: Double,
        to values: inout [Double]
    ) {
        values.append(value)
        if values.count > 120 {
            values.removeFirst(values.count - 120)
        }
    }

    private func joint(
        aliases: [String],
        in joints: [String: BodyJoint2D]
    ) -> BodyJoint2D? {
        for alias in aliases {
            if let value = joints[Self.normalize(alias)] {
                return value
            }
        }
        return nil
    }

    private func midpoint(
        _ first: BodyJoint2D?,
        _ second: BodyJoint2D?
    ) -> BodyJoint2D? {
        guard let first,
              let second
        else {
            return nil
        }

        return BodyJoint2D(
            id: "midpoint",
            x: (first.x + second.x) / 2,
            y: (first.y + second.y) / 2,
            confidence: min(first.confidence, second.confidence)
        )
    }

    private func kneeFlexion(
        hip: BodyJoint2D?,
        knee: BodyJoint2D?,
        ankle: BodyJoint2D?
    ) -> Double? {
        guard let hip,
              let knee,
              let ankle
        else {
            return nil
        }

        let first = (x: hip.x - knee.x, y: hip.y - knee.y)
        let second = (x: ankle.x - knee.x, y: ankle.y - knee.y)
        let firstNorm = hypot(first.x, first.y)
        let secondNorm = hypot(second.x, second.y)
        guard firstNorm > 1e-9,
              secondNorm > 1e-9
        else {
            return nil
        }

        let cosine = min(
            1,
            max(
                -1,
                (
                    first.x * second.x
                        + first.y * second.y
                )
                / (firstNorm * secondNorm)
            )
        )
        let angle = acos(cosine) * 180 / .pi
        return max(0, 180 - angle)
    }

    private func distance(
        _ first: BodyJoint2D,
        _ second: BodyJoint2D
    ) -> Double {
        hypot(first.x - second.x, first.y - second.y)
    }

    private func median(
        _ values: [Double]
    ) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        let ordered = values.sorted()
        let middle = ordered.count / 2
        if ordered.count.isMultiple(of: 2) {
            return (
                ordered[middle - 1]
                    + ordered[middle]
            ) / 2
        }
        return ordered[middle]
    }

    private static func normalize(
        _ value: String
    ) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

import Foundation

public struct MobilityProtocolResult: Codable, Sendable, Equatable {
    public static let schemaVersion = "motionos.mobility-protocol.v1"
    public static let protocolID = "motionos.mobility.guided-envelope.v1"

    public let schemaVersion: String
    public let protocolID: String
    public let challengeID: String
    public let capturedAt: Date
    public let cameraSessionID: String

    public let leftShoulderSampleCount: Int
    public let rightShoulderSampleCount: Int
    public let squatSampleCount: Int
    public let trunkTwistSampleCount: Int

    /// Arm-versus-torso geometry observed by Vision during the guided window.
    /// It is a pose-envelope metric, not a clinical range-of-motion diagnosis.
    public let maximumLeftShoulderElevationDegrees: Double?
    public let maximumRightShoulderElevationDegrees: Double?
    public let shoulderElevationAsymmetryDegrees: Double?

    /// Minimum mean bilateral knee angle during the guided squat window.
    public let minimumMeanKneeAngleDegrees: Double?

    /// Maximum absolute angle between shoulder and hip lines projected into
    /// the root-relative x-z plane during the guided twist window.
    public let maximumTrunkTwistProxyDegrees: Double?

    public let claimBoundary: String

    public init(
        schemaVersion: String = Self.schemaVersion,
        protocolID: String = Self.protocolID,
        challengeID: String,
        capturedAt: Date,
        cameraSessionID: String,
        leftShoulderSampleCount: Int,
        rightShoulderSampleCount: Int,
        squatSampleCount: Int,
        trunkTwistSampleCount: Int,
        maximumLeftShoulderElevationDegrees: Double?,
        maximumRightShoulderElevationDegrees: Double?,
        shoulderElevationAsymmetryDegrees: Double?,
        minimumMeanKneeAngleDegrees: Double?,
        maximumTrunkTwistProxyDegrees: Double?
    ) {
        self.schemaVersion = schemaVersion
        self.protocolID = protocolID
        self.challengeID = challengeID
        self.capturedAt = capturedAt
        self.cameraSessionID = cameraSessionID
        self.leftShoulderSampleCount = leftShoulderSampleCount
        self.rightShoulderSampleCount = rightShoulderSampleCount
        self.squatSampleCount = squatSampleCount
        self.trunkTwistSampleCount = trunkTwistSampleCount
        self.maximumLeftShoulderElevationDegrees =
            maximumLeftShoulderElevationDegrees
        self.maximumRightShoulderElevationDegrees =
            maximumRightShoulderElevationDegrees
        self.shoulderElevationAsymmetryDegrees =
            shoulderElevationAsymmetryDegrees
        self.minimumMeanKneeAngleDegrees =
            minimumMeanKneeAngleDegrees
        self.maximumTrunkTwistProxyDegrees =
            maximumTrunkTwistProxyDegrees
        self.claimBoundary = (
            "Mobility Protocol v1 reports observed Vision 3D pose-envelope "
                + "geometry under a standardized guided task. It is not a "
                + "clinical range-of-motion exam, diagnosis, injury-risk "
                + "assessment, or evidence that more range is better."
        )
    }

    public var hasUsableCoverage: Bool {
        leftShoulderSampleCount >= 8
            && rightShoulderSampleCount >= 8
            && squatSampleCount >= 8
            && trunkTwistSampleCount >= 8
    }

    public func personaEvidence() -> PersonaSessionEvidence {
        let contextKey = [
            "mobility_challenge",
            protocolID,
            "iphone_vision_fixed_camera",
        ].joined(separator: "|")

        var metrics: [PersonaMetricObservation] = []

        func append(
            id: String,
            label: String,
            value: Double?,
            unit: String = "deg"
        ) {
            guard let value, value.isFinite else { return }
            metrics.append(
                PersonaMetricObservation(
                    dimension: .mobility,
                    metricID: id,
                    label: label,
                    unit: unit,
                    value: value,
                    observedAt: capturedAt,
                    contextKey: contextKey,
                    provenance: .derived,
                    sourceSessionID: challengeID
                )
            )
        }

        append(
            id: "vision.left_shoulder_elevation_envelope_deg",
            label: "Left shoulder elevation envelope",
            value: maximumLeftShoulderElevationDegrees
        )
        append(
            id: "vision.right_shoulder_elevation_envelope_deg",
            label: "Right shoulder elevation envelope",
            value: maximumRightShoulderElevationDegrees
        )
        append(
            id: "vision.shoulder_elevation_asymmetry_deg",
            label: "Shoulder elevation side difference",
            value: shoulderElevationAsymmetryDegrees
        )
        append(
            id: "vision.minimum_mean_knee_angle_deg",
            label: "Minimum mean knee angle",
            value: minimumMeanKneeAngleDegrees
        )
        append(
            id: "vision.trunk_twist_proxy_deg",
            label: "Trunk twist geometry proxy",
            value: maximumTrunkTwistProxyDegrees
        )

        return PersonaSessionEvidence(
            id: challengeID,
            sport: "mobility_challenge",
            protocolID: protocolID,
            captureMode: "iphone_vision_fixed_camera",
            observedAt: capturedAt,
            completed: hasUsableCoverage,
            sources: [.iPhoneVision, .iPhoneCamera],
            metrics: metrics
        )
    }
}

public struct MobilityProtocolAccumulator: Sendable, Equatable {
    public static let targetDurationSeconds: TimeInterval = 40

    public enum Window: String, Sendable, Equatable {
        case settle
        case leftShoulder
        case rightShoulder
        case squat
        case twist
        case finish

        static func resolve(
            elapsed: TimeInterval
        ) -> Window? {
            switch elapsed {
            case 0..<5:
                return .settle
            case 5..<12:
                return .leftShoulder
            case 12..<19:
                return .rightShoulder
            case 19..<27:
                return .squat
            case 27..<37:
                return .twist
            case 37..<40:
                return .finish
            default:
                return nil
            }
        }
    }

    private var lastFrameKey: String?

    private var leftShoulder: [Double] = []
    private var rightShoulder: [Double] = []
    private var squatKneeAngles: [Double] = []
    private var trunkTwist: [Double] = []

    public init() {}

    @discardableResult
    public mutating func observe(
        _ frame: BodyMovementFrame,
        elapsedSeconds: TimeInterval
    ) -> Bool {
        let key = frame.sessionID + ":" + String(frame.sequence)
        guard key != lastFrameKey else {
            return false
        }
        lastFrameKey = key

        guard let window = Window.resolve(
            elapsed: elapsedSeconds
        ) else {
            return false
        }

        switch window {
        case .leftShoulder:
            if let value = shoulderElevation(
                frame,
                side: .left
            ) {
                leftShoulder.append(value)
                return true
            }

        case .rightShoulder:
            if let value = shoulderElevation(
                frame,
                side: .right
            ) {
                rightShoulder.append(value)
                return true
            }

        case .squat:
            if let value = meanKneeAngle(frame) {
                squatKneeAngles.append(value)
                return true
            }

        case .twist:
            if let value = trunkTwistDegrees(frame) {
                trunkTwist.append(value)
                return true
            }

        case .settle, .finish:
            break
        }

        return false
    }

    public func result(
        challengeID: String,
        capturedAt: Date,
        cameraSessionID: String
    ) -> MobilityProtocolResult {
        let left = robustUpperEnvelope(leftShoulder)
        let right = robustUpperEnvelope(rightShoulder)
        let asymmetry: Double?
        if let left, let right {
            asymmetry = abs(left - right)
        } else {
            asymmetry = nil
        }

        return MobilityProtocolResult(
            challengeID: challengeID,
            capturedAt: capturedAt,
            cameraSessionID: cameraSessionID,
            leftShoulderSampleCount: leftShoulder.count,
            rightShoulderSampleCount: rightShoulder.count,
            squatSampleCount: squatKneeAngles.count,
            trunkTwistSampleCount: trunkTwist.count,
            maximumLeftShoulderElevationDegrees: left,
            maximumRightShoulderElevationDegrees: right,
            shoulderElevationAsymmetryDegrees: asymmetry,
            minimumMeanKneeAngleDegrees:
                robustLowerEnvelope(squatKneeAngles),
            maximumTrunkTwistProxyDegrees:
                robustUpperEnvelope(trunkTwist)
        )
    }

    private enum Side {
        case left
        case right
    }

    private func shoulderElevation(
        _ frame: BodyMovementFrame,
        side: Side
    ) -> Double? {
        let map = frame.jointMap

        guard let leftShoulder = find(
                ["leftShoulder", "left_shoulder"],
                in: map
              ),
              let rightShoulder = find(
                ["rightShoulder", "right_shoulder"],
                in: map
              ),
              let leftHip = find(
                ["leftHip", "left_hip"],
                in: map
              ),
              let rightHip = find(
                ["rightHip", "right_hip"],
                in: map
              )
        else {
            return nil
        }

        let shoulderCenter = midpoint(
            leftShoulder.position,
            rightShoulder.position
        )
        let hipCenter = midpoint(
            leftHip.position,
            rightHip.position
        )
        let torsoDown = vector(
            from: shoulderCenter,
            to: hipCenter
        )

        let shoulder: BodyJoint3D?
        let elbow: BodyJoint3D?
        switch side {
        case .left:
            shoulder = leftShoulder
            elbow = find(
                ["leftElbow", "left_elbow"],
                in: map
            )
        case .right:
            shoulder = rightShoulder
            elbow = find(
                ["rightElbow", "right_elbow"],
                in: map
            )
        }

        guard let shoulder,
              let elbow
        else {
            return nil
        }

        let upperArm = vector(
            from: shoulder.position,
            to: elbow.position
        )
        return angleDegrees(
            torsoDown,
            upperArm
        )
    }

    private func meanKneeAngle(
        _ frame: BodyMovementFrame
    ) -> Double? {
        let map = frame.jointMap

        let left = jointAngle(
            first: find(["leftHip", "left_hip"], in: map),
            vertex: find(["leftKnee", "left_knee"], in: map),
            third: find(
                ["leftAnkle", "left_ankle", "leftFoot", "left_foot"],
                in: map
            )
        )
        let right = jointAngle(
            first: find(["rightHip", "right_hip"], in: map),
            vertex: find(["rightKnee", "right_knee"], in: map),
            third: find(
                ["rightAnkle", "right_ankle", "rightFoot", "right_foot"],
                in: map
            )
        )

        let values = [left, right].compactMap { $0 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func trunkTwistDegrees(
        _ frame: BodyMovementFrame
    ) -> Double? {
        let map = frame.jointMap
        guard let leftShoulder = find(
                ["leftShoulder", "left_shoulder"],
                in: map
              ),
              let rightShoulder = find(
                ["rightShoulder", "right_shoulder"],
                in: map
              ),
              let leftHip = find(
                ["leftHip", "left_hip"],
                in: map
              ),
              let rightHip = find(
                ["rightHip", "right_hip"],
                in: map
              )
        else {
            return nil
        }

        let shoulderLine = MotionVector3(
            rightShoulder.position.x - leftShoulder.position.x,
            0,
            rightShoulder.position.z - leftShoulder.position.z
        )
        let hipLine = MotionVector3(
            rightHip.position.x - leftHip.position.x,
            0,
            rightHip.position.z - leftHip.position.z
        )

        return angleDegrees(
            shoulderLine,
            hipLine
        )
    }

    private func jointAngle(
        first: BodyJoint3D?,
        vertex: BodyJoint3D?,
        third: BodyJoint3D?
    ) -> Double? {
        guard let first,
              let vertex,
              let third
        else {
            return nil
        }

        return angleDegrees(
            vector(
                from: vertex.position,
                to: first.position
            ),
            vector(
                from: vertex.position,
                to: third.position
            )
        )
    }

    private func angleDegrees(
        _ lhs: MotionVector3,
        _ rhs: MotionVector3
    ) -> Double? {
        let lhsNorm = norm(lhs)
        let rhsNorm = norm(rhs)
        guard lhsNorm > 0.0001,
              rhsNorm > 0.0001
        else {
            return nil
        }

        let dot =
            lhs.x * rhs.x
                + lhs.y * rhs.y
                + lhs.z * rhs.z
        let cosine = min(
            1,
            max(-1, dot / (lhsNorm * rhsNorm))
        )
        return acos(cosine) * 180 / .pi
    }

    private func find(
        _ aliases: [String],
        in map: [String: BodyJoint3D]
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

    private func normalize(
        _ value: String
    ) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func vector(
        from start: MotionVector3,
        to end: MotionVector3
    ) -> MotionVector3 {
        MotionVector3(
            end.x - start.x,
            end.y - start.y,
            end.z - start.z
        )
    }

    private func midpoint(
        _ lhs: MotionVector3,
        _ rhs: MotionVector3
    ) -> MotionVector3 {
        MotionVector3(
            (lhs.x + rhs.x) / 2,
            (lhs.y + rhs.y) / 2,
            (lhs.z + rhs.z) / 2
        )
    }

    private func norm(
        _ value: MotionVector3
    ) -> Double {
        sqrt(
            value.x * value.x
                + value.y * value.y
                + value.z * value.z
        )
    }

    /// Median of the top 20% resists one-frame pose spikes while representing
    /// the observed end of the guided envelope.
    private func robustUpperEnvelope(
        _ values: [Double]
    ) -> Double? {
        let finite = values.filter(\.isFinite).sorted()
        guard finite.count >= 3 else { return nil }

        let count = max(
            1,
            Int(ceil(Double(finite.count) * 0.20))
        )
        return median(
            Array(finite.suffix(count))
        )
    }

    /// Median of the bottom 20% for the same reason.
    private func robustLowerEnvelope(
        _ values: [Double]
    ) -> Double? {
        let finite = values.filter(\.isFinite).sorted()
        guard finite.count >= 3 else { return nil }

        let count = max(
            1,
            Int(ceil(Double(finite.count) * 0.20))
        )
        return median(
            Array(finite.prefix(count))
        )
    }

    private func median(
        _ values: [Double]
    ) -> Double? {
        let finite = values.filter(\.isFinite).sorted()
        guard !finite.isEmpty else { return nil }
        let middle = finite.count / 2
        if finite.count.isMultiple(of: 2) {
            return (
                finite[middle - 1]
                    + finite[middle]
            ) / 2
        }
        return finite[middle]
    }
}

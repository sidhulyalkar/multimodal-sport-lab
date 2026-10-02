import Foundation

public struct BodyCalibrationProgress: Sendable, Equatable {
    public let framesSeen: Int
    public let acceptedFrames: Int
    public let parameterSampleCounts: [BodyParameterKind: Int]

    public init(
        framesSeen: Int,
        acceptedFrames: Int,
        parameterSampleCounts: [BodyParameterKind: Int]
    ) {
        self.framesSeen = framesSeen
        self.acceptedFrames = acceptedFrames
        self.parameterSampleCounts = parameterSampleCounts
    }

    public var acceptanceFraction: Double {
        guard framesSeen > 0 else { return 0 }
        return Double(acceptedFrames) / Double(framesSeen)
    }
}

public struct BodyCalibrationResult: Sendable, Equatable {
    public let model: PersonalBodyModel
    public let framesSeen: Int
    public let acceptedFrames: Int
    public let parameterSampleCounts: [BodyParameterKind: Int]
    public let parameterRobustSpreadMeters: [BodyParameterKind: Double]

    public init(
        model: PersonalBodyModel,
        framesSeen: Int,
        acceptedFrames: Int,
        parameterSampleCounts: [BodyParameterKind: Int],
        parameterRobustSpreadMeters: [BodyParameterKind: Double]
    ) {
        self.model = model
        self.framesSeen = framesSeen
        self.acceptedFrames = acceptedFrames
        self.parameterSampleCounts = parameterSampleCounts
        self.parameterRobustSpreadMeters = parameterRobustSpreadMeters
    }
}

public struct BodyCalibrationAccumulator: Sendable, Equatable {
    public static let minimumAcceptedFrames = 24
    public static let minimumSamplesPerRequiredParameter = 12

    public private(set) var framesSeen = 0
    public private(set) var acceptedFrames = 0
    public private(set) var samples: [BodyParameterKind: [Double]] = [:]

    public init() {}

    @discardableResult
    public mutating func observe(
        _ frame: BodyMovementFrame
    ) -> Bool {
        framesSeen += 1

        let map = frame.jointMap
        var frameMeasurements: [BodyParameterKind: Double] = [:]

        if let height = frame.bodyHeightM,
           height.isFinite,
           (0.5...2.5).contains(height) {
            frameMeasurements[.standingHeight] = height
        }

        measure(
            .shoulderWidth,
            between: ["leftShoulder", "left_shoulder"],
            and: ["rightShoulder", "right_shoulder"],
            map: map,
            into: &frameMeasurements
        )
        measure(
            .hipWidth,
            between: ["leftHip", "left_hip"],
            and: ["rightHip", "right_hip"],
            map: map,
            into: &frameMeasurements
        )

        if let leftShoulder = findJoint(
                ["leftShoulder", "left_shoulder"],
                in: map
            ),
           let rightShoulder = findJoint(
                ["rightShoulder", "right_shoulder"],
                in: map
           ),
           let leftHip = findJoint(
                ["leftHip", "left_hip"],
                in: map
           ),
           let rightHip = findJoint(
                ["rightHip", "right_hip"],
                in: map
           ) {
            let shoulderCenter = midpoint(
                leftShoulder.position,
                rightShoulder.position
            )
            let hipCenter = midpoint(
                leftHip.position,
                rightHip.position
            )
            let length = distance(
                shoulderCenter,
                hipCenter
            )
            if plausible(length) {
                frameMeasurements[.torsoLength] = length
            }
        }

        measure(
            .leftUpperArmLength,
            between: ["leftShoulder", "left_shoulder"],
            and: ["leftElbow", "left_elbow"],
            map: map,
            into: &frameMeasurements
        )
        measure(
            .rightUpperArmLength,
            between: ["rightShoulder", "right_shoulder"],
            and: ["rightElbow", "right_elbow"],
            map: map,
            into: &frameMeasurements
        )
        measure(
            .leftForearmLength,
            between: ["leftElbow", "left_elbow"],
            and: ["leftWrist", "left_wrist"],
            map: map,
            into: &frameMeasurements
        )
        measure(
            .rightForearmLength,
            between: ["rightElbow", "right_elbow"],
            and: ["rightWrist", "right_wrist"],
            map: map,
            into: &frameMeasurements
        )
        measure(
            .leftFemurLength,
            between: ["leftHip", "left_hip"],
            and: ["leftKnee", "left_knee"],
            map: map,
            into: &frameMeasurements
        )
        measure(
            .rightFemurLength,
            between: ["rightHip", "right_hip"],
            and: ["rightKnee", "right_knee"],
            map: map,
            into: &frameMeasurements
        )
        measure(
            .leftTibiaLength,
            between: ["leftKnee", "left_knee"],
            and: ["leftAnkle", "left_ankle", "leftFoot", "left_foot"],
            map: map,
            into: &frameMeasurements
        )
        measure(
            .rightTibiaLength,
            between: ["rightKnee", "right_knee"],
            and: ["rightAnkle", "right_ankle", "rightFoot", "right_foot"],
            map: map,
            into: &frameMeasurements
        )

        // A frame must contribute enough independent geometry to be useful.
        // Partial frames can still add measurements, but they don't advance
        // the accepted-frame counter used by the guided quality gate.
        let accepted = frameMeasurements.count >= 8
        if accepted {
            acceptedFrames += 1
        }

        for (kind, value) in frameMeasurements {
            samples[kind, default: []].append(value)
        }

        return accepted
    }

    public var progress: BodyCalibrationProgress {
        BodyCalibrationProgress(
            framesSeen: framesSeen,
            acceptedFrames: acceptedFrames,
            parameterSampleCounts: samples.mapValues(\.count)
        )
    }

    public func canFinalize: Bool {
        guard acceptedFrames >= Self.minimumAcceptedFrames else {
            return false
        }

        for kind in Self.requiredParameters {
            guard samples[kind, default: []].count
                    >= Self.minimumSamplesPerRequiredParameter
            else {
                return false
            }
        }
        return true
    }

    public func finalize(
        versionID: String,
        calibratedAt: Date = Date(),
        sourceID: String,
        meshAssetRelativePath: String? = nil
    ) throws -> BodyCalibrationResult {
        guard canFinalize else {
            throw CalibrationError.insufficientCoverage
        }

        var observations: [BodyParameterObservation] = []
        var spreads: [BodyParameterKind: Double] = [:]

        for kind in BodyParameterKind.allCases {
            guard let rawValues = samples[kind],
                  rawValues.count >= 3,
                  let robust = robustEstimate(rawValues)
            else {
                continue
            }

            observations.append(
                BodyParameterObservation(
                    kind: kind,
                    valueMeters: robust.center,
                    observedAt: calibratedAt,
                    provenance: .visionCalibration,
                    sourceID: sourceID,
                    uncertaintyMeters: robust.spread
                )
            )
            spreads[kind] = robust.spread
        }

        let model = try PersonalBodyModelBuilder.build(
            versionID: versionID,
            calibratedAt: calibratedAt,
            observations: observations,
            meshAssetRelativePath: meshAssetRelativePath
        )

        return BodyCalibrationResult(
            model: model,
            framesSeen: framesSeen,
            acceptedFrames: acceptedFrames,
            parameterSampleCounts: samples.mapValues(\.count),
            parameterRobustSpreadMeters: spreads
        )
    }

    private static let requiredParameters: [BodyParameterKind] = [
        .shoulderWidth,
        .hipWidth,
        .torsoLength,
        .leftUpperArmLength,
        .rightUpperArmLength,
        .leftForearmLength,
        .rightForearmLength,
        .leftFemurLength,
        .rightFemurLength,
        .leftTibiaLength,
        .rightTibiaLength,
    ]

    private func measure(
        _ kind: BodyParameterKind,
        between firstAliases: [String],
        and secondAliases: [String],
        map: [String: BodyJoint3D],
        into measurements: inout [BodyParameterKind: Double]
    ) {
        guard let first = findJoint(
                firstAliases,
                in: map
              ),
              let second = findJoint(
                secondAliases,
                in: map
              )
        else {
            return
        }

        let value = distance(
            first.position,
            second.position
        )
        if plausible(value) {
            measurements[kind] = value
        }
    }

    private func plausible(
        _ value: Double
    ) -> Bool {
        value.isFinite
            && value >= 0.04
            && value <= 1.5
    }

    private func findJoint(
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

    private func distance(
        _ lhs: MotionVector3,
        _ rhs: MotionVector3
    ) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        let dz = lhs.z - rhs.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    private func robustEstimate(
        _ values: [Double]
    ) -> (center: Double, spread: Double)? {
        let finite = values.filter {
            $0.isFinite && $0 > 0
        }
        guard finite.count >= 3 else {
            return nil
        }

        let initialMedian = median(finite)
        let absoluteDeviations = finite.map {
            abs($0 - initialMedian)
        }
        let mad = median(absoluteDeviations)
        let robustScale = 1.4826 * mad

        // Keep a floor only for outlier rejection, not for the reported
        // uncertainty. This avoids zero-MAD samples accepting absurd frames.
        let threshold = max(
            0.015,
            initialMedian * 0.12,
            robustScale * 4
        )
        let filtered = finite.filter {
            abs($0 - initialMedian) <= threshold
        }
        guard filtered.count >= 3 else {
            return nil
        }

        let center = median(filtered)
        let filteredMAD = median(
            filtered.map {
                abs($0 - center)
            }
        )

        return (
            center,
            1.4826 * filteredMAD
        )
    }

    private func median(
        _ values: [Double]
    ) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }

        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (
                sorted[middle - 1]
                    + sorted[middle]
            ) / 2
        }
        return sorted[middle]
    }

    public enum CalibrationError: LocalizedError, Equatable {
        case insufficientCoverage

        public var errorDescription: String? {
            switch self {
            case .insufficientCoverage:
                return (
                    "Body calibration needs more complete full-body Vision "
                        + "frames before MotionOS can create a stable model."
                )
            }
        }
    }
}

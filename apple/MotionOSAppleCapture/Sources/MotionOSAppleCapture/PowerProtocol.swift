import Foundation

public struct PowerProtocolAttempt: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let index: Int
    public let validFrameCount: Int
    public let durationSeconds: Double
    /// Bounding-box diagonal of the skeleton root in camera space during the
    /// attempt. This is a kinematic path-range proxy, not jump height.
    public let rootTravelRangeCameraM: Double?
    /// Peak finite-difference root speed in camera space. This is not power,
    /// force, or takeoff velocity.
    public let peakRootSpeedCameraMPS: Double?
    public let minimumMeanKneeAngleDegrees: Double?
    public let maximumMeanKneeAngleDegrees: Double?

    public init(
        id: String,
        index: Int,
        validFrameCount: Int,
        durationSeconds: Double,
        rootTravelRangeCameraM: Double?,
        peakRootSpeedCameraMPS: Double?,
        minimumMeanKneeAngleDegrees: Double?,
        maximumMeanKneeAngleDegrees: Double?
    ) {
        self.id = id
        self.index = index
        self.validFrameCount = validFrameCount
        self.durationSeconds = durationSeconds
        self.rootTravelRangeCameraM = rootTravelRangeCameraM
        self.peakRootSpeedCameraMPS = peakRootSpeedCameraMPS
        self.minimumMeanKneeAngleDegrees = minimumMeanKneeAngleDegrees
        self.maximumMeanKneeAngleDegrees = maximumMeanKneeAngleDegrees
    }
}

public struct PowerProtocolResult: Codable, Sendable, Equatable {
    public static let schemaVersion = "motionos.power-protocol.v1"
    public static let protocolID = "motionos.power.countermovement.v1"

    public let schemaVersion: String
    public let protocolID: String
    public let challengeID: String
    public let capturedAt: Date
    public let cameraSessionID: String
    public let attempts: [PowerProtocolAttempt]
    public let medianPeakRootSpeedCameraMPS: Double?
    public let medianRootTravelRangeCameraM: Double?
    public let peakSpeedCoefficientOfVariation: Double?
    public let rootTravelCoefficientOfVariation: Double?
    public let claimBoundary: String

    public init(
        schemaVersion: String = Self.schemaVersion,
        protocolID: String = Self.protocolID,
        challengeID: String,
        capturedAt: Date,
        cameraSessionID: String,
        attempts: [PowerProtocolAttempt],
        medianPeakRootSpeedCameraMPS: Double?,
        medianRootTravelRangeCameraM: Double?,
        peakSpeedCoefficientOfVariation: Double?,
        rootTravelCoefficientOfVariation: Double?
    ) {
        self.schemaVersion = schemaVersion
        self.protocolID = protocolID
        self.challengeID = challengeID
        self.capturedAt = capturedAt
        self.cameraSessionID = cameraSessionID
        self.attempts = attempts
        self.medianPeakRootSpeedCameraMPS =
            medianPeakRootSpeedCameraMPS
        self.medianRootTravelRangeCameraM =
            medianRootTravelRangeCameraM
        self.peakSpeedCoefficientOfVariation =
            peakSpeedCoefficientOfVariation
        self.rootTravelCoefficientOfVariation =
            rootTravelCoefficientOfVariation
        self.claimBoundary = (
            "Power Protocol v1 reports camera-space kinematic proxies from a "
                + "standardized countermovement-jump challenge. It does not "
                + "measure mechanical power, watts, ground-reaction force, "
                + "center of mass, or validated jump height."
        )
    }

    public var validAttemptCount: Int {
        attempts.filter {
            $0.validFrameCount >= 8
                && $0.peakRootSpeedCameraMPS != nil
                && $0.rootTravelRangeCameraM != nil
        }.count
    }

    public func personaEvidence() -> PersonaSessionEvidence {
        let contextKey = [
            "power_challenge",
            protocolID,
            "iphone_vision_fixed_camera",
        ].joined(separator: "|")

        var metrics: [PersonaMetricObservation] = []

        if let value = medianPeakRootSpeedCameraMPS {
            metrics.append(
                PersonaMetricObservation(
                    dimension: .power,
                    metricID: "vision.root_speed_proxy_m_s",
                    label: "Camera-space root speed proxy",
                    unit: "m/s",
                    value: value,
                    observedAt: capturedAt,
                    contextKey: contextKey,
                    provenance: .derived,
                    sourceSessionID: challengeID
                )
            )
        }

        if let value = medianRootTravelRangeCameraM {
            metrics.append(
                PersonaMetricObservation(
                    dimension: .power,
                    metricID: "vision.root_travel_proxy_m",
                    label: "Camera-space root travel proxy",
                    unit: "m",
                    value: value,
                    observedAt: capturedAt,
                    contextKey: contextKey,
                    provenance: .derived,
                    sourceSessionID: challengeID
                )
            )
        }

        if let value = peakSpeedCoefficientOfVariation {
            metrics.append(
                PersonaMetricObservation(
                    dimension: .power,
                    metricID: "vision.root_speed_repeatability_cv",
                    label: "Root-speed repeatability CV",
                    unit: "ratio",
                    value: value,
                    observedAt: capturedAt,
                    contextKey: contextKey,
                    provenance: .derived,
                    sourceSessionID: challengeID
                )
            )
        }

        return PersonaSessionEvidence(
            id: challengeID,
            sport: "power_challenge",
            protocolID: protocolID,
            captureMode: "iphone_vision_fixed_camera",
            observedAt: capturedAt,
            completed: validAttemptCount >= 2,
            sources: [.iPhoneVision, .iPhoneCamera],
            metrics: metrics
        )
    }
}

public struct PowerProtocolAccumulator: Sendable, Equatable {
    public static let targetDurationSeconds: TimeInterval = 28

    public struct AttemptWindow: Sendable, Equatable, Identifiable {
        public let id: String
        public let index: Int
        public let startSeconds: TimeInterval
        public let endSeconds: TimeInterval

        public init(
            id: String,
            index: Int,
            startSeconds: TimeInterval,
            endSeconds: TimeInterval
        ) {
            self.id = id
            self.index = index
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
        }

        public func contains(_ elapsed: TimeInterval) -> Bool {
            elapsed >= startSeconds && elapsed < endSeconds
        }
    }

    public static let attemptWindows: [AttemptWindow] = [
        .init(id: "jump-1", index: 1, startSeconds: 5, endSeconds: 10),
        .init(id: "jump-2", index: 2, startSeconds: 13, endSeconds: 18),
        .init(id: "jump-3", index: 3, startSeconds: 21, endSeconds: 26),
    ]

    private var accumulators: [String: AttemptAccumulator] = [:]
    private var lastFrameKey: String?

    public init() {}

    @discardableResult
    public mutating func observe(
        _ frame: BodyMovementFrame,
        elapsedSeconds: TimeInterval
    ) -> Bool {
        let frameKey = frame.sessionID + ":" + String(frame.sequence)
        guard frameKey != lastFrameKey else {
            return false
        }
        lastFrameKey = frameKey

        guard let window = Self.attemptWindows.first(where: {
            $0.contains(elapsedSeconds)
        }) else {
            return false
        }

        var accumulator =
            accumulators[window.id]
                ?? AttemptAccumulator(
                    window: window
                )
        accumulator.observe(frame)
        accumulators[window.id] = accumulator
        return true
    }

    public func result(
        challengeID: String,
        capturedAt: Date,
        cameraSessionID: String
    ) -> PowerProtocolResult {
        let attempts = Self.attemptWindows.map { window in
            (accumulators[window.id]
                ?? AttemptAccumulator(window: window))
                .result()
        }

        let speeds = attempts.compactMap(
            \.peakRootSpeedCameraMPS
        )
        let travel = attempts.compactMap(
            \.rootTravelRangeCameraM
        )

        return PowerProtocolResult(
            challengeID: challengeID,
            capturedAt: capturedAt,
            cameraSessionID: cameraSessionID,
            attempts: attempts,
            medianPeakRootSpeedCameraMPS:
                median(speeds),
            medianRootTravelRangeCameraM:
                median(travel),
            peakSpeedCoefficientOfVariation:
                coefficientOfVariation(speeds),
            rootTravelCoefficientOfVariation:
                coefficientOfVariation(travel)
        )
    }

    private struct AttemptAccumulator: Sendable, Equatable {
        let window: AttemptWindow
        var frameCount = 0
        var firstTimeNS: UInt64?
        var lastTimeNS: UInt64?
        var roots: [MotionVector3] = []
        var peakRootSpeed = 0.0
        var kneeAngles: [Double] = []
        var previousRoot: MotionVector3?
        var previousTimeNS: UInt64?

        mutating func observe(
            _ frame: BodyMovementFrame
        ) {
            frameCount += 1
            firstTimeNS = firstTimeNS ?? frame.deviceTimeNS
            lastTimeNS = frame.deviceTimeNS

            if let root = frame.rootPositionCameraM {
                roots.append(root)

                if let previousRoot,
                   let previousTimeNS,
                   frame.deviceTimeNS > previousTimeNS {
                    let dt = Double(
                        frame.deviceTimeNS - previousTimeNS
                    ) / 1_000_000_000
                    if dt > 0 {
                        peakRootSpeed = max(
                            peakRootSpeed,
                            distance(root, previousRoot) / dt
                        )
                    }
                }

                previousRoot = root
                previousTimeNS = frame.deviceTimeNS
            }

            if let angle = meanKneeAngle(frame) {
                kneeAngles.append(angle)
            }
        }

        func result() -> PowerProtocolAttempt {
            let duration: Double
            if let firstTimeNS,
               let lastTimeNS,
               lastTimeNS >= firstTimeNS {
                duration = Double(
                    lastTimeNS - firstTimeNS
                ) / 1_000_000_000
            } else {
                duration = 0
            }

            return PowerProtocolAttempt(
                id: window.id,
                index: window.index,
                validFrameCount: frameCount,
                durationSeconds: duration,
                rootTravelRangeCameraM:
                    cameraSpaceRange(roots),
                peakRootSpeedCameraMPS:
                    roots.count >= 3 && peakRootSpeed.isFinite
                        ? peakRootSpeed
                        : nil,
                minimumMeanKneeAngleDegrees:
                    kneeAngles.min(),
                maximumMeanKneeAngleDegrees:
                    kneeAngles.max()
            )
        }

        private func meanKneeAngle(
            _ frame: BodyMovementFrame
        ) -> Double? {
            let map = frame.jointMap
            let left = jointAngleDegrees(
                hip: find(["leftHip", "left_hip"], in: map),
                knee: find(["leftKnee", "left_knee"], in: map),
                ankle: find(
                    ["leftAnkle", "left_ankle", "leftFoot", "left_foot"],
                    in: map
                )
            )
            let right = jointAngleDegrees(
                hip: find(["rightHip", "right_hip"], in: map),
                knee: find(["rightKnee", "right_knee"], in: map),
                ankle: find(
                    ["rightAnkle", "right_ankle", "rightFoot", "right_foot"],
                    in: map
                )
            )

            let values = [left, right].compactMap { $0 }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        private func jointAngleDegrees(
            hip: BodyJoint3D?,
            knee: BodyJoint3D?,
            ankle: BodyJoint3D?
        ) -> Double? {
            guard let hip, let knee, let ankle else {
                return nil
            }

            let a = MotionVector3(
                hip.position.x - knee.position.x,
                hip.position.y - knee.position.y,
                hip.position.z - knee.position.z
            )
            let b = MotionVector3(
                ankle.position.x - knee.position.x,
                ankle.position.y - knee.position.y,
                ankle.position.z - knee.position.z
            )

            let aNorm = vectorNorm(a)
            let bNorm = vectorNorm(b)
            guard aNorm > 0.0001,
                  bNorm > 0.0001
            else {
                return nil
            }

            let dot =
                a.x * b.x
                + a.y * b.y
                + a.z * b.z
            let cosine = min(
                1,
                max(-1, dot / (aNorm * bNorm))
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

        private func cameraSpaceRange(
            _ points: [MotionVector3]
        ) -> Double? {
            guard points.count >= 3 else {
                return nil
            }

            guard let minX = points.map(\.x).min(),
                  let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(),
                  let maxY = points.map(\.y).max(),
                  let minZ = points.map(\.z).min(),
                  let maxZ = points.map(\.z).max()
            else {
                return nil
            }

            return sqrt(
                pow(maxX - minX, 2)
                    + pow(maxY - minY, 2)
                    + pow(maxZ - minZ, 2)
            )
        }

        private func distance(
            _ lhs: MotionVector3,
            _ rhs: MotionVector3
        ) -> Double {
            sqrt(
                pow(lhs.x - rhs.x, 2)
                    + pow(lhs.y - rhs.y, 2)
                    + pow(lhs.z - rhs.z, 2)
            )
        }

        private func vectorNorm(
            _ value: MotionVector3
        ) -> Double {
            sqrt(
                value.x * value.x
                    + value.y * value.y
                    + value.z * value.z
            )
        }
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

    private func coefficientOfVariation(
        _ values: [Double]
    ) -> Double? {
        let finite = values.filter {
            $0.isFinite && $0 >= 0
        }
        guard finite.count >= 2 else {
            return nil
        }

        let mean = finite.reduce(0, +)
            / Double(finite.count)
        guard mean > 0.000001 else {
            return nil
        }

        let variance = finite.reduce(0) {
            $0 + pow($1 - mean, 2)
        } / Double(finite.count)
        return sqrt(variance) / mean
    }
}

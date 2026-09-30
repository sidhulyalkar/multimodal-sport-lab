import Foundation

public enum CameraSourceKind: String, Codable, Sendable, Equatable {
    case builtIn = "built_in"
    case externalRecorded = "external_recorded"
    case externalLiveStream = "external_live_stream"
}

public struct CameraSource: Codable, Sendable, Equatable, Identifiable {
    public let sourceID: String
    public let displayName: String
    public let kind: CameraSourceKind
    public let clockDomain: String
    public let timestampBasis: String
    public let supportsLiveFrames: Bool
    public let supportsRemoteControl: Bool
    public let capabilities: [String]

    public var id: String { sourceID }

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case displayName = "display_name"
        case kind
        case clockDomain = "clock_domain"
        case timestampBasis = "timestamp_basis"
        case supportsLiveFrames = "supports_live_frames"
        case supportsRemoteControl = "supports_remote_control"
        case capabilities
    }

    public init(
        sourceID: String,
        displayName: String,
        kind: CameraSourceKind,
        clockDomain: String,
        timestampBasis: String,
        supportsLiveFrames: Bool,
        supportsRemoteControl: Bool,
        capabilities: [String] = []
    ) {
        self.sourceID = sourceID
        self.displayName = displayName
        self.kind = kind
        self.clockDomain = clockDomain
        self.timestampBasis = timestampBasis
        self.supportsLiveFrames = supportsLiveFrames
        self.supportsRemoteControl = supportsRemoteControl
        self.capabilities = capabilities
    }
}

public struct VideoFrameTimestamp: Codable, Sendable, Equatable {
    public let sourceID: String
    public let sequence: UInt64
    public let sourceTimeNS: UInt64
    public let hostMonotonicTimeNS: UInt64?
    public let sessionTimeNS: UInt64?
    public let timingUncertaintyNS: UInt64?

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case sequence
        case sourceTimeNS = "source_time_ns"
        case hostMonotonicTimeNS = "host_monotonic_time_ns"
        case sessionTimeNS = "session_time_ns"
        case timingUncertaintyNS = "timing_uncertainty_ns"
    }

    public init(
        sourceID: String,
        sequence: UInt64,
        sourceTimeNS: UInt64,
        hostMonotonicTimeNS: UInt64? = nil,
        sessionTimeNS: UInt64? = nil,
        timingUncertaintyNS: UInt64? = nil
    ) {
        self.sourceID = sourceID
        self.sequence = sequence
        self.sourceTimeNS = sourceTimeNS
        self.hostMonotonicTimeNS = hostMonotonicTimeNS
        self.sessionTimeNS = sessionTimeNS
        self.timingUncertaintyNS = timingUncertaintyNS
    }
}

public struct CameraCalibration: Codable, Sendable, Equatable {
    public let calibrationID: String
    public let cameraSourceID: String
    public let imageWidthPixels: Int
    public let imageHeightPixels: Int
    public let intrinsicsRowMajor: [Double]
    public let distortionModel: String
    public let distortionCoefficients: [Double]
    public let worldFromCameraRowMajor: [Double]
    public let reprojectionRMSPixels: Double
    public let sourceArtifactSHA256: String?

    enum CodingKeys: String, CodingKey {
        case calibrationID = "calibration_id"
        case cameraSourceID = "camera_source_id"
        case imageWidthPixels = "image_width_px"
        case imageHeightPixels = "image_height_px"
        case intrinsicsRowMajor = "intrinsics_row_major"
        case distortionModel = "distortion_model"
        case distortionCoefficients = "distortion_coefficients"
        case worldFromCameraRowMajor = "world_from_camera_row_major"
        case reprojectionRMSPixels = "reprojection_rms_px"
        case sourceArtifactSHA256 = "source_artifact_sha256"
    }

    public var isStructurallyValid: Bool {
        imageWidthPixels > 0
            && imageHeightPixels > 0
            && intrinsicsRowMajor.count == 9
            && worldFromCameraRowMajor.count == 16
            && reprojectionRMSPixels.isFinite
            && reprojectionRMSPixels >= 0
    }
}

public struct VisionJointObservation: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double?
    public let confidence: Double

    public init(
        x: Double,
        y: Double,
        z: Double? = nil,
        confidence: Double
    ) {
        self.x = x
        self.y = y
        self.z = z
        self.confidence = confidence
    }
}

public struct VisionObservation: Codable, Sendable, Equatable {
    public let sourceID: String
    public let frameSequence: UInt64
    public let frameSourceTimeNS: UInt64
    public let mappedSessionTimeNS: UInt64?
    public let timingUncertaintyNS: UInt64?
    public let coordinateFrame: String
    public let modelIdentifier: String
    public let joints: [String: VisionJointObservation]

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case frameSequence = "frame_sequence"
        case frameSourceTimeNS = "frame_source_time_ns"
        case mappedSessionTimeNS = "mapped_session_time_ns"
        case timingUncertaintyNS = "timing_uncertainty_ns"
        case coordinateFrame = "coordinate_frame"
        case modelIdentifier = "model_identifier"
        case joints
    }
}

public enum SyncLandmarkKind: String, Codable, Sendable, Equatable {
    case wholeBodyImpulse = "whole_body_impulse"
    case screenFlash = "screen_flash"
    case audioChirp = "audio_chirp"
    case manualMarker = "manual_marker"
}

public struct SyncLandmark: Codable, Sendable, Equatable, Identifiable {
    public let landmarkID: String
    public let sessionID: String
    public let kind: SyncLandmarkKind
    public let hostMonotonicTimeNS: UInt64
    public let createdAtUnixMS: UInt64
    public let note: String?

    public var id: String { landmarkID }

    enum CodingKeys: String, CodingKey {
        case landmarkID = "landmark_id"
        case sessionID = "session_id"
        case kind
        case hostMonotonicTimeNS = "host_monotonic_time_ns"
        case createdAtUnixMS = "created_at_unix_ms"
        case note
    }
}

public struct VisionSessionManifest: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let sessionID: String
    public let sport: String
    public let captureMode: String
    public let createdAtUTC: String
    public let cameraSources: [CameraSource]
    public let syncLandmarks: [SyncLandmark]
    public let claimBoundary: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case sport
        case captureMode = "capture_mode"
        case createdAtUTC = "created_at_utc"
        case cameraSources = "camera_sources"
        case syncLandmarks = "sync_landmarks"
        case claimBoundary = "claim_boundary"
    }

    public init(
        schemaVersion: String = "motionos.vision-session.v1",
        sessionID: String,
        sport: String,
        captureMode: String,
        createdAtUTC: String,
        cameraSources: [CameraSource],
        syncLandmarks: [SyncLandmark],
        claimBoundary: String = "Camera and wearable streams retain native timing until explicit calibration; derived biomechanics carry uncertainty."
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.sport = sport
        self.captureMode = captureMode
        self.createdAtUTC = createdAtUTC
        self.cameraSources = cameraSources
        self.syncLandmarks = syncLandmarks
        self.claimBoundary = claimBoundary
    }
}

public enum MetricDirection: String, Codable, Sendable, Equatable {
    case lowerIsBetter = "lower_is_better"
    case higherIsBetter = "higher_is_better"
    case descriptive
}

public struct IndoBoardMetricSnapshot: Codable, Sendable, Equatable {
    public let sessionID: String
    public let metricID: String
    public let value: Double
    public let unit: String
    public let direction: MetricDirection
    public let confidence: Double
    public let sessionTimeNS: UInt64?
    public let uncertainty: Double?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case metricID = "metric_id"
        case value
        case unit
        case direction
        case confidence
        case sessionTimeNS = "session_time_ns"
        case uncertainty
    }
}

public enum CoachingCueKind: String, Codable, Sendable, Equatable {
    case informational
    case techniqueWarning = "technique_warning"
    case positiveReinforcement = "positive_reinforcement"
}

public struct CoachingCue: Codable, Sendable, Equatable, Identifiable {
    public let cueID: String
    public let sessionID: String
    public let metricID: String
    public let value: Double?
    public let unit: String?
    public let message: String
    public let kind: CoachingCueKind
    public let confidence: Double
    public let issuedAtUnixMS: UInt64
    public let validForMS: UInt64

    public var id: String { cueID }

    enum CodingKeys: String, CodingKey {
        case cueID = "cue_id"
        case sessionID = "session_id"
        case metricID = "metric_id"
        case value
        case unit
        case message
        case kind
        case confidence
        case issuedAtUnixMS = "issued_at_unix_ms"
        case validForMS = "valid_for_ms"
    }

    public var expiresAtUnixMS: UInt64 {
        issuedAtUnixMS &+ validForMS
    }

    public func isEligibleForLiveDelivery(
        nowUnixMS: UInt64,
        minimumConfidence: Double = 0.75
    ) -> Bool {
        confidence >= minimumConfidence
            && nowUnixMS <= expiresAtUnixMS
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct LongitudinalMetricBaseline: Codable, Sendable, Equatable {
    public let metricID: String
    public let direction: MetricDirection
    public private(set) var sampleCount: UInt64
    public private(set) var mean: Double
    public private(set) var m2: Double
    public private(set) var bestValue: Double?
    public private(set) var latestValue: Double?

    public init(
        metricID: String,
        direction: MetricDirection,
        sampleCount: UInt64 = 0,
        mean: Double = 0,
        m2: Double = 0,
        bestValue: Double? = nil,
        latestValue: Double? = nil
    ) {
        self.metricID = metricID
        self.direction = direction
        self.sampleCount = sampleCount
        self.mean = mean
        self.m2 = m2
        self.bestValue = bestValue
        self.latestValue = latestValue
    }

    public var sampleStandardDeviation: Double? {
        guard sampleCount > 1 else { return nil }
        return sqrt(m2 / Double(sampleCount - 1))
    }

    public mutating func observe(_ value: Double) {
        guard value.isFinite else { return }

        sampleCount += 1
        let delta = value - mean
        mean += delta / Double(sampleCount)
        let delta2 = value - mean
        m2 += delta * delta2
        latestValue = value

        guard let currentBest = bestValue else {
            bestValue = value
            return
        }

        switch direction {
        case .lowerIsBetter:
            bestValue = min(currentBest, value)
        case .higherIsBetter:
            bestValue = max(currentBest, value)
        case .descriptive:
            break
        }
    }
}

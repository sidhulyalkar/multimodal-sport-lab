import Foundation

public enum BodyParameterKind: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case standingHeight = "standing_height"
    case shoulderWidth = "shoulder_width"
    case hipWidth = "hip_width"
    case torsoLength = "torso_length"
    case leftUpperArmLength = "left_upper_arm_length"
    case rightUpperArmLength = "right_upper_arm_length"
    case leftForearmLength = "left_forearm_length"
    case rightForearmLength = "right_forearm_length"
    case leftFemurLength = "left_femur_length"
    case rightFemurLength = "right_femur_length"
    case leftTibiaLength = "left_tibia_length"
    case rightTibiaLength = "right_tibia_length"
}

public enum BodyParameterProvenance: String, Codable, Sendable, Equatable, Hashable {
    case visionCalibration = "vision_calibration"
    case userMeasurement = "user_measurement"
    case importedMeasurement = "imported_measurement"
    case modelEstimated = "model_estimated"
}

public struct BodyParameterObservation: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        kind.rawValue + "|" + sourceID
    }

    public let kind: BodyParameterKind
    public let valueMeters: Double
    public let observedAt: Date
    public let provenance: BodyParameterProvenance
    public let sourceID: String
    public let uncertaintyMeters: Double?

    public init(
        kind: BodyParameterKind,
        valueMeters: Double,
        observedAt: Date,
        provenance: BodyParameterProvenance,
        sourceID: String,
        uncertaintyMeters: Double? = nil
    ) {
        self.kind = kind
        self.valueMeters = valueMeters
        self.observedAt = observedAt
        self.provenance = provenance
        self.sourceID = sourceID
        self.uncertaintyMeters = uncertaintyMeters
    }

    public var isValid: Bool {
        guard valueMeters.isFinite,
              valueMeters > 0
        else {
            return false
        }

        if let uncertaintyMeters {
            return uncertaintyMeters.isFinite
                && uncertaintyMeters >= 0
        }

        return true
    }
}

public struct PersonalBodyModel: Codable, Sendable, Equatable {
    public static let schemaVersion = "motionos.personal-body-model.v1"
    public static let canonicalRigID = "motionos.human-rig.v1"

    public let schemaVersion: String
    public let versionID: String
    public let canonicalRigID: String
    public let calibratedAt: Date
    public let parameters: [BodyParameterObservation]
    public let meshAssetRelativePath: String?
    public let claimBoundary: String

    public init(
        schemaVersion: String = Self.schemaVersion,
        versionID: String,
        canonicalRigID: String = Self.canonicalRigID,
        calibratedAt: Date,
        parameters: [BodyParameterObservation],
        meshAssetRelativePath: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.versionID = versionID
        self.canonicalRigID = canonicalRigID
        self.calibratedAt = calibratedAt
        self.parameters = parameters
        self.meshAssetRelativePath = meshAssetRelativePath
        self.claimBoundary = (
            "The Personal Body Model stores stable geometric calibration for "
                + "rendering and movement normalization. It does not infer "
                + "body composition, muscle force, injury risk, or medical "
                + "status. Daily weight and body-composition observations "
                + "belong in the longitudinal body-state timeline instead."
        )
    }

    public func parameter(
        _ kind: BodyParameterKind
    ) -> BodyParameterObservation? {
        parameters.first { $0.kind == kind }
    }
}

public enum PersonalBodyModelBuilder {
    public static func build(
        versionID: String,
        calibratedAt: Date,
        observations: [BodyParameterObservation],
        meshAssetRelativePath: String? = nil
    ) throws -> PersonalBodyModel {
        guard !versionID.isEmpty else {
            throw BuildError.emptyVersionID
        }

        let valid = observations.filter(\.isValid)
        guard valid.count == observations.count else {
            throw BuildError.invalidObservation
        }

        var latestByKind: [BodyParameterKind: BodyParameterObservation] = [:]
        for observation in observations {
            if let existing = latestByKind[observation.kind],
               existing.observedAt > observation.observedAt {
                continue
            }
            latestByKind[observation.kind] = observation
        }

        let parameters = BodyParameterKind.allCases.compactMap {
            latestByKind[$0]
        }

        guard !parameters.isEmpty else {
            throw BuildError.noParameters
        }

        return PersonalBodyModel(
            versionID: versionID,
            calibratedAt: calibratedAt,
            parameters: parameters,
            meshAssetRelativePath: meshAssetRelativePath
        )
    }

    public enum BuildError: LocalizedError, Equatable {
        case emptyVersionID
        case invalidObservation
        case noParameters

        public var errorDescription: String? {
            switch self {
            case .emptyVersionID:
                return "Body model version ID cannot be empty."
            case .invalidObservation:
                return "Body calibration contains an invalid geometric observation."
            case .noParameters:
                return "Body model requires at least one geometric parameter."
            }
        }
    }
}

import Foundation

public enum IndoBoardEquipmentModelQualificationStatus:
    String,
    Codable,
    Sendable,
    Equatable {
    case unqualified
    case evaluationOnly = "evaluation_only"
    case qualifiedForBetaTracking =
        "qualified_for_beta_tracking"
    case qualifiedForBetaCoaching =
        "qualified_for_beta_coaching"

    fileprivate var rank: Int {
        switch self {
        case .unqualified:
            0
        case .evaluationOnly:
            1
        case .qualifiedForBetaTracking:
            2
        case .qualifiedForBetaCoaching:
            3
        }
    }
}

public enum IndoBoardEquipmentUseIntent:
    String,
    Codable,
    Sendable,
    Equatable {
    case displayTracking = "display_tracking"
    case coachingEvidence = "coaching_evidence"
}

public struct IndoBoardEquipmentModelQualification:
    Codable,
    Sendable,
    Equatable,
    Identifiable {
    public static let schemaVersion =
        "motionos.indo-equipment-model-qualification.v1"

    public let schemaVersion: String
    public let modelID: String
    public let status:
        IndoBoardEquipmentModelQualificationStatus
    public let evaluationDatasetID: String?
    public let evaluationReferenceSHA256: String?
    public let metrics: [String: Double]
    public let claimBoundary: String

    public var id: String { modelID }

    public init(
        schemaVersion: String =
            IndoBoardEquipmentModelQualification.schemaVersion,
        modelID: String,
        status:
            IndoBoardEquipmentModelQualificationStatus,
        evaluationDatasetID: String? = nil,
        evaluationReferenceSHA256: String? = nil,
        metrics: [String: Double] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.status = status
        self.evaluationDatasetID = evaluationDatasetID
        self.evaluationReferenceSHA256 =
            evaluationReferenceSHA256
        self.metrics = metrics
        self.claimBoundary = (
            "Qualification authorizes only the declared MotionOS beta "
                + "equipment-tracking use. It does not establish metric "
                + "camera calibration, force, center-of-mass, medical, "
                + "or injury-risk validity."
        )
    }
}

public struct IndoBoardEquipmentDetectionCandidate:
    Sendable,
    Equatable {
    public let observation:
        IndoBoardEquipmentObservation
    public let detectorID: String

    public init(
        observation: IndoBoardEquipmentObservation,
        detectorID: String
    ) {
        self.observation = observation
        self.detectorID = detectorID
    }

    public var balanceState:
        IndoBoardBalanceState? {
        IndoBoardBalanceStateEstimator.estimate(
            from: observation
        )
    }

    public var confidence: Double {
        balanceState?.confidence ?? 0
    }
}

public enum IndoBoardEquipmentSelectionReason:
    String,
    Codable,
    Sendable,
    Equatable {
    case humanReviewedReference =
        "human_reviewed_reference"
    case fiducialMeasurement =
        "fiducial_measurement"
    case qualifiedMarkerlessModel =
        "qualified_markerless_model"
    case noCompleteObservation =
        "no_complete_observation"
    case noAuthorizedObservation =
        "no_authorized_observation"
}

public struct IndoBoardEquipmentSelection:
    Sendable,
    Equatable {
    public let selected:
        IndoBoardEquipmentDetectionCandidate?
    public let reason:
        IndoBoardEquipmentSelectionReason
    public let rejectedDetectorIDs: [String]

    public init(
        selected:
            IndoBoardEquipmentDetectionCandidate?,
        reason: IndoBoardEquipmentSelectionReason,
        rejectedDetectorIDs: [String]
    ) {
        self.selected = selected
        self.reason = reason
        self.rejectedDetectorIDs =
            rejectedDetectorIDs.sorted()
    }
}

public struct IndoBoardEquipmentObservationSelector:
    Sendable {
    private let qualificationByModelID:
        [String: IndoBoardEquipmentModelQualification]

    public init(
        qualifications:
            [IndoBoardEquipmentModelQualification] = []
    ) {
        var strongest:
            [String: IndoBoardEquipmentModelQualification] = [:]

        for qualification in qualifications {
            guard !qualification.modelID.isEmpty else {
                continue
            }

            if let existing =
                    strongest[qualification.modelID],
               existing.status.rank
                    >= qualification.status.rank {
                continue
            }

            strongest[qualification.modelID] =
                qualification
        }

        self.qualificationByModelID = strongest
    }

    public func select(
        _ candidates:
            [IndoBoardEquipmentDetectionCandidate],
        intent: IndoBoardEquipmentUseIntent
    ) -> IndoBoardEquipmentSelection {
        let complete = candidates.filter {
            $0.balanceState != nil
        }

        guard !complete.isEmpty else {
            return IndoBoardEquipmentSelection(
                selected: nil,
                reason: .noCompleteObservation,
                rejectedDetectorIDs:
                    candidates.map(\.detectorID)
            )
        }

        let humanReviewed = complete.filter {
            $0.balanceState?.provenance
                == .manualAnnotated
        }
        if let selected = strongest(
            humanReviewed
        ) {
            return result(
                selected,
                reason: .humanReviewedReference,
                from: candidates
            )
        }

        let fiducials = complete.filter {
            $0.balanceState?.provenance
                == .fiducialMeasured
        }
        if let selected = strongest(fiducials) {
            return result(
                selected,
                reason: .fiducialMeasurement,
                from: candidates
            )
        }

        let authorizedModels = complete.filter {
            candidate in
            guard candidate.balanceState?.provenance
                    == .modelEstimated,
                  let modelID =
                    candidate.observation.modelID,
                  let qualification =
                    qualificationByModelID[modelID]
            else {
                return false
            }

            switch intent {
            case .displayTracking:
                return qualification.status.rank
                    >= IndoBoardEquipmentModelQualificationStatus
                        .qualifiedForBetaTracking.rank
            case .coachingEvidence:
                return qualification.status.rank
                    >= IndoBoardEquipmentModelQualificationStatus
                        .qualifiedForBetaCoaching.rank
            }
        }

        if let selected = strongest(
            authorizedModels
        ) {
            return result(
                selected,
                reason: .qualifiedMarkerlessModel,
                from: candidates
            )
        }

        return IndoBoardEquipmentSelection(
            selected: nil,
            reason: .noAuthorizedObservation,
            rejectedDetectorIDs:
                complete.map(\.detectorID)
        )
    }

    private func strongest(
        _ candidates:
            [IndoBoardEquipmentDetectionCandidate]
    ) -> IndoBoardEquipmentDetectionCandidate? {
        candidates.max { first, second in
            if first.confidence
                == second.confidence {
                return first.detectorID
                    < second.detectorID
            }
            return first.confidence
                < second.confidence
        }
    }

    private func result(
        _ selected:
            IndoBoardEquipmentDetectionCandidate,
        reason: IndoBoardEquipmentSelectionReason,
        from all:
            [IndoBoardEquipmentDetectionCandidate]
    ) -> IndoBoardEquipmentSelection {
        IndoBoardEquipmentSelection(
            selected: selected,
            reason: reason,
            rejectedDetectorIDs:
                all
                    .filter {
                        $0.detectorID
                            != selected.detectorID
                    }
                    .map(\.detectorID)
        )
    }
}

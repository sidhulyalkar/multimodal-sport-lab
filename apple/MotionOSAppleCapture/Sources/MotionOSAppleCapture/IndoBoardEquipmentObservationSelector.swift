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
    public let evaluationReportSHA256: String?
    public let authorizationNote: String?
    public let metrics: [String: Double]
    public let claimBoundary: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case modelID = "model_id"
        case status
        case evaluationDatasetID =
            "evaluation_dataset_id"
        case evaluationReportSHA256 =
            "evaluation_report_sha256"
        case authorizationNote =
            "authorization_note"
        case metrics
        case claimBoundary = "claim_boundary"
    }

    public var id: String { modelID }

    fileprivate var hasCompleteAuthorizationReceipt: Bool {
        guard let datasetID = evaluationDatasetID?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
              !datasetID.isEmpty,
              let reportHash = evaluationReportSHA256?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
              reportHash.count == 64,
              reportHash.allSatisfy({
                  $0.isHexDigit
              }),
              let note = authorizationNote?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
              !note.isEmpty
        else {
            return false
        }

        return true
    }

    fileprivate var effectiveAuthorizationRank: Int {
        guard status.rank
                >= IndoBoardEquipmentModelQualificationStatus
                    .qualifiedForBetaTracking.rank
        else {
            return status.rank
        }

        return hasCompleteAuthorizationReceipt
            ? status.rank
            : IndoBoardEquipmentModelQualificationStatus
                .evaluationOnly.rank
    }

    fileprivate func authorizes(
        _ intent: IndoBoardEquipmentUseIntent
    ) -> Bool {
        switch intent {
        case .displayTracking:
            return effectiveAuthorizationRank
                >= IndoBoardEquipmentModelQualificationStatus
                    .qualifiedForBetaTracking.rank
        case .coachingEvidence:
            return effectiveAuthorizationRank
                >= IndoBoardEquipmentModelQualificationStatus
                    .qualifiedForBetaCoaching.rank
        }
    }

    public init(
        schemaVersion: String =
            IndoBoardEquipmentModelQualification.schemaVersion,
        modelID: String,
        status:
            IndoBoardEquipmentModelQualificationStatus,
        evaluationDatasetID: String? = nil,
        evaluationReportSHA256: String? = nil,
        authorizationNote: String? = nil,
        metrics: [String: Double] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.status = status
        self.evaluationDatasetID = evaluationDatasetID
        self.evaluationReportSHA256 =
            evaluationReportSHA256
        self.authorizationNote = authorizationNote
        self.metrics = metrics
        self.claimBoundary = (
            "Qualification authorizes only the declared MotionOS beta "
                + "equipment-tracking use. It does not establish metric "
                + "camera calibration, force, center-of-mass, medical, "
                + "or injury-risk validity."
        )
    }
}

public struct IndoBoardEquipmentModelQualificationRegistry:
    Codable,
    Sendable,
    Equatable {
    public static let schemaVersion =
        "motionos.indo-equipment-model-qualification-registry.v1"

    public let schemaVersion: String
    public let qualifications:
        [IndoBoardEquipmentModelQualification]
    public let claimBoundary: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case qualifications
        case claimBoundary = "claim_boundary"
    }

    public init(
        schemaVersion: String =
            IndoBoardEquipmentModelQualificationRegistry
                .schemaVersion,
        qualifications:
            [IndoBoardEquipmentModelQualification]
    ) {
        self.schemaVersion = schemaVersion
        self.qualifications = qualifications
        self.claimBoundary = (
            "This registry is an explicit runtime authorization boundary. "
                + "Absence from the registry must fail closed rather than "
                + "silently authorizing a markerless model."
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

public struct IndoBoardEquipmentSelectionReceipt:
    Codable,
    Sendable,
    Equatable {
    public static let schemaVersion =
        "motionos.indo-equipment-selection-receipt.v1"

    public let schemaVersion: String
    public let intent: IndoBoardEquipmentUseIntent
    public let reason:
        IndoBoardEquipmentSelectionReason
    public let selectedDetectorID: String?
    public let selectedModelID: String?
    public let selectedProvenance:
        IndoBoardEquipmentProvenance?
    public let selectedConfidence: Double?
    public let rejectedDetectorIDs: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case intent
        case reason
        case selectedDetectorID =
            "selected_detector_id"
        case selectedModelID =
            "selected_model_id"
        case selectedProvenance =
            "selected_provenance"
        case selectedConfidence =
            "selected_confidence"
        case rejectedDetectorIDs =
            "rejected_detector_ids"
    }

    public init(
        schemaVersion: String =
            IndoBoardEquipmentSelectionReceipt.schemaVersion,
        intent: IndoBoardEquipmentUseIntent,
        reason: IndoBoardEquipmentSelectionReason,
        selectedDetectorID: String?,
        selectedModelID: String?,
        selectedProvenance:
            IndoBoardEquipmentProvenance?,
        selectedConfidence: Double?,
        rejectedDetectorIDs: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.intent = intent
        self.reason = reason
        self.selectedDetectorID = selectedDetectorID
        self.selectedModelID = selectedModelID
        self.selectedProvenance = selectedProvenance
        self.selectedConfidence =
            selectedConfidence.map {
                min(1, max(0, $0))
            }
        self.rejectedDetectorIDs =
            rejectedDetectorIDs.sorted()
    }
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

    public func receipt(
        intent: IndoBoardEquipmentUseIntent
    ) -> IndoBoardEquipmentSelectionReceipt {
        IndoBoardEquipmentSelectionReceipt(
            intent: intent,
            reason: reason,
            selectedDetectorID:
                selected?.detectorID,
            selectedModelID:
                selected?.observation.modelID,
            selectedProvenance:
                selected?.balanceState?.provenance,
            selectedConfidence:
                selected?.confidence,
            rejectedDetectorIDs:
                rejectedDetectorIDs
        )
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
               existing.effectiveAuthorizationRank
                    >= qualification.effectiveAuthorizationRank {
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

            return qualification.authorizes(
                intent
            )
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

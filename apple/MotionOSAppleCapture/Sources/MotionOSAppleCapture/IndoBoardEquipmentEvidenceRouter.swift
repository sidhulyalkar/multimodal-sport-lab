import Foundation

public struct IndoBoardEquipmentCandidateAudit:
    Codable,
    Sendable,
    Equatable {
    public let detectorID: String
    public let modelID: String?
    public let provenance:
        IndoBoardEquipmentProvenance?
    public let confidence: Double
    public let isComplete: Bool

    enum CodingKeys: String, CodingKey {
        case detectorID = "detector_id"
        case modelID = "model_id"
        case provenance
        case confidence
        case isComplete = "is_complete"
    }

    public init(
        detectorID: String,
        modelID: String?,
        provenance:
            IndoBoardEquipmentProvenance?,
        confidence: Double,
        isComplete: Bool
    ) {
        self.detectorID = detectorID
        self.modelID = modelID
        self.provenance = provenance
        self.confidence = min(1, max(0, confidence))
        self.isComplete = isComplete
    }
}

public struct IndoBoardEquipmentRoutingAudit:
    Codable,
    Sendable,
    Equatable {
    public static let schemaVersion =
        "motionos.indo-equipment-routing-audit.v1"

    public let schemaVersion: String
    public let tracking:
        IndoBoardEquipmentSelectionReceipt
    public let coaching:
        IndoBoardEquipmentSelectionReceipt
    public let candidates:
        [IndoBoardEquipmentCandidateAudit]
    public let claimBoundary: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case tracking
        case coaching
        case candidates
        case claimBoundary = "claim_boundary"
    }

    public init(
        schemaVersion: String =
            IndoBoardEquipmentRoutingAudit.schemaVersion,
        tracking:
            IndoBoardEquipmentSelectionReceipt,
        coaching:
            IndoBoardEquipmentSelectionReceipt,
        candidates:
            [IndoBoardEquipmentCandidateAudit]
    ) {
        self.schemaVersion = schemaVersion
        self.tracking = tracking
        self.coaching = coaching
        self.candidates = candidates
        self.claimBoundary = (
            "Routing records which equipment source was eligible for "
                + "display and which source was eligible for coaching. "
                + "A display-authorized model is not automatically "
                + "authorized to influence coaching."
        )
    }

    public var cameraPayload: JSONValue {
        .object([
            "schema_version": .string(schemaVersion),
            "tracking": receiptJSON(tracking),
            "coaching": receiptJSON(coaching),
            "candidates": .array(
                candidates.map(candidateJSON)
            ),
            "claim_boundary": .string(claimBoundary),
        ])
    }

    private func receiptJSON(
        _ receipt: IndoBoardEquipmentSelectionReceipt
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "schema_version":
                .string(receipt.schemaVersion),
            "intent":
                .string(receipt.intent.rawValue),
            "reason":
                .string(receipt.reason.rawValue),
            "rejected_detector_ids":
                .array(
                    receipt.rejectedDetectorIDs.map {
                        .string($0)
                    }
                ),
        ]

        if let value = receipt.selectedDetectorID {
            object["selected_detector_id"] =
                .string(value)
        }
        if let value = receipt.selectedModelID {
            object["selected_model_id"] =
                .string(value)
        }
        if let value = receipt.selectedProvenance {
            object["selected_provenance"] =
                .string(value.rawValue)
        }
        if let value = receipt.selectedConfidence {
            object["selected_confidence"] =
                .number(value)
        }

        return .object(object)
    }

    private func candidateJSON(
        _ candidate: IndoBoardEquipmentCandidateAudit
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "detector_id": .string(candidate.detectorID),
            "confidence": .number(candidate.confidence),
            "is_complete": .bool(candidate.isComplete),
        ]

        if let value = candidate.modelID {
            object["model_id"] = .string(value)
        }
        if let value = candidate.provenance {
            object["provenance"] =
                .string(value.rawValue)
        }

        return .object(object)
    }
}

public struct IndoBoardEquipmentRoutingResult:
    Sendable,
    Equatable {
    public let tracking:
        IndoBoardEquipmentSelection
    public let coaching:
        IndoBoardEquipmentSelection
    public let audit:
        IndoBoardEquipmentRoutingAudit

    public init(
        tracking:
            IndoBoardEquipmentSelection,
        coaching:
            IndoBoardEquipmentSelection,
        audit:
            IndoBoardEquipmentRoutingAudit
    ) {
        self.tracking = tracking
        self.coaching = coaching
        self.audit = audit
    }
}

public struct IndoBoardEquipmentEvidenceRouter:
    Sendable {
    private let selector:
        IndoBoardEquipmentObservationSelector

    public init(
        registry:
            IndoBoardEquipmentModelQualificationRegistry? = nil
    ) {
        let qualifications:
            [IndoBoardEquipmentModelQualification]

        if let registry,
           registry.schemaVersion
                == IndoBoardEquipmentModelQualificationRegistry
                    .schemaVersion {
            qualifications =
                registry.qualifications
        } else {
            qualifications = []
        }

        self.selector =
            IndoBoardEquipmentObservationSelector(
                qualifications:
                    qualifications
            )
    }

    public func route(
        _ candidates:
            [IndoBoardEquipmentDetectionCandidate]
    ) -> IndoBoardEquipmentRoutingResult {
        let tracking = selector.select(
            candidates,
            intent: .displayTracking
        )
        let coaching = selector.select(
            candidates,
            intent: .coachingEvidence
        )

        let audits = candidates
            .map { candidate in
                let state =
                    candidate.balanceState
                return IndoBoardEquipmentCandidateAudit(
                    detectorID:
                        candidate.detectorID,
                    modelID:
                        candidate.observation.modelID,
                    provenance:
                        state?.provenance,
                    confidence:
                        candidate.confidence,
                    isComplete:
                        state != nil
                )
            }
            .sorted {
                $0.detectorID < $1.detectorID
            }

        let audit =
            IndoBoardEquipmentRoutingAudit(
                tracking:
                    tracking.receipt(
                        intent: .displayTracking
                    ),
                coaching:
                    coaching.receipt(
                        intent: .coachingEvidence
                    ),
                candidates: audits
            )

        return IndoBoardEquipmentRoutingResult(
            tracking: tracking,
            coaching: coaching,
            audit: audit
        )
    }
}

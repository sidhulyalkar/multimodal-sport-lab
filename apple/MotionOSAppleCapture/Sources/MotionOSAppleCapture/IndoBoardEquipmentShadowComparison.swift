import Foundation

public struct IndoBoardEquipmentShadowComparison:
    Codable,
    Sendable,
    Equatable {
    public static let schemaVersion =
        "motionos.indo-equipment-shadow-comparison.v1"

    public let schemaVersion: String
    public let referenceDetectorID: String
    public let candidateDetectorID: String
    public let candidateModelID: String?
    public let deckLeftError: Double
    public let deckRightError: Double
    public let deckEndpointMeanError: Double
    public let rollerCenterError: Double
    public let rollerAlongReferenceDeckAbsError: Double
    public let centerZoneAgreement: Bool
    public let edgeZoneAgreement: Bool
    public let referenceConfidence: Double
    public let candidateConfidence: Double
    public let claimBoundary: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case referenceDetectorID =
            "reference_detector_id"
        case candidateDetectorID =
            "candidate_detector_id"
        case candidateModelID =
            "candidate_model_id"
        case deckLeftError =
            "deck_left_error"
        case deckRightError =
            "deck_right_error"
        case deckEndpointMeanError =
            "deck_endpoint_mean_error"
        case rollerCenterError =
            "roller_center_error"
        case rollerAlongReferenceDeckAbsError =
            "roller_along_reference_deck_abs_error"
        case centerZoneAgreement =
            "center_zone_agreement"
        case edgeZoneAgreement =
            "edge_zone_agreement"
        case referenceConfidence =
            "reference_confidence"
        case candidateConfidence =
            "candidate_confidence"
        case claimBoundary = "claim_boundary"
    }

    public init(
        referenceDetectorID: String,
        candidateDetectorID: String,
        candidateModelID: String?,
        deckLeftError: Double,
        deckRightError: Double,
        deckEndpointMeanError: Double,
        rollerCenterError: Double,
        rollerAlongReferenceDeckAbsError: Double,
        centerZoneAgreement: Bool,
        edgeZoneAgreement: Bool,
        referenceConfidence: Double,
        candidateConfidence: Double
    ) {
        self.schemaVersion = Self.schemaVersion
        self.referenceDetectorID =
            referenceDetectorID
        self.candidateDetectorID =
            candidateDetectorID
        self.candidateModelID =
            candidateModelID
        self.deckLeftError =
            max(0, deckLeftError)
        self.deckRightError =
            max(0, deckRightError)
        self.deckEndpointMeanError =
            max(0, deckEndpointMeanError)
        self.rollerCenterError =
            max(0, rollerCenterError)
        self.rollerAlongReferenceDeckAbsError =
            max(
                0,
                rollerAlongReferenceDeckAbsError
            )
        self.centerZoneAgreement =
            centerZoneAgreement
        self.edgeZoneAgreement =
            edgeZoneAgreement
        self.referenceConfidence =
            min(1, max(0, referenceConfidence))
        self.candidateConfidence =
            min(1, max(0, candidateConfidence))
        self.claimBoundary = (
            "Shadow comparison is normalized image-space agreement against "
                + "a trusted reference observation. It is detector "
                + "evaluation evidence, not calibrated biomechanics."
        )
    }

    public var cameraPayload: JSONValue {
        var object: [String: JSONValue] = [
            "schema_version":
                .string(schemaVersion),
            "reference_detector_id":
                .string(referenceDetectorID),
            "candidate_detector_id":
                .string(candidateDetectorID),
            "deck_left_error":
                .number(deckLeftError),
            "deck_right_error":
                .number(deckRightError),
            "deck_endpoint_mean_error":
                .number(deckEndpointMeanError),
            "roller_center_error":
                .number(rollerCenterError),
            "roller_along_reference_deck_abs_error":
                .number(
                    rollerAlongReferenceDeckAbsError
                ),
            "center_zone_agreement":
                .bool(centerZoneAgreement),
            "edge_zone_agreement":
                .bool(edgeZoneAgreement),
            "reference_confidence":
                .number(referenceConfidence),
            "candidate_confidence":
                .number(candidateConfidence),
            "claim_boundary":
                .string(claimBoundary),
        ]

        if let candidateModelID {
            object["candidate_model_id"] =
                .string(candidateModelID)
        }

        return .object(object)
    }
}

public enum IndoBoardEquipmentShadowComparator {
    public static func compare(
        reference:
            IndoBoardEquipmentDetectionCandidate,
        candidate:
            IndoBoardEquipmentDetectionCandidate
    ) -> IndoBoardEquipmentShadowComparison? {
        guard let referenceDeck =
                reference.observation.deck,
              let referenceRoller =
                reference.observation.roller,
              let candidateDeck =
                candidate.observation.deck,
              let candidateRoller =
                candidate.observation.roller,
              let referenceState =
                reference.balanceState,
              let candidateState =
                candidate.balanceState
        else {
            return nil
        }

        let leftError = distance(
            referenceDeck.leftEnd,
            candidateDeck.leftEnd
        )
        let rightError = distance(
            referenceDeck.rightEnd,
            candidateDeck.rightEnd
        )
        let rollerCenterError = distance(
            referenceRoller.center,
            candidateRoller.center
        )

        guard let candidateAlongReference =
                rollerAlongReferenceDeck(
                    deckLeft:
                        referenceDeck.leftEnd,
                    deckRight:
                        referenceDeck.rightEnd,
                    roller:
                        candidateRoller.center
                )
        else {
            return nil
        }

        let referenceAlong =
            referenceState.rollerAlongDeck

        return IndoBoardEquipmentShadowComparison(
            referenceDetectorID:
                reference.detectorID,
            candidateDetectorID:
                candidate.detectorID,
            candidateModelID:
                candidate.observation.modelID,
            deckLeftError: leftError,
            deckRightError: rightError,
            deckEndpointMeanError:
                (leftError + rightError) / 2,
            rollerCenterError:
                rollerCenterError,
            rollerAlongReferenceDeckAbsError:
                abs(
                    candidateAlongReference
                        - referenceAlong
                ),
            centerZoneAgreement:
                (
                    abs(referenceAlong)
                        <= IndoBoardBalanceThresholds
                            .centerZone
                )
                == (
                    abs(candidateAlongReference)
                        <= IndoBoardBalanceThresholds
                            .centerZone
                ),
            edgeZoneAgreement:
                (
                    abs(referenceAlong)
                        >= IndoBoardBalanceThresholds
                            .edgeZone
                )
                == (
                    abs(candidateAlongReference)
                        >= IndoBoardBalanceThresholds
                            .edgeZone
                ),
            referenceConfidence:
                referenceState.confidence,
            candidateConfidence:
                candidateState.confidence
        )
    }

    private static func distance(
        _ first: NormalizedImagePoint2D,
        _ second: NormalizedImagePoint2D
    ) -> Double {
        hypot(
            first.x - second.x,
            first.y - second.y
        )
    }

    private static func rollerAlongReferenceDeck(
        deckLeft: NormalizedImagePoint2D,
        deckRight: NormalizedImagePoint2D,
        roller: NormalizedImagePoint2D
    ) -> Double? {
        let dx =
            deckRight.x - deckLeft.x
        let dy =
            deckRight.y - deckLeft.y
        let lengthSquared =
            dx * dx + dy * dy

        guard lengthSquared > 1e-6 else {
            return nil
        }

        let relX =
            roller.x - deckLeft.x
        let relY =
            roller.y - deckLeft.y
        let projection =
            (relX * dx + relY * dy)
                / lengthSquared

        return (projection - 0.5) * 2
    }
}

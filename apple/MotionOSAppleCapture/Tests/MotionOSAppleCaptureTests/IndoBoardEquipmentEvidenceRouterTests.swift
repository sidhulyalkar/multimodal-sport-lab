import XCTest
@testable import MotionOSAppleCapture

final class IndoBoardEquipmentEvidenceRouterTests:
    XCTestCase {
    func testTrackingCanUseModelWhileCoachingFailsClosed() {
        let registry =
            IndoBoardEquipmentModelQualificationRegistry(
                qualifications: [
                    qualification(
                        status:
                            .qualifiedForBetaTracking
                    ),
                ]
            )
        let router =
            IndoBoardEquipmentEvidenceRouter(
                registry: registry
            )

        let result = router.route([
            modelCandidate(confidence: 0.91),
        ])

        XCTAssertEqual(
            result.tracking.selected?.detectorID,
            "markerless"
        )
        XCTAssertNil(result.coaching.selected)
        XCTAssertEqual(
            result.audit.tracking.reason,
            .qualifiedMarkerlessModel
        )
        XCTAssertEqual(
            result.audit.coaching.reason,
            .noAuthorizedObservation
        )
    }

    func testFiducialWinsBothPaths() {
        let registry =
            IndoBoardEquipmentModelQualificationRegistry(
                qualifications: [
                    qualification(
                        status:
                            .qualifiedForBetaCoaching
                    ),
                ]
            )
        let router =
            IndoBoardEquipmentEvidenceRouter(
                registry: registry
            )

        let result = router.route([
            modelCandidate(confidence: 0.99),
            fiducialCandidate(confidence: 0.76),
        ])

        XCTAssertEqual(
            result.tracking.selected?.detectorID,
            "qr"
        )
        XCTAssertEqual(
            result.coaching.selected?.detectorID,
            "qr"
        )
        XCTAssertEqual(
            result.audit.candidates.count,
            2
        )
    }

    func testUnknownRegistrySchemaFailsClosedForModel() {
        let registry =
            IndoBoardEquipmentModelQualificationRegistry(
                schemaVersion: "future-schema",
                qualifications: [
                    qualification(
                        status:
                            .qualifiedForBetaCoaching
                    ),
                ]
            )
        let router =
            IndoBoardEquipmentEvidenceRouter(
                registry: registry
            )

        let result = router.route([
            modelCandidate(confidence: 0.99),
        ])

        XCTAssertNil(result.tracking.selected)
        XCTAssertNil(result.coaching.selected)
        XCTAssertEqual(
            result.audit.tracking.reason,
            .noAuthorizedObservation
        )
    }

    func testRoutingAuditCameraPayloadContainsBothIntents() {
        let router =
            IndoBoardEquipmentEvidenceRouter()
        let result = router.route([
            fiducialCandidate(confidence: 0.88),
        ])

        guard case .object(let payload) =
                result.audit.cameraPayload,
              case .object(let tracking) =
                payload["tracking"],
              case .object(let coaching) =
                payload["coaching"],
              case .array(let candidates) =
                payload["candidates"]
        else {
            XCTFail("Expected routing audit JSON object")
            return
        }

        XCTAssertEqual(
            tracking["intent"],
            .string("display_tracking")
        )
        XCTAssertEqual(
            coaching["intent"],
            .string("coaching_evidence")
        )
        XCTAssertEqual(candidates.count, 1)
    }

    func testIncompleteCandidateIsPreservedInAudit() {
        let incomplete =
            IndoBoardEquipmentDetectionCandidate(
                observation:
                    IndoBoardEquipmentObservation(
                        sequence: 1,
                        deviceTimeNS: 1,
                        deck: deck(
                            provenance:
                                .modelEstimated,
                            confidence: 0.9
                        ),
                        roller: nil,
                        modelID: "markerless-v1"
                    ),
                detectorID: "markerless"
            )

        let result =
            IndoBoardEquipmentEvidenceRouter()
                .route([incomplete])

        XCTAssertNil(result.tracking.selected)
        XCTAssertEqual(
            result.audit.candidates.first?.isComplete,
            false
        )
        XCTAssertEqual(
            result.audit.tracking.reason,
            .noCompleteObservation
        )
    }

    private func qualification(
        status:
            IndoBoardEquipmentModelQualificationStatus
    ) -> IndoBoardEquipmentModelQualification {
        IndoBoardEquipmentModelQualification(
            modelID: "markerless-v1",
            status: status,
            evaluationDatasetID: "heldout-v1",
            evaluationReportSHA256:
                String(repeating: "a", count: 64),
            authorizationNote:
                "Approved for beta test fixture.",
            metrics: [
                "reference_coverage_fraction": 0.95,
            ]
        )
    }

    private func modelCandidate(
        confidence: Double
    ) -> IndoBoardEquipmentDetectionCandidate {
        candidate(
            detectorID: "markerless",
            modelID: "markerless-v1",
            provenance: .modelEstimated,
            confidence: confidence
        )
    }

    private func fiducialCandidate(
        confidence: Double
    ) -> IndoBoardEquipmentDetectionCandidate {
        candidate(
            detectorID: "qr",
            modelID:
                IndoBoardFiducialEquipmentBuilder.modelID,
            provenance: .fiducialMeasured,
            confidence: confidence
        )
    }

    private func candidate(
        detectorID: String,
        modelID: String,
        provenance: IndoBoardEquipmentProvenance,
        confidence: Double
    ) -> IndoBoardEquipmentDetectionCandidate {
        IndoBoardEquipmentDetectionCandidate(
            observation: IndoBoardEquipmentObservation(
                sequence: 1,
                deviceTimeNS: 1,
                deck: deck(
                    provenance: provenance,
                    confidence: confidence
                ),
                roller: IndoBoardRollerObservation(
                    center: .init(
                        x: 0.5,
                        y: 0.7
                    ),
                    confidence: confidence,
                    provenance: provenance
                ),
                modelID: modelID
            ),
            detectorID: detectorID
        )
    }

    private func deck(
        provenance: IndoBoardEquipmentProvenance,
        confidence: Double
    ) -> IndoBoardDeckObservation {
        IndoBoardDeckObservation(
            polygon: [],
            leftEnd: .init(
                x: 0.2,
                y: 0.7
            ),
            rightEnd: .init(
                x: 0.8,
                y: 0.7
            ),
            confidence: confidence,
            provenance: provenance
        )
    }
}

import XCTest
@testable import MotionOSAppleCapture

final class IndoBoardEquipmentObservationSelectorTests:
    XCTestCase {
    func testFiducialMeasurementBeatsQualifiedModel() {
        let selector = IndoBoardEquipmentObservationSelector(
            qualifications: [
                qualification(
                    modelID: "markerless-v1",
                    status: .qualifiedForBetaCoaching
                ),
            ]
        )

        let result = selector.select(
            [
                candidate(
                    detectorID: "markerless",
                    modelID: "markerless-v1",
                    provenance: .modelEstimated,
                    confidence: 0.98
                ),
                candidate(
                    detectorID: "qr",
                    modelID:
                        IndoBoardFiducialEquipmentBuilder.modelID,
                    provenance: .fiducialMeasured,
                    confidence: 0.82
                ),
            ],
            intent: .coachingEvidence
        )

        XCTAssertEqual(
            result.selected?.detectorID,
            "qr"
        )
        XCTAssertEqual(
            result.reason,
            .fiducialMeasurement
        )
    }

    func testTrackingQualificationDoesNotAuthorizeCoaching() {
        let selector = IndoBoardEquipmentObservationSelector(
            qualifications: [
                qualification(
                    modelID: "markerless-v1",
                    status: .qualifiedForBetaTracking
                ),
            ]
        )
        let input = [
            candidate(
                detectorID: "markerless",
                modelID: "markerless-v1",
                provenance: .modelEstimated,
                confidence: 0.91
            ),
        ]

        let display = selector.select(
            input,
            intent: .displayTracking
        )
        let coaching = selector.select(
            input,
            intent: .coachingEvidence
        )

        XCTAssertEqual(
            display.selected?.detectorID,
            "markerless"
        )
        XCTAssertEqual(
            display.reason,
            .qualifiedMarkerlessModel
        )
        XCTAssertNil(coaching.selected)
        XCTAssertEqual(
            coaching.reason,
            .noAuthorizedObservation
        )
    }

    func testQualifiedStatusWithoutReceiptStillFailsClosed() {
        let incomplete =
            IndoBoardEquipmentModelQualification(
                modelID: "markerless-v1",
                status: .qualifiedForBetaCoaching,
                evaluationDatasetID: "indo-heldout-v1",
                evaluationReportSHA256:
                    String(repeating: "a", count: 64),
                authorizationNote: nil
            )
        let selector = IndoBoardEquipmentObservationSelector(
            qualifications: [incomplete]
        )

        let result = selector.select(
            [
                candidate(
                    detectorID: "markerless",
                    modelID: "markerless-v1",
                    provenance: .modelEstimated,
                    confidence: 0.99
                ),
            ],
            intent: .coachingEvidence
        )

        XCTAssertNil(result.selected)
        XCTAssertEqual(
            result.reason,
            .noAuthorizedObservation
        )
    }

    func testMalformedEvaluationHashFailsClosed() {
        let incomplete =
            IndoBoardEquipmentModelQualification(
                modelID: "markerless-v1",
                status: .qualifiedForBetaTracking,
                evaluationDatasetID: "indo-heldout-v1",
                evaluationReportSHA256: "not-a-sha256",
                authorizationNote:
                    "Approved after review."
            )
        let selector = IndoBoardEquipmentObservationSelector(
            qualifications: [incomplete]
        )

        let result = selector.select(
            [
                candidate(
                    detectorID: "markerless",
                    modelID: "markerless-v1",
                    provenance: .modelEstimated,
                    confidence: 0.99
                ),
            ],
            intent: .displayTracking
        )

        XCTAssertNil(result.selected)
        XCTAssertEqual(
            result.reason,
            .noAuthorizedObservation
        )
    }

    func testEvaluationOnlyModelFailsClosed() {
        let selector = IndoBoardEquipmentObservationSelector(
            qualifications: [
                qualification(
                    modelID: "markerless-v1",
                    status: .evaluationOnly
                ),
            ]
        )

        let result = selector.select(
            [
                candidate(
                    detectorID: "markerless",
                    modelID: "markerless-v1",
                    provenance: .modelEstimated,
                    confidence: 0.99
                ),
            ],
            intent: .displayTracking
        )

        XCTAssertNil(result.selected)
        XCTAssertEqual(
            result.reason,
            .noAuthorizedObservation
        )
    }

    func testIncompleteFiducialDoesNotBlockQualifiedModel() {
        let selector = IndoBoardEquipmentObservationSelector(
            qualifications: [
                qualification(
                    modelID: "markerless-v1",
                    status: .qualifiedForBetaCoaching
                ),
            ]
        )

        let incomplete = IndoBoardEquipmentObservation(
            sequence: 1,
            deviceTimeNS: 1,
            deck: deck(
                provenance: .fiducialMeasured,
                confidence: 0.99
            ),
            roller: nil,
            modelID:
                IndoBoardFiducialEquipmentBuilder.modelID
        )

        let result = selector.select(
            [
                .init(
                    observation: incomplete,
                    detectorID: "qr"
                ),
                candidate(
                    detectorID: "markerless",
                    modelID: "markerless-v1",
                    provenance: .modelEstimated,
                    confidence: 0.88
                ),
            ],
            intent: .coachingEvidence
        )

        XCTAssertEqual(
            result.selected?.detectorID,
            "markerless"
        )
        XCTAssertEqual(
            result.reason,
            .qualifiedMarkerlessModel
        )
    }

    func testHumanReviewedReferenceWinsOffline() {
        let selector = IndoBoardEquipmentObservationSelector(
            qualifications: []
        )

        let result = selector.select(
            [
                candidate(
                    detectorID: "reviewed",
                    modelID: "human",
                    provenance: .manualAnnotated,
                    confidence: 0.75
                ),
                candidate(
                    detectorID: "qr",
                    modelID: "qr",
                    provenance: .fiducialMeasured,
                    confidence: 0.99
                ),
            ],
            intent: .coachingEvidence
        )

        XCTAssertEqual(
            result.selected?.detectorID,
            "reviewed"
        )
        XCTAssertEqual(
            result.reason,
            .humanReviewedReference
        )
    }

    func testNoCompleteObservationFailsClosed() {
        let selector = IndoBoardEquipmentObservationSelector()

        let input = IndoBoardEquipmentDetectionCandidate(
            observation: IndoBoardEquipmentObservation(
                sequence: 1,
                deviceTimeNS: 1,
                deck: nil,
                roller: roller(
                    provenance: .modelEstimated,
                    confidence: 0.9
                ),
                modelID: "markerless-v1"
            ),
            detectorID: "markerless"
        )

        let result = selector.select(
            [input],
            intent: .displayTracking
        )

        XCTAssertNil(result.selected)
        XCTAssertEqual(
            result.reason,
            .noCompleteObservation
        )
    }

    func testSelectionReceiptPreservesEvidenceDecision() {
        let selector = IndoBoardEquipmentObservationSelector(
            qualifications: [
                qualification(
                    modelID: "markerless-v1",
                    status: .qualifiedForBetaTracking
                ),
            ]
        )

        let selection = selector.select(
            [
                candidate(
                    detectorID: "markerless",
                    modelID: "markerless-v1",
                    provenance: .modelEstimated,
                    confidence: 0.87
                ),
            ],
            intent: .displayTracking
        )
        let receipt = selection.receipt(
            intent: .displayTracking
        )

        XCTAssertEqual(
            receipt.selectedDetectorID,
            "markerless"
        )
        XCTAssertEqual(
            receipt.selectedModelID,
            "markerless-v1"
        )
        XCTAssertEqual(
            receipt.selectedProvenance,
            .modelEstimated
        )
        XCTAssertEqual(
            receipt.reason,
            .qualifiedMarkerlessModel
        )
        XCTAssertEqual(
            receipt.selectedConfidence ?? 0,
            0.87,
            accuracy: 0.001
        )
    }

    func testDuplicateQualificationsKeepStrongestAuthorization() {
        let selector = IndoBoardEquipmentObservationSelector(
            qualifications: [
                qualification(
                    modelID: "markerless-v1",
                    status: .evaluationOnly
                ),
                qualification(
                    modelID: "markerless-v1",
                    status: .qualifiedForBetaTracking
                ),
            ]
        )

        let result = selector.select(
            [
                candidate(
                    detectorID: "markerless",
                    modelID: "markerless-v1",
                    provenance: .modelEstimated,
                    confidence: 0.90
                ),
            ],
            intent: .displayTracking
        )

        XCTAssertNotNil(result.selected)
        XCTAssertEqual(
            result.reason,
            .qualifiedMarkerlessModel
        )
    }

    func testQualificationRegistryRoundTrips() throws {
        let registry =
            IndoBoardEquipmentModelQualificationRegistry(
                qualifications: [
                    qualification(
                        modelID: "markerless-v1",
                        status:
                            .qualifiedForBetaTracking
                    ),
                ]
            )

        let data = try JSONEncoder().encode(registry)
        let decoded = try JSONDecoder().decode(
            IndoBoardEquipmentModelQualificationRegistry.self,
            from: data
        )

        XCTAssertEqual(decoded, registry)
        XCTAssertEqual(
            decoded.qualifications.first?.modelID,
            "markerless-v1"
        )
    }

    func testSnakeCaseResearchRegistryDecodesIntoRuntime() throws {
        let json = """
        {
          "schema_version": "motionos.indo-equipment-model-qualification-registry.v1",
          "qualifications": [
            {
              "schema_version": "motionos.indo-equipment-model-qualification.v1",
              "model_id": "indo-equipment-v1",
              "status": "qualified_for_beta_tracking",
              "evaluation_dataset_id": "indo-heldout-2026-10",
              "evaluation_report_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "authorization_note": "Approved after held-out review.",
              "metrics": {
                "reference_coverage_fraction": 0.96,
                "roller_center_error_p90": 0.03
              },
              "claim_boundary": "runtime authorization boundary"
            }
          ],
          "claim_boundary": "registry authorization boundary"
        }
        """

        let registry = try JSONDecoder().decode(
            IndoBoardEquipmentModelQualificationRegistry.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(
            registry.qualifications.first?.modelID,
            "indo-equipment-v1"
        )
        XCTAssertEqual(
            registry.qualifications.first?.status,
            .qualifiedForBetaTracking
        )
        XCTAssertEqual(
            registry.qualifications.first?.authorizationNote,
            "Approved after held-out review."
        )

        let selector = IndoBoardEquipmentObservationSelector(
            qualifications: registry.qualifications
        )
        let result = selector.select(
            [
                candidate(
                    detectorID: "markerless",
                    modelID: "indo-equipment-v1",
                    provenance: .modelEstimated,
                    confidence: 0.88
                ),
            ],
            intent: .displayTracking
        )

        XCTAssertEqual(
            result.reason,
            .qualifiedMarkerlessModel
        )
        XCTAssertNotNil(result.selected)
    }

    private func qualification(
        modelID: String,
        status:
            IndoBoardEquipmentModelQualificationStatus
    ) -> IndoBoardEquipmentModelQualification {
        IndoBoardEquipmentModelQualification(
            modelID: modelID,
            status: status,
            evaluationDatasetID:
                "indo-heldout-v1",
            evaluationReportSHA256:
                String(repeating: "a", count: 64),
            authorizationNote:
                status == .qualifiedForBetaTracking
                    || status == .qualifiedForBetaCoaching
                    ? "Approved after held-out physical beta review."
                    : nil,
            metrics: [
                "roller_center_error_p90": 0.03,
            ]
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
                roller: roller(
                    provenance: provenance,
                    confidence: confidence
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

    private func roller(
        provenance: IndoBoardEquipmentProvenance,
        confidence: Double
    ) -> IndoBoardRollerObservation {
        IndoBoardRollerObservation(
            center: .init(
                x: 0.5,
                y: 0.7
            ),
            confidence: confidence,
            provenance: provenance
        )
    }
}

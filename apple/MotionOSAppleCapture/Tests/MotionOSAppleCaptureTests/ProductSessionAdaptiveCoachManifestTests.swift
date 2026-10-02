import XCTest
@testable import MotionOSAppleCapture

final class ProductSessionAdaptiveCoachManifestTests: XCTestCase {
    func testAdaptiveCoachExperimentRoundTripsInManifest() throws {
        let coach = ProductSessionManifest.CoachSummary(
            headline: "Use one clean return",
            observation: "Your controlled shift needed fewer corrections.",
            tip: "Make one small early correction.",
            drill: "Five slow shifts",
            confidence: 0.81,
            evidenceLabel:
                "Camera body pose · within-session experiment",
            metrics: [
                "cue-response": "−18%",
            ],
            numericMetrics: [
                "controlled_shift_range": 0.12,
            ],
            interventionID: "smaller-second-correction",
            interventionCue:
                "Make one small early correction and soften the second.",
            interventionTargetMetric: "pelvis_motion_spread",
            interventionDesiredDirection: "decrease",
            experimentOutcome: "improved",
            experimentBefore: 0.10,
            experimentAfter: 0.08,
            experimentRelativeChange: -0.20,
            experimentSummary:
                "During the coached retry, pelvis-motion spread moved in the intended direction."
        )

        let manifest = ProductSessionManifest(
            runID: "indo-run-1",
            captureMode: "Watch + iPhone",
            targetDurationSeconds: 120,
            watchSessionID: "watch-1",
            cameraSessionID: "camera-1",
            syncReceipts: [],
            externalCameraExpected: false,
            externalCameraImported: false,
            externalCameraSHA256: nil,
            operatorEvidenceSealed: true,
            cameraEvidenceSealed: true,
            coachSummary: coach
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(
            ProductSessionManifest.self,
            from: data
        )

        XCTAssertEqual(
            decoded.coachSummary?.interventionID,
            "smaller-second-correction"
        )
        XCTAssertEqual(
            decoded.coachSummary?.experimentOutcome,
            "improved"
        )
        XCTAssertEqual(
            decoded.coachSummary?.experimentRelativeChange,
            -0.20
        )
    }

    func testOlderCoachSummaryWithoutExperimentStillDecodes() throws {
        let json = """
        {
          "headline": "Baseline",
          "observation": "Usable session",
          "tip": "Repeat",
          "drill": "Neutral hold",
          "confidence": 0.6,
          "evidenceLabel": "Camera body pose",
          "metrics": {},
          "numericMetrics": {}
        }
        """

        let summary = try JSONDecoder().decode(
            ProductSessionManifest.CoachSummary.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(summary.interventionID)
        XCTAssertNil(summary.experimentOutcome)
    }
}

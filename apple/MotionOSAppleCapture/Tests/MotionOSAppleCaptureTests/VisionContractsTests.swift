import XCTest
@testable import MotionOSAppleCapture

final class VisionContractsTests: XCTestCase {
    func testClockModelCodableUsesEvidenceKeys() throws {
        let model = ClockModel(
            slope: 1.00001,
            interceptNS: 250,
            residualRMSNS: 500_000
        )
        let data = try JSONEncoder().encode(model)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )

        XCTAssertEqual(object["intercept_ns"] as? Double, 250)
        XCTAssertEqual(object["residual_rms_ns"] as? Double, 500_000)
        XCTAssertNil(object["interceptNS"])
        XCTAssertEqual(
            try JSONDecoder().decode(ClockModel.self, from: data),
            model
        )
    }

    func testVisionSessionManifestRoundTrip() throws {
        let source = CameraSource(
            sourceID: "dji-action4",
            displayName: "DJI Osmo Action 4",
            kind: .externalRecorded,
            clockDomain: "action4-video-pts",
            timestampBasis: "container_video_pts",
            supportsLiveFrames: false,
            supportsRemoteControl: false,
            capabilities: ["4k", "timecode", "wide_fov"]
        )
        let landmark = SyncLandmark(
            landmarkID: "sync-1",
            sessionID: "indo-1",
            kind: .wholeBodyImpulse,
            hostMonotonicTimeNS: 123,
            createdAtUnixMS: 456,
            note: "three-axis body impulse"
        )
        let manifest = VisionSessionManifest(
            sessionID: "indo-1",
            sport: "indo_board",
            captureMode: "multiview_calibration",
            createdAtUTC: "2026-09-30T22:00:00Z",
            cameraSources: [source],
            syncLandmarks: [landmark]
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(
            VisionSessionManifest.self,
            from: data
        )

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.cameraSources[0].sourceID, "dji-action4")
        XCTAssertFalse(decoded.cameraSources[0].supportsLiveFrames)
    }

    func testCameraCalibrationStructuralGate() {
        let calibration = CameraCalibration(
            calibrationID: "cal-1",
            cameraSourceID: "iphone-rear",
            imageWidthPixels: 1920,
            imageHeightPixels: 1080,
            intrinsicsRowMajor: [
                1000, 0, 960,
                0, 1000, 540,
                0, 0, 1,
            ],
            distortionModel: "none",
            distortionCoefficients: [],
            worldFromCameraRowMajor: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            ],
            reprojectionRMSPixels: 0.5,
            sourceArtifactSHA256: nil
        )

        XCTAssertTrue(calibration.isStructurallyValid)
    }

    func testCoachingCueRejectsLowConfidenceAndExpiredCue() {
        let cue = CoachingCue(
            cueID: "cue-1",
            sessionID: "indo-1",
            metricID: "balance_stability_m",
            value: 0.04,
            unit: "m",
            message: "Center over the board",
            kind: .techniqueWarning,
            confidence: 0.8,
            issuedAtUnixMS: 1_000,
            validForMS: 500
        )

        XCTAssertTrue(cue.isEligibleForLiveDelivery(nowUnixMS: 1_400))
        XCTAssertFalse(cue.isEligibleForLiveDelivery(nowUnixMS: 1_501))

        let lowConfidence = CoachingCue(
            cueID: "cue-2",
            sessionID: "indo-1",
            metricID: "balance_stability_m",
            value: nil,
            unit: nil,
            message: "Center over the board",
            kind: .techniqueWarning,
            confidence: 0.4,
            issuedAtUnixMS: 1_000,
            validForMS: 500
        )
        XCTAssertFalse(
            lowConfidence.isEligibleForLiveDelivery(nowUnixMS: 1_200)
        )
    }

    func testLongitudinalMetricBaselineUsesWelfordUpdate() {
        var baseline = LongitudinalMetricBaseline(
            metricID: "recovery_latency_s",
            direction: .lowerIsBetter
        )
        baseline.observe(0.6)
        baseline.observe(0.4)
        baseline.observe(0.5)

        XCTAssertEqual(baseline.sampleCount, 3)
        XCTAssertEqual(baseline.mean, 0.5, accuracy: 1e-12)
        XCTAssertEqual(baseline.bestValue, 0.4)
        XCTAssertEqual(
            baseline.sampleStandardDeviation ?? 0,
            0.1,
            accuracy: 1e-12
        )
    }
}

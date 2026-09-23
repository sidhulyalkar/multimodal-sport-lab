import XCTest
@testable import MotionOSAppleCapture

final class MotionOSAppleCaptureTests: XCTestCase {
    func testClockMapping() {
        let model = ClockModel(slope: 1.00001, interceptNS: 1000, residualRMSNS: 0)
        XCTAssertEqual(model.sessionTime(deviceTimeNS: 1_000_000), 1_001_010)
    }

    func testMonotonicClockAdvances() {
        let a = MonotonicClock.nowNS()
        let b = MonotonicClock.nowNS()
        XCTAssertGreaterThanOrEqual(b, a)
    }

    func testEnvelopeJSONRoundTrip() throws {
        let event = SensorEnvelope(
            sessionID: "s1",
            deviceID: "watch",
            stream: "/body/watch/imu",
            sequence: 1,
            deviceTimeNS: 100,
            payload: ["ax": .number(1.2)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(event)

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["session_id"] as? String, "s1")
        XCTAssertEqual(object["device_id"] as? String, "watch")
        XCTAssertEqual(object["device_time_ns"] as? Int, 100)
        XCTAssertNil(object["sessionID"])
        XCTAssertNil(object["deviceTimeNS"])

        XCTAssertEqual(
            try JSONDecoder().decode(SensorEnvelope.self, from: data),
            event
        )
    }

    func testCanonicalFixtureDecodesInSwift() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "sensor_event",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let data = try Data(contentsOf: url)
        let event = try JSONDecoder().decode(SensorEnvelope.self, from: data)
        XCTAssertEqual(event.sessionID, "fixture-session")
        XCTAssertEqual(event.deviceID, "apple-watch")
        XCTAssertEqual(event.sequence, 42)
        XCTAssertEqual(event.sessionTimeNS, 123_460_000)
        XCTAssertEqual(event.syncQuality, 0.98)
    }
    func testEquipmentMountCalibrationIdentity() throws {
        let level = Array(repeating: MotionVector3(0, 0, 9.81), count: 20)
        let nose = Array(repeating: MotionVector3(-4.146, 0, 8.891), count: 20)

        let calibration = try EquipmentMountCalibrator.calibrate(
            levelSamples: level,
            noseUpSamples: nose
        )

        XCTAssertTrue(
            calibration.sensorToEquipment.isProperRotation(tolerance: 1e-5)
        )
        let transformed = calibration.sensorToEquipment.transform(
            MotionVector3(1, 2, 3)
        )
        XCTAssertEqual(transformed.x, 1, accuracy: 1e-3)
        XCTAssertEqual(transformed.y, 2, accuracy: 1e-3)
        XCTAssertEqual(transformed.z, 3, accuracy: 1e-3)
    }

    func testEquipmentProfileFixtureDecodesInSwift() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "equipment_profile",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let data = try Data(contentsOf: url)
        let profile = try JSONDecoder().decode(
            EquipmentProfileContract.self,
            from: data
        )

        XCTAssertEqual(profile.equipmentID, "longboard-001")
        XCTAssertEqual(profile.mountID, "center-deck-v1")
        XCTAssertEqual(profile.calibration.sensorToEquipment.determinant, 1.0)
    }

    func testEquipmentCalibrationRejectsTinyPitch() {
        let level = Array(repeating: MotionVector3(0, 0, 9.81), count: 10)
        let nose = Array(repeating: MotionVector3(0.01, 0, 9.81), count: 10)

        XCTAssertThrowsError(
            try EquipmentMountCalibrator.calibrate(
                levelSamples: level,
                noseUpSamples: nose
            )
        ) { error in
            XCTAssertEqual(
                error as? EquipmentFrameError,
                .insufficientPitchExcitation
            )
        }
    }


    func testSampleTimingHealthTracksRateMedianAndGap() {
        var health = SampleTimingHealth(recentWindowSize: 4)
        for timestamp in [
            UInt64(0),
            20_000_000,
            40_000_000,
            60_000_000,
            100_000_000,
        ] {
            health.observe(timestampNS: timestamp)
        }

        XCTAssertEqual(health.sampleCount, 5)
        XCTAssertEqual(health.nonMonotonicCount, 0)
        XCTAssertEqual(health.effectiveHz ?? 0, 40.0, accuracy: 1e-9)
        XCTAssertEqual(health.recentMedianIntervalNS, 20_000_000)
        XCTAssertEqual(health.recentMedianHz ?? 0, 50.0, accuracy: 1e-9)
        XCTAssertEqual(health.maxGapMS, 40.0, accuracy: 1e-9)
    }

    func testSampleTimingHealthFlagsNonMonotonicTimestamp() {
        var health = SampleTimingHealth()
        health.observe(timestampNS: 100)
        health.observe(timestampNS: 90)
        health.observe(timestampNS: 200)

        XCTAssertEqual(health.sampleCount, 3)
        XCTAssertEqual(health.nonMonotonicCount, 1)
        XCTAssertEqual(health.lastTimestampNS, 200)
        XCTAssertEqual(health.maxGapNS, 100)
    }

    func testFileEvidenceDigestUsesExactBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("motionos\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let evidence = try FileEvidence.digest(url, chunkSize: 3)

        XCTAssertEqual(evidence.byteCount, 9)
        XCTAssertEqual(
            evidence.sha256,
            "813916c35345e2efead732487f339a103a320fb00fca8c2e0618e594783536af"
        )
    }

    func testGuidedP0AEnforcesStationaryMinimum() {
        let plan = GuidedProtocolPlan.p0A
        var progress = GuidedProtocolProgress()
        progress.start(plan: plan)

        XCTAssertEqual(progress.currentStep(plan: plan)?.id, "stationary")
        XCTAssertFalse(
            progress.completeCurrentStep(
                plan: plan,
                stepElapsedSeconds: 59,
                planElapsedSeconds: 59
            )
        )
        XCTAssertTrue(
            progress.completeCurrentStep(
                plan: plan,
                stepElapsedSeconds: 60,
                planElapsedSeconds: 60
            )
        )
        XCTAssertEqual(progress.currentStep(plan: plan)?.id, "roll")
    }

    func testGuidedP0ACannotSkipRequiredChallenge() {
        let plan = GuidedProtocolPlan.p0A
        var progress = GuidedProtocolProgress()
        progress.start(plan: plan)

        XCTAssertFalse(progress.skipCurrentStep(plan: plan))
        XCTAssertEqual(progress.currentStep(plan: plan)?.id, "stationary")
    }

    func testGuidedPlanElapsedGateCannotBeSatisfiedByStepTimeAlone() {
        let step = GuidedProtocolStep(
            id: "duration",
            title: "Duration",
            instruction: "Reach total duration.",
            minimumPlanElapsedSeconds: 600,
            allowsSkip: false
        )

        XCTAssertFalse(
            step.canComplete(
                stepElapsedSeconds: 700,
                planElapsedSeconds: 599
            )
        )
        XCTAssertTrue(
            step.canComplete(
                stepElapsedSeconds: 1,
                planElapsedSeconds: 600
            )
        )
    }

    func testGuidedProtocolTracksSkippedAndCompletedSteps() {
        let plan = GuidedProtocolPlan(
            id: "fixture",
            version: "v1",
            title: "Fixture",
            targetDurationSeconds: 10,
            steps: [
                .init(
                    id: "optional",
                    title: "Optional",
                    instruction: "Optional step."
                ),
                .init(
                    id: "required",
                    title: "Required",
                    instruction: "Required step.",
                    allowsSkip: false
                ),
            ]
        )
        var progress = GuidedProtocolProgress()
        progress.start(plan: plan)

        XCTAssertTrue(progress.skipCurrentStep(plan: plan))
        XCTAssertEqual(progress.skippedStepIDs, ["optional"])

        XCTAssertTrue(
            progress.completeCurrentStep(
                plan: plan,
                stepElapsedSeconds: 0,
                planElapsedSeconds: 0
            )
        )
        XCTAssertEqual(progress.completedStepIDs, ["required"])
        XCTAssertEqual(progress.state, .completed)
    }
}

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


    func testProductSessionManifestRoundTripsWithSourceHashes() throws {
        let manifest = ProductSessionManifest(
            runID: "run-001",
            captureMode: "Multiview capture",
            targetDurationSeconds: 120,
            createdAtUTC: "2026-10-01T17:00:00Z",
            watchSessionID: "watch-001",
            watchJournalSHA256: "watch-journal",
            watchJournalByteCount: 4_096,
            cameraSessionID: "camera-001",
            operatorJournalSHA256: "op-journal",
            operatorMetadataSHA256: "op-meta",
            cameraVideoSHA256: "camera-video",
            cameraJournalSHA256: "camera-journal",
            cameraMetadataSHA256: "camera-meta",
            syncReceipts: [
                .init(
                    cueID: "sync-start",
                    label: "start",
                    acknowledgedAtUTC: "2026-10-01T17:00:12Z",
                    watchDeviceTimeNS: 12_000_000_000
                )
            ],
            externalCameraExpected: true,
            externalCameraImported: true,
            externalCameraSHA256: "action4",
            operatorEvidenceSealed: true,
            cameraEvidenceSealed: true
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(
            ProductSessionManifest.self,
            from: data
        )

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(
            decoded.schemaVersion,
            ProductSessionManifest.schemaVersion
        )
        XCTAssertEqual(decoded.syncReceipts.first?.label, "start")
        XCTAssertEqual(decoded.watchJournalSHA256, "watch-journal")
        XCTAssertEqual(decoded.watchJournalByteCount, 4_096)
        XCTAssertTrue(decoded.claimBoundary.contains("does not itself prove"))
    }

    func testProductSessionManifestOutcomeRoundTripAndLegacyDefault() throws {
        let aborted = ProductSessionManifest(
            runID: "run-aborted",
            captureMode: "Watch + iPhone",
            targetDurationSeconds: 120,
            outcome: .aborted,
            watchSessionID: "watch-aborted",
            cameraSessionID: nil,
            syncReceipts: [],
            externalCameraExpected: false,
            externalCameraImported: false,
            externalCameraSHA256: nil,
            operatorEvidenceSealed: true,
            cameraEvidenceSealed: false
        )

        let encoded = try JSONEncoder().encode(aborted)
        let decoded = try JSONDecoder().decode(
            ProductSessionManifest.self,
            from: encoded
        )
        XCTAssertEqual(decoded.resolvedOutcome, .aborted)

        var legacyObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: encoded
            ) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "outcome")
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyObject,
            options: [.sortedKeys]
        )
        let legacy = try JSONDecoder().decode(
            ProductSessionManifest.self,
            from: legacyData
        )
        XCTAssertEqual(legacy.resolvedOutcome, .completed)
    }

    func testProductSessionManifestStoreWritesAtomicArtifact() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "motionos-product-manifest-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = ProductSessionManifest(
            runID: "run-002",
            captureMode: "Watch + iPhone",
            targetDurationSeconds: 120,
            watchSessionID: nil,
            cameraSessionID: nil,
            syncReceipts: [],
            externalCameraExpected: false,
            externalCameraImported: false,
            externalCameraSHA256: nil,
            operatorEvidenceSealed: true,
            cameraEvidenceSealed: true
        )

        let url = try ProductSessionManifestStore.write(
            manifest,
            to: directory
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(
            try ProductSessionManifestStore.load(from: url),
            manifest
        )
    }

    func testIndoBoardProductProtocolIsContiguousAndBounded() {
        XCTAssertTrue(IndoBoardProductProtocol.isInternallyConsistent)
        XCTAssertEqual(
            IndoBoardProductProtocol.blocks.first?.startSeconds,
            0
        )
        XCTAssertEqual(
            IndoBoardProductProtocol.blocks.last?.endSeconds,
            IndoBoardProductProtocol.targetDurationSeconds
        )
        XCTAssertEqual(
            Set(
                IndoBoardProductProtocol.syncWindows.map(\.label)
            ),
            Set(["start", "middle", "end"])
        )
    }

    func testIndoBoardProductProtocolPrioritizesUnacknowledgedSyncCue() {
        let instruction = IndoBoardProductProtocol.instruction(
            at: 12,
            acknowledgedSyncLabels: []
        )
        XCTAssertTrue(instruction.contains("START"))

        let acknowledged = IndoBoardProductProtocol.instruction(
            at: 12,
            acknowledgedSyncLabels: ["start"]
        )
        XCTAssertEqual(
            acknowledged,
            IndoBoardProductProtocol.blocks[0].instruction
        )
    }

    func testIndoBoardProductProtocolCompletionThreshold() {
        XCTAssertFalse(
            IndoBoardProductProtocol.reachedTarget(at: 119.999)
        )
        XCTAssertTrue(
            IndoBoardProductProtocol.reachedTarget(at: 120.0)
        )
        XCTAssertTrue(
            IndoBoardProductProtocol.reachedTarget(at: 121.0)
        )
    }

    func testIndoBoardProductProtocolFindsActiveBlock() {
        XCTAssertEqual(
            IndoBoardProductProtocol.activeBlock(at: 60)?.id,
            "partial-squats"
        )
        XCTAssertNil(
            IndoBoardProductProtocol.activeBlock(
                at: IndoBoardProductProtocol.targetDurationSeconds
            )
        )
    }

    func testBodyMovementFrameParsesVisionPoseWithoutInventingCOM() throws {
        let payload: [String: JSONValue] = [
            "joints_root_relative_m": .object([
                "root": .array([.number(0), .number(1), .number(0)]),
                "leftHip": .array([.number(-0.15), .number(0.95), .number(0)]),
                "rightHip": .array([.number(0.15), .number(0.95), .number(0)]),
                "leftKnee": .array([.number(-0.16), .number(0.52), .number(0)]),
                "rightKnee": .array([.number(0.16), .number(0.52), .number(0)]),
                "leftAnkle": .array([.number(-0.17), .number(0.05), .number(0)]),
                "rightAnkle": .array([.number(0.17), .number(0.05), .number(0)]),
            ]),
            "joint_parents": .object([
                "root": .null,
                "leftHip": .string("root"),
                "rightHip": .string("root"),
                "leftKnee": .string("leftHip"),
                "rightKnee": .string("rightHip"),
                "leftAnkle": .string("leftKnee"),
                "rightAnkle": .string("rightKnee"),
            ]),
            "body_height_m": .number(1.70),
            "joint_coordinate_frame":
                .string("vision_root_joint_relative_meters"),
        ]

        let frame = try XCTUnwrap(
            BodyMovementFrameParser.parseVisionPose(
                payload: payload,
                sessionID: "camera-1",
                sequence: 7,
                deviceTimeNS: 123
            )
        )

        XCTAssertEqual(frame.sessionID, "camera-1")
        XCTAssertEqual(frame.sequence, 7)
        XCTAssertEqual(frame.joints.count, 7)
        XCTAssertEqual(frame.bodyHeightM, 1.70)
        XCTAssertNil(frame.centerOfMass)
        XCTAssertEqual(frame.supportPoints.count, 2)
        XCTAssertEqual(
            frame.pelvisReference?.provenance,
            .geometricProxy
        )
        XCTAssertTrue(
            frame.pelvisReference?.label.contains("not center of mass")
                == true
        )
        XCTAssertTrue(frame.muscleActivations.isEmpty)
    }

    func testBodyMovementFrameRejectsInvalidOrTinyPose() {
        let payload: [String: JSONValue] = [
            "joints_root_relative_m": .object([
                "root": .array([.number(0), .number(0), .number(0)]),
            ]),
            "joint_parents": .object([
                "root": .null,
            ]),
        ]

        XCTAssertNil(
            BodyMovementFrameParser.parseVisionPose(
                payload: payload,
                sessionID: "tiny",
                sequence: 0,
                deviceTimeNS: 1
            )
        )
    }

    func testBodyMovementFrameAcceptsExplicitModelEstimates() throws {
        let payload: [String: JSONValue] = [
            "joints_root_relative_m": .object([
                "root": .array([.number(0), .number(1), .number(0)]),
                "leftHip": .array([.number(-0.1), .number(0.9), .number(0)]),
                "rightHip": .array([.number(0.1), .number(0.9), .number(0)]),
                "leftKnee": .array([.number(-0.1), .number(0.5), .number(0)]),
                "rightKnee": .array([.number(0.1), .number(0.5), .number(0)]),
                "leftAnkle": .array([.number(-0.1), .number(0), .number(0)]),
                "rightAnkle": .array([.number(0.1), .number(0), .number(0)]),
            ]),
            "joint_parents": .object([
                "root": .null,
                "leftHip": .string("root"),
                "rightHip": .string("root"),
                "leftKnee": .string("leftHip"),
                "rightKnee": .string("rightHip"),
                "leftAnkle": .string("leftKnee"),
                "rightAnkle": .string("rightKnee"),
            ]),
            "center_of_mass_root_relative_m":
                .array([.number(0.02), .number(0.88), .number(0.01)]),
            "center_of_mass_provenance": .string("model_estimated"),
            "muscle_activation": .object([
                "left_thigh": .number(0.8),
                "right_thigh": .number(1.4),
            ]),
            "muscle_activation_model_id": .string("fixture-model"),
        ]

        let frame = try XCTUnwrap(
            BodyMovementFrameParser.parseVisionPose(
                payload: payload,
                sessionID: "estimated",
                sequence: 1,
                deviceTimeNS: 2
            )
        )

        XCTAssertEqual(
            frame.centerOfMass?.provenance,
            .modelEstimated
        )
        XCTAssertEqual(frame.muscleActivations.count, 2)
        XCTAssertEqual(
            frame.muscleActivations.first {
                $0.region == .rightThigh
            }?.intensity,
            1.0
        )
        XCTAssertEqual(
            frame.muscleActivations.first {
                $0.region == .leftThigh
            }?.modelID,
            "fixture-model"
        )
    }

    func testWatchMotionDerivationUsesUserAccelerationChannels() throws {
        let gravity = 9.80665
        let derived = try XCTUnwrap(
            WatchMotionDerivation.derive(
                payload: [
                    "ax": .number(gravity * 4),
                    "ay": .number(0),
                    "az": .number(0),
                    "user_ax": .number(gravity * 0.3),
                    "user_ay": .number(gravity * 0.4),
                    "user_az": .number(0),
                    "gx": .number(1),
                    "gy": .number(2),
                    "gz": .number(2),
                ]
            )
        )

        XCTAssertEqual(derived.userAccelerationG, 0.5, accuracy: 1e-9)
        XCTAssertEqual(derived.rotationRateRadS, 3.0, accuracy: 1e-9)
    }

    func testWatchMotionDerivationFallsBackForLegacyTotalAcceleration() throws {
        let gravity = 9.80665
        let derived = try XCTUnwrap(
            WatchMotionDerivation.derive(
                payload: [
                    "ax": .number(gravity * 1.2),
                    "ay": .number(0),
                    "az": .number(0),
                    "gx": .number(0),
                    "gy": .number(0),
                    "gz": .number(0),
                ]
            )
        )

        XCTAssertEqual(derived.userAccelerationG, 0.2, accuracy: 1e-9)
        XCTAssertEqual(derived.rotationRateRadS, 0, accuracy: 1e-9)
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

    func testCaptureSequenceFenceRejectsStaleGeneration() {
        let fence = CaptureSequenceFence()

        let first = fence.begin()
        XCTAssertEqual(fence.takeNextSequence(for: first), 0)
        XCTAssertEqual(fence.takeNextSequence(for: first), 1)

        fence.invalidate()
        XCTAssertNil(fence.takeNextSequence(for: first))
    }

    func testCaptureSequenceFenceResetsForNewGeneration() {
        let fence = CaptureSequenceFence()

        let first = fence.begin()
        XCTAssertEqual(fence.takeNextSequence(for: first), 0)

        let second = fence.begin()
        XCTAssertNotEqual(first, second)
        XCTAssertNil(fence.takeNextSequence(for: first))
        XCTAssertEqual(fence.takeNextSequence(for: second), 0)
        XCTAssertEqual(fence.takeNextSequence(for: second), 1)
    }

    func testCaptureSequenceFenceCountsRejectedCallbacks() {
        let fence = CaptureSequenceFence()

        let first = fence.begin()
        XCTAssertEqual(fence.takeNextSequence(for: first), 0)
        XCTAssertEqual(fence.rejectedCallbackCount, 0)

        fence.invalidate()
        XCTAssertNil(fence.takeNextSequence(for: first))
        XCTAssertNil(fence.takeNextSequence(for: first))
        XCTAssertEqual(fence.rejectedCallbackCount, 2)

        let second = fence.begin()
        XCTAssertEqual(fence.takeNextSequence(for: second), 0)
        XCTAssertEqual(fence.rejectedCallbackCount, 2)
    }

    // MARK: - Shutdown boundary

    func testAdmissionRejectsSameSessionEventsOnceFinalizationBegins() {
        var admission = CaptureEventAdmission()
        admission.begin(sessionID: "s1")
        XCTAssertNil(admission.admit(sessionID: "s1"))

        admission.beginFinalizing()
        XCTAssertFalse(admission.isCapturing)
        XCTAssertEqual(admission.admit(sessionID: "s1"), .afterShutdown)

        admission.finish()
        XCTAssertEqual(admission.admit(sessionID: "s1"), .afterShutdown)
        XCTAssertEqual(admission.rejections.afterShutdown, 2)
        XCTAssertEqual(admission.rejections.total, 2)
    }

    func testAdmissionRejectsForeignSessionsInEveryPhase() {
        var admission = CaptureEventAdmission()
        XCTAssertEqual(admission.admit(sessionID: "s1"), .noActiveSession)

        admission.begin(sessionID: "s2")
        XCTAssertEqual(admission.admit(sessionID: "s1"), .sessionMismatch)
        admission.beginFinalizing()
        XCTAssertEqual(admission.admit(sessionID: "s1"), .sessionMismatch)
        admission.finish()
        XCTAssertEqual(admission.admit(sessionID: "s1"), .sessionMismatch)

        XCTAssertEqual(admission.rejections.sessionMismatch, 3)
        XCTAssertEqual(admission.rejections.afterShutdown, 0)
    }

    func testAdmissionBeginResetsCountsForNewSession() {
        var admission = CaptureEventAdmission()
        admission.begin(sessionID: "s1")
        admission.beginFinalizing()
        _ = admission.admit(sessionID: "s1")
        admission.setStaleMotionGenerationCount(3)
        XCTAssertEqual(admission.rejections.total, 4)

        admission.begin(sessionID: "s2")
        XCTAssertEqual(admission.rejections, CaptureRejectionCounts())
        XCTAssertNil(admission.admit(sessionID: "s2"))
    }

    func testSessionJournalRejectsAppendAfterCloseWithoutThrowing() async throws {
        let url = try makeShutdownJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try CaptureSessionJournal(sessionID: "s1", url: url)

        let first = try await journal.append(Self.shutdownEvent(sequence: 0))
        XCTAssertEqual(first, .appended(count: 1))
        let closedCount = try await journal.close()
        XCTAssertEqual(closedCount, 1)

        let late = try await journal.append(Self.shutdownEvent(sequence: 1))
        XCTAssertEqual(late, .rejected(.afterShutdown))
        let reclosedCount = try await journal.close()
        XCTAssertEqual(reclosedCount, 1)
        XCTAssertEqual(try journalSequences(url), [0])
    }

    func testSessionJournalRejectsForeignSessionEvents() async throws {
        let url = try makeShutdownJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try CaptureSessionJournal(sessionID: "s1", url: url)

        let foreign = try await journal.append(
            Self.shutdownEvent(sequence: 0, sessionID: "s0")
        )
        XCTAssertEqual(foreign, .rejected(.sessionMismatch))
        let count = try await journal.close()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try journalSequences(url), [])
    }

    /// Forces the shutdown interleaving: an append is suspended inside the
    /// writer when close() begins. The late append is rejected, and the writer
    /// is not closed until the admitted append has finished.
    func testSessionJournalCloseWaitsForInFlightAppend() async throws {
        let writer = GatedJournalWriter()
        let journal = CaptureSessionJournal(
            sessionID: "s1",
            url: URL(fileURLWithPath: "/dev/null"),
            writer: writer
        )

        let admittedEvent = Self.shutdownEvent(sequence: 0)
        let admitted = Task.detached {
            try await journal.append(admittedEvent)
        }
        await writer.waitUntilAppendEntered()

        let closing = Task.detached {
            try await journal.close()
        }
        while !(await journal.isClosing) {
            await Task.yield()
        }

        let late = try await journal.append(Self.shutdownEvent(sequence: 1))
        XCTAssertEqual(late, .rejected(.afterShutdown))
        let logBeforeRelease = await writer.log
        XCTAssertEqual(logBeforeRelease, ["append-begin 0"])

        await writer.release()
        let admittedOutcome = try await admitted.value
        let closedCount = try await closing.value
        XCTAssertEqual(admittedOutcome, .appended(count: 1))
        XCTAssertEqual(closedCount, 1)
        let finalLog = await writer.log
        XCTAssertEqual(finalLog, ["append-begin 0", "append-end 0", "close"])
    }

    /// Races appends against close() on the real file journal. Whatever the
    /// interleaving, every append reported as written is on disk and nothing
    /// rejected is.
    func testSessionJournalCloseDrainsAdmittedAppendsUnderRace() async throws {
        for _ in 0..<50 {
            let url = try makeShutdownJournalURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let journal = try CaptureSessionJournal(sessionID: "s1", url: url)
            let total = 40

            let (outcomes, closedCount) = try await withThrowingTaskGroup(
                of: (UInt64, CaptureSessionJournal.AppendOutcome)?.self
            ) { group in
                for sequence in 0..<UInt64(total) {
                    group.addTask {
                        let outcome = try await journal.append(
                            Self.shutdownEvent(sequence: sequence)
                        )
                        return (sequence, outcome)
                    }
                    if sequence == UInt64(total / 2) {
                        group.addTask {
                            _ = try await journal.close()
                            return nil
                        }
                    }
                }

                var outcomes: [UInt64: CaptureSessionJournal.AppendOutcome] = [:]
                for try await result in group {
                    if let (sequence, outcome) = result {
                        outcomes[sequence] = outcome
                    }
                }
                return (outcomes, try await journal.close())
            }

            let written = Set(outcomes.compactMap { sequence, outcome in
                if case .appended = outcome { return sequence }
                return nil
            })
            let rejected = outcomes.values.filter {
                $0 == .rejected(.afterShutdown)
            }.count

            XCTAssertEqual(outcomes.count, total)
            XCTAssertEqual(written.count + rejected, total)
            XCTAssertEqual(closedCount, written.count)
            XCTAssertEqual(Set(try journalSequences(url)), written)
            XCTAssertEqual(try journalSequences(url).count, written.count)
        }
    }

    func testWatchSessionSummaryBuildsDerivedMetricsFromJournal() throws {
        let url = try makeWatchSummaryJournal()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
            )
        }

        let summary = try WatchSessionSummaryBuilder.build(
            journalURL: url,
            sourceJournalSHA256: "fixture-sha",
            bucketSeconds: 0.1
        )

        XCTAssertEqual(
            summary.protocolVersion,
            WatchSessionSummary.protocolVersion
        )
        XCTAssertEqual(summary.sessionID, "summary-session")
        XCTAssertEqual(summary.sourceJournalSHA256, "fixture-sha")

        XCTAssertEqual(summary.imu.count, 10)
        XCTAssertEqual(summary.imu.durationSeconds, 0.18, accuracy: 1e-9)
        XCTAssertEqual(summary.imu.effectiveHz, 50.0, accuracy: 1e-9)
        XCTAssertEqual(summary.imu.maxGapMS, 20.0, accuracy: 1e-9)
        XCTAssertEqual(summary.imu.missingSequences, 0)
        XCTAssertEqual(summary.imu.nonMonotonicSequences, 0)
        XCTAssertEqual(summary.imu.nonMonotonicTimestamps, 0)

        XCTAssertEqual(summary.heartRate.count, 2)
        XCTAssertEqual(summary.heartRate.minimumBPM ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(summary.heartRate.meanBPM ?? 0, 105, accuracy: 1e-9)
        XCTAssertEqual(summary.heartRate.maximumBPM ?? 0, 110, accuracy: 1e-9)

        XCTAssertEqual(
            summary.motion.userAccelerationRMSG ?? 0,
            0.1,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            summary.motion.userAccelerationP95G ?? 0,
            0.1,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            summary.motion.rotationRateRMSRadS ?? 0,
            1.0,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            summary.motion.rotationRateP95RadS ?? 0,
            1.0,
            accuracy: 1e-9
        )

        XCTAssertEqual(summary.trace.count, 2)
        XCTAssertEqual(
            summary.trace[0].meanUserAccelerationG,
            0.1,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            summary.trace[1].meanRotationRateRadS,
            1.0,
            accuracy: 1e-9
        )
        XCTAssertTrue(summary.claimBoundary.contains("not raw evidence"))
    }

    func testWatchSessionSummaryRejectsMixedSessionIDs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "motionos-summary-mixed-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("watch.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let events = [
            SensorEnvelope(
                sessionID: "one",
                deviceID: "apple-watch",
                stream: "/meta/watch",
                sequence: 0,
                deviceTimeNS: 1,
                payload: [:]
            ),
            SensorEnvelope(
                sessionID: "two",
                deviceID: "apple-watch",
                stream: "/body/watch/imu",
                sequence: 0,
                deviceTimeNS: 2,
                payload: [
                    "user_ax": .number(0),
                    "user_ay": .number(0),
                    "user_az": .number(0),
                    "gx": .number(0),
                    "gy": .number(0),
                    "gz": .number(0),
                ]
            ),
        ]
        try writeJSONL(events, to: url)

        XCTAssertThrowsError(
            try WatchSessionSummaryBuilder.build(
                journalURL: url,
                sourceJournalSHA256: "fixture"
            )
        ) { error in
            XCTAssertEqual(
                error as? WatchSessionSummaryBuilder.SummaryError,
                .mixedSessionIDs
            )
        }
    }

    func testWatchSessionSummaryWritesSourceBoundJSON() throws {
        let journalURL = try makeWatchSummaryJournal()
        let directory = journalURL.deletingLastPathComponent()
        let summaryURL = directory.appendingPathComponent("summary.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let summary = try WatchSessionSummaryBuilder.build(
            journalURL: journalURL,
            sourceJournalSHA256: "abc123"
        )
        try WatchSessionSummaryBuilder.write(summary, to: summaryURL)

        let roundTrip = try JSONDecoder().decode(
            WatchSessionSummary.self,
            from: Data(contentsOf: summaryURL)
        )
        XCTAssertEqual(roundTrip, summary)
        XCTAssertEqual(roundTrip.sourceJournalSHA256, "abc123")
    }

    /// A journal writer whose first append suspends until `release()`.
    private actor GatedJournalWriter: CaptureJournalWriting {
        private(set) var log: [String] = []
        private var appendEntered = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var gate: CheckedContinuation<Void, Never>?

        func append(_ event: SensorEnvelope) async throws {
            log.append("append-begin \(event.sequence)")
            let isFirstAppend = !appendEntered
            appendEntered = true
            enteredWaiters.forEach { $0.resume() }
            enteredWaiters.removeAll()
            if isFirstAppend, !released {
                await withCheckedContinuation { gate = $0 }
            }
            log.append("append-end \(event.sequence)")
        }

        func close() async throws {
            log.append("close")
        }

        func waitUntilAppendEntered() async {
            guard !appendEntered else { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func release() {
            released = true
            gate?.resume()
            gate = nil
        }
    }

    private func makeWatchSummaryJournal() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "motionos-summary-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let url = directory.appendingPathComponent("watch.jsonl")
        let gravity = 9.80665
        var events: [SensorEnvelope] = [
            SensorEnvelope(
                sessionID: "summary-session",
                deviceID: "apple-watch",
                stream: "/meta/watch",
                sequence: 0,
                deviceTimeNS: 1,
                payload: ["requested_imu_hz": .number(50)]
            )
        ]

        for sequence in 0..<UInt64(10) {
            events.append(
                SensorEnvelope(
                    sessionID: "summary-session",
                    deviceID: "apple-watch",
                    stream: "/body/watch/imu",
                    sequence: sequence,
                    deviceTimeNS: sequence * 20_000_000,
                    payload: [
                        "ax": .number(gravity),
                        "ay": .number(0),
                        "az": .number(0),
                        "user_ax": .number(gravity * 0.1),
                        "user_ay": .number(0),
                        "user_az": .number(0),
                        "gx": .number(1),
                        "gy": .number(0),
                        "gz": .number(0),
                    ]
                )
            )
        }

        for (sequence, bpm) in [100.0, 110.0].enumerated() {
            events.append(
                SensorEnvelope(
                    sessionID: "summary-session",
                    deviceID: "apple-watch",
                    stream: "/body/watch/hr",
                    sequence: UInt64(sequence),
                    deviceTimeNS: UInt64(sequence + 1) * 1_000_000_000,
                    payload: ["bpm": .number(bpm)]
                )
            )
        }

        try writeJSONL(events, to: url)
        return url
    }

    private func writeJSONL(
        _ events: [SensorEnvelope],
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    private func makeShutdownJournalURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "motionos-shutdown-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("watch.jsonl")
    }

    private static func shutdownEvent(
        sequence: UInt64,
        sessionID: String = "s1"
    ) -> SensorEnvelope {
        SensorEnvelope(
            sessionID: sessionID,
            deviceID: "apple-watch",
            stream: "/body/watch/imu",
            sequence: sequence,
            deviceTimeNS: 1_000 + sequence,
            payload: ["ax": .number(0)]
        )
    }

    private func journalSequences(_ url: URL) throws -> [UInt64] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try JSONDecoder().decode(
                SensorEnvelope.self,
                from: Data($0.utf8)
            ).sequence
        }
    }
}

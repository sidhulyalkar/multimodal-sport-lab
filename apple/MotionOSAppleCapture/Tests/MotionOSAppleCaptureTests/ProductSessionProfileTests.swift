import Foundation
import XCTest
@testable import MotionOSAppleCapture

final class ProductSessionProfileTests: XCTestCase {
    func testManifestRoundTripsProfileAndSport() throws {
        let manifest = ProductSessionManifest(
            runID: "run-profile-1",
            profileID: "profile-alex",
            sport: "indo_board",
            captureMode: "Watch + iPhone",
            targetDurationSeconds: 120,
            watchSessionID: "watch-1",
            cameraSessionID: "camera-1",
            syncReceipts: [],
            externalCameraExpected: false,
            externalCameraImported: false,
            externalCameraSHA256: nil,
            operatorEvidenceSealed: true,
            cameraEvidenceSealed: true
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(
            ProductSessionManifest.self,
            from: data
        )

        XCTAssertEqual(decoded.profileID, "profile-alex")
        XCTAssertEqual(decoded.sport, "indo_board")
    }

    func testLegacyManifestWithoutProfileStillDecodes() throws {
        let json = """
        {
          "schemaVersion": "motionos.product-session.v1",
          "runID": "legacy-run",
          "sport": "indo_board",
          "captureMode": "Watch + iPhone",
          "targetDurationSeconds": 120,
          "createdAtUTC": "2026-10-01T00:00:00Z",
          "outcome": "completed",
          "watchSessionID": null,
          "watchJournalSHA256": null,
          "watchJournalByteCount": null,
          "cameraSessionID": null,
          "operatorJournalSHA256": null,
          "operatorMetadataSHA256": null,
          "cameraVideoSHA256": null,
          "cameraJournalSHA256": null,
          "cameraMetadataSHA256": null,
          "syncReceipts": [],
          "externalCameraExpected": false,
          "externalCameraImported": false,
          "externalCameraSHA256": null,
          "operatorEvidenceSealed": true,
          "cameraEvidenceSealed": true,
          "coachSummary": null,
          "claimBoundary": "fixture"
        }
        """

        let decoded = try JSONDecoder().decode(
            ProductSessionManifest.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(decoded.profileID)
        XCTAssertEqual(decoded.sport, "indo_board")
    }

    func testBindingWatchEvidencePreservesProfileAndSport() {
        let manifest = ProductSessionManifest(
            runID: "run-profile-2",
            profileID: "profile-2",
            sport: "indo_board",
            captureMode: "Watch + iPhone",
            targetDurationSeconds: 120,
            watchSessionID: nil,
            cameraSessionID: "camera-2",
            syncReceipts: [],
            externalCameraExpected: false,
            externalCameraImported: false,
            externalCameraSHA256: nil,
            operatorEvidenceSealed: true,
            cameraEvidenceSealed: true
        )

        let bound = manifest.bindingWatchEvidence(
            watchSessionID: "watch-2",
            journalSHA256: "abc",
            journalByteCount: 123
        )

        XCTAssertEqual(bound.profileID, "profile-2")
        XCTAssertEqual(bound.sport, "indo_board")
        XCTAssertEqual(bound.watchSessionID, "watch-2")
    }
}

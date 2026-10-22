import XCTest
@testable import MotionOSAppleCapture

final class IndoBoardFirstCaptureGuideTests: XCTestCase {
    func testStandardGuideDoesNotRequireAdditionalResearchHardware() {
        let steps = IndoBoardFirstCaptureGuide.steps(externalCamera: false)
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(
            Set(steps.map(\.id)).count,
            steps.count,
            "Manual setup reminders must have stable unique identities"
        )
        XCTAssertFalse(steps.contains { $0.id == "action4" })
        XCTAssertTrue(steps.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
    }

    func testExternalCameraOnlyAddsManualImportReminder() {
        let standard = IndoBoardFirstCaptureGuide.steps(externalCamera: false)
        let extra = IndoBoardFirstCaptureGuide.steps(externalCamera: true)
        XCTAssertEqual(extra.count, standard.count + 1)
        XCTAssertEqual(Array(extra.prefix(standard.count)), standard)
        XCTAssertEqual(extra.last?.id, "action4")
        XCTAssertTrue(extra.last?.detail.contains("original movie") == true)
    }

    func testDisplayedProtocolAlwaysUsesCanonicalVersionTwo() {
        XCTAssertEqual(
            IndoBoardFirstCaptureGuide.durationSeconds,
            IndoBoardProductProtocol.targetDurationSeconds
        )
        XCTAssertEqual(
            IndoBoardFirstCaptureGuide.blocks,
            IndoBoardProductProtocol.blocks
        )
        XCTAssertEqual(
            IndoBoardFirstCaptureGuide.syncWindows,
            IndoBoardProductProtocol.syncWindows
        )
        XCTAssertEqual(
            IndoBoardFirstCaptureGuide.blocks.map(\.startSeconds),
            [0, 15, 35, 60, 85, 105]
        )
        XCTAssertEqual(
            IndoBoardFirstCaptureGuide.syncWindows.map(\.label),
            ["start", "middle", "end"]
        )
    }
}

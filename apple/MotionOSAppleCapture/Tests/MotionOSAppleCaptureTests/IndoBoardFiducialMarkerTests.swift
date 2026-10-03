import XCTest
@testable import MotionOSAppleCapture

final class IndoBoardFiducialMarkerTests: XCTestCase {
    func testDeckEndpointsAndRollerCenterBuildBoardState() {
        let detections = [
            IndoBoardFiducialDetection(
                marker: .deckLeft,
                center: .init(x: 0.20, y: 0.70),
                confidence: 0.95
            ),
            IndoBoardFiducialDetection(
                marker: .deckRight,
                center: .init(x: 0.80, y: 0.70),
                confidence: 0.94
            ),
            IndoBoardFiducialDetection(
                marker: .rollerCenter,
                center: .init(x: 0.50, y: 0.70),
                confidence: 0.90
            ),
        ]

        let observation =
            IndoBoardFiducialEquipmentBuilder.makeObservation(
                detections: detections,
                sequence: 8,
                deviceTimeNS: 800_000_000
            )
        let state = observation.flatMap {
            IndoBoardBalanceStateEstimator.estimate(
                from: $0
            )
        }

        XCTAssertNotNil(observation)
        XCTAssertEqual(
            observation?.deck?.provenance,
            .fiducialMeasured
        )
        XCTAssertEqual(
            observation?.roller?.provenance,
            .fiducialMeasured
        )
        XCTAssertEqual(
            state?.rollerAlongDeck ?? 1,
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            state?.provenance,
            .fiducialMeasured
        )
    }

    func testRollerEndpointMarkersProvideAxisAndCenter() {
        let detections = [
            IndoBoardFiducialDetection(
                marker: .deckLeft,
                center: .init(x: 0.20, y: 0.70),
                confidence: 0.9
            ),
            IndoBoardFiducialDetection(
                marker: .deckRight,
                center: .init(x: 0.80, y: 0.70),
                confidence: 0.9
            ),
            IndoBoardFiducialDetection(
                marker: .rollerLeft,
                center: .init(x: 0.42, y: 0.72),
                confidence: 0.88
            ),
            IndoBoardFiducialDetection(
                marker: .rollerRight,
                center: .init(x: 0.48, y: 0.72),
                confidence: 0.86
            ),
        ]

        let observation =
            IndoBoardFiducialEquipmentBuilder.makeObservation(
                detections: detections
            )

        XCTAssertEqual(
            observation?.roller?.center.x ?? 0,
            0.45,
            accuracy: 0.001
        )
        XCTAssertNotNil(
            observation?.roller?.axisStart
        )
        XCTAssertNotNil(
            observation?.roller?.axisEnd
        )
    }

    func testIncompleteDeckMarkersFailClosed() {
        let detections = [
            IndoBoardFiducialDetection(
                marker: .deckLeft,
                center: .init(x: 0.20, y: 0.70),
                confidence: 0.95
            ),
            IndoBoardFiducialDetection(
                marker: .rollerCenter,
                center: .init(x: 0.50, y: 0.70),
                confidence: 0.90
            ),
        ]

        XCTAssertNil(
            IndoBoardFiducialEquipmentBuilder.makeObservation(
                detections: detections
            )
        )
    }

    func testHighestConfidenceDuplicateMarkerWins() {
        let detections = [
            IndoBoardFiducialDetection(
                marker: .deckLeft,
                center: .init(x: 0.10, y: 0.70),
                confidence: 0.2
            ),
            IndoBoardFiducialDetection(
                marker: .deckLeft,
                center: .init(x: 0.20, y: 0.70),
                confidence: 0.95
            ),
            IndoBoardFiducialDetection(
                marker: .deckRight,
                center: .init(x: 0.80, y: 0.70),
                confidence: 0.94
            ),
            IndoBoardFiducialDetection(
                marker: .rollerCenter,
                center: .init(x: 0.50, y: 0.70),
                confidence: 0.90
            ),
        ]

        let observation =
            IndoBoardFiducialEquipmentBuilder.makeObservation(
                detections: detections
            )

        XCTAssertEqual(
            observation?.deck?.leftEnd.x ?? 0,
            0.20,
            accuracy: 0.001
        )
    }
}

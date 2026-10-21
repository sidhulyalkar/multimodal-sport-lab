import XCTest
@testable import MotionOSAppleCapture

final class IndoBoardControlInsightsTests: XCTestCase {
    func testMatchedBlocksExposeDescriptiveChanges() {
        let early = (0..<200).map { index in
            sample(
                "free-balance-a",
                time: 15 + Double(index) * 0.1,
                position: index.isMultiple(of: 4) ? 0.1 : -0.1
            )
        }
        let later = (0..<200).map { index in
            sample(
                "free-balance-b",
                time: 85 + Double(index) * 0.1,
                position: index.isMultiple(of: 4) ? 0.1 : 0.50
            )
        }

        let result = IndoBoardControlAnalyzer.analyze(early + later)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.earlyCenterFraction ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(result?.repeatCenterFraction ?? -1, 0.25, accuracy: 0.005)
        XCTAssertEqual(
            result?.centerChangePercentagePoints ?? 0,
            -75,
            accuracy: 0.30
        )
        XCTAssertEqual(
            result?.positiveSideExposureFraction ?? -1,
            1,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(result?.repeatReversalsPerMinute ?? 0, 0)
        XCTAssertGreaterThan(result?.earlyObservedSeconds ?? 0, 19)
    }

    func testLowConfidenceAndInsufficientWindowsFailClosed() {
        let missing = (0..<200).map { index in
            sample(
                "free-balance-a",
                time: 15 + Double(index) * 0.1,
                position: 0.1
            )
        }
        XCTAssertNil(IndoBoardControlAnalyzer.analyze(missing))

        let lowQuality = (0..<200).map { index in
            sample(
                "free-balance-b",
                time: 85 + Double(index) * 0.1,
                position: 0.2,
                confidence: 0.3
            )
        }
        XCTAssertNil(IndoBoardControlAnalyzer.analyze(missing + lowQuality))
    }

    func testGapsAndDuplicateTimestampsDoNotCreateFakeCorrections() {
        let first = (0..<40).map { index in
            sample(
                "free-balance-a",
                time: 15 + Double(index) * 10,
                position: index.isMultiple(of: 2) ? -0.8 : 0.8
            )
        }
        let second = (0..<40).map { index in
            sample(
                "free-balance-b",
                time: 85 + Double(index) * 10,
                position: index.isMultiple(of: 2) ? -0.8 : 0.8
            )
        }
        XCTAssertNil(IndoBoardControlAnalyzer.analyze(first + second))
    }

    func testDuplicateTimestampsCannotBiasCenterTime() {
        let early = (0..<200).map { index in
            sample(
                "free-balance-a",
                time: 15 + Double(index) * 0.1,
                position: 0.1
            )
        }
        let repeatSamples = (0..<200).map { index in
            sample(
                "free-balance-b",
                time: 85 + Double(index) * 0.1,
                position: 0.1
            )
        }
        let duplicated = (0..<100).map { _ in
            sample(
                "free-balance-a",
                time: 15,
                position: 0.9,
                confidence: 0.6
            )
        }

        let result = IndoBoardControlAnalyzer.analyze(
            early + duplicated + repeatSamples
        )
        XCTAssertEqual(result?.earlyCenterFraction ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(result?.repeatCenterFraction ?? -1, 1, accuracy: 0.001)
    }

    func testDirectionalMetricRequiresEnoughOffCenterSamples() {
        let early = (0..<160).map { index in
            sample(
                "free-balance-a",
                time: 15 + Double(index) * 0.1,
                position: 0.05
            )
        }
        let later = (0..<160).map { index in
            sample(
                "free-balance-b",
                time: 85 + Double(index) * 0.1,
                position: index == 0 ? -0.5 : 0.05
            )
        }
        let result = IndoBoardControlAnalyzer.analyze(early + later)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.positiveSideExposureFraction)
        XCTAssertEqual(result?.directionalObservationCount, 1)
    }

    private func sample(
        _ block: String,
        time: Double,
        position: Double,
        confidence: Double = 0.9
    ) -> IndoBoardControlObservation {
        .init(
            blockID: block,
            elapsedSeconds: time,
            rollerAlongDeck: position,
            confidence: confidence
        )
    }
}

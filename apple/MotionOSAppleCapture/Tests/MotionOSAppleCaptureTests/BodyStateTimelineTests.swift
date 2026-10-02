import XCTest
@testable import MotionOSAppleCapture

final class BodyStateTimelineTests: XCTestCase {
    func testUpsertIsIdempotentAndDeletionRemovesExactSourceSample() {
        let start = Date(timeIntervalSince1970: 1_000)
        let source = fixtureSource(name: "Scale")
        let observation = BodyStateObservation(
            id: "sample-1",
            kind: .bodyMass,
            startDate: start,
            endDate: start,
            numericValue: 70,
            unit: "kg",
            categoryValue: nil,
            provenance: .sourceReported,
            source: source,
            ingestedAt: start
        )

        var timeline = BodyStateTimeline()
        timeline.apply(upserts: [observation], at: start)
        timeline.apply(upserts: [observation], at: start.addingTimeInterval(1))

        XCTAssertEqual(timeline.observations.count, 1)
        XCTAssertEqual(timeline.latest(.bodyMass)?.numericValue, 70)

        timeline.apply(
            upserts: [],
            deletedIDs: ["sample-1"],
            at: start.addingTimeInterval(2)
        )
        XCTAssertTrue(timeline.observations.isEmpty)
    }

    func testNewerUpsertForSameIDReplacesPriorRepresentation() throws {
        let start = Date(timeIntervalSince1970: 2_000)
        let source = fixtureSource(name: "Scale")

        var timeline = BodyStateTimeline()
        timeline.apply(
            upserts: [
                BodyStateObservation(
                    id: "same",
                    kind: .bodyMass,
                    startDate: start,
                    endDate: start,
                    numericValue: 70,
                    unit: "kg",
                    categoryValue: nil,
                    provenance: .sourceReported,
                    source: source,
                    ingestedAt: start
                )
            ]
        )
        timeline.apply(
            upserts: [
                BodyStateObservation(
                    id: "same",
                    kind: .bodyMass,
                    startDate: start,
                    endDate: start,
                    numericValue: 69.8,
                    unit: "kg",
                    categoryValue: nil,
                    provenance: .sourceReported,
                    source: source,
                    metadata: ["revision": "2"],
                    ingestedAt: start.addingTimeInterval(10)
                )
            ]
        )

        let latest = try XCTUnwrap(timeline.latest(.bodyMass))
        XCTAssertEqual(latest.numericValue, 69.8)
        XCTAssertEqual(latest.metadata["revision"], "2")
        XCTAssertEqual(timeline.observations.count, 1)
    }

    func testInvalidNumericObservationIsIgnored() {
        let start = Date(timeIntervalSince1970: 3_000)
        var timeline = BodyStateTimeline()
        timeline.apply(
            upserts: [
                BodyStateObservation(
                    id: "bad",
                    kind: .bodyMass,
                    startDate: start,
                    endDate: start,
                    numericValue: .nan,
                    unit: "kg",
                    categoryValue: nil,
                    provenance: .sourceReported,
                    source: fixtureSource(name: "Broken"),
                    ingestedAt: start
                )
            ]
        )

        XCTAssertTrue(timeline.observations.isEmpty)
    }

    func testLatestDoesNotLeakFutureObservationIntoPastContext() throws {
        let start = Date(timeIntervalSince1970: 4_000)
        var timeline = BodyStateTimeline()
        timeline.apply(
            upserts: [
                valueObservation(
                    id: "old",
                    kind: .restingHeartRate,
                    date: start,
                    value: 60,
                    unit: "bpm"
                ),
                valueObservation(
                    id: "future",
                    kind: .restingHeartRate,
                    date: start.addingTimeInterval(3_600),
                    value: 55,
                    unit: "bpm"
                ),
            ]
        )

        let contextTime = start.addingTimeInterval(1_800)
        let latest = try XCTUnwrap(
            timeline.latest(.restingHeartRate, at: contextTime)
        )
        XCTAssertEqual(latest.id, "old")
        XCTAssertEqual(latest.numericValue, 60)
    }

    func testSleepAggregationCountsOnlyAsleepStagesAndClipsWindow() {
        let start = Date(timeIntervalSince1970: 10_000)
        let source = fixtureSource(name: "Sleep")
        var timeline = BodyStateTimeline()
        timeline.apply(
            upserts: [
                BodyStateObservation(
                    id: "awake",
                    kind: .sleepStage,
                    startDate: start,
                    endDate: start.addingTimeInterval(1_800),
                    numericValue: nil,
                    unit: nil,
                    categoryValue: "awake",
                    provenance: .sourceReported,
                    source: source,
                    ingestedAt: start
                ),
                BodyStateObservation(
                    id: "core",
                    kind: .sleepStage,
                    startDate: start.addingTimeInterval(1_800),
                    endDate: start.addingTimeInterval(5_400),
                    numericValue: nil,
                    unit: nil,
                    categoryValue: "asleepCore",
                    provenance: .sourceReported,
                    source: source,
                    ingestedAt: start
                ),
                BodyStateObservation(
                    id: "deep",
                    kind: .sleepStage,
                    startDate: start.addingTimeInterval(5_400),
                    endDate: start.addingTimeInterval(7_200),
                    numericValue: nil,
                    unit: nil,
                    categoryValue: "asleepDeep",
                    provenance: .sourceReported,
                    source: source,
                    ingestedAt: start
                ),
            ]
        )

        XCTAssertEqual(
            timeline.sleepDuration(
                from: start.addingTimeInterval(2_700),
                through: start.addingTimeInterval(6_300)
            ),
            3_600,
            accuracy: 1e-9
        )
    }

    func testContextSnapshotPreservesSourceObservationIDs() throws {
        let start = Date(timeIntervalSince1970: 20_000)
        var timeline = BodyStateTimeline()
        timeline.apply(
            upserts: [
                valueObservation(
                    id: "mass",
                    kind: .bodyMass,
                    date: start,
                    value: 70,
                    unit: "kg"
                ),
                valueObservation(
                    id: "hrv",
                    kind: .heartRateVariabilitySDNN,
                    date: start,
                    value: 45,
                    unit: "ms"
                ),
            ]
        )

        let snapshot = BodyStateContextSnapshot(
            capturedAt: start.addingTimeInterval(60),
            timeline: timeline
        )

        XCTAssertEqual(snapshot.latestBodyMass?.id, "mass")
        XCTAssertEqual(snapshot.latestHRV?.id, "hrv")
        XCTAssertEqual(
            Set(snapshot.sourceObservationIDs),
            Set(["mass", "hrv"])
        )
    }

    func testSourceNamesRemainDistinctForProvenance() {
        let start = Date(timeIntervalSince1970: 30_000)
        var timeline = BodyStateTimeline()
        timeline.apply(
            upserts: [
                BodyStateObservation(
                    id: "a",
                    kind: .bodyMass,
                    startDate: start,
                    endDate: start,
                    numericValue: 70,
                    unit: "kg",
                    categoryValue: nil,
                    provenance: .sourceReported,
                    source: fixtureSource(name: "Scale A"),
                    ingestedAt: start
                ),
                BodyStateObservation(
                    id: "b",
                    kind: .bodyMass,
                    startDate: start.addingTimeInterval(1),
                    endDate: start.addingTimeInterval(1),
                    numericValue: 70.1,
                    unit: "kg",
                    categoryValue: nil,
                    provenance: .sourceReported,
                    source: fixtureSource(name: "Scale B"),
                    ingestedAt: start
                ),
            ]
        )

        XCTAssertEqual(
            timeline.sourceNames(for: .bodyMass),
            ["Scale A", "Scale B"]
        )
    }

    private func valueObservation(
        id: String,
        kind: BodyStateKind,
        date: Date,
        value: Double,
        unit: String
    ) -> BodyStateObservation {
        BodyStateObservation(
            id: id,
            kind: kind,
            startDate: date,
            endDate: date,
            numericValue: value,
            unit: unit,
            categoryValue: nil,
            provenance: .sourceReported,
            source: fixtureSource(name: "Health Source"),
            ingestedAt: date
        )
    }

    private func fixtureSource(
        name: String
    ) -> BodyStateSource {
        BodyStateSource(
            bundleIdentifier: "com.example.health",
            name: name,
            version: "1.0",
            deviceName: "Device",
            manufacturer: "Example",
            model: "Model",
            hardwareVersion: "1",
            softwareVersion: "1"
        )
    }
}

import Combine
import Foundation
import MotionOSAppleCapture

@MainActor
final class FitnessPersonaCoordinator: ObservableObject {
    @Published private(set) var snapshot: FitnessPersonaSnapshot
    @Published private(set) var snapshotURL: URL?
    @Published private(set) var errorMessage: String?

    private let manager = FileManager.default

    init() {
        if let loaded = Self.loadPersistedSnapshot() {
            snapshot = loaded.snapshot
            snapshotURL = loaded.url
        } else {
            snapshot = FitnessPersonaEngine.build(
                evidence: [],
                generatedAt: Date()
            )
            snapshotURL = nil
        }
    }

    func rebuild(
        from runs: [ProductRunRecord],
        supplementalEvidence: [PersonaSessionEvidence] = [],
        bodyModelVersion: String? = nil
    ) {
        let evidence =
            runs.map(Self.sessionEvidence)
                + supplementalEvidence
        let next = FitnessPersonaEngine.build(
            evidence: evidence,
            bodyModelVersion: bodyModelVersion,
            generatedAt: Date()
        )

        snapshot = next

        do {
            snapshotURL = try persist(next)
            errorMessage = nil
        } catch {
            errorMessage = (
                "Persona snapshot could not be saved: "
                    + error.localizedDescription
            )
        }
    }

    private func persist(
        _ snapshot: FitnessPersonaSnapshot
    ) throws -> URL {
        let directory = try Self.personaDirectory()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let url = directory.appendingPathComponent(
            "fitness-persona-v0.json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(
            to: url,
            options: .atomic
        )
        return url
    }

    private static func loadPersistedSnapshot()
        -> (snapshot: FitnessPersonaSnapshot, url: URL)? {
        guard let directory = try? personaDirectory() else {
            return nil
        }

        let url = directory.appendingPathComponent(
            "fitness-persona-v0.json"
        )
        guard FileManager.default.fileExists(
            atPath: url.path
        ),
        let data = try? Data(contentsOf: url)
        else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(
            FitnessPersonaSnapshot.self,
            from: data
        ) else {
            return nil
        }

        return (snapshot, url)
    }

    private static func personaDirectory() throws -> URL {
        try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(
            "MotionOSPersona",
            isDirectory: true
        )
    }

    nonisolated private static func sessionEvidence(
        _ run: ProductRunRecord
    ) -> PersonaSessionEvidence {
        let observedAt =
            run.startedAt
                ?? run.sealedAt
                ?? .distantPast

        let sport =
            run.productManifest?.sport
                ?? run.protocolKind

        let captureMode =
            run.productManifest?.captureMode
                ?? run.captureMode
                ?? "unspecified"

        let protocolID =
            run.protocolKind
                + "|"
                + run.protocolVersion

        let contextKey = [
            sport,
            protocolID,
            captureMode,
        ].joined(separator: "|")

        var sources: [PersonaEvidenceSource] = []
        var metrics: [PersonaMetricObservation] = []

        if let summary = run.watchSummary {
            sources.append(.appleWatch)

            if let value = summary.motion.userAccelerationRMSG,
               value.isFinite {
                metrics.append(
                    PersonaMetricObservation(
                        dimension: .movement,
                        metricID: "watch.user_acceleration_rms_g",
                        label: "Watch acceleration RMS",
                        unit: "g",
                        value: value,
                        observedAt: observedAt,
                        contextKey: contextKey,
                        provenance: .derived,
                        sourceSessionID: run.runID
                    )
                )
            }

            if let value = summary.motion.rotationRateRMSRadS,
               value.isFinite {
                metrics.append(
                    PersonaMetricObservation(
                        dimension: .movement,
                        metricID: "watch.rotation_rate_rms_rad_s",
                        label: "Watch rotation RMS",
                        unit: "rad/s",
                        value: value,
                        observedAt: observedAt,
                        contextKey: contextKey,
                        provenance: .derived,
                        sourceSessionID: run.runID
                    )
                )
            }

            if let value = summary.heartRate.meanBPM,
               value.isFinite {
                metrics.append(
                    PersonaMetricObservation(
                        dimension: .cardiovascularResponse,
                        metricID: "watch.mean_heart_rate_bpm",
                        label: "Mean recorded heart rate",
                        unit: "bpm",
                        value: value,
                        observedAt: observedAt,
                        contextKey: contextKey,
                        provenance: .derived,
                        sourceSessionID: run.runID
                    )
                )
            }
        }

        if run.cameraVideoURL != nil
            || run.cameraJournalURL != nil {
            // This records the existence of camera evidence only. We do not
            // mark Vision/body geometry as characterized until a persisted,
            // validated calibration summary exists.
            sources.append(.iPhoneCamera)
        }

        if run.externalVideoURL != nil {
            sources.append(.iPhoneCamera)
        }

        return PersonaSessionEvidence(
            id: run.runID,
            sport: sport,
            protocolID: protocolID,
            captureMode: captureMode,
            observedAt: observedAt,
            completed: run.outcome == .completed,
            sources: sources,
            metrics: metrics
        )
    }
}

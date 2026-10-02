import Combine
import Foundation
import MotionOSAppleCapture

@MainActor
final class PersonaReliabilityCoordinator: ObservableObject {
    @Published private(set) var snapshot: PersonaReliabilitySnapshot
    @Published private(set) var snapshotURL: URL?
    @Published private(set) var errorMessage: String?

    init() {
        if let loaded = Self.loadPersistedSnapshot() {
            snapshot = loaded.snapshot
            snapshotURL = loaded.url
        } else {
            snapshot = PersonaReliabilityEngine.build(
                evidence: [],
                generatedAt: Date()
            )
            snapshotURL = nil
        }
    }

    func rebuild(
        from runs: [ProductRunRecord],
        supplementalEvidence: [PersonaSessionEvidence]
    ) {
        let evidence =
            runs.map(
                FitnessPersonaCoordinator.sessionEvidence
            )
            + supplementalEvidence

        let next =
            PersonaReliabilityEngine.build(
                evidence: evidence,
                generatedAt: Date()
            )

        snapshot = next

        do {
            snapshotURL = try persist(next)
            errorMessage = nil
        } catch {
            errorMessage =
                "Reliability snapshot could not be saved: "
                    + error.localizedDescription
        }
    }

    private func persist(
        _ snapshot: PersonaReliabilitySnapshot
    ) throws -> URL {
        let directory =
            try Self.personaDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let url =
            directory.appendingPathComponent(
                "persona-reliability-v1.json"
            )
        try PersonaReliabilityStore.write(
            snapshot,
            to: url
        )
        return url
    }

    private static func loadPersistedSnapshot()
        -> (
            snapshot: PersonaReliabilitySnapshot,
            url: URL
        )? {
        guard let directory =
                try? personaDirectory()
        else {
            return nil
        }

        let url =
            directory.appendingPathComponent(
                "persona-reliability-v1.json"
            )
        guard FileManager.default.fileExists(
            atPath: url.path
        ) else {
            return nil
        }

        guard let snapshot =
                try? PersonaReliabilityStore.load(
                    from: url
                )
        else {
            return nil
        }

        return (snapshot, url)
    }

    private static func personaDirectory()
        throws -> URL {
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
}

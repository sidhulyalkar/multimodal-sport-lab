import Combine
import Foundation
import MotionOSAppleCapture

struct GhostReferenceRecord: Codable, Sendable, Equatable {
    let contextKey: String
    let runID: String
    let pinnedAt: Date
    let userSelected: Bool
}

@MainActor
final class GhostComparisonCoordinator: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var references: [String: GhostReferenceRecord] = [:]
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var currentTrajectory: BodyPoseTrajectory?
    @Published private(set) var referenceTrajectory: BodyPoseTrajectory?
    @Published private(set) var summary: GhostComparisonSummary?
    @Published private(set) var summaryURL: URL?
    @Published private(set) var errorMessage: String?

    private var cache: [String: BodyPoseTrajectory] = [:]

    init() {
        loadReferences()
    }

    func comparisonContextKey(
        for run: ProductRunRecord
    ) -> String {
        let sport =
            run.productManifest?.sport
                ?? run.protocolKind
        let protocolKey =
            run.protocolKind
                + "|"
                + run.protocolVersion
        let captureMode =
            run.productManifest?.captureMode
                ?? run.captureMode
                ?? "unspecified"

        return [
            sport,
            protocolKey,
            captureMode,
        ].joined(separator: "|")
    }

    func pinnedReferenceID(
        for run: ProductRunRecord
    ) -> String? {
        references[
            comparisonContextKey(for: run)
        ]?.runID
    }

    func isPinnedReference(
        _ run: ProductRunRecord
    ) -> Bool {
        pinnedReferenceID(for: run)
            == run.runID
    }

    func referenceRun(
        for run: ProductRunRecord,
        in library: ProductRunLibrary
    ) -> ProductRunRecord? {
        guard let runID = pinnedReferenceID(
            for: run
        ) else {
            return nil
        }

        return library.runs.first {
            $0.runID == runID
        }
    }

    func pinReference(
        _ run: ProductRunRecord
    ) {
        guard run.outcome == .completed,
              run.cameraJournalURL != nil
        else {
            errorMessage =
                "A reference ghost requires a completed run with Vision pose evidence."
            return
        }

        let context = comparisonContextKey(
            for: run
        )
        references[context] = GhostReferenceRecord(
            contextKey: context,
            runID: run.runID,
            pinnedAt: Date(),
            userSelected: true
        )
        persistReferences()
        errorMessage = nil
    }

    func clearReference(
        for run: ProductRunRecord
    ) {
        references.removeValue(
            forKey: comparisonContextKey(
                for: run
            )
        )
        persistReferences()
    }

    func loadComparison(
        current: ProductRunRecord,
        reference: ProductRunRecord
    ) async {
        guard current.runID != reference.runID else {
            state = .failed(
                "Choose another comparable run to compare with this reference."
            )
            return
        }
        guard comparisonContextKey(for: current)
                == comparisonContextKey(for: reference)
        else {
            state = .failed(
                "Ghost comparison requires the same sport, protocol, and capture mode."
            )
            return
        }
        guard let currentURL = current.cameraJournalURL,
              let referenceURL = reference.cameraJournalURL
        else {
            state = .failed(
                "Both runs need camera pose journals for ghost comparison."
            )
            return
        }

        state = .loading
        errorMessage = nil
        summary = nil
        summaryURL = nil

        do {
            let currentTrajectory = try await trajectory(
                cacheKey: current.runID,
                url: currentURL,
                sha256:
                    current.productManifest?.cameraJournalSHA256
            )
            let referenceTrajectory = try await trajectory(
                cacheKey: reference.runID,
                url: referenceURL,
                sha256:
                    reference.productManifest?.cameraJournalSHA256
            )
            let summary = await Task.detached(
                priority: .userInitiated
            ) {
                GhostComparisonEngine.compare(
                    current: currentTrajectory,
                    reference: referenceTrajectory
                )
            }.value

            self.currentTrajectory = currentTrajectory
            self.referenceTrajectory = referenceTrajectory
            self.summary = summary
            self.summaryURL = try? persistSummary(
                summary,
                in: current.directoryURL
            )
            self.state = .ready
        } catch {
            let message =
                "Ghost comparison failed: "
                    + error.localizedDescription
            errorMessage = message
            state = .failed(message)
        }
    }

    private func persistSummary(
        _ summary: GhostComparisonSummary,
        in runDirectory: URL
    ) throws -> URL {
        let safeReference =
            summary.referenceSessionID
                .replacingOccurrences(
                    of: "/",
                    with: "_"
                )
        let url = runDirectory.appendingPathComponent(
            "ghost-comparison-\(safeReference).json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(
            to: url,
            options: .atomic
        )
        return url
    }

    private func trajectory(
        cacheKey: String,
        url: URL,
        sha256: String?
    ) async throws -> BodyPoseTrajectory {
        if let cached = cache[cacheKey],
           cached.sourceJournalSHA256 == sha256
                || sha256 == nil {
            return cached
        }

        let trajectory = try await Task.detached(
            priority: .userInitiated
        ) {
            try BodyPoseTrajectoryBuilder.build(
                journalURL: url,
                sourceJournalSHA256: sha256,
                targetSampleCount: 90
            )
        }.value

        cache[cacheKey] = trajectory
        return trajectory
    }

    private func loadReferences() {
        guard let url = try? referencesURL(),
              let data = try? Data(contentsOf: url)
        else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let values = try? decoder.decode(
            [String: GhostReferenceRecord].self,
            from: data
        ) {
            references = values
        }
    }

    private func persistReferences() {
        do {
            let url = try referencesURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(references).write(
                to: url,
                options: .atomic
            )
        } catch {
            errorMessage =
                "Reference ghost could not be saved: "
                    + error.localizedDescription
        }
    }

    private func referencesURL() throws -> URL {
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
        .appendingPathComponent(
            "ghost-references.json"
        )
    }
}

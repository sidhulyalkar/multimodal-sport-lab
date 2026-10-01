import Combine
import Foundation
import MotionOSAppleCapture

struct ProductRunRecord: Identifiable, Equatable, Sendable {
    let id: String
    let runID: String
    let protocolKind: String
    let protocolVersion: String
    let startedAt: Date?
    let sealedAt: Date?
    let completedBlockIDs: [String]
    let syncCueLabels: [String]
    let failureNoteCount: Int
    let directoryURL: URL
    let operatorJournalURL: URL
    let operatorMetadataURL: URL
    let productManifestURL: URL?
    let productManifest: ProductSessionManifest?
    let watchSessionID: String?
    let watchJournalURL: URL?
    let watchSummaryURL: URL?
    let watchSummary: WatchSessionSummary?
    let cameraSessionID: String?
    let cameraVideoURL: URL?
    let cameraJournalURL: URL?
    let cameraMetadataURL: URL?
    let externalVideoURL: URL?
    let externalMetadataURL: URL?
    let feedbackURL: URL?

    var sourceCount: Int {
        var count = 1 // operator evidence
        if watchJournalURL != nil { count += 1 }
        if cameraVideoURL != nil { count += 1 }
        if externalVideoURL != nil { count += 1 }
        return count
    }

    var syncComplete: Bool {
        Set(syncCueLabels).isSuperset(
            of: ["start", "middle", "end"]
        )
    }

    var captureModeLabel: String {
        productManifest?.captureMode ?? "Legacy / unspecified"
    }

    var expectedSourceCount: Int {
        if productManifest?.externalCameraExpected == true {
            return 4
        }
        return 3
    }

    var evidenceComplete: Bool {
        guard operatorMetadataURL.isFileURL,
              watchJournalURL != nil,
              cameraVideoURL != nil
        else {
            return false
        }

        if productManifest?.externalCameraExpected == true {
            return externalVideoURL != nil
        }
        return true
    }
}

@MainActor
final class ProductRunLibrary: ObservableObject {
    @Published private(set) var runs: [ProductRunRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func refresh() {
        guard !isLoading else { return }
        isLoading = true

        Task { [weak self] in
            do {
                let values = try await Task.detached(
                    priority: .utility
                ) {
                    try Self.loadRuns()
                }
                .value

                guard let self else { return }
                self.runs = values
                self.isLoading = false
                self.errorMessage = nil
            } catch {
                guard let self else { return }
                self.isLoading = false
                self.errorMessage = (
                    "Run library refresh failed: "
                        + error.localizedDescription
                )
            }
        }
    }

    private static func loadRuns() throws -> [ProductRunRecord] {
        let manager = FileManager.default
        let documents = try manager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = documents.appendingPathComponent(
            "MotionOSRuns",
            isDirectory: true
        )

        guard manager.fileExists(atPath: root.path) else {
            return []
        }

        let directories = try manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let formatter = ISO8601DateFormatter()
        let decoder = JSONDecoder()

        return directories.compactMap {
            directory -> ProductRunRecord? in
            let resource = try? directory.resourceValues(
                forKeys: [.isDirectoryKey]
            )
            guard resource?.isDirectory == true else {
                return nil
            }

            let metadataURL = directory.appendingPathComponent(
                "operator-metadata.json"
            )
            let journalURL = directory.appendingPathComponent(
                "operator-events.jsonl"
            )
            guard manager.fileExists(atPath: metadataURL.path),
                  manager.fileExists(atPath: journalURL.path),
                  let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONSerialization.jsonObject(
                    with: data
                  ) as? [String: Any],
                  let runID = metadata["run_id"] as? String
            else {
                return nil
            }

            let productManifestURL = existingURL(
                directory.appendingPathComponent(
                    "product-session.json"
                ),
                manager: manager
            )
            let productManifest: ProductSessionManifest?
            if let productManifestURL,
               let manifestData = try? Data(
                    contentsOf: productManifestURL
               ) {
                productManifest = try? decoder.decode(
                    ProductSessionManifest.self,
                    from: manifestData
                )
            } else {
                productManifest = nil
            }

            let startReadiness = stringMap(
                metadata["start_readiness"]
            )
            let sealReadiness = stringMap(
                metadata["seal_readiness"]
            )
            let watchSessionID = usefulIdentifier(
                productManifest?.watchSessionID
                    ?? sealReadiness["watch_session_id"]
                    ?? startReadiness["watch_session_id"]
            )
            let cameraSessionID = usefulIdentifier(
                productManifest?.cameraSessionID
                    ?? sealReadiness["iphone_camera_session_id"]
                    ?? startReadiness["iphone_camera_session_id"]
            )

            let watchDirectory = watchSessionID.map {
                documents
                    .appendingPathComponent(
                        "MotionOSInbox",
                        isDirectory: true
                    )
                    .appendingPathComponent(
                        $0,
                        isDirectory: true
                    )
            }
            let watchJournal = existingURL(
                watchDirectory?.appendingPathComponent(
                    "watch.jsonl"
                ),
                manager: manager
            )
            let watchSummaryURL = existingURL(
                watchDirectory?.appendingPathComponent(
                    "watch-summary.json"
                ),
                manager: manager
            )
            let watchSummary: WatchSessionSummary?
            if let watchSummaryURL,
               let summaryData = try? Data(
                    contentsOf: watchSummaryURL
               ) {
                watchSummary = try? decoder.decode(
                    WatchSessionSummary.self,
                    from: summaryData
                )
            } else {
                watchSummary = nil
            }

            let cameraDirectory = cameraSessionID.map {
                documents
                    .appendingPathComponent(
                        "MotionOSCamera",
                        isDirectory: true
                    )
                    .appendingPathComponent(
                        $0,
                        isDirectory: true
                    )
            }
            let cameraVideo = existingURL(
                cameraDirectory?.appendingPathComponent(
                    "camera.mov"
                ),
                manager: manager
            )
            let cameraJournal = existingURL(
                cameraDirectory?.appendingPathComponent(
                    "camera-frames.jsonl"
                ),
                manager: manager
            )
            let cameraMetadata = existingURL(
                cameraDirectory?.appendingPathComponent(
                    "camera-metadata.json"
                ),
                manager: manager
            )

            let externalDirectory = directory
                .appendingPathComponent(
                    "external",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "action4",
                    isDirectory: true
                )
            let externalMetadata = existingURL(
                externalDirectory.appendingPathComponent(
                    "external-camera-metadata.json"
                ),
                manager: manager
            )
            let externalVideo = externalVideoURL(
                in: externalDirectory,
                manager: manager
            )

            let completed = metadata["completed_block_ids"]
                as? [String] ?? []
            let syncLabels = metadata["sync_cue_labels"]
                as? [String] ?? []
            let failureCount = int(
                metadata["failure_note_count"]
            ) ?? 0

            return ProductRunRecord(
                id: runID,
                runID: runID,
                protocolKind:
                    metadata["protocol_kind"] as? String
                        ?? "Unknown",
                protocolVersion:
                    metadata["protocol_version"] as? String
                        ?? "unknown",
                startedAt: date(
                    metadata["started_at_utc"],
                    formatter: formatter
                ),
                sealedAt: date(
                    metadata["sealed_at_utc"],
                    formatter: formatter
                ),
                completedBlockIDs: completed,
                syncCueLabels: syncLabels,
                failureNoteCount: failureCount,
                directoryURL: directory,
                operatorJournalURL: journalURL,
                operatorMetadataURL: metadataURL,
                productManifestURL: productManifestURL,
                productManifest: productManifest,
                watchSessionID: watchSessionID,
                watchJournalURL: watchJournal,
                watchSummaryURL: watchSummaryURL,
                watchSummary: watchSummary,
                cameraSessionID: cameraSessionID,
                cameraVideoURL: cameraVideo,
                cameraJournalURL: cameraJournal,
                cameraMetadataURL: cameraMetadata,
                externalVideoURL: externalVideo,
                externalMetadataURL: externalMetadata,
                feedbackURL: existingURL(
                    directory.appendingPathComponent(
                        "product-feedback.json"
                    ),
                    manager: manager
                )
            )
        }
        .sorted {
            ($0.sealedAt ?? $0.startedAt ?? .distantPast)
                > ($1.sealedAt ?? $1.startedAt ?? .distantPast)
        }
    }

    private static func stringMap(
        _ value: Any?
    ) -> [String: String] {
        guard let dictionary = value as? [String: Any] else {
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: dictionary.compactMap {
                key,
                value -> (String, String)? in
                if let string = value as? String {
                    return (key, string)
                }
                return nil
            }
        )
    }

    private static func usefulIdentifier(
        _ value: String?
    ) -> String? {
        guard let value,
              !value.isEmpty,
              value != "unknown",
              value != "none"
        else {
            return nil
        }
        return value
    }

    private static func existingURL(
        _ url: URL?,
        manager: FileManager
    ) -> URL? {
        guard let url,
              manager.fileExists(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    private static func externalVideoURL(
        in directory: URL,
        manager: FileManager
    ) -> URL? {
        guard manager.fileExists(atPath: directory.path),
              let files = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              )
        else {
            return nil
        }
        return files.first {
            $0.lastPathComponent.hasPrefix("original-")
        }
    }

    private static func date(
        _ value: Any?,
        formatter: ISO8601DateFormatter
    ) -> Date? {
        guard let value = value as? String else {
            return nil
        }
        return formatter.date(from: value)
    }

    private static func int(
        _ value: Any?
    ) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }
}

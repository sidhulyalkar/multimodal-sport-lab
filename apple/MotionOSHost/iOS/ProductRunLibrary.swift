import Combine
import Foundation
import MotionOSAppleCapture

struct ProductRunRecord: Identifiable, Equatable, Sendable {
    let id: String
    let runID: String
    let protocolKind: String
    let protocolVersion: String
    let outcome: ProductSessionOutcome
    let captureMode: String?
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
        guard let raw = productManifest?.captureMode else {
            return "Legacy / unspecified"
        }
        return IndoBoardSessionCoordinator.CaptureMode(rawValue: raw)?
            .displayName ?? raw
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
    private var refreshPending = false

    func refresh() {
        if isLoading {
            refreshPending = true
            return
        }
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
                self.runPendingRefreshIfNeeded()
            } catch {
                guard let self else { return }
                self.isLoading = false
                self.errorMessage = (
                    "Run library refresh failed: "
                        + error.localizedDescription
                )
                self.runPendingRefreshIfNeeded()
            }
        }
    }

    private func runPendingRefreshIfNeeded() {
        guard refreshPending else { return }
        refreshPending = false
        refresh()
    }

    nonisolated private static func loadRuns() throws -> [ProductRunRecord] {
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
        let linkedWatchSessions = watchSessionIDsByProductRun(
            documents: documents,
            manager: manager
        )

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
            ) ?? linkedWatchSessions[runID]
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
            let syncLabels = productManifest?.syncReceipts.map(\.label)
                ?? (metadata["sync_cue_labels"] as? [String] ?? [])
            let failureCount = int(
                metadata["failure_note_count"]
            ) ?? 0
            let outcome =
                productManifest?.resolvedOutcome
                ?? ProductSessionOutcome(
                    rawValue:
                        metadata["run_outcome"] as? String
                            ?? ""
                )
                ?? .completed

            return ProductRunRecord(
                id: runID,
                runID: runID,
                protocolKind:
                    metadata["protocol_kind"] as? String
                        ?? "Unknown",
                protocolVersion:
                    metadata["protocol_version"] as? String
                        ?? "unknown",
                outcome: outcome,
                captureMode: productManifest?.captureMode,
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

    nonisolated private static func watchSessionIDsByProductRun(
        documents: URL,
        manager: FileManager
    ) -> [String: String] {
        let root = documents.appendingPathComponent(
            "MotionOSInbox",
            isDirectory: true
        )
        guard manager.fileExists(atPath: root.path),
              let directories = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return [:]
        }

        var candidates: [String: Set<String>] = [:]
        for directory in directories {
            let hostURL = directory.appendingPathComponent(
                "iphone-host.json"
            )
            guard let data = try? Data(contentsOf: hostURL),
                  let object = try? JSONSerialization.jsonObject(
                    with: data
                  ) as? [String: Any],
                  let transfer =
                    object["transfer_metadata"] as? [String: Any],
                  let runID = transfer["product_run_id"] as? String,
                  !runID.isEmpty
            else {
                continue
            }

            let sessionID =
                object["session_id"] as? String
                    ?? directory.lastPathComponent
            candidates[runID, default: []].insert(sessionID)
        }

        return Dictionary(
            uniqueKeysWithValues: candidates.compactMap {
                runID,
                sessionIDs -> (String, String)? in
                // Preserve the existing fail-closed policy: an ambiguous
                // product run never gets linked to an arbitrary Watch session.
                guard sessionIDs.count == 1,
                      let sessionID = sessionIDs.first
                else {
                    return nil
                }
                return (runID, sessionID)
            }
        )
    }

    nonisolated private static func stringMap(
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

    nonisolated private static func usefulIdentifier(
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

    nonisolated private static func existingURL(
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

    nonisolated private static func externalVideoURL(
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
        let originals = files.filter {
            $0.lastPathComponent.hasPrefix("original-")
        }
        guard originals.count == 1 else {
            return nil
        }
        return originals[0]
    }

    nonisolated private static func date(
        _ value: Any?,
        formatter: ISO8601DateFormatter
    ) -> Date? {
        guard let value = value as? String else {
            return nil
        }
        return formatter.date(from: value)
    }

    nonisolated private static func int(
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

import Combine
import Foundation
import MotionOSAppleCapture
import UIKit

struct WatchTransferDiagnostics: Equatable, Sendable {
    let afterShutdown: UInt64
    let sessionMismatch: UInt64
    let noActiveSession: UInt64
    let staleMotionGeneration: UInt64

    var total: UInt64 {
        afterShutdown
            &+ sessionMismatch
            &+ noActiveSession
            &+ staleMotionGeneration
    }
}

struct JournalIngestReceipt: Sendable {
    let sessionID: String
    let journalURL: URL
    let hostMetadataURL: URL
    let journalSHA256: String
    let byteCount: UInt64
    let duplicateRetransfer: Bool
    let captureOrigin: String?
    let transferDiagnostics: WatchTransferDiagnostics?
}

@MainActor
final class PhoneJournalInbox: ObservableObject {
    @Published private(set) var latestSessionID: String?
    @Published private(set) var latestJournalURL: URL?
    @Published private(set) var latestHostMetadataURL: URL?
    @Published private(set) var latestJournalSHA256: String?
    @Published private(set) var latestJournalByteCount: UInt64?
    @Published private(set) var latestDuplicateRetransfer = false
    @Published private(set) var latestCaptureOrigin: String?
    @Published private(set) var latestTransferDiagnostics: WatchTransferDiagnostics?
    @Published private(set) var latestSessionSummary: WatchSessionSummary?
    @Published private(set) var latestSessionSummaryURL: URL?
    @Published private(set) var summaryError: String?
    @Published private(set) var lastError: String?

    func ingest(
        fileURL: URL,
        metadata: [String: Any]?
    ) -> JournalIngestReceipt? {
        do {
            let receipt = try ingestVerified(
                fileURL: fileURL,
                metadata: metadata
            )
            latestSessionID = receipt.sessionID
            latestJournalURL = receipt.journalURL
            latestHostMetadataURL = receipt.hostMetadataURL
            latestJournalSHA256 = receipt.journalSHA256
            latestJournalByteCount = receipt.byteCount
            latestDuplicateRetransfer = receipt.duplicateRetransfer
            latestCaptureOrigin = receipt.captureOrigin
            latestTransferDiagnostics = receipt.transferDiagnostics
            latestSessionSummary = nil
            latestSessionSummaryURL = nil
            summaryError = nil
            lastError = nil
            deriveSessionSummary(for: receipt)
            return receipt
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func deriveSessionSummary(
        for receipt: JournalIngestReceipt
    ) {
        let journalURL = receipt.journalURL
        let sourceHash = receipt.journalSHA256
        let summaryURL = journalURL
            .deletingLastPathComponent()
            .appendingPathComponent("watch-summary.json")

        Task { [weak self] in
            do {
                let summary = try await Task.detached(
                    priority: .utility
                ) {
                    let summary = try WatchSessionSummaryBuilder.build(
                        journalURL: journalURL,
                        sourceJournalSHA256: sourceHash
                    )
                    try WatchSessionSummaryBuilder.write(
                        summary,
                        to: summaryURL
                    )
                    return summary
                }
                .value

                guard let self else { return }
                self.latestSessionSummary = summary
                self.latestSessionSummaryURL = summaryURL
                self.summaryError = nil
            } catch {
                guard let self else { return }
                self.summaryError = (
                    "Derived Watch summary unavailable: "
                        + error.localizedDescription
                )
            }
        }
    }

    private func ingestVerified(
        fileURL: URL,
        metadata: [String: Any]?
    ) throws -> JournalIngestReceipt {
        let sessionID = (metadata?["session_id"] as? String)
            ?? "unknown-\(UUID().uuidString.prefix(8).lowercased())"
        let incoming = try FileEvidence.digest(fileURL)

        if let expectedHash = metadata?["journal_sha256"] as? String,
           expectedHash.lowercased() != incoming.sha256 {
            throw InboxError.hashMismatch(
                expected: expectedHash.lowercased(),
                actual: incoming.sha256
            )
        }

        if let expectedBytes = Self.uint64(
            metadata?["journal_byte_count"]
        ),
           expectedBytes != incoming.byteCount {
            throw InboxError.byteCountMismatch(
                expected: expectedBytes,
                actual: incoming.byteCount
            )
        }

        let manager = FileManager.default
        let documents = try manager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents
            .appendingPathComponent("MotionOSInbox", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let destination = directory.appendingPathComponent("watch.jsonl")
        let duplicateRetransfer: Bool
        if manager.fileExists(atPath: destination.path) {
            let existing = try FileEvidence.digest(destination)
            guard existing == incoming else {
                throw InboxError.conflictingSessionEvidence(
                    sessionID: sessionID,
                    existingSHA256: existing.sha256,
                    incomingSHA256: incoming.sha256
                )
            }
            duplicateRetransfer = true
        } else {
            try manager.copyItem(at: fileURL, to: destination)
            duplicateRetransfer = false
        }

        let hostMetadataURL = directory.appendingPathComponent(
            "iphone-host.json"
        )
        let device = UIDevice.current
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"

        var transferMetadata: [String: Any] = [:]
        for key in [
            "schema_version",
            "stream",
            "session_id",
            "journal_sha256",
            "journal_byte_count",
            "capture_origin",
            "rejected_after_shutdown_count",
            "rejected_session_mismatch_count",
            "rejected_no_session_count",
            "rejected_stale_motion_count",
        ] {
            if let value = metadata?[key] {
                transferMetadata[key] = value
            }
        }

        let hostMetadata: [String: Any] = [
            "session_id": sessionID,
            "received_at_utc": ISO8601DateFormatter().string(from: Date()),
            "iphone_model": device.model,
            "iphone_localized_model": device.localizedModel,
            "iphone_system_name": device.systemName,
            "iphone_system_version": device.systemVersion,
            "app_version": appVersion,
            "app_build": appBuild,
            "watch_journal_sha256": incoming.sha256,
            "watch_journal_byte_count": incoming.byteCount,
            "duplicate_retransfer": duplicateRetransfer,
            "transfer_metadata": transferMetadata,
        ]
        let hostData = try JSONSerialization.data(
            withJSONObject: hostMetadata,
            options: [.prettyPrinted, .sortedKeys]
        )
        try hostData.write(
            to: hostMetadataURL,
            options: .atomic
        )

        let captureOrigin = metadata?["capture_origin"] as? String
        let diagnosticKeys = [
            "rejected_after_shutdown_count",
            "rejected_session_mismatch_count",
            "rejected_no_session_count",
            "rejected_stale_motion_count",
        ]
        let hasDiagnostics = diagnosticKeys.contains {
            metadata?[$0] != nil
        }
        let diagnostics = hasDiagnostics
            ? WatchTransferDiagnostics(
                afterShutdown: Self.uint64(
                    metadata?["rejected_after_shutdown_count"]
                ) ?? 0,
                sessionMismatch: Self.uint64(
                    metadata?["rejected_session_mismatch_count"]
                ) ?? 0,
                noActiveSession: Self.uint64(
                    metadata?["rejected_no_session_count"]
                ) ?? 0,
                staleMotionGeneration: Self.uint64(
                    metadata?["rejected_stale_motion_count"]
                ) ?? 0
            )
            : nil

        return JournalIngestReceipt(
            sessionID: sessionID,
            journalURL: destination,
            hostMetadataURL: hostMetadataURL,
            journalSHA256: incoming.sha256,
            byteCount: incoming.byteCount,
            duplicateRetransfer: duplicateRetransfer,
            captureOrigin: captureOrigin,
            transferDiagnostics: diagnostics
        )
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? Int, value >= 0 {
            return UInt64(value)
        }
        if let value = value as? NSNumber {
            let signed = value.int64Value
            return signed >= 0 ? UInt64(signed) : nil
        }
        return nil
    }

    enum InboxError: LocalizedError {
        case hashMismatch(expected: String, actual: String)
        case byteCountMismatch(expected: UInt64, actual: UInt64)
        case conflictingSessionEvidence(
            sessionID: String,
            existingSHA256: String,
            incomingSHA256: String
        )

        var errorDescription: String? {
            switch self {
            case .hashMismatch(let expected, let actual):
                "Watch journal SHA-256 mismatch. Expected \(expected), got \(actual)."
            case .byteCountMismatch(let expected, let actual):
                "Watch journal byte-count mismatch. Expected \(expected), got \(actual)."
            case .conflictingSessionEvidence(
                let sessionID,
                let existingSHA256,
                let incomingSHA256
            ):
                "Session \(sessionID) already exists with different bytes "
                    + "(existing \(existingSHA256), incoming \(incomingSHA256))."
            }
        }
    }
}

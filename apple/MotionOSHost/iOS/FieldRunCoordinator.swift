import CryptoKit
import Foundation
import UIKit

struct FieldRunStateSnapshot: Codable, Sendable {
    let watch: String
    let equipmentPod: String
    let camera: String
    let insoles: String

    enum CodingKeys: String, CodingKey {
        case watch
        case equipmentPod = "equipment_pod"
        case camera
        case insoles
    }
}

struct FieldRunEvent: Codable, Sendable {
    let schemaVersion: String
    let runID: String
    let sequence: UInt64
    let eventType: String
    let hostMonotonicNS: UInt64
    let wallTimeUTC: String
    let label: String?
    let blockID: String?
    let state: FieldRunStateSnapshot
    let timingAuthority: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case sequence
        case eventType = "event_type"
        case hostMonotonicNS = "host_monotonic_ns"
        case wallTimeUTC = "wall_time_utc"
        case label
        case blockID = "block_id"
        case state
        case timingAuthority = "timing_authority"
    }
}

struct FieldRunEvidenceBundle: Sendable {
    let directory: URL
    let ledgerURL: URL
    let metadataURL: URL
}

actor FieldRunJournal {
    private let runID: String
    private let directory: URL
    private let ledgerURL: URL
    private let metadataURL: URL
    private let encoder: JSONEncoder
    private var handle: FileHandle?
    private var sequence: UInt64 = 0
    private var eventCounts: [String: Int] = [:]

    init(runID: String) throws {
        self.runID = runID

        let manager = FileManager.default
        let documents = try manager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = documents
            .appendingPathComponent("MotionOSFieldRuns", isDirectory: true)
        let directory = root
            .appendingPathComponent(runID, isDirectory: true)
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let ledgerURL = directory.appendingPathComponent("field-run.jsonl")
        let metadataURL = directory.appendingPathComponent(
            "field-run-metadata.json"
        )
        for url in [ledgerURL, metadataURL] {
            if manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
        }

        _ = manager.createFile(atPath: ledgerURL.path, contents: nil)

        self.directory = directory
        self.ledgerURL = ledgerURL
        self.metadataURL = metadataURL
        self.handle = try FileHandle(forWritingTo: ledgerURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func append(
        eventType: String,
        label: String? = nil,
        blockID: String? = nil,
        state: FieldRunStateSnapshot
    ) throws {
        guard let handle else {
            throw FieldRunError.journalClosed
        }

        let event = FieldRunEvent(
            schemaVersion: "motionos.field-run.v1",
            runID: runID,
            sequence: sequence,
            eventType: eventType,
            hostMonotonicNS: Self.monotonicNowNS(),
            wallTimeUTC: ISO8601DateFormatter().string(from: Date()),
            label: label,
            blockID: blockID,
            state: state,
            timingAuthority: "operator_annotation_only"
        )

        var data = try encoder.encode(event)
        data.append(0x0A)
        try handle.write(contentsOf: data)

        sequence += 1
        eventCounts[eventType, default: 0] += 1
    }

    func close(
        plannedBlocks: [String],
        hostModel: String,
        hostOSVersion: String
    ) throws -> FieldRunEvidenceBundle {
        guard let handle else {
            throw FieldRunError.journalClosed
        }
        try handle.synchronize()
        try handle.close()
        self.handle = nil

        let metadata: [String: Any] = [
            "schema_version": "motionos.field-run.v1",
            "run_id": runID,
            "closed_at_utc": ISO8601DateFormatter().string(from: Date()),
            "host": [
                "model": hostModel,
                "os_version": hostOSVersion,
            ],
            "protocol_version": "motionos.longboard-calibration.v1",
            "planned_movement_blocks": plannedBlocks,
            "event_counts": eventCounts,
            "timing_authority": "operator_annotation_only",
            "ledger_sha256": try Self.sha256(ledgerURL),
            "claim_boundary": [
                "Operator marker times are protocol/troubleshooting context.",
                "They are not cross-device clock correspondences.",
                "Physical landmarks must still be detected in each sensor clock.",
            ],
        ]

        let data = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: metadataURL, options: .atomic)

        return FieldRunEvidenceBundle(
            directory: directory,
            ledgerURL: ledgerURL,
            metadataURL: metadataURL
        )
    }

    private static func monotonicNowNS() -> UInt64 {
        let seconds = ProcessInfo.processInfo.systemUptime
        return UInt64(max(0, seconds * 1_000_000_000))
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(
            upToCount: 1024 * 1024
        ), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    enum FieldRunError: LocalizedError {
        case journalClosed

        var errorDescription: String? {
            switch self {
            case .journalClosed:
                "The field-run operator ledger is already closed."
            }
        }
    }
}

@MainActor
final class FieldRunCoordinator: ObservableObject {
    struct MovementBlock: Identifiable, Sendable {
        let id: String
        let label: String
    }

    enum Phase: String {
        case idle
        case running
        case finalizing
        case evidenceReady = "evidence ready"
        case failed
    }

    static let movementBlocks: [MovementBlock] = [
        MovementBlock(id: "baseline", label: "30 s quiet stance"),
        MovementBlock(id: "pushes", label: "10 pushes"),
        MovementBlock(id: "straight-glide", label: "Straight glide"),
        MovementBlock(id: "left-carves", label: "Repeated left carves"),
        MovementBlock(id: "right-carves", label: "Repeated right carves"),
        MovementBlock(id: "front-load", label: "Front-load shifts"),
        MovementBlock(id: "rear-load", label: "Rear-load shifts"),
        MovementBlock(id: "foot-reposition", label: "Foot repositioning"),
        MovementBlock(id: "braking", label: "Controlled braking / stopping"),
        MovementBlock(id: "perturbations", label: "Stabilization perturbations"),
    ]

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var runID: String?
    @Published private(set) var activeBlockID: String?
    @Published private(set) var completedBlockIDs: Set<String> = []
    @Published private(set) var syncMarkers: Set<String> = []
    @Published private(set) var evidenceBundle: FieldRunEvidenceBundle?
    @Published private(set) var errorMessage: String?

    private var journal: FieldRunJournal?

    func start(
        state: FieldRunStateSnapshot
    ) async {
        guard phase == .idle || phase == .evidenceReady || phase == .failed
        else {
            return
        }

        errorMessage = nil
        evidenceBundle = nil
        completedBlockIDs = []
        syncMarkers = []
        activeBlockID = nil

        let id = Self.makeRunID()
        do {
            let journal = try FieldRunJournal(runID: id)
            try await journal.append(
                eventType: "run_started",
                label: "combined calibration run started",
                state: state
            )
            self.journal = journal
            runID = id
            phase = .running
        } catch {
            fail(error)
        }
    }

    func markSync(
        _ label: String,
        state: FieldRunStateSnapshot
    ) async {
        guard phase == .running,
              ["start", "middle", "end"].contains(label),
              let journal
        else {
            return
        }

        do {
            try await journal.append(
                eventType: "sync_marker",
                label: label,
                state: state
            )
            syncMarkers.insert(label)
        } catch {
            fail(error)
        }
    }

    func beginBlock(
        id: String,
        state: FieldRunStateSnapshot
    ) async {
        guard phase == .running, let journal else { return }
        do {
            try await journal.append(
                eventType: "movement_block_started",
                label: Self.label(for: id),
                blockID: id,
                state: state
            )
            activeBlockID = id
        } catch {
            fail(error)
        }
    }

    func completeBlock(
        id: String,
        state: FieldRunStateSnapshot
    ) async {
        guard phase == .running, let journal else { return }
        do {
            try await journal.append(
                eventType: "movement_block_completed",
                label: Self.label(for: id),
                blockID: id,
                state: state
            )
            completedBlockIDs.insert(id)
            if activeBlockID == id {
                activeBlockID = nil
            }
        } catch {
            fail(error)
        }
    }

    func addNote(
        _ note: String,
        state: FieldRunStateSnapshot
    ) async {
        let trimmed = note.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard phase == .running,
              !trimmed.isEmpty,
              let journal
        else {
            return
        }

        do {
            try await journal.append(
                eventType: "operator_note",
                label: trimmed,
                state: state
            )
        } catch {
            fail(error)
        }
    }

    func recordFailure(
        _ note: String,
        state: FieldRunStateSnapshot
    ) async {
        let trimmed = note.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard phase == .running,
              !trimmed.isEmpty,
              let journal
        else {
            return
        }

        do {
            try await journal.append(
                eventType: "failure_marker",
                label: trimmed,
                state: state
            )
        } catch {
            fail(error)
        }
    }

    func stop(
        state: FieldRunStateSnapshot
    ) async {
        guard phase == .running, let journal else { return }
        phase = .finalizing

        do {
            try await journal.append(
                eventType: "run_stopped",
                label: "combined calibration run stopped",
                state: state
            )
            evidenceBundle = try await journal.close(
                plannedBlocks: Self.movementBlocks.map { $0.id },
                hostModel: UIDevice.current.model,
                hostOSVersion: UIDevice.current.systemVersion
            )
            self.journal = nil
            activeBlockID = nil
            phase = .evidenceReady
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        phase = .failed
        errorMessage = error.localizedDescription
    }

    private static func label(for id: String) -> String {
        movementBlocks.first(where: { $0.id == id })?.label ?? id
    }

    private static func makeRunID() -> String {
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "m0-longboard-\(stamp)-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

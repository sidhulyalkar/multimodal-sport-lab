import Combine
import CryptoKit
import Foundation
import MotionOSAppleCapture

struct FieldProtocolBlock: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let instruction: String

    static let longboardM0: [FieldProtocolBlock] = [
        .init(
            id: "quiet-stance",
            label: "Quiet stance",
            instruction: "Hold a stable stance for 30 seconds."
        ),
        .init(
            id: "pushes",
            label: "10 pushes",
            instruction: "Perform ten deliberate pushes with normal recovery."
        ),
        .init(
            id: "straight-glide",
            label: "Straight glide",
            instruction: "Ride a steady low-curvature line."
        ),
        .init(
            id: "left-carves",
            label: "Left carves",
            instruction: "Perform repeated controlled left carves."
        ),
        .init(
            id: "right-carves",
            label: "Right carves",
            instruction: "Perform repeated controlled right carves."
        ),
        .init(
            id: "front-load",
            label: "Front-load shifts",
            instruction: "Shift plantar loading forward repeatedly."
        ),
        .init(
            id: "rear-load",
            label: "Rear-load shifts",
            instruction: "Shift plantar loading rearward repeatedly."
        ),
        .init(
            id: "foot-reposition",
            label: "Foot repositioning",
            instruction: "Perform repeated stance-foot repositioning."
        ),
        .init(
            id: "braking",
            label: "Braking / stopping",
            instruction: "Perform controlled braking and full stops."
        ),
        .init(
            id: "perturbations",
            label: "Stabilization perturbations",
            instruction: "Perform safe deliberate balance corrections."
        ),
    ]
}

struct OperatorEvidenceBundle: Sendable {
    let directory: URL
    let journalURL: URL
    let metadataURL: URL
}

private struct OperatorEvent: Codable {
    let schemaVersion: String
    let runID: String
    let sequence: UInt64
    let hostMonotonicNS: UInt64
    let wallClockUTC: String
    let kind: String
    let blockID: String?
    let label: String?
    let payload: [String: String]
    let timingSemantics: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case sequence
        case hostMonotonicNS = "host_monotonic_ns"
        case wallClockUTC = "wall_clock_utc"
        case kind
        case blockID = "block_id"
        case label
        case payload
        case timingSemantics = "timing_semantics"
    }
}

@MainActor
final class FieldRunCoordinator: ObservableObject {
    enum Phase: String {
        case idle
        case armed
        case running
        case sealing
        case sealed
        case failed
    }

    enum CoordinatorError: LocalizedError {
        case invalidState(String)
        case unknownBlock(String)
        case invalidSyncLabel(String)
        case duplicateSyncLabel(String)
        case emptyFailureNote
        case journalUnavailable
        case appendAfterSeal

        var errorDescription: String? {
            switch self {
            case .invalidState(let message):
                message
            case .unknownBlock(let id):
                "Unknown field-protocol block: \(id)"
            case .invalidSyncLabel(let label):
                "Sync cue must be start, middle, or end; got \(label)."
            case .duplicateSyncLabel(let label):
                "Sync cue \(label) is already recorded for this run."
            case .emptyFailureNote:
                "Failure note cannot be empty."
            case .journalUnavailable:
                "Operator event journal is unavailable."
            case .appendAfterSeal:
                "This operator journal is sealed and cannot accept new events."
            }
        }
    }

    static let schemaVersion = "motionos.operator-events.v1"
    static let metadataSchemaVersion = "motionos.operator-metadata.v1"
    static let protocolVersion = "motionos.longboard-calibration.v1"
    static let timingSemantics = "annotation_only_not_sync_authority"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var runID: String?
    @Published private(set) var eventCount: UInt64 = 0
    @Published private(set) var startedAtUTC: String?
    @Published private(set) var activeBlockID: String?
    @Published private(set) var completedBlockIDs: Set<String> = []
    @Published private(set) var syncCueLabels: [String] = []
    @Published private(set) var failureNoteCount = 0
    @Published private(set) var evidenceBundle: OperatorEvidenceBundle?
    @Published private(set) var errorMessage: String?

    let protocolBlocks = FieldProtocolBlock.longboardM0

    var closureWarnings: [String] {
        var warnings: [String] = []

        let missingBlocks = protocolBlocks.filter {
            !completedBlockIDs.contains($0.id)
        }
        if !missingBlocks.isEmpty {
            warnings.append(
                "\(missingBlocks.count) protocol block(s) incomplete"
            )
        }

        let missingCues = ["start", "middle", "end"].filter {
            !syncCueLabels.contains($0)
        }
        if !missingCues.isEmpty {
            warnings.append(
                "missing sync cue(s): " + missingCues.joined(separator: ", ")
            )
        }

        if activeBlockID != nil {
            warnings.append("a protocol block is still active")
        }

        return warnings
    }

    private var directoryURL: URL?
    private var journalURL: URL?
    private var metadataURL: URL?
    private var journalHandle: FileHandle?
    private var sequence: UInt64 = 0
    private var lastHostMonotonicNS: UInt64?
    private var armedAtUTC: String?
    private var sealedAtUTC: String?
    private var startReadiness: [String: String] = [:]
    private var sealReadiness: [String: String] = [:]
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    func createRun() {
        guard phase == .idle || phase == .sealed || phase == .failed else {
            fail(CoordinatorError.invalidState(
                "Seal or discard the active run before creating another."
            ))
            return
        }

        do {
            resetMutableState()
            let id = Self.makeRunID()
            let urls = try Self.makeEvidenceURLs(runID: id)

            _ = FileManager.default.createFile(
                atPath: urls.journal.path,
                contents: nil
            )
            let handle = try FileHandle(forWritingTo: urls.journal)

            runID = id
            directoryURL = urls.directory
            journalURL = urls.journal
            metadataURL = urls.metadata
            journalHandle = handle
            armedAtUTC = Self.utcNow()
            phase = .armed

            try append(
                kind: "run_created",
                label: "first multimodal longboard calibration",
                payload: [
                    "protocol_version": Self.protocolVersion,
                ]
            )
        } catch {
            fail(error)
        }
    }

    func startRun(readiness: [String: String]) {
        guard phase == .armed else {
            fail(CoordinatorError.invalidState(
                "The run must be armed before it can start."
            ))
            return
        }

        do {
            startReadiness = readiness
            startedAtUTC = Self.utcNow()
            try append(
                kind: "run_started",
                label: "operator start",
                payload: readinessPayload(
                    prefix: "readiness",
                    snapshot: readiness
                )
            )
            phase = .running
        } catch {
            fail(error)
        }
    }

    func startBlock(_ id: String) {
        guard phase == .running else {
            fail(CoordinatorError.invalidState(
                "Protocol blocks can be marked only while the run is active."
            ))
            return
        }
        guard let block = protocolBlocks.first(where: { $0.id == id }) else {
            fail(CoordinatorError.unknownBlock(id))
            return
        }

        do {
            if let current = activeBlockID, current != id {
                try append(
                    kind: "protocol_block_interrupted",
                    blockID: current,
                    label: protocolBlocks.first(where: { $0.id == current })?.label
                )
            }
            activeBlockID = id
            try append(
                kind: "protocol_block_started",
                blockID: id,
                label: block.label,
                payload: ["instruction": block.instruction]
            )
        } catch {
            fail(error)
        }
    }

    func completeBlock(_ id: String) {
        guard phase == .running else {
            fail(CoordinatorError.invalidState(
                "Protocol blocks can be completed only while the run is active."
            ))
            return
        }
        guard let block = protocolBlocks.first(where: { $0.id == id }) else {
            fail(CoordinatorError.unknownBlock(id))
            return
        }

        do {
            try append(
                kind: "protocol_block_completed",
                blockID: id,
                label: block.label
            )
            completedBlockIDs.insert(id)
            if activeBlockID == id {
                activeBlockID = nil
            }
        } catch {
            fail(error)
        }
    }

    func markSyncCue(_ label: String) {
        guard phase == .running else {
            fail(CoordinatorError.invalidState(
                "Sync cues can be annotated only while the run is active."
            ))
            return
        }

        let normalized = label.lowercased()
        guard ["start", "middle", "end"].contains(normalized) else {
            fail(CoordinatorError.invalidSyncLabel(label))
            return
        }
        guard !syncCueLabels.contains(normalized) else {
            fail(CoordinatorError.duplicateSyncLabel(normalized))
            return
        }

        do {
            try append(
                kind: "sync_cue_annotation",
                label: normalized,
                payload: [
                    "instruction":
                        "physical landmark intended to be observed by independent sensors",
                    "clock_claim":
                        "operator timestamp is not a clock correspondence",
                ]
            )
            syncCueLabels.append(normalized)
        } catch {
            fail(error)
        }
    }

    func addFailureNote(_ note: String) {
        guard phase == .running else {
            fail(CoordinatorError.invalidState(
                "Failure notes can be added only while the run is active."
            ))
            return
        }
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(CoordinatorError.emptyFailureNote)
            return
        }

        do {
            try append(
                kind: "failure_note",
                label: "operator-observed failure",
                payload: ["message": note]
            )
            failureNoteCount += 1
        } catch {
            fail(error)
        }
    }

    func addNote(_ note: String) {
        guard phase == .running else {
            fail(CoordinatorError.invalidState(
                "Notes can be added only while the run is active."
            ))
            return
        }
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        do {
            try append(
                kind: "operator_note",
                payload: ["message": note]
            )
        } catch {
            fail(error)
        }
    }

    func seal(readiness: [String: String]) {
        guard phase == .running || phase == .armed else {
            fail(CoordinatorError.invalidState(
                "Only an armed or running field run can be sealed."
            ))
            return
        }
        guard let runID,
              let directoryURL,
              let journalURL,
              let metadataURL,
              let journalHandle
        else {
            fail(CoordinatorError.journalUnavailable)
            return
        }

        phase = .sealing

        do {
            sealReadiness = readiness
            try append(
                kind: "run_sealed",
                label: "operator seal",
                payload: readinessPayload(
                    prefix: "readiness",
                    snapshot: readiness
                )
            )
            sealedAtUTC = Self.utcNow()

            try journalHandle.synchronize()
            try journalHandle.close()
            self.journalHandle = nil

            let armedAtValue: Any = armedAtUTC.map { $0 as Any } ?? NSNull()
            let startedAtValue: Any = startedAtUTC.map { $0 as Any } ?? NSNull()
            let sealedAtValue: Any = sealedAtUTC.map { $0 as Any } ?? NSNull()

            let metadata: [String: Any] = [
                "schema_version": Self.metadataSchemaVersion,
                "event_schema_version": Self.schemaVersion,
                "run_id": runID,
                "protocol_version": Self.protocolVersion,
                "armed_at_utc": armedAtValue,
                "started_at_utc": startedAtValue,
                "sealed_at_utc": sealedAtValue,
                "event_count": Int(eventCount),
                "completed_block_ids": protocolBlocks
                    .map(\.id)
                    .filter { completedBlockIDs.contains($0) },
                "sync_cue_labels": syncCueLabels,
                "failure_note_count": failureNoteCount,
                "start_readiness": startReadiness,
                "seal_readiness": sealReadiness,
                "operator_events_sha256": try Self.sha256(journalURL),
                "timing_semantics": Self.timingSemantics,
                "claim_boundary":
                    "Operator timestamps document protocol intent and observed failures only; "
                    + "they are not cross-device synchronization authority.",
            ]
            let data = try JSONSerialization.data(
                withJSONObject: metadata,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: metadataURL, options: .atomic)

            evidenceBundle = OperatorEvidenceBundle(
                directory: directoryURL,
                journalURL: journalURL,
                metadataURL: metadataURL
            )
            phase = .sealed
            errorMessage = nil
        } catch {
            fail(error)
        }
    }

    private func append(
        kind: String,
        blockID: String? = nil,
        label: String? = nil,
        payload: [String: String] = [:]
    ) throws {
        guard phase != .sealed else {
            throw CoordinatorError.appendAfterSeal
        }
        guard let runID, let journalHandle else {
            throw CoordinatorError.journalUnavailable
        }

        let now = MonotonicClock.nowNS()
        let monotonic = max(now, lastHostMonotonicNS ?? now)
        let event = OperatorEvent(
            schemaVersion: Self.schemaVersion,
            runID: runID,
            sequence: sequence,
            hostMonotonicNS: monotonic,
            wallClockUTC: Self.utcNow(),
            kind: kind,
            blockID: blockID,
            label: label,
            payload: payload,
            timingSemantics: Self.timingSemantics
        )
        var data = try encoder.encode(event)
        data.append(0x0A)
        try journalHandle.write(contentsOf: data)

        lastHostMonotonicNS = monotonic
        sequence += 1
        eventCount = sequence
        errorMessage = nil
    }

    private func readinessPayload(
        prefix: String,
        snapshot: [String: String]
    ) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: snapshot.map { key, value in
                ("\(prefix).\(key)", value)
            }
        )
    }

    private func resetMutableState() {
        try? journalHandle?.close()
        journalHandle = nil
        phase = .idle
        runID = nil
        eventCount = 0
        startedAtUTC = nil
        activeBlockID = nil
        completedBlockIDs = []
        syncCueLabels = []
        failureNoteCount = 0
        evidenceBundle = nil
        errorMessage = nil
        directoryURL = nil
        journalURL = nil
        metadataURL = nil
        sequence = 0
        lastHostMonotonicNS = nil
        armedAtUTC = nil
        sealedAtUTC = nil
        startReadiness = [:]
        sealReadiness = [:]
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        if phase == .sealing {
            phase = .failed
        }
    }

    private static func makeRunID() -> String {
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "m0-longboard-\(stamp)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func utcNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func makeEvidenceURLs(
        runID: String
    ) throws -> (
        directory: URL,
        journal: URL,
        metadata: URL
    ) {
        let manager = FileManager.default
        let documents = try manager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents
            .appendingPathComponent("MotionOSRuns", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (
            directory,
            directory.appendingPathComponent("operator-events.jsonl"),
            directory.appendingPathComponent("operator-metadata.json")
        )
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
}

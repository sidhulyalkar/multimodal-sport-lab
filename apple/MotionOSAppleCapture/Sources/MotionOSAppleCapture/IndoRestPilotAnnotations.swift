import Foundation

/// Optional experiment markers. The existing 120-second Indo protocol is unchanged.
/// These are operator annotations, never camera/Watch synchronization authority.
public enum IndoRestPilotPhase: String, Codable, CaseIterable, Sendable {
    case reference
    case late
    case postRest = "post_rest"
}

public struct IndoRestPilotContext: Equatable, Sendable {
    public let skillID: String
    public let setupID: String
    public let stanceID: String
    public let trackingMode: String

    public init(
        skillID: String,
        setupID: String,
        stanceID: String,
        trackingMode: String
    ) {
        self.skillID = skillID
        self.setupID = setupID
        self.stanceID = stanceID
        self.trackingMode = trackingMode
    }

    var payload: [String: String] {
        [
            "skill_id": skillID,
            "setup_id": setupID,
            "stance_id": stanceID,
            "tracking_mode": trackingMode,
        ]
    }

    var isValid: Bool {
        [skillID, setupID, stanceID, trackingMode].allSatisfy {
            let cleaned = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !cleaned.isEmpty && cleaned.utf8.count <= 128
        }
    }
}

public enum IndoRestPilotMarker: Equatable, Sendable {
    case boutStarted(id: String, phase: IndoRestPilotPhase, context: IndoRestPilotContext)
    case boutFinished(id: String)
    case restStarted
    case restFinished
    case effortReported(boutID: String, rating: Int)
}

public enum IndoRestPilotError: Error, Equatable {
    case invalidTransition
    case invalidIdentifier
    case invalidContext
    case invalidEffort
    case duplicateBoutID
    case duplicateEffort
    case restNotCompleted
}

/// A copyable state reducer: persist the returned event *before* adopting
/// the proposed new state, avoiding a journal/state divergence on I/O errors.
public struct IndoRestPilotRecorder: Sendable {
    public static let schemaVersion = "motionos.indo-rest-events.v1"

    public private(set) var activeBoutID: String?
    public private(set) var isResting = false
    public private(set) var lastFinishedBoutID: String?
    public private(set) var completedRestCount = 0
    private var seenBoutIDs: Set<String> = []
    private var ratedBoutIDs: Set<String> = []

    public init() {}

    private func validateID(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else {
            throw IndoRestPilotError.invalidIdentifier
        }
    }

    public mutating func accept(
        _ marker: IndoRestPilotMarker
    ) throws -> (kind: String, payload: [String: String]) {
        var payload = ["event_schema": Self.schemaVersion]
        let kind: String

        switch marker {
        case .boutStarted(let id, let phase, let context):
            try validateID(id)
            guard context.isValid else { throw IndoRestPilotError.invalidContext }
            guard activeBoutID == nil, !isResting else {
                throw IndoRestPilotError.invalidTransition
            }
            guard !seenBoutIDs.contains(id) else {
                throw IndoRestPilotError.duplicateBoutID
            }
            if phase == .postRest && completedRestCount == 0 {
                throw IndoRestPilotError.restNotCompleted
            }
            activeBoutID = id
            seenBoutIDs.insert(id)
            lastFinishedBoutID = nil
            payload["bout_id"] = id
            payload["phase"] = phase.rawValue
            payload.merge(context.payload) { _, new in new }
            kind = "indo_rest_bout_started"

        case .boutFinished(let id):
            guard activeBoutID == id, !isResting else {
                throw IndoRestPilotError.invalidTransition
            }
            activeBoutID = nil
            lastFinishedBoutID = id
            payload["bout_id"] = id
            kind = "indo_rest_bout_finished"

        case .restStarted:
            guard activeBoutID == nil, !isResting else {
                throw IndoRestPilotError.invalidTransition
            }
            isResting = true
            kind = "indo_rest_rest_started"

        case .restFinished:
            guard isResting, activeBoutID == nil else {
                throw IndoRestPilotError.invalidTransition
            }
            isResting = false
            completedRestCount += 1
            kind = "indo_rest_rest_finished"

        case .effortReported(let boutID, let rating):
            guard (0...10).contains(rating) else {
                throw IndoRestPilotError.invalidEffort
            }
            guard activeBoutID == nil, lastFinishedBoutID == boutID else {
                throw IndoRestPilotError.invalidTransition
            }
            guard !ratedBoutIDs.contains(boutID) else {
                throw IndoRestPilotError.duplicateEffort
            }
            ratedBoutIDs.insert(boutID)
            payload["bout_id"] = boutID
            payload["effort_0_10"] = String(rating)
            kind = "indo_rest_effort_reported"
        }
        return (kind: kind, payload: payload)
    }
}

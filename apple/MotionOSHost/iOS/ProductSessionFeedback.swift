import Foundation

enum ProductSessionCoachUsefulness:
    String,
    Codable,
    CaseIterable,
    Identifiable,
    Sendable {
    case helpful
    case notSure = "not_sure"
    case wrong
    case unclear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .helpful:
            "Helpful"
        case .notSure:
            "Not sure"
        case .wrong:
            "Wrong"
        case .unclear:
            "Unclear"
        }
    }
}

enum ProductSessionIntent: String, Codable, CaseIterable, Identifiable, Sendable {
    case practice
    case warmup
    case activeRecovery = "active_recovery"
    case rehabTracking = "rehab_tracking"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .practice: "Skill practice"
        case .warmup: "Warm-up"
        case .activeRecovery: "Active recovery"
        case .rehabTracking: "Rehab tracking"
        }
    }
}

enum ProductSessionPriorLoad: String, Codable, CaseIterable, Identifiable, Sendable {
    case fresh
    case moderate
    case strenuous

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fresh: "Fresh"
        case .moderate: "Some earlier exercise"
        case .strenuous: "After hard exercise"
        }
    }
}

struct ProductSessionFeedback: Codable, Equatable, Sendable {
    static let schemaVersion =
        "motionos.product-session-feedback.v1"

    let schemaVersion: String
    let runID: String
    let recordedAtUTC: String
    let perceivedStability: Int
    let perceivedEffort: Int
    let trainingIntent: ProductSessionIntent?
    let priorLoad: ProductSessionPriorLoad?
    let movementNotes: String
    let productNotes: String
    let coachUsefulness: ProductSessionCoachUsefulness?
    let coachTriedCue: Bool?
    let claimBoundary: String

    init(
        runID: String,
        perceivedStability: Int,
        perceivedEffort: Int,
        trainingIntent: ProductSessionIntent? = nil,
        priorLoad: ProductSessionPriorLoad? = nil,
        movementNotes: String,
        productNotes: String,
        coachUsefulness: ProductSessionCoachUsefulness? = nil,
        coachTriedCue: Bool? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.runID = runID
        self.recordedAtUTC =
            ISO8601DateFormatter().string(from: Date())
        self.perceivedStability = min(
            5,
            max(1, perceivedStability)
        )
        self.perceivedEffort = min(
            5,
            max(1, perceivedEffort)
        )
        self.trainingIntent = trainingIntent
        self.priorLoad = priorLoad
        self.movementNotes = movementNotes
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.productNotes = productNotes
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.coachUsefulness = coachUsefulness
        self.coachTriedCue = coachTriedCue
        self.claimBoundary = (
            "Self-reported session context for product iteration. "
                + "It is not a biomechanical measurement, diagnosis, "
                + "qualification gate, or sensor ground truth."
        )
    }
}

enum ProductSessionFeedbackStore {
    static func load(
        from url: URL
    ) throws -> ProductSessionFeedback {
        try JSONDecoder().decode(
            ProductSessionFeedback.self,
            from: Data(contentsOf: url)
        )
    }

    @discardableResult
    static func write(
        _ feedback: ProductSessionFeedback,
        to runDirectory: URL
    ) throws -> URL {
        let url = runDirectory.appendingPathComponent(
            "product-feedback.json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(feedback).write(
            to: url,
            options: .atomic
        )
        return url
    }
}

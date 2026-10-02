import Foundation

public enum ProductSessionOutcome: String, Codable, Equatable, Sendable {
    case completed
    case aborted
}

public struct ProductSessionManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = "motionos.product-session.v1"

    public let schemaVersion: String
    public let runID: String
    public let sport: String
    public let captureMode: String
    public let targetDurationSeconds: Double
    public let createdAtUTC: String
    public let outcome: ProductSessionOutcome?
    public let watchSessionID: String?
    public let watchJournalSHA256: String?
    public let watchJournalByteCount: UInt64?
    public let cameraSessionID: String?
    public let operatorJournalSHA256: String?
    public let operatorMetadataSHA256: String?
    public let cameraVideoSHA256: String?
    public let cameraJournalSHA256: String?
    public let cameraMetadataSHA256: String?
    public let syncReceipts: [SyncReceipt]
    public let externalCameraExpected: Bool
    public let externalCameraImported: Bool
    public let externalCameraSHA256: String?
    public let operatorEvidenceSealed: Bool
    public let cameraEvidenceSealed: Bool
    public let coachSummary: CoachSummary?
    public let coachExperiment: CoachExperiment?
    public let claimBoundary: String

    public struct CoachExperiment: Codable, Equatable, Sendable {
        public let sourceRunID: String
        public let headline: String
        public let tip: String
        public let drill: String
        public let sourceConfidence: Double

        public init(
            sourceRunID: String,
            headline: String,
            tip: String,
            drill: String,
            sourceConfidence: Double
        ) {
            self.sourceRunID = sourceRunID
            self.headline = headline
            self.tip = tip
            self.drill = drill
            self.sourceConfidence = min(
                1,
                max(0, sourceConfidence)
            )
        }
    }

    public struct CoachSummary: Codable, Equatable, Sendable {
        public let headline: String
        public let observation: String
        public let tip: String
        public let drill: String
        public let confidence: Double
        public let evidenceLabel: String
        public let metrics: [String: String]
        public let numericMetrics: [String: Double]?

        public init(
            headline: String,
            observation: String,
            tip: String,
            drill: String,
            confidence: Double,
            evidenceLabel: String,
            metrics: [String: String],
            numericMetrics: [String: Double]? = nil
        ) {
            self.headline = headline
            self.observation = observation
            self.tip = tip
            self.drill = drill
            self.confidence = min(1, max(0, confidence))
            self.evidenceLabel = evidenceLabel
            self.metrics = metrics
            self.numericMetrics = numericMetrics
        }
    }

    public struct SyncReceipt: Codable, Equatable, Sendable {
        public let cueID: String
        public let label: String
        public let acknowledgedAtUTC: String
        public let watchDeviceTimeNS: UInt64

        public init(
            cueID: String,
            label: String,
            acknowledgedAtUTC: String,
            watchDeviceTimeNS: UInt64
        ) {
            self.cueID = cueID
            self.label = label
            self.acknowledgedAtUTC = acknowledgedAtUTC
            self.watchDeviceTimeNS = watchDeviceTimeNS
        }
    }

    public init(
        runID: String,
        captureMode: String,
        targetDurationSeconds: Double,
        createdAtUTC: String = ISO8601DateFormatter().string(from: Date()),
        outcome: ProductSessionOutcome? = .completed,
        watchSessionID: String?,
        watchJournalSHA256: String? = nil,
        watchJournalByteCount: UInt64? = nil,
        cameraSessionID: String?,
        operatorJournalSHA256: String? = nil,
        operatorMetadataSHA256: String? = nil,
        cameraVideoSHA256: String? = nil,
        cameraJournalSHA256: String? = nil,
        cameraMetadataSHA256: String? = nil,
        syncReceipts: [SyncReceipt],
        externalCameraExpected: Bool,
        externalCameraImported: Bool,
        externalCameraSHA256: String?,
        operatorEvidenceSealed: Bool,
        cameraEvidenceSealed: Bool,
        coachSummary: CoachSummary? = nil,
        coachExperiment: CoachExperiment? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.runID = runID
        self.sport = "indo_board"
        self.captureMode = captureMode
        self.targetDurationSeconds = targetDurationSeconds
        self.createdAtUTC = createdAtUTC
        self.outcome = outcome
        self.watchSessionID = watchSessionID
        self.watchJournalSHA256 = watchJournalSHA256
        self.watchJournalByteCount = watchJournalByteCount
        self.cameraSessionID = cameraSessionID
        self.operatorJournalSHA256 = operatorJournalSHA256
        self.operatorMetadataSHA256 = operatorMetadataSHA256
        self.cameraVideoSHA256 = cameraVideoSHA256
        self.cameraJournalSHA256 = cameraJournalSHA256
        self.cameraMetadataSHA256 = cameraMetadataSHA256
        self.syncReceipts = syncReceipts
        self.externalCameraExpected = externalCameraExpected
        self.externalCameraImported = externalCameraImported
        self.externalCameraSHA256 = externalCameraSHA256
        self.operatorEvidenceSealed = operatorEvidenceSealed
        self.cameraEvidenceSealed = cameraEvidenceSealed
        self.coachSummary = coachSummary
        self.coachExperiment = coachExperiment
        self.claimBoundary = (
            "This manifest links product workflow artifacts and operator-confirmed "
                + "capture intent. It does not itself prove cross-device clock "
                + "synchronization, camera calibration, biomechanics accuracy, "
                + "or physiological accuracy."
        )
    }

    public var resolvedOutcome: ProductSessionOutcome {
        outcome ?? .completed
    }
}

public enum ProductSessionManifestStore {
    @discardableResult
    public static func write(
        _ manifest: ProductSessionManifest,
        to runDirectory: URL
    ) throws -> URL {
        let url = runDirectory.appendingPathComponent(
            "product-session.json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
        return url
    }

    public static func load(
        from url: URL
    ) throws -> ProductSessionManifest {
        try JSONDecoder().decode(
            ProductSessionManifest.self,
            from: Data(contentsOf: url)
        )
    }
}

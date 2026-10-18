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
    public let context: SessionContext?
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
    public let claimBoundary: String

    public struct SessionContext: Codable, Equatable, Sendable {
        public let profileID: String
        public let activityID: String
        public let protocolID: String
        public let dimensions: [String: String]

        public init(
            profileID: String,
            activityID: String,
            protocolID: String,
            dimensions: [String: String] = [:]
        ) {
            self.profileID = profileID
            self.activityID = activityID
            self.protocolID = protocolID
            self.dimensions = dimensions
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
        public let interventionID: String?
        public let interventionCue: String?
        public let interventionTargetMetric: String?
        public let interventionDesiredDirection: String?
        public let experimentOutcome: String?
        public let experimentBefore: Double?
        public let experimentAfter: Double?
        public let experimentRelativeChange: Double?
        public let experimentSummary: String?

        public init(
            headline: String,
            observation: String,
            tip: String,
            drill: String,
            confidence: Double,
            evidenceLabel: String,
            metrics: [String: String],
            numericMetrics: [String: Double]? = nil,
            interventionID: String? = nil,
            interventionCue: String? = nil,
            interventionTargetMetric: String? = nil,
            interventionDesiredDirection: String? = nil,
            experimentOutcome: String? = nil,
            experimentBefore: Double? = nil,
            experimentAfter: Double? = nil,
            experimentRelativeChange: Double? = nil,
            experimentSummary: String? = nil
        ) {
            self.headline = headline
            self.observation = observation
            self.tip = tip
            self.drill = drill
            self.confidence = min(1, max(0, confidence))
            self.evidenceLabel = evidenceLabel
            self.metrics = metrics
            self.numericMetrics = numericMetrics
            self.interventionID = interventionID
            self.interventionCue = interventionCue
            self.interventionTargetMetric =
                interventionTargetMetric
            self.interventionDesiredDirection =
                interventionDesiredDirection
            self.experimentOutcome = experimentOutcome
            self.experimentBefore = experimentBefore
            self.experimentAfter = experimentAfter
            self.experimentRelativeChange =
                experimentRelativeChange
            self.experimentSummary = experimentSummary
        }
    }

    public struct SyncReceipt: Codable, Equatable, Sendable {
        public let cueID: String
        public let label: String
        public let acknowledgedAtUTC: String
        public let watchDeviceTimeNS: UInt64
        /// Nearest iPhone camera PTS observed when the Watch cue
        /// acknowledgment reached the coordinator. This is a coarse cue-onset
        /// search anchor, not the visual gesture peak itself.
        public let iPhoneCameraPTSNS: UInt64?

        public init(
            cueID: String,
            label: String,
            acknowledgedAtUTC: String,
            watchDeviceTimeNS: UInt64,
            iPhoneCameraPTSNS: UInt64? = nil
        ) {
            self.cueID = cueID
            self.label = label
            self.acknowledgedAtUTC = acknowledgedAtUTC
            self.watchDeviceTimeNS = watchDeviceTimeNS
            self.iPhoneCameraPTSNS = iPhoneCameraPTSNS
        }
    }

    public init(
        runID: String,
        sport: String = "indo_board",
        context: SessionContext? = nil,
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
        coachSummary: CoachSummary? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.runID = runID
        self.sport = sport
        self.context = context
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
        self.claimBoundary = (
            "This manifest links product workflow artifacts and operator-confirmed "
                + "capture intent. It does not itself prove cross-device clock "
                + "synchronization, camera calibration, biomechanics accuracy, "
                + "or physiological accuracy."
        )
    }

    public func bindingWatchEvidence(
        watchSessionID: String,
        journalSHA256: String,
        journalByteCount: UInt64
    ) -> ProductSessionManifest {
        ProductSessionManifest(
            runID: runID,
            sport: sport,
            context: context,
            captureMode: captureMode,
            targetDurationSeconds: targetDurationSeconds,
            createdAtUTC: createdAtUTC,
            outcome: outcome,
            watchSessionID: self.watchSessionID ?? watchSessionID,
            watchJournalSHA256: journalSHA256,
            watchJournalByteCount: journalByteCount,
            cameraSessionID: cameraSessionID,
            operatorJournalSHA256: operatorJournalSHA256,
            operatorMetadataSHA256: operatorMetadataSHA256,
            cameraVideoSHA256: cameraVideoSHA256,
            cameraJournalSHA256: cameraJournalSHA256,
            cameraMetadataSHA256: cameraMetadataSHA256,
            syncReceipts: syncReceipts,
            externalCameraExpected: externalCameraExpected,
            externalCameraImported: externalCameraImported,
            externalCameraSHA256: externalCameraSHA256,
            operatorEvidenceSealed: operatorEvidenceSealed,
            cameraEvidenceSealed: cameraEvidenceSealed,
            coachSummary: coachSummary
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

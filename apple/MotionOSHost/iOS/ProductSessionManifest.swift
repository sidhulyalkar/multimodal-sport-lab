import Foundation

struct ProductSessionManifest: Codable, Equatable, Sendable {
    static let schemaVersion = "motionos.product-session.v1"

    let schemaVersion: String
    let runID: String
    let sport: String
    let captureMode: String
    let targetDurationSeconds: Double
    let createdAtUTC: String
    let watchSessionID: String?
    let cameraSessionID: String?
    let syncReceipts: [SyncReceipt]
    let externalCameraExpected: Bool
    let externalCameraImported: Bool
    let externalCameraSHA256: String?
    let operatorEvidenceSealed: Bool
    let cameraEvidenceSealed: Bool
    let claimBoundary: String

    struct SyncReceipt: Codable, Equatable, Sendable {
        let cueID: String
        let label: String
        let acknowledgedAtUTC: String
        let watchDeviceTimeNS: UInt64
    }

    init(
        runID: String,
        captureMode: String,
        targetDurationSeconds: Double,
        createdAtUTC: String = ISO8601DateFormatter().string(from: Date()),
        watchSessionID: String?,
        cameraSessionID: String?,
        syncReceipts: [SyncReceipt],
        externalCameraExpected: Bool,
        externalCameraImported: Bool,
        externalCameraSHA256: String?,
        operatorEvidenceSealed: Bool,
        cameraEvidenceSealed: Bool
    ) {
        self.schemaVersion = Self.schemaVersion
        self.runID = runID
        self.sport = "indo_board"
        self.captureMode = captureMode
        self.targetDurationSeconds = targetDurationSeconds
        self.createdAtUTC = createdAtUTC
        self.watchSessionID = watchSessionID
        self.cameraSessionID = cameraSessionID
        self.syncReceipts = syncReceipts
        self.externalCameraExpected = externalCameraExpected
        self.externalCameraImported = externalCameraImported
        self.externalCameraSHA256 = externalCameraSHA256
        self.operatorEvidenceSealed = operatorEvidenceSealed
        self.cameraEvidenceSealed = cameraEvidenceSealed
        self.claimBoundary = (
            "This manifest links product workflow artifacts and operator-confirmed "
                + "capture intent. It does not itself prove cross-device clock "
                + "synchronization, camera calibration, biomechanics accuracy, "
                + "or physiological accuracy."
        )
    }
}

enum ProductSessionManifestStore {
    @discardableResult
    static func write(
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

    static func load(
        from url: URL
    ) throws -> ProductSessionManifest {
        try JSONDecoder().decode(
            ProductSessionManifest.self,
            from: Data(contentsOf: url)
        )
    }
}

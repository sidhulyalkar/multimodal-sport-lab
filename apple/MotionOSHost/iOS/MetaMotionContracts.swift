import Foundation

/// Backend-neutral values used by the optional MetaMotion equipment-pod UI.
/// Keeping these contracts outside the MetaWear package lets the default
/// MotionOS product build stay lean while preserving the lab adapter surface.
struct MetaMotionCandidate: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int?
}

struct MetaMotionVector: Sendable, Equatable {
    let x: Double
    let y: Double
    let z: Double
}

struct MetaMotionDeviceMetadata: Sendable, Equatable {
    let identifier: UUID
    let model: String
    let modelNumber: String
    let serialNumber: String
    let firmwareRevision: String
    let hardwareRevision: String
    let requestedAccelHz: Double
    let requestedAccelRangeG: Float
    let requestedGyroHz: Double
    let requestedGyroRangeDPS: Float
    let sdkRevision: String
}

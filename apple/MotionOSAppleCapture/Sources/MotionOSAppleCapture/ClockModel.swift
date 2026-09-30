import Foundation

public struct ClockModel: Codable, Sendable, Equatable {
    public let slope: Double
    public let interceptNS: Double
    public let residualRMSNS: Double

    enum CodingKeys: String, CodingKey {
        case slope
        case interceptNS = "intercept_ns"
        case residualRMSNS = "residual_rms_ns"
    }

    public init(slope: Double, interceptNS: Double, residualRMSNS: Double) {
        self.slope = slope
        self.interceptNS = interceptNS
        self.residualRMSNS = residualRMSNS
    }

    public func sessionTime(deviceTimeNS: UInt64) -> UInt64 {
        UInt64(max(0, (slope * Double(deviceTimeNS) + interceptNS).rounded()))
    }

    public var driftPPM: Double { (slope - 1.0) * 1_000_000.0 }
}

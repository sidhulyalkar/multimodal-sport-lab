import Foundation

public struct WatchMotionDerivedMetrics: Equatable, Sendable {
    public let userAccelerationG: Double
    public let rotationRateRadS: Double

    public init(
        userAccelerationG: Double,
        rotationRateRadS: Double
    ) {
        self.userAccelerationG = userAccelerationG
        self.rotationRateRadS = rotationRateRadS
    }
}

public enum WatchMotionDerivation {
    private static let standardGravity = 9.80665

    public static func derive(
        payload: [String: JSONValue]
    ) -> WatchMotionDerivedMetrics? {
        guard let gx = number(payload["gx"]),
              let gy = number(payload["gy"]),
              let gz = number(payload["gz"])
        else {
            return nil
        }

        let userAccelerationG: Double
        if let x = number(payload["user_ax"]),
           let y = number(payload["user_ay"]),
           let z = number(payload["user_az"]) {
            userAccelerationG =
                sqrt(x * x + y * y + z * z) / standardGravity
        } else if let x = number(payload["ax"]),
                  let y = number(payload["ay"]),
                  let z = number(payload["az"]) {
            // Legacy fallback for journals that predate decomposed
            // Core Motion user-acceleration channels.
            let totalG = sqrt(x * x + y * y + z * z) / standardGravity
            userAccelerationG = abs(totalG - 1.0)
        } else {
            return nil
        }

        return WatchMotionDerivedMetrics(
            userAccelerationG: userAccelerationG,
            rotationRateRadS: sqrt(gx * gx + gy * gy + gz * gz)
        )
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard case .number(let number) = value,
              number.isFinite
        else {
            return nil
        }
        return number
    }
}

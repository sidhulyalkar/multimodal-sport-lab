#if os(watchOS) && canImport(CoreMotion)
import CoreMotion
import Foundation

public final class WatchMotionRecorder: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue: OperationQueue
    private var sequence: UInt64 = 0

    public init() {
        queue = OperationQueue()
        queue.name = "motionos.watch.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    public func start(
        sessionID: String,
        deviceID: String,
        hz: Double = 50,
        sink: @escaping @Sendable (SensorEnvelope) -> Void
    ) throws {
        guard manager.isDeviceMotionAvailable else {
            throw RecorderError.deviceMotionUnavailable
        }
        sequence = 0
        manager.deviceMotionUpdateInterval = 1.0 / hz
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let timestampNS = UInt64(max(0, motion.timestamp * 1_000_000_000))
            let standardGravity = 9.80665
            let totalAX = (motion.userAcceleration.x + motion.gravity.x) * standardGravity
            let totalAY = (motion.userAcceleration.y + motion.gravity.y) * standardGravity
            let totalAZ = (motion.userAcceleration.z + motion.gravity.z) * standardGravity

            let payload: [String: JSONValue] = [
                // Canonical IMU channels: SI units shared with equipment adapters.
                "ax": .number(totalAX),
                "ay": .number(totalAY),
                "az": .number(totalAZ),
                "gx": .number(motion.rotationRate.x),
                "gy": .number(motion.rotationRate.y),
                "gz": .number(motion.rotationRate.z),

                // Preserve decomposed Core Motion signals for later modeling.
                "user_ax": .number(motion.userAcceleration.x * standardGravity),
                "user_ay": .number(motion.userAcceleration.y * standardGravity),
                "user_az": .number(motion.userAcceleration.z * standardGravity),
                "gravity_x": .number(motion.gravity.x * standardGravity),
                "gravity_y": .number(motion.gravity.y * standardGravity),
                "gravity_z": .number(motion.gravity.z * standardGravity),
                "roll": .number(motion.attitude.roll),
                "pitch": .number(motion.attitude.pitch),
                "yaw": .number(motion.attitude.yaw),
                "units": .object([
                    "acceleration": .string("m/s^2"),
                    "rotation_rate": .string("rad/s"),
                    "attitude": .string("rad")
                ])
            ]
            let event = SensorEnvelope(
                sessionID: sessionID,
                deviceID: deviceID,
                stream: "/body/watch/imu",
                sequence: self.sequence,
                deviceTimeNS: timestampNS,
                payload: payload
            )
            self.sequence += 1
            sink(event)
        }
    }

    public func stop() {
        manager.stopDeviceMotionUpdates()
    }

    public enum RecorderError: Error {
        case deviceMotionUnavailable
    }
}
#endif

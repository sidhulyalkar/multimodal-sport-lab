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
        manager.deviceMotionUpdateInterval = 1.0 / hz
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let timestampNS = UInt64(max(0, motion.timestamp * 1_000_000_000))
            let payload: [String: JSONValue] = [
                "user_ax": .number(motion.userAcceleration.x),
                "user_ay": .number(motion.userAcceleration.y),
                "user_az": .number(motion.userAcceleration.z),
                "gravity_x": .number(motion.gravity.x),
                "gravity_y": .number(motion.gravity.y),
                "gravity_z": .number(motion.gravity.z),
                "gx": .number(motion.rotationRate.x),
                "gy": .number(motion.rotationRate.y),
                "gz": .number(motion.rotationRate.z),
                "roll": .number(motion.attitude.roll),
                "pitch": .number(motion.attitude.pitch),
                "yaw": .number(motion.attitude.yaw)
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

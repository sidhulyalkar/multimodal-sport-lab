import Foundation

/// A lossy, disposable real-time preview of an active Watch recording.
///
/// The sealed Watch journal is the authoritative evidence. A snapshot is a
/// compact derived summary sent at roughly 4 Hz while the iPhone is
/// reachable. Snapshots are never queued, retried, or journaled, and a
/// recording must remain complete even if every snapshot is dropped.
public struct LiveTelemetrySnapshot: Sendable, Equatable {
    public static let messageType = "motionos_live_telemetry"
    public static let schemaVersion = 1

    public enum Activity: String, Sendable, Equatable {
        case recording
        case paused
    }

    /// Motion derived from the IMU samples observed since the previous
    /// snapshot. Absent when no IMU sample arrived in that window.
    public struct Motion: Sendable, Equatable {
        public let userAccelerationPeakG: Double
        public let userAccelerationLatestG: Double
        public let rotationRatePeakRadS: Double
        public let rotationRateLatestRadS: Double
        public let rollRadians: Double?
        public let pitchRadians: Double?
        public let yawRadians: Double?
        public let windowSampleCount: Int

        public init(
            userAccelerationPeakG: Double,
            userAccelerationLatestG: Double,
            rotationRatePeakRadS: Double,
            rotationRateLatestRadS: Double,
            rollRadians: Double?,
            pitchRadians: Double?,
            yawRadians: Double?,
            windowSampleCount: Int
        ) {
            self.userAccelerationPeakG = userAccelerationPeakG
            self.userAccelerationLatestG = userAccelerationLatestG
            self.rotationRatePeakRadS = rotationRatePeakRadS
            self.rotationRateLatestRadS = rotationRateLatestRadS
            self.rollRadians = rollRadians
            self.pitchRadians = pitchRadians
            self.yawRadians = yawRadians
            self.windowSampleCount = windowSampleCount
        }
    }

    public let sessionID: String
    /// Monotonic within one session, starting at 0.
    public let sequence: UInt64
    /// Watch monotonic clock when the snapshot was built.
    public let sourceMonotonicNS: UInt64
    /// Watch wall clock when the snapshot was built. Diagnostics only: the
    /// iPhone judges freshness by its own receive time.
    public let sourceSentAt: Date
    public let activity: Activity
    /// Seconds since the Watch recording started, when known.
    public let elapsedSeconds: Double?
    public let imuSampleCount: UInt64
    public let effectiveIMUHz: Double?
    public let recentMedianIMUHz: Double?
    public let maxIMUGapMS: Double
    public let nonMonotonicIMUCount: UInt64
    public let motion: Motion?
    /// Present only when the Watch has a recent heart-rate sample.
    public let heartRateBPM: Double?
    public let watchBatteryFraction: Double?

    public init(
        sessionID: String,
        sequence: UInt64,
        sourceMonotonicNS: UInt64,
        sourceSentAt: Date,
        activity: Activity,
        elapsedSeconds: Double? = nil,
        imuSampleCount: UInt64,
        effectiveIMUHz: Double?,
        recentMedianIMUHz: Double?,
        maxIMUGapMS: Double,
        nonMonotonicIMUCount: UInt64,
        motion: Motion?,
        heartRateBPM: Double?,
        watchBatteryFraction: Double?
    ) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.sourceMonotonicNS = sourceMonotonicNS
        self.sourceSentAt = sourceSentAt
        self.activity = activity
        self.elapsedSeconds = elapsedSeconds
        self.imuSampleCount = imuSampleCount
        self.effectiveIMUHz = effectiveIMUHz
        self.recentMedianIMUHz = recentMedianIMUHz
        self.maxIMUGapMS = maxIMUGapMS
        self.nonMonotonicIMUCount = nonMonotonicIMUCount
        self.motion = motion
        self.heartRateBPM = heartRateBPM
        self.watchBatteryFraction = watchBatteryFraction
    }

    public enum ParseError: Error, Equatable {
        case notLiveTelemetry
        case unsupportedSchema
        case missingField(String)
        case invalidField(String)
    }

    private enum Key {
        static let message = "motionos_message"
        static let schema = "schema_version"
        static let session = "session_id"
        static let sequence = "sequence"
        static let monotonic = "source_monotonic_ns"
        static let sentAt = "sent_at_unix_s"
        static let activity = "activity"
        static let elapsed = "recording_elapsed_s"
        static let imuCount = "imu_sample_count"
        static let effectiveHz = "imu_effective_hz"
        static let medianHz = "imu_recent_median_hz"
        static let maxGap = "imu_max_gap_ms"
        static let nonMonotonic = "imu_non_monotonic_count"
        static let accelPeak = "user_accel_peak_g"
        static let accelLatest = "user_accel_latest_g"
        static let rotationPeak = "rotation_peak_rad_s"
        static let rotationLatest = "rotation_latest_rad_s"
        static let roll = "roll_rad"
        static let pitch = "pitch_rad"
        static let yaw = "yaw_rad"
        static let windowSamples = "motion_window_samples"
        static let heartRate = "heart_rate_bpm"
        static let battery = "watch_battery_fraction"
    }

    /// A WatchConnectivity-safe property-list dictionary. Unavailable signals
    /// are omitted rather than encoded as zero.
    public var message: [String: Any] {
        var message: [String: Any] = [
            Key.message: Self.messageType,
            Key.schema: Self.schemaVersion,
            Key.session: sessionID,
            Key.sequence: NSNumber(value: sequence),
            Key.monotonic: NSNumber(value: sourceMonotonicNS),
            Key.sentAt: sourceSentAt.timeIntervalSince1970,
            Key.activity: activity.rawValue,
            Key.imuCount: NSNumber(value: imuSampleCount),
            Key.maxGap: maxIMUGapMS,
            Key.nonMonotonic: NSNumber(value: nonMonotonicIMUCount),
        ]
        message[Key.elapsed] = elapsedSeconds
        message[Key.effectiveHz] = effectiveIMUHz
        message[Key.medianHz] = recentMedianIMUHz
        if let motion {
            message[Key.accelPeak] = motion.userAccelerationPeakG
            message[Key.accelLatest] = motion.userAccelerationLatestG
            message[Key.rotationPeak] = motion.rotationRatePeakRadS
            message[Key.rotationLatest] = motion.rotationRateLatestRadS
            message[Key.roll] = motion.rollRadians
            message[Key.pitch] = motion.pitchRadians
            message[Key.yaw] = motion.yawRadians
            message[Key.windowSamples] = motion.windowSampleCount
        }
        message[Key.heartRate] = heartRateBPM
        message[Key.battery] = watchBatteryFraction
        return message
    }

    /// Returns `true` when the dictionary claims to be live telemetry, even if
    /// it later fails validation.
    public static func isLiveTelemetry(_ message: [String: Any]) -> Bool {
        message[Key.message] as? String == messageType
    }

    /// Strictly validates a received dictionary. Any malformed field rejects
    /// the whole packet; the caller drops it.
    public init(message: [String: Any]) throws(ParseError) {
        guard Self.isLiveTelemetry(message) else {
            throw .notLiveTelemetry
        }
        guard let schema = try Self.optionalUInt(message, Key.schema),
              schema == UInt64(Self.schemaVersion)
        else {
            throw .unsupportedSchema
        }

        guard let sessionID = message[Key.session] as? String else {
            throw .missingField(Key.session)
        }
        guard !sessionID.isEmpty, sessionID.count <= 256 else {
            throw .invalidField(Key.session)
        }

        guard let rawActivity = message[Key.activity] as? String else {
            throw .missingField(Key.activity)
        }
        guard let activity = Activity(rawValue: rawActivity) else {
            throw .invalidField(Key.activity)
        }

        let sentAt = try Self.requiredDouble(message, Key.sentAt)
        guard sentAt > 0 else { throw .invalidField(Key.sentAt) }

        let maxGap = try Self.requiredDouble(message, Key.maxGap)
        guard maxGap >= 0 else { throw .invalidField(Key.maxGap) }

        let elapsed = try Self.optionalDouble(message, Key.elapsed)
        if let elapsed, !(0...86_400).contains(elapsed) {
            throw .invalidField(Key.elapsed)
        }

        let motion = try Self.parseMotion(message)
        let heartRate = try Self.optionalDouble(message, Key.heartRate)
        if let heartRate, !(20...260).contains(heartRate) {
            throw .invalidField(Key.heartRate)
        }
        let battery = try Self.optionalDouble(message, Key.battery)
        if let battery, !(0...1).contains(battery) {
            throw .invalidField(Key.battery)
        }

        self.init(
            sessionID: sessionID,
            sequence: try Self.requiredUInt(message, Key.sequence),
            sourceMonotonicNS: try Self.requiredUInt(message, Key.monotonic),
            sourceSentAt: Date(timeIntervalSince1970: sentAt),
            activity: activity,
            elapsedSeconds: elapsed,
            imuSampleCount: try Self.requiredUInt(message, Key.imuCount),
            effectiveIMUHz: try Self.optionalRate(message, Key.effectiveHz),
            recentMedianIMUHz: try Self.optionalRate(message, Key.medianHz),
            maxIMUGapMS: maxGap,
            nonMonotonicIMUCount: try Self.requiredUInt(
                message,
                Key.nonMonotonic
            ),
            motion: motion,
            heartRateBPM: heartRate,
            watchBatteryFraction: battery
        )
    }

    private static func parseMotion(
        _ message: [String: Any]
    ) throws(ParseError) -> Motion? {
        let magnitudeKeys = [
            Key.accelPeak,
            Key.accelLatest,
            Key.rotationPeak,
            Key.rotationLatest,
            Key.windowSamples,
        ]
        let present = magnitudeKeys.filter { message[$0] != nil }
        guard !present.isEmpty else {
            for key in [Key.roll, Key.pitch, Key.yaw] where message[key] != nil {
                throw .invalidField(key)
            }
            return nil
        }
        guard present.count == magnitudeKeys.count else {
            let missing = magnitudeKeys.first { message[$0] == nil }
            throw .missingField(missing ?? Key.accelPeak)
        }

        func magnitude(_ key: String) throws(ParseError) -> Double {
            let value = try requiredDouble(message, key)
            guard value >= 0 else { throw .invalidField(key) }
            return value
        }

        func angle(_ key: String) throws(ParseError) -> Double? {
            guard let value = try optionalDouble(message, key) else {
                return nil
            }
            guard abs(value) <= 2 * Double.pi + 1e-9 else {
                throw .invalidField(key)
            }
            return value
        }

        let samples = try requiredUInt(message, Key.windowSamples)
        guard samples > 0, samples <= 10_000 else {
            throw .invalidField(Key.windowSamples)
        }

        return Motion(
            userAccelerationPeakG: try magnitude(Key.accelPeak),
            userAccelerationLatestG: try magnitude(Key.accelLatest),
            rotationRatePeakRadS: try magnitude(Key.rotationPeak),
            rotationRateLatestRadS: try magnitude(Key.rotationLatest),
            rollRadians: try angle(Key.roll),
            pitchRadians: try angle(Key.pitch),
            yawRadians: try angle(Key.yaw),
            windowSampleCount: Int(samples)
        )
    }

    private static func optionalRate(
        _ message: [String: Any],
        _ key: String
    ) throws(ParseError) -> Double? {
        guard let value = try optionalDouble(message, key) else {
            return nil
        }
        guard (0...1_000).contains(value) else { throw .invalidField(key) }
        return value
    }

    private static func requiredDouble(
        _ message: [String: Any],
        _ key: String
    ) throws(ParseError) -> Double {
        guard let value = try optionalDouble(message, key) else {
            throw .missingField(key)
        }
        return value
    }

    private static func optionalDouble(
        _ message: [String: Any],
        _ key: String
    ) throws(ParseError) -> Double? {
        guard let raw = message[key] else { return nil }
        guard !isBoolean(raw) else { throw .invalidField(key) }

        let value: Double
        if let number = raw as? NSNumber {
            value = number.doubleValue
        } else if let number = raw as? Double {
            value = number
        } else if let number = raw as? Int {
            value = Double(number)
        } else {
            throw .invalidField(key)
        }
        guard value.isFinite else { throw .invalidField(key) }
        return value
    }

    private static func requiredUInt(
        _ message: [String: Any],
        _ key: String
    ) throws(ParseError) -> UInt64 {
        guard let value = try optionalUInt(message, key) else {
            throw .missingField(key)
        }
        return value
    }

    private static func optionalUInt(
        _ message: [String: Any],
        _ key: String
    ) throws(ParseError) -> UInt64? {
        guard let raw = message[key] else { return nil }
        guard !isBoolean(raw) else { throw .invalidField(key) }

        if let value = raw as? UInt64 {
            return value
        }
        if let value = raw as? Int {
            guard value >= 0 else { throw .invalidField(key) }
            return UInt64(value)
        }
        if let number = raw as? NSNumber {
            let double = number.doubleValue
            guard double.isFinite,
                  double >= 0,
                  double.rounded() == double
            else {
                throw .invalidField(key)
            }
            return number.uint64Value
        }
        throw .invalidField(key)
    }

    private static func isBoolean(_ value: Any) -> Bool {
        if value is Bool && !(value is NSNumber) {
            return true
        }
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

/// Aggregates per-sample derived motion between two live snapshots, so a
/// 4 Hz preview still reflects short, sharp movements.
public struct LiveMotionWindow: Sendable, Equatable {
    private var accelerationPeak = 0.0
    private var rotationPeak = 0.0
    private var latest: WatchMotionDerivedMetrics?
    private var roll: Double?
    private var pitch: Double?
    private var yaw: Double?
    private var sampleCount = 0

    public init() {}

    public mutating func observe(
        _ metrics: WatchMotionDerivedMetrics,
        roll: Double?,
        pitch: Double?,
        yaw: Double?
    ) {
        guard metrics.userAccelerationG.isFinite,
              metrics.rotationRateRadS.isFinite
        else {
            return
        }
        accelerationPeak = max(accelerationPeak, metrics.userAccelerationG)
        rotationPeak = max(rotationPeak, metrics.rotationRateRadS)
        latest = metrics
        self.roll = roll.flatMap { $0.isFinite ? $0 : nil }
        self.pitch = pitch.flatMap { $0.isFinite ? $0 : nil }
        self.yaw = yaw.flatMap { $0.isFinite ? $0 : nil }
        sampleCount += 1
    }

    /// Returns the window summary and starts a new window.
    public mutating func drain() -> LiveTelemetrySnapshot.Motion? {
        defer { self = LiveMotionWindow() }
        guard let latest, sampleCount > 0 else { return nil }
        return LiveTelemetrySnapshot.Motion(
            userAccelerationPeakG: accelerationPeak,
            userAccelerationLatestG: latest.userAccelerationG,
            rotationRatePeakRadS: rotationPeak,
            rotationRateLatestRadS: latest.rotationRateRadS,
            rollRadians: roll,
            pitchRadians: pitch,
            yawRadians: yaw,
            windowSampleCount: sampleCount
        )
    }
}

/// Where disposable live snapshots go. Today this is WatchConnectivity
/// `sendMessage`; an active mirrored workout could later use the HealthKit
/// workout data channel without changing the publisher or the Observatory.
public protocol LiveTelemetryChannel: AnyObject {
    /// Whether a packet can be delivered immediately right now.
    var canDeliverLiveTelemetry: Bool { get }

    /// Sends immediately or drops. Implementations must never queue the
    /// packet for later delivery or retry it.
    @discardableResult
    func sendLiveTelemetry(_ message: [String: Any]) -> Bool
}

/// Decides when a live snapshot may be built and attempted.
///
/// Each cadence slot is consumed whether or not the channel is available,
/// so an unreachable iPhone can never cause a tight send loop from the
/// 50 Hz IMU path. Unavailable slots drop the motion window instead of
/// carrying it into a later packet.
public struct LiveTelemetryPublisher: Sendable, Equatable {
    public static let defaultInterval: TimeInterval = 0.25

    public struct Slot: Sendable, Equatable {
        public let sequence: UInt64
        public let motion: LiveTelemetrySnapshot.Motion?
    }

    public let interval: TimeInterval
    public private(set) var sessionID: String?
    public private(set) var nextSequence: UInt64 = 0
    public private(set) var attemptedCount: UInt64 = 0
    public private(set) var droppedUnavailableCount: UInt64 = 0
    private var nextSlotAt: TimeInterval?
    private var window = LiveMotionWindow()

    public init(interval: TimeInterval = Self.defaultInterval) {
        self.interval = max(0.05, interval)
    }

    public mutating func begin(sessionID: String) {
        self = LiveTelemetryPublisher(interval: interval)
        self.sessionID = sessionID
    }

    public mutating func end() {
        sessionID = nil
        nextSlotAt = nil
        window = LiveMotionWindow()
    }

    public mutating func observe(
        _ metrics: WatchMotionDerivedMetrics,
        roll: Double?,
        pitch: Double?,
        yaw: Double?
    ) {
        guard sessionID != nil else { return }
        window.observe(metrics, roll: roll, pitch: pitch, yaw: yaw)
    }

    /// Call from any frequent path with a monotonic clock in seconds.
    /// `channelAvailable` is only evaluated when a slot is due. Returns a
    /// slot to send now, or `nil` to do nothing.
    public mutating func takeSlot(
        at now: TimeInterval,
        channelAvailable: @autoclosure () -> Bool
    ) -> Slot? {
        guard sessionID != nil else { return nil }
        if let nextSlotAt, now < nextSlotAt,
           nextSlotAt - now <= interval {
            return nil
        }
        // Keep a fixed grid so 50 Hz callbacks yield a true 4 Hz cadence;
        // after a gap, restart the grid instead of bursting to catch up.
        if let nextSlotAt, now - nextSlotAt < interval {
            self.nextSlotAt = nextSlotAt + interval
        } else {
            nextSlotAt = now + interval
        }
        let motion = window.drain()

        guard channelAvailable() else {
            droppedUnavailableCount &+= 1
            return nil
        }

        let sequence = nextSequence
        nextSequence &+= 1
        attemptedCount &+= 1
        return Slot(sequence: sequence, motion: motion)
    }
}

import Foundation

public struct SampleTimingHealth: Sendable, Equatable {
    public private(set) var sampleCount: UInt64 = 0
    public private(set) var firstTimestampNS: UInt64?
    public private(set) var lastTimestampNS: UInt64?
    public private(set) var maxGapNS: UInt64 = 0
    public private(set) var nonMonotonicCount: UInt64 = 0

    public let recentWindowSize: Int
    private var recentIntervalsNS: [UInt64] = []

    public init(recentWindowSize: Int = 128) {
        self.recentWindowSize = max(1, recentWindowSize)
    }

    public mutating func observe(timestampNS: UInt64) {
        sampleCount += 1

        guard let previous = lastTimestampNS else {
            firstTimestampNS = timestampNS
            lastTimestampNS = timestampNS
            return
        }

        guard timestampNS > previous else {
            nonMonotonicCount += 1
            return
        }

        let interval = timestampNS - previous
        maxGapNS = max(maxGapNS, interval)
        recentIntervalsNS.append(interval)
        if recentIntervalsNS.count > recentWindowSize {
            recentIntervalsNS.removeFirst(
                recentIntervalsNS.count - recentWindowSize
            )
        }
        lastTimestampNS = timestampNS
    }

    public var effectiveHz: Double? {
        guard sampleCount >= 2,
              let firstTimestampNS,
              let lastTimestampNS,
              lastTimestampNS > firstTimestampNS
        else {
            return nil
        }

        let validIntervals = sampleCount - nonMonotonicCount - 1
        guard validIntervals > 0 else { return nil }

        let spanSeconds = Double(
            lastTimestampNS - firstTimestampNS
        ) / 1_000_000_000.0
        guard spanSeconds > 0 else { return nil }
        return Double(validIntervals) / spanSeconds
    }

    public var recentMedianIntervalNS: UInt64? {
        guard !recentIntervalsNS.isEmpty else { return nil }
        let sorted = recentIntervalsNS.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            let left = sorted[midpoint - 1]
            let right = sorted[midpoint]
            return left + (right - left) / 2
        }
        return sorted[midpoint]
    }

    public var recentMedianHz: Double? {
        guard let interval = recentMedianIntervalNS,
              interval > 0
        else {
            return nil
        }
        return 1_000_000_000.0 / Double(interval)
    }

    public var maxGapMS: Double {
        Double(maxGapNS) / 1_000_000.0
    }
}

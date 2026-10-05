import Foundation

public struct DualViewPlaybackSyncDecision:
    Equatable,
    Sendable {
    public let driftMS: Double
    public let shouldCorrect: Bool

    public init(
        driftMS: Double,
        shouldCorrect: Bool
    ) {
        self.driftMS = driftMS
        self.shouldCorrect = shouldCorrect
    }
}

public struct DualViewPlaybackReferenceWindow:
    Equatable,
    Sendable {
    public let startSeconds: Double
    public let endSeconds: Double

    public init(
        startSeconds: Double,
        endSeconds: Double
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    public var durationSeconds: Double {
        max(
            0,
            endSeconds - startSeconds
        )
    }
}

public enum DualViewPlaybackSyncPolicy {
    public static func referenceOverlapWindow(
        referenceDurationSeconds: Double,
        sourceDurationNS: UInt64,
        slope: Double,
        interceptNS: Double
    ) -> DualViewPlaybackReferenceWindow? {
        guard referenceDurationSeconds.isFinite,
              referenceDurationSeconds > 0,
              sourceDurationNS > 0,
              slope.isFinite,
              slope > 0,
              interceptNS.isFinite
        else {
            return nil
        }

        let referenceDurationNS =
            referenceDurationSeconds
                * 1_000_000_000
        let sourceStartReferenceNS =
            interceptNS
        let sourceEndReferenceNS =
            slope * Double(sourceDurationNS)
                + interceptNS

        guard sourceStartReferenceNS.isFinite,
              sourceEndReferenceNS.isFinite
        else {
            return nil
        }

        let startNS = max(
            0,
            sourceStartReferenceNS
        )
        let endNS = min(
            referenceDurationNS,
            sourceEndReferenceNS
        )
        guard endNS > startNS else {
            return nil
        }

        return DualViewPlaybackReferenceWindow(
            startSeconds:
                startNS / 1_000_000_000,
            endSeconds:
                endNS / 1_000_000_000
        )
    }

    public static func referenceDriftMS(
        referencePTSNS: UInt64,
        observedSourcePTSNS: UInt64,
        slope: Double,
        interceptNS: Double
    ) -> Double? {
        guard slope.isFinite,
              slope > 0,
              interceptNS.isFinite
        else {
            return nil
        }

        let observedReferenceNS =
            slope
                * Double(
                    observedSourcePTSNS
                )
                + interceptNS
        guard observedReferenceNS.isFinite
        else {
            return nil
        }

        return (
            observedReferenceNS
                - Double(referencePTSNS)
        ) / 1_000_000
    }

    public static func evaluate(
        expectedSourcePTSNS: UInt64,
        observedSourcePTSNS: UInt64,
        correctionThresholdMS: Double = 90,
        correctionAllowed: Bool
    ) -> DualViewPlaybackSyncDecision {
        let magnitudeNS: UInt64
        let sign: Double

        if observedSourcePTSNS
            >= expectedSourcePTSNS {
            magnitudeNS =
                observedSourcePTSNS
                    - expectedSourcePTSNS
            sign = 1
        } else {
            magnitudeNS =
                expectedSourcePTSNS
                    - observedSourcePTSNS
            sign = -1
        }

        let driftMS =
            sign
                * Double(magnitudeNS)
                / 1_000_000
        let threshold =
            max(
                0,
                correctionThresholdMS
            )

        return DualViewPlaybackSyncDecision(
            driftMS: driftMS,
            shouldCorrect:
                correctionAllowed
                    && abs(driftMS)
                        > threshold
        )
    }
}

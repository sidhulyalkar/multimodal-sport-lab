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

public enum DualViewPlaybackSyncPolicy {
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

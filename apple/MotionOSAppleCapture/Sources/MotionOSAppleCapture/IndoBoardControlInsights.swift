import Foundation

/// Descriptive, image-plane roller observations from two matched free-balance
/// blocks of the v2 Indo Board protocol. These are not force or EMG data.
public struct IndoBoardControlObservation: Sendable, Equatable {
    public let blockID: String
    public let elapsedSeconds: Double
    public let rollerAlongDeck: Double
    public let confidence: Double

    public init(
        blockID: String,
        elapsedSeconds: Double,
        rollerAlongDeck: Double,
        confidence: Double
    ) {
        self.blockID = blockID
        self.elapsedSeconds = elapsedSeconds
        self.rollerAlongDeck = rollerAlongDeck
        self.confidence = confidence
    }
}

public struct IndoBoardControlInsights: Sendable, Equatable {
    public let earlyCenterFraction: Double
    public let repeatCenterFraction: Double
    public let centerChangePercentagePoints: Double
    public let earlyReversalsPerMinute: Double
    public let repeatReversalsPerMinute: Double
    public let positiveSideExposureFraction: Double?
    public let directionalObservationCount: Int
    public let earlyObservedSeconds: Double
    public let repeatObservedSeconds: Double

    public init(
        earlyCenterFraction: Double,
        repeatCenterFraction: Double,
        earlyReversalsPerMinute: Double,
        repeatReversalsPerMinute: Double,
        positiveSideExposureFraction: Double?,
        directionalObservationCount: Int,
        earlyObservedSeconds: Double,
        repeatObservedSeconds: Double
    ) {
        self.earlyCenterFraction = earlyCenterFraction
        self.repeatCenterFraction = repeatCenterFraction
        self.centerChangePercentagePoints =
            (repeatCenterFraction - earlyCenterFraction) * 100
        self.earlyReversalsPerMinute = earlyReversalsPerMinute
        self.repeatReversalsPerMinute = repeatReversalsPerMinute
        self.positiveSideExposureFraction = positiveSideExposureFraction
        self.directionalObservationCount = directionalObservationCount
        self.earlyObservedSeconds = earlyObservedSeconds
        self.repeatObservedSeconds = repeatObservedSeconds
    }
}

/// Only compares the two same-instruction, 20-second natural balance blocks.
/// Long gaps, duplicate timestamps, or low-confidence board estimates must not
/// be treated as continuously observed motion.
public enum IndoBoardControlAnalyzer {
    private static let minimumSamplesPerBlock = 30
    private static let minimumObservedSeconds = 6.0
    private static let maximumSampleGap = 0.50
    private static let minimumSpeed = 0.20
    private static let sideThreshold = 0.20

    public static func analyze(
        _ observations: [IndoBoardControlObservation]
    ) -> IndoBoardControlInsights? {
        let valid = observations.filter {
            $0.elapsedSeconds.isFinite
                && $0.elapsedSeconds >= 0
                && $0.rollerAlongDeck.isFinite
                && abs($0.rollerAlongDeck) <= 1
                && $0.confidence.isFinite
                && $0.confidence >=
                    IndoBoardEvidenceQualityThresholds.minimumStateConfidence
        }
        let early = valid.filter {
            $0.blockID == "free-balance-a"
        }.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
        let later = valid.filter {
            $0.blockID == "free-balance-b"
        }.sorted { $0.elapsedSeconds < $1.elapsedSeconds }

        guard early.count >= minimumSamplesPerBlock,
              later.count >= minimumSamplesPerBlock
        else {
            return nil
        }

        let earlyObserved = observedSeconds(early)
        let laterObserved = observedSeconds(later)
        guard earlyObserved >= minimumObservedSeconds,
              laterObserved >= minimumObservedSeconds
        else {
            return nil
        }

        let exposures = (early + later).filter {
            abs($0.rollerAlongDeck) > sideThreshold
        }
        let positiveFraction: Double? = exposures.count >= 20
            ? Double(
                exposures.filter { $0.rollerAlongDeck > 0 }.count
            ) / Double(exposures.count)
            : nil

        let earlyCenter = centerFraction(early)
        let laterCenter = centerFraction(later)
        return IndoBoardControlInsights(
            earlyCenterFraction: earlyCenter,
            repeatCenterFraction: laterCenter,
            earlyReversalsPerMinute:
                60 * Double(reversals(early)) / earlyObserved,
            repeatReversalsPerMinute:
                60 * Double(reversals(later)) / laterObserved,
            positiveSideExposureFraction: positiveFraction,
            directionalObservationCount: exposures.count,
            earlyObservedSeconds: earlyObserved,
            repeatObservedSeconds: laterObserved
        )
    }

    private static func centerFraction(
        _ samples: [IndoBoardControlObservation]
    ) -> Double {
        Double(samples.filter {
            abs($0.rollerAlongDeck) <= IndoBoardBalanceThresholds.centerZone
        }.count) / Double(samples.count)
    }

    private static func observedSeconds(
        _ samples: [IndoBoardControlObservation]
    ) -> Double {
        zip(samples, samples.dropFirst()).reduce(0.0) { result, pair in
            let dt = pair.1.elapsedSeconds - pair.0.elapsedSeconds
            return result
                + (dt > 0 && dt <= maximumSampleGap ? dt : 0)
        }
    }

    private static func reversals(
        _ samples: [IndoBoardControlObservation]
    ) -> Int {
        var previousSign: Int?
        var result = 0
        for (before, after) in zip(samples, samples.dropFirst()) {
            let dt = after.elapsedSeconds - before.elapsedSeconds
            guard dt > 0, dt <= maximumSampleGap else {
                // Motion across a missing interval is not measured.
                previousSign = nil
                continue
            }
            let speed = (after.rollerAlongDeck - before.rollerAlongDeck) / dt
            guard abs(speed) >= minimumSpeed else {
                continue
            }
            let sign = speed > 0 ? 1 : -1
            if let previousSign, sign != previousSign {
                result += 1
            }
            previousSign = sign
        }
        return result
    }
}

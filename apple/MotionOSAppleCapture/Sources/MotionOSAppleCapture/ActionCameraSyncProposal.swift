import Foundation

public struct MotionEnergySample:
    Codable,
    Equatable,
    Sendable {
    public let timeNS: UInt64
    public let energy: Double
    public let confidence: Double

    public init(
        timeNS: UInt64,
        energy: Double,
        confidence: Double
    ) {
        self.timeNS = timeNS
        self.energy = max(0, energy.isFinite ? energy : 0)
        self.confidence = min(
            1,
            max(0, confidence.isFinite ? confidence : 0)
        )
    }
}

public struct SyncReferenceGesture:
    Codable,
    Equatable,
    Sendable {
    public let label: String
    public let referenceTimeNS: UInt64
    public let cueTimeNS: UInt64?
    public let energy: Double
    public let confidence: Double

    public init(
        label: String,
        referenceTimeNS: UInt64,
        cueTimeNS: UInt64? = nil,
        energy: Double,
        confidence: Double
    ) {
        self.label = label
        self.referenceTimeNS = referenceTimeNS
        self.cueTimeNS = cueTimeNS
        self.energy = max(0, energy.isFinite ? energy : 0)
        self.confidence = min(
            1,
            max(0, confidence.isFinite ? confidence : 0)
        )
    }
}

public struct ActionCameraSyncAnchor:
    Codable,
    Equatable,
    Sendable {
    public let label: String
    public let externalPTSNS: UInt64
    public let referenceTimeNS: UInt64
    public let externalEnergy: Double
    public let referenceEnergy: Double
    public let confidence: Double

    public init(
        label: String,
        externalPTSNS: UInt64,
        referenceTimeNS: UInt64,
        externalEnergy: Double,
        referenceEnergy: Double,
        confidence: Double
    ) {
        self.label = label
        self.externalPTSNS = externalPTSNS
        self.referenceTimeNS = referenceTimeNS
        self.externalEnergy = externalEnergy
        self.referenceEnergy = referenceEnergy
        self.confidence = min(1, max(0, confidence))
    }
}

public struct ActionCameraSyncProposal:
    Codable,
    Equatable,
    Sendable {
    public static let schemaVersion =
        "motionos.action-camera-sync-proposal.v1"

    public let schemaVersion: String
    public let anchors: [ActionCameraSyncAnchor]
    public let affineSlope: Double
    public let affineInterceptNS: Double
    public let middleResidualNS: Double
    public let intervalRMSErrorNS: Double
    public let confidence: Double
    public let externalPeakCount: Int
    public let claimBoundary: String

    public init(
        anchors: [ActionCameraSyncAnchor],
        affineSlope: Double,
        affineInterceptNS: Double,
        middleResidualNS: Double,
        intervalRMSErrorNS: Double,
        confidence: Double,
        externalPeakCount: Int
    ) {
        self.schemaVersion = Self.schemaVersion
        self.anchors = anchors
        self.affineSlope = affineSlope
        self.affineInterceptNS = affineInterceptNS
        self.middleResidualNS = middleResidualNS
        self.intervalRMSErrorNS = intervalRMSErrorNS
        self.confidence = min(1, max(0, confidence))
        self.externalPeakCount = externalPeakCount
        self.claimBoundary = (
            "This artifact is a synchronization proposal generated from "
                + "cross-view arm-motion timing. It is not synchronization "
                + "authority until reviewed and converted into a sealed "
                + "video-alignment receipt."
        )
    }
}

public enum ActionCameraSyncMatcher {
    private struct Peak: Equatable {
        let sample: MotionEnergySample
        let normalizedStrength: Double
    }

    private struct Candidate {
        let peaks: [Peak]
        let slope: Double
        let interceptNS: Double
        let middleResidualNS: Double
        let intervalRMSErrorNS: Double
        let confidence: Double
    }

    public static func propose(
        referenceGestures: [SyncReferenceGesture],
        externalTrace: [MotionEnergySample],
        minimumPeakSeparationNS: UInt64 = 650_000_000,
        maximumCandidatePeaks: Int = 36,
        maximumSlopeDeviation: Double = 0.015,
        maximumMiddleResidualNS: Double = 1_250_000_000
    ) -> ActionCameraSyncProposal? {
        let references = normalizedReferences(referenceGestures)
        guard references.count == 3,
              references.map(\.label) == ["start", "middle", "end"]
        else {
            return nil
        }

        let peaks = detectPeaks(
            externalTrace,
            minimumPeakSeparationNS: minimumPeakSeparationNS,
            maximumPeakCount: maximumCandidatePeaks
        )
        guard peaks.count >= 3 else {
            return nil
        }

        var best: Candidate?

        for firstIndex in 0..<(peaks.count - 2) {
            for middleIndex in (firstIndex + 1)..<(peaks.count - 1) {
                for lastIndex in (middleIndex + 1)..<peaks.count {
                    let first = peaks[firstIndex]
                    let middle = peaks[middleIndex]
                    let last = peaks[lastIndex]

                    let externalSpan =
                        Double(last.sample.timeNS - first.sample.timeNS)
                    let referenceSpan = Double(
                        references[2].referenceTimeNS
                            - references[0].referenceTimeNS
                    )
                    guard externalSpan > 1_000_000_000,
                          referenceSpan > 1_000_000_000
                    else {
                        continue
                    }

                    let slope = referenceSpan / externalSpan
                    guard abs(slope - 1) <= maximumSlopeDeviation else {
                        continue
                    }

                    let intercept =
                        Double(references[0].referenceTimeNS)
                            - slope * Double(first.sample.timeNS)
                    let predictedMiddle =
                        slope * Double(middle.sample.timeNS)
                            + intercept
                    let middleResidual = abs(
                        predictedMiddle
                            - Double(references[1].referenceTimeNS)
                    )
                    guard middleResidual <= maximumMiddleResidualNS else {
                        continue
                    }

                    let firstIntervalResidual =
                        abs(
                            slope
                                * Double(
                                    middle.sample.timeNS
                                        - first.sample.timeNS
                                )
                                - Double(
                                    references[1].referenceTimeNS
                                        - references[0].referenceTimeNS
                                )
                        )
                    let secondIntervalResidual =
                        abs(
                            slope
                                * Double(
                                    last.sample.timeNS
                                        - middle.sample.timeNS
                                )
                                - Double(
                                    references[2].referenceTimeNS
                                        - references[1].referenceTimeNS
                                )
                        )
                    let intervalRMS = sqrt(
                        (
                            firstIntervalResidual * firstIntervalResidual
                                + secondIntervalResidual
                                    * secondIntervalResidual
                        ) / 2
                    )

                    let peakStrength = (
                        first.normalizedStrength
                            + middle.normalizedStrength
                            + last.normalizedStrength
                    ) / 3
                    let peakConfidence = (
                        first.sample.confidence
                            + middle.sample.confidence
                            + last.sample.confidence
                    ) / 3
                    let referenceConfidence =
                        references.map(\.confidence)
                            .reduce(0, +)
                            / 3

                    let residualScore = exp(
                        -middleResidual / 450_000_000
                    )
                    let intervalScore = exp(
                        -intervalRMS / 650_000_000
                    )
                    let slopeScore = max(
                        0,
                        1
                            - abs(slope - 1)
                                / maximumSlopeDeviation
                    )
                    let confidence = min(
                        1,
                        max(
                            0,
                            0.28 * residualScore
                                + 0.24 * intervalScore
                                + 0.18 * slopeScore
                                + 0.18 * peakStrength
                                + 0.07 * peakConfidence
                                + 0.05 * referenceConfidence
                        )
                    )

                    let candidate = Candidate(
                        peaks: [first, middle, last],
                        slope: slope,
                        interceptNS: intercept,
                        middleResidualNS: middleResidual,
                        intervalRMSErrorNS: intervalRMS,
                        confidence: confidence
                    )

                    if shouldPrefer(
                        candidate,
                        over: best
                    ) {
                        best = candidate
                    }
                }
            }
        }

        guard let best else {
            return nil
        }

        let anchors = zip(
            references,
            best.peaks
        )
        .map { reference, peak in
            ActionCameraSyncAnchor(
                label: reference.label,
                externalPTSNS: peak.sample.timeNS,
                referenceTimeNS: reference.referenceTimeNS,
                externalEnergy: peak.sample.energy,
                referenceEnergy: reference.energy,
                confidence: min(
                    reference.confidence,
                    peak.sample.confidence
                )
            )
        }

        return ActionCameraSyncProposal(
            anchors: anchors,
            affineSlope: best.slope,
            affineInterceptNS: best.interceptNS,
            middleResidualNS: best.middleResidualNS,
            intervalRMSErrorNS: best.intervalRMSErrorNS,
            confidence: best.confidence,
            externalPeakCount: peaks.count
        )
    }

    public static func strongestGesture(
        in trace: [MotionEnergySample],
        around cueTimeNS: UInt64,
        lookBehindNS: UInt64 = 350_000_000,
        lookAheadNS: UInt64 = 2_000_000_000
    ) -> MotionEnergySample? {
        let start = cueTimeNS > lookBehindNS
            ? cueTimeNS - lookBehindNS
            : 0
        let end = cueTimeNS.addingReportingOverflow(
            lookAheadNS
        )
        let upper = end.overflow
            ? UInt64.max
            : end.partialValue

        return trace
            .filter {
                $0.timeNS >= start
                    && $0.timeNS <= upper
            }
            .max {
                weightedEnergy($0)
                    < weightedEnergy($1)
            }
    }

    private static func normalizedReferences(
        _ references: [SyncReferenceGesture]
    ) -> [SyncReferenceGesture] {
        let required = ["start", "middle", "end"]
        let byLabel = Dictionary(
            uniqueKeysWithValues: references.map {
                ($0.label.lowercased(), $0)
            }
        )

        return required.compactMap { label in
            guard let value = byLabel[label]
            else {
                return nil
            }
            return SyncReferenceGesture(
                label: label,
                referenceTimeNS: value.referenceTimeNS,
                cueTimeNS: value.cueTimeNS,
                energy: value.energy,
                confidence: value.confidence
            )
        }
    }

    private static func detectPeaks(
        _ trace: [MotionEnergySample],
        minimumPeakSeparationNS: UInt64,
        maximumPeakCount: Int
    ) -> [Peak] {
        let sorted = trace
            .filter {
                $0.energy.isFinite
                    && $0.confidence > 0
            }
            .sorted { $0.timeNS < $1.timeNS }

        guard sorted.count >= 3 else {
            return []
        }

        let positive = sorted
            .map(\.energy)
            .filter { $0 > 0 }
            .sorted()
        guard let maximum = positive.last,
              maximum > 0
        else {
            return []
        }

        let baselineIndex = max(
            0,
            Int(Double(positive.count - 1) * 0.60)
        )
        let baseline = positive[baselineIndex]
        let threshold = max(
            baseline * 1.18,
            maximum * 0.12
        )

        var local: [Peak] = []
        for index in 1..<(sorted.count - 1) {
            let sample = sorted[index]
            guard sample.energy >= threshold,
                  sample.energy >= sorted[index - 1].energy,
                  sample.energy > sorted[index + 1].energy
            else {
                continue
            }

            local.append(
                Peak(
                    sample: sample,
                    normalizedStrength: min(
                        1,
                        sample.energy / maximum
                    )
                )
            )
        }

        let ranked = local.sorted {
            weightedEnergy($0.sample)
                > weightedEnergy($1.sample)
        }

        var selected: [Peak] = []
        for peak in ranked {
            let tooClose = selected.contains {
                distance(
                    $0.sample.timeNS,
                    peak.sample.timeNS
                ) < minimumPeakSeparationNS
            }
            guard !tooClose else {
                continue
            }
            selected.append(peak)
            if selected.count >= max(3, maximumPeakCount) {
                break
            }
        }

        return selected.sorted {
            $0.sample.timeNS < $1.sample.timeNS
        }
    }

    private static func shouldPrefer(
        _ candidate: Candidate,
        over current: Candidate?
    ) -> Bool {
        guard let current else {
            return true
        }
        if abs(candidate.confidence - current.confidence) > 1e-9 {
            return candidate.confidence > current.confidence
        }
        if abs(
            candidate.intervalRMSErrorNS
                - current.intervalRMSErrorNS
        ) > 1 {
            return candidate.intervalRMSErrorNS
                < current.intervalRMSErrorNS
        }
        return candidate.middleResidualNS
            < current.middleResidualNS
    }

    private static func weightedEnergy(
        _ sample: MotionEnergySample
    ) -> Double {
        sample.energy * (
            0.35 + 0.65 * sample.confidence
        )
    }

    private static func distance(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }
}

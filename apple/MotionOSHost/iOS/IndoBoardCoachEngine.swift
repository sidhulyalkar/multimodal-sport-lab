import Foundation
import MotionOSAppleCapture

struct IndoBoardCoachMetric: Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let value: String
}

struct IndoBoardCoachReport: Equatable, Sendable {
    let headline: String
    let observation: String
    let tip: String
    let drill: String
    let confidence: Double
    let evidenceLabel: String
    let metrics: [IndoBoardCoachMetric]

    var confidencePercent: Int {
        Int((min(1, max(0, confidence)) * 100).rounded())
    }
}

@MainActor
final class IndoBoardCoachEngine {
    private struct Sample: Sendable {
        let elapsedSeconds: Double
        let blockID: String
        let poseConfidence: Double
        let kneeFlexionDeg: Double?
        let trunkOffsetRatio: Double?
        let pelvisX: Double?
        let stanceWidthRatio: Double?
        let armExcursionRatio: Double?
    }

    private var samples: [Sample] = []
    private var lastSequence: UInt64?

    func reset() {
        samples.removeAll(keepingCapacity: true)
        lastSequence = nil
    }

    func ingest(
        frame: BodyMovementFrame,
        elapsedSeconds: Double
    ) {
        guard frame.sequence != lastSequence,
              let framing = frame.imageFraming,
              let imageJoints = frame.imageJoints,
              framing.bounds.width > 0.05,
              framing.bounds.height > 0.10
        else {
            return
        }

        lastSequence = frame.sequence
        let joints = Dictionary(
            uniqueKeysWithValues: imageJoints.map {
                (Self.normalize($0.id), $0)
            }
        )

        let leftHip = joint(
            aliases: ["leftHip", "left_hip"],
            in: joints
        )
        let rightHip = joint(
            aliases: ["rightHip", "right_hip"],
            in: joints
        )
        let leftKnee = joint(
            aliases: ["leftKnee", "left_knee"],
            in: joints
        )
        let rightKnee = joint(
            aliases: ["rightKnee", "right_knee"],
            in: joints
        )
        let leftAnkle = joint(
            aliases: [
                "leftAnkle",
                "left_ankle",
                "leftFoot",
                "left_foot",
            ],
            in: joints
        )
        let rightAnkle = joint(
            aliases: [
                "rightAnkle",
                "right_ankle",
                "rightFoot",
                "right_foot",
            ],
            in: joints
        )
        let leftShoulder = joint(
            aliases: ["leftShoulder", "left_shoulder"],
            in: joints
        )
        let rightShoulder = joint(
            aliases: ["rightShoulder", "right_shoulder"],
            in: joints
        )
        let leftWrist = joint(
            aliases: [
                "leftWrist",
                "left_wrist",
                "leftHand",
                "left_hand",
            ],
            in: joints
        )
        let rightWrist = joint(
            aliases: [
                "rightWrist",
                "right_wrist",
                "rightHand",
                "right_hand",
            ],
            in: joints
        )

        let flexions = [
            kneeFlexion(
                hip: leftHip,
                knee: leftKnee,
                ankle: leftAnkle
            ),
            kneeFlexion(
                hip: rightHip,
                knee: rightKnee,
                ankle: rightAnkle
            ),
        ].compactMap { $0 }

        let pelvis = midpoint(leftHip, rightHip)
        let shoulders = midpoint(leftShoulder, rightShoulder)

        let kneeFlexion = flexions.isEmpty
            ? nil
            : flexions.reduce(0, +) / Double(flexions.count)

        let trunkOffset = {
            guard let pelvis,
                  let shoulders
            else {
                return nil
            }
            return abs(shoulders.x - pelvis.x)
                / framing.bounds.width
        }()

        let stanceWidth = {
            guard let leftAnkle,
                  let rightAnkle
            else {
                return nil
            }
            return distance(leftAnkle, rightAnkle)
                / framing.bounds.width
        }()

        let armExcursion = {
            guard let shoulders else {
                return nil
            }

            let wrists = [leftWrist, rightWrist]
                .compactMap { $0 }
            guard !wrists.isEmpty else {
                return nil
            }

            return wrists
                .map {
                    distance($0, shoulders)
                        / framing.bounds.height
                }
                .reduce(0, +)
                / Double(wrists.count)
        }()

        let blockID =
            IndoBoardProductProtocol.activeBlock(
                at: elapsedSeconds
            )?.id ?? "unclassified"

        samples.append(
            Sample(
                elapsedSeconds: elapsedSeconds,
                blockID: blockID,
                poseConfidence: framing.meanConfidence,
                kneeFlexionDeg: kneeFlexion,
                trunkOffsetRatio: trunkOffset,
                pelvisX: pelvis?.x,
                stanceWidthRatio: stanceWidth,
                armExcursionRatio: armExcursion
            )
        )

        // A two-minute 10 Hz product session is ~1,200 samples.
        // Keep a comfortable hard ceiling in case a run stays open.
        if samples.count > 4_000 {
            samples.removeFirst(samples.count - 4_000)
        }
    }

    func makeReport() -> IndoBoardCoachReport {
        guard samples.count >= 30 else {
            return IndoBoardCoachReport(
                headline: "Capture more clean movement",
                observation:
                    "MotionOS did not collect enough confident body-pose samples to make a useful technique claim.",
                tip:
                    "Keep your full body visible and repeat the short baseline protocol.",
                drill: "30-second neutral balance hold",
                confidence: 0.25,
                evidenceLabel: "Body pose · low evidence",
                metrics: [
                    .init(
                        id: "pose-frames",
                        label: "Usable pose frames",
                        value: "\(samples.count)"
                    ),
                ]
            )
        }

        let poseConfidence = mean(
            samples.map(\.poseConfidence)
        )
        let coverageFactor = min(
            1,
            Double(samples.count) / 700.0
        )
        let confidence = min(
            0.92,
            max(0.20, poseConfidence * coverageFactor)
        )

        let kneeValues = samples.compactMap(\.kneeFlexionDeg)
        let trunkValues = samples.compactMap(\.trunkOffsetRatio)
        let stanceValues = samples.compactMap(\.stanceWidthRatio)
        let armValues = samples.compactMap(\.armExcursionRatio)

        let medianKnee = median(kneeValues)
        let trunkP90 = percentile(trunkValues, q: 0.90)
        let medianStance = median(stanceValues)
        let medianArm = median(armValues)

        let neutralStart = blockSamples("neutral-settle")
            .compactMap(\.pelvisX)
        let neutralFinish = blockSamples("neutral-finish")
            .compactMap(\.pelvisX)
        let shiftPelvis = blockSamples("controlled-shifts")
            .compactMap(\.pelvisX)
        let squatKnees = blockSamples("partial-squats")
            .compactMap(\.kneeFlexionDeg)

        let startSpread = robustSpread(neutralStart)
        let finishSpread = robustSpread(neutralFinish)
        let shiftRange = robustRange(shiftPelvis)
        let correctionProxy = correctionCount(
            blockSamples("controlled-shifts")
        )
        let squatDepth = percentile(squatKnees, q: 0.75)

        let metrics = metricCards(
            medianKnee: medianKnee,
            trunkP90: trunkP90,
            startSpread: startSpread,
            finishSpread: finishSpread,
            shiftRange: shiftRange,
            correctionProxy: correctionProxy,
            squatDepth: squatDepth,
            medianStance: medianStance,
            medianArm: medianArm
        )

        if let medianKnee,
           let trunkP90,
           medianKnee < 14,
           trunkP90 > 0.09 {
            return IndoBoardCoachReport(
                headline: "Let the knees absorb more",
                observation:
                    "Your knees stayed fairly straight while your upper body moved laterally during the session.",
                tip:
                    "Try starting corrections through a small knee and hip bend before moving the shoulders.",
                drill:
                    "3 shallow squat holds, then 5 slow side-to-side shifts",
                confidence: confidence * 0.90,
                evidenceLabel: "Camera body pose · technique hypothesis",
                metrics: metrics
            )
        }

        if let startSpread,
           let finishSpread,
           startSpread > 0.006,
           finishSpread < startSpread * 0.82 {
            let improvement = Int(
                ((1 - finishSpread / startSpread) * 100).rounded()
            )
            return IndoBoardCoachReport(
                headline: "You settled as the session went on",
                observation:
                    "Your pelvis-motion spread during the final neutral hold was about \(improvement)% lower than at the start.",
                tip:
                    "Keep that quieter finish and add slightly more deliberate controlled shifts next round.",
                drill: "5 slow shifts each direction with a pause at center",
                confidence: confidence * 0.88,
                evidenceLabel: "Camera body pose · within-session comparison",
                metrics: metrics
            )
        }

        if let shiftRange,
           shiftRange < 0.045 {
            return IndoBoardCoachReport(
                headline: "Make the training shifts more distinct",
                observation:
                    "The controlled-shift block looked close to your neutral movement range, so the left/right contrast was weak.",
                tip:
                    "Move deliberately enough that MotionOS can compare your loading and recovery in both directions.",
                drill:
                    "5 slow left/right shifts, returning to a clear center pause each time",
                confidence: confidence * 0.78,
                evidenceLabel: "Camera body pose · protocol quality",
                metrics: metrics
            )
        }

        if correctionProxy >= 10 {
            return IndoBoardCoachReport(
                headline: "Use fewer, cleaner corrections",
                observation:
                    "Your controlled-shift block contained many direction reversals in the pelvis trajectory.",
                tip:
                    "Try one smooth return toward center, then soften the second correction instead of chasing the balance point.",
                drill:
                    "5 tilt-and-recover reps at half speed",
                confidence: confidence * 0.72,
                evidenceLabel:
                    "Camera body pose · correction proxy, board tracking pending",
                metrics: metrics
            )
        }

        if let squatDepth,
           squatDepth < 18 {
            return IndoBoardCoachReport(
                headline: "Give the squat block a clearer range",
                observation:
                    "The squat block did not separate strongly from your normal knee-flexion range.",
                tip:
                    "Use a shallow but obvious squat you can hold without sacrificing control.",
                drill: "3 controlled 5-second partial squat holds",
                confidence: confidence * 0.76,
                evidenceLabel: "Camera body pose · drill-quality check",
                metrics: metrics
            )
        }

        return IndoBoardCoachReport(
            headline: "Build a cleaner center return",
            observation:
                "Your first session is usable as a baseline. The most valuable next signal is repeatable controlled left/right recovery.",
            tip:
                "Move slowly enough to feel the center, then pause briefly before shifting the other way.",
            drill:
                "5 slow shifts each direction with a one-second center pause",
            confidence: confidence * 0.72,
            evidenceLabel:
                "Camera body pose · cold-start baseline, board tracking pending",
            metrics: metrics
        )
    }

    private func blockSamples(
        _ id: String
    ) -> [Sample] {
        samples.filter { $0.blockID == id }
    }

    private func metricCards(
        medianKnee: Double?,
        trunkP90: Double?,
        startSpread: Double?,
        finishSpread: Double?,
        shiftRange: Double?,
        correctionProxy: Int,
        squatDepth: Double?,
        medianStance: Double?,
        medianArm: Double?
    ) -> [IndoBoardCoachMetric] {
        var result: [IndoBoardCoachMetric] = []

        if let medianKnee {
            result.append(
                .init(
                    id: "knee",
                    label: "Median knee flexion",
                    value: "\(Int(medianKnee.rounded()))°"
                )
            )
        }
        if let trunkP90 {
            result.append(
                .init(
                    id: "trunk",
                    label: "Upper-body offset P90",
                    value: String(
                        format: "%.2f× body width",
                        trunkP90
                    )
                )
            )
        }
        if let startSpread,
           let finishSpread {
            result.append(
                .init(
                    id: "neutral-change",
                    label: "Neutral motion spread",
                    value: String(
                        format: "%.3f → %.3f",
                        startSpread,
                        finishSpread
                    )
                )
            )
        }
        if let shiftRange {
            result.append(
                .init(
                    id: "shift-range",
                    label: "Shift range proxy",
                    value: String(format: "%.3f", shiftRange)
                )
            )
        }
        if correctionProxy > 0 {
            result.append(
                .init(
                    id: "corrections",
                    label: "Direction-change proxy",
                    value: "\(correctionProxy)"
                )
            )
        }
        if let squatDepth {
            result.append(
                .init(
                    id: "squat",
                    label: "Squat flexion P75",
                    value: "\(Int(squatDepth.rounded()))°"
                )
            )
        }
        if let medianStance {
            result.append(
                .init(
                    id: "stance",
                    label: "Stance width",
                    value: String(
                        format: "%.2f× body width",
                        medianStance
                    )
                )
            )
        }
        if let medianArm {
            result.append(
                .init(
                    id: "arms",
                    label: "Arm excursion",
                    value: String(
                        format: "%.2f× body height",
                        medianArm
                    )
                )
            )
        }

        return Array(result.prefix(6))
    }

    private func correctionCount(
        _ block: [Sample]
    ) -> Int {
        let ordered = block
            .filter { $0.pelvisX != nil }
            .sorted { $0.elapsedSeconds < $1.elapsedSeconds }

        guard ordered.count >= 5 else {
            return 0
        }

        var signs: [Int] = []
        for pair in zip(ordered, ordered.dropFirst()) {
            guard let first = pair.0.pelvisX,
                  let second = pair.1.pelvisX
            else {
                continue
            }

            let dt = max(
                0.02,
                pair.1.elapsedSeconds - pair.0.elapsedSeconds
            )
            let speed = (second - first) / dt
            guard abs(speed) >= 0.025 else {
                continue
            }

            signs.append(speed > 0 ? 1 : -1)
        }

        guard signs.count >= 2 else {
            return 0
        }

        return zip(signs, signs.dropFirst())
            .filter { $0.0 != $0.1 }
            .count
    }

    private func joint(
        aliases: [String],
        in joints: [String: BodyJoint2D]
    ) -> BodyJoint2D? {
        for alias in aliases {
            if let value = joints[Self.normalize(alias)] {
                return value
            }
        }
        return nil
    }

    private func kneeFlexion(
        hip: BodyJoint2D?,
        knee: BodyJoint2D?,
        ankle: BodyJoint2D?
    ) -> Double? {
        guard let hip,
              let knee,
              let ankle
        else {
            return nil
        }

        let first = (x: hip.x - knee.x, y: hip.y - knee.y)
        let second = (x: ankle.x - knee.x, y: ankle.y - knee.y)
        let firstNorm = hypot(first.x, first.y)
        let secondNorm = hypot(second.x, second.y)
        guard firstNorm > 1e-9,
              secondNorm > 1e-9
        else {
            return nil
        }

        let cosine = min(
            1,
            max(
                -1,
                (first.x * second.x + first.y * second.y)
                    / (firstNorm * secondNorm)
            )
        )
        let angle = acos(cosine) * 180 / .pi
        return max(0, 180 - angle)
    }

    private func midpoint(
        _ first: BodyJoint2D?,
        _ second: BodyJoint2D?
    ) -> BodyJoint2D? {
        guard let first,
              let second
        else {
            return nil
        }

        return BodyJoint2D(
            id: "midpoint",
            x: (first.x + second.x) / 2,
            y: (first.y + second.y) / 2,
            confidence: min(first.confidence, second.confidence)
        )
    }

    private func distance(
        _ first: BodyJoint2D,
        _ second: BodyJoint2D
    ) -> Double {
        hypot(first.x - second.x, first.y - second.y)
    }

    private func robustSpread(
        _ values: [Double]
    ) -> Double? {
        guard values.count >= 5 else {
            return nil
        }
        return percentile(values, q: 0.90).flatMap { high in
            percentile(values, q: 0.10).map { low in
                high - low
            }
        }
    }

    private func robustRange(
        _ values: [Double]
    ) -> Double? {
        robustSpread(values)
    }

    private func mean(
        _ values: [Double]
    ) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }

    private func median(
        _ values: [Double]
    ) -> Double? {
        percentile(values, q: 0.50)
    }

    private func percentile(
        _ values: [Double],
        q: Double
    ) -> Double? {
        guard !values.isEmpty else {
            return nil
        }

        let ordered = values.sorted()
        guard ordered.count > 1 else {
            return ordered[0]
        }

        let position =
            Double(ordered.count - 1) * min(1, max(0, q))
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper {
            return ordered[lower]
        }

        let fraction = position - Double(lower)
        return ordered[lower] * (1 - fraction)
            + ordered[upper] * fraction
    }

    private static func normalize(
        _ value: String
    ) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

import Foundation

public enum IndoBoardCoachTargetMetric:
    String,
    Codable,
    Sendable,
    Equatable {
    case trunkExcursionP90 = "trunk_excursion_p90"
    case medianKneeFlexion = "median_knee_flexion_deg"
    case pelvisMotionSpread = "pelvis_motion_spread"
    case rollerExcursionP90 = "roller_excursion_p90"
    case centerTimeFraction = "center_time_fraction"
}

public enum IndoBoardCoachDirection:
    String,
    Codable,
    Sendable,
    Equatable {
    case increase
    case decrease
}

public enum IndoBoardCoachExperimentOutcome:
    String,
    Codable,
    Sendable,
    Equatable {
    case improved
    case noClearChange = "no_clear_change"
    case oppositeDirection = "opposite_direction"
    case insufficientEvidence = "insufficient_evidence"
}

public struct IndoBoardCoachIntervention:
    Codable,
    Equatable,
    Sendable {
    public let id: String
    public let title: String
    public let cue: String
    public let drill: String
    public let targetMetric: IndoBoardCoachTargetMetric
    public let desiredDirection: IndoBoardCoachDirection
    public let confidence: Double
    public let evidenceLabel: String

    public init(
        id: String,
        title: String,
        cue: String,
        drill: String,
        targetMetric: IndoBoardCoachTargetMetric,
        desiredDirection: IndoBoardCoachDirection,
        confidence: Double,
        evidenceLabel: String
    ) {
        self.id = id
        self.title = title
        self.cue = cue
        self.drill = drill
        self.targetMetric = targetMetric
        self.desiredDirection = desiredDirection
        self.confidence = min(1, max(0, confidence))
        self.evidenceLabel = evidenceLabel
    }
}

public struct IndoBoardCoachExperimentResult:
    Codable,
    Equatable,
    Sendable {
    public let targetMetric: IndoBoardCoachTargetMetric
    public let before: Double?
    public let after: Double?
    public let relativeChange: Double?
    public let outcome: IndoBoardCoachExperimentOutcome
    public let summary: String

    public init(
        targetMetric: IndoBoardCoachTargetMetric,
        before: Double?,
        after: Double?,
        relativeChange: Double?,
        outcome: IndoBoardCoachExperimentOutcome,
        summary: String
    ) {
        self.targetMetric = targetMetric
        self.before = before
        self.after = after
        self.relativeChange = relativeChange
        self.outcome = outcome
        self.summary = summary
    }
}

public struct IndoBoardCoachMetric: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let value: String

    public init(
        id: String,
        label: String,
        value: String
    ) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct IndoBoardCoachReport: Equatable, Sendable {
    public let headline: String
    public let observation: String
    public let tip: String
    public let drill: String
    public let confidence: Double
    public let evidenceLabel: String
    public let metrics: [IndoBoardCoachMetric]
    public let numericMetrics: [String: Double]
    public let intervention: IndoBoardCoachIntervention?
    public let experimentResult: IndoBoardCoachExperimentResult?

    public init(
        headline: String,
        observation: String,
        tip: String,
        drill: String,
        confidence: Double,
        evidenceLabel: String,
        metrics: [IndoBoardCoachMetric],
        numericMetrics: [String: Double] = [:],
        intervention: IndoBoardCoachIntervention? = nil,
        experimentResult: IndoBoardCoachExperimentResult? = nil
    ) {
        self.headline = headline
        self.observation = observation
        self.tip = tip
        self.drill = drill
        self.confidence = min(1, max(0, confidence))
        self.evidenceLabel = evidenceLabel
        self.metrics = metrics
        self.numericMetrics = numericMetrics
        self.intervention = intervention
        self.experimentResult = experimentResult
    }

    public var confidencePercent: Int {
        Int((min(1, max(0, confidence)) * 100).rounded())
    }
}

@MainActor
public final class IndoBoardCoachEngine {
    private struct Sample: Sendable {
        let elapsedSeconds: Double
        let blockID: String
        let poseConfidence: Double
        let kneeFlexionDeg: Double?
        let trunkOffsetRatio: Double?
        let pelvisX: Double?
        let stanceWidthRatio: Double?
        let armExcursionRatio: Double?
        let rollerAlongDeck: Double?
        let boardStateConfidence: Double?
    }

    private var samples: [Sample] = []
    private var lastSequence: UInt64?
    private let balanceAccumulator =
        IndoBoardBalanceMetricAccumulator()

    public init() {}

    public func reset() {
        samples.removeAll(keepingCapacity: true)
        lastSequence = nil
        balanceAccumulator.reset()
    }

    public func ingest(
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

        let trunkOffset: Double? = {
            guard let pelvis,
                  let shoulders
            else {
                return nil
            }
            return abs(shoulders.x - pelvis.x)
                / framing.bounds.width
        }()

        let stanceWidth: Double? = {
            guard let leftAnkle,
                  let rightAnkle
            else {
                return nil
            }
            return distance(leftAnkle, rightAnkle)
                / framing.bounds.width
        }()

        let armExcursion: Double? = {
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

        let balanceState = frame.indoBoardBalanceState
        if let balanceState {
            balanceAccumulator.ingest(
                balanceState,
                elapsedSeconds: elapsedSeconds
            )
        }

        samples.append(
            Sample(
                elapsedSeconds: elapsedSeconds,
                blockID: blockID,
                poseConfidence: framing.meanConfidence,
                kneeFlexionDeg: kneeFlexion,
                trunkOffsetRatio: trunkOffset,
                pelvisX: pelvis?.x,
                stanceWidthRatio: stanceWidth,
                armExcursionRatio: armExcursion,
                rollerAlongDeck:
                    balanceState?.rollerAlongDeck,
                boardStateConfidence:
                    balanceState?.confidence
            )
        )

        // A two-minute 10 Hz product session is ~1,200 samples.
        // Keep a comfortable hard ceiling in case a run stays open.
        if samples.count > 4_000 {
            samples.removeFirst(samples.count - 4_000)
        }
    }

    public func makeIntervention() -> IndoBoardCoachIntervention? {
        let baseline = blockSamples("neutral-settle")
            + blockSamples("free-balance-a")
        guard baseline.count >= 40 else {
            return nil
        }

        let confidence = min(
            0.90,
            max(
                0.25,
                mean(baseline.map(\.poseConfidence))
                    * min(1, Double(baseline.count) / 180.0)
            )
        )
        let firstBalanceBlock =
            blockSamples("free-balance-a")
        let boardBaseline = firstBalanceBlock
            .filter {
                ($0.boardStateConfidence ?? 0) >= 0.55
                    && $0.rollerAlongDeck != nil
            }
        let boardBaselineCoverage = boardCoverage(
            firstBalanceBlock,
            minimumConfidence: 0.55
        )
        if boardBaseline.count >= 30,
           boardBaselineCoverage >= 0.60 {
            let excursion = percentile(
                boardBaseline.compactMap {
                    $0.rollerAlongDeck.map(abs)
                },
                q: 0.90
            )
            let centerTime =
                Double(
                    boardBaseline.filter {
                        abs($0.rollerAlongDeck ?? 1)
                            <= IndoBoardBalanceThresholds.centerZone
                    }.count
                )
                / Double(boardBaseline.count)

            if (excursion ?? 0) >= 0.58
                || centerTime < 0.55 {
                return IndoBoardCoachIntervention(
                    id: "earlier-smaller-board-recovery",
                    title: "Recover earlier",
                    cue:
                        "On the next balance block, start a smaller correction before the roller travels as far from center.",
                    drill:
                        "Natural balance with small early returns toward center",
                    targetMetric: .rollerExcursionP90,
                    desiredDirection: .decrease,
                    confidence: confidence * 0.92,
                    evidenceLabel:
                        "Deck + roller image geometry · within-session experiment"
                )
            }
        }

        let medianKnee = median(
            baseline.compactMap(\.kneeFlexionDeg)
        )
        let trunkP90 = percentile(
            baseline.compactMap(\.trunkOffsetRatio),
            q: 0.90
        )
        let correctionProxy = correctionCount(
            blockSamples("controlled-shifts")
        )
        let squatDepth = percentile(
            blockSamples("partial-squats")
                .compactMap(\.kneeFlexionDeg),
            q: 0.75
        )

        if let medianKnee,
           let trunkP90,
           medianKnee < 14,
           trunkP90 > 0.09 {
            return IndoBoardCoachIntervention(
                id: "soft-knee-quiet-shoulders",
                title: "Try softer knees",
                cue:
                    "On the next balance block, start each correction with a small knee and hip bend before moving the shoulders.",
                drill:
                    "Natural balance for 20 seconds with soft knees",
                targetMetric: .trunkExcursionP90,
                desiredDirection: .decrease,
                confidence: confidence * 0.88,
                evidenceLabel:
                    "Camera body pose · within-session experiment"
            )
        }

        if correctionProxy >= 10 {
            return IndoBoardCoachIntervention(
                id: "smaller-second-correction",
                title: "Use one clean return",
                cue:
                    "On the next balance block, make one small early correction and soften the second instead of chasing center.",
                drill:
                    "Natural balance with smaller early corrections",
                targetMetric: .pelvisMotionSpread,
                desiredDirection: .decrease,
                confidence: confidence * 0.76,
                evidenceLabel:
                    "Camera body pose · correction proxy experiment"
            )
        }

        if let squatDepth,
           squatDepth < 18 {
            return IndoBoardCoachIntervention(
                id: "slightly-softer-stance",
                title: "Keep a softer stance",
                cue:
                    "On the next balance block, keep a little more knee bend than before without forcing a deep squat.",
                drill:
                    "Natural balance with a comfortable soft-knee stance",
                targetMetric: .medianKneeFlexion,
                desiredDirection: .increase,
                confidence: confidence * 0.72,
                evidenceLabel:
                    "Camera body pose · within-session experiment"
            )
        }

        return IndoBoardCoachIntervention(
            id: "smaller-earlier-corrections",
            title: "Make corrections smaller",
            cue:
                "On the next balance block, correct a little earlier and pause briefly when you pass through center.",
            drill:
                "Natural balance with small early corrections",
            targetMetric: .pelvisMotionSpread,
            desiredDirection: .decrease,
            confidence: confidence * 0.68,
            evidenceLabel:
                "Camera body pose · cold-start experiment"
        )
    }

    public func makeReport(
        intervention: IndoBoardCoachIntervention?
    ) -> IndoBoardCoachReport {
        let base = makeReport()
        guard let intervention else {
            return base
        }

        let experiment = evaluate(intervention)
        var numeric = base.numericMetrics
        if let before = experiment.before {
            numeric[
                "intervention_before_"
                    + intervention.targetMetric.rawValue
            ] = before
        }
        if let after = experiment.after {
            numeric[
                "intervention_after_"
                    + intervention.targetMetric.rawValue
            ] = after
        }
        if let change = experiment.relativeChange {
            numeric[
                "intervention_relative_change_"
                    + intervention.targetMetric.rawValue
            ] = change
        }

        var metrics = base.metrics
        if let change = experiment.relativeChange {
            let percent = Int((abs(change) * 100).rounded())
            let prefix = change < 0 ? "−" : "+"
            metrics.append(
                IndoBoardCoachMetric(
                    id: "cue-response",
                    label: "Cue response",
                    value: prefix + "\(percent)%"
                )
            )
        }

        return IndoBoardCoachReport(
            headline: base.headline,
            observation: base.observation,
            tip: base.tip,
            drill: base.drill,
            confidence: base.confidence,
            evidenceLabel: base.evidenceLabel,
            metrics: Array(metrics.prefix(6)),
            numericMetrics: numeric,
            intervention: intervention,
            experimentResult: experiment
        )
    }

    public func makeReport() -> IndoBoardCoachReport {
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
                ],
                numericMetrics: [
                    "usable_pose_frames": Double(samples.count),
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

        var metrics = metricCards(
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
        var numericMetrics: [String: Double] = [
            "usable_pose_frames": Double(samples.count),
            "pose_confidence": poseConfidence,
            "correction_direction_changes":
                Double(correctionProxy),
        ]

        let balanceMetrics =
            balanceAccumulator.makeMetrics()
        let boardCoverageAll = boardCoverage(
            samples,
            minimumConfidence: 0.55
        )
        let boardCoverageFirstBalance = boardCoverage(
            blockSamples("free-balance-a"),
            minimumConfidence: 0.55
        )
        let boardCoverageSecondBalance = boardCoverage(
            blockSamples("free-balance-b"),
            minimumConfidence: 0.55
        )
        numericMetrics["board_state_coverage_fraction"] =
            boardCoverageAll
        numericMetrics[
            "board_free_balance_a_coverage_fraction"
        ] = boardCoverageFirstBalance
        numericMetrics[
            "board_free_balance_b_coverage_fraction"
        ] = boardCoverageSecondBalance

        if let balanceMetrics {
            numericMetrics["board_sample_count"] =
                Double(balanceMetrics.sampleCount)
            numericMetrics["board_state_confidence"] =
                balanceMetrics.meanConfidence
            numericMetrics["board_center_time_fraction"] =
                balanceMetrics.centerTimeFraction
            numericMetrics["board_roller_excursion_p90"] =
                balanceMetrics.rollerExcursionP90
            numericMetrics["board_edge_approach_count"] =
                Double(balanceMetrics.edgeApproachCount)
            numericMetrics["board_direction_change_count"] =
                Double(balanceMetrics.directionChangeCount)
            numericMetrics["board_recovery_count"] =
                Double(balanceMetrics.recoveryCount)
            if let recovery =
                    balanceMetrics.meanRecoveryTimeMS {
                numericMetrics["board_mean_recovery_ms"] =
                    recovery
            }
            if let recovery =
                    balanceMetrics.p90RecoveryTimeMS {
                numericMetrics["board_p90_recovery_ms"] =
                    recovery
            }

            metrics.insert(
                IndoBoardCoachMetric(
                    id: "board-center-time",
                    label: "Board center time",
                    value: String(
                        format: "%.0f%%",
                        balanceMetrics.centerTimeFraction * 100
                    )
                ),
                at: 0
            )
            metrics.insert(
                IndoBoardCoachMetric(
                    id: "board-excursion",
                    label: "Roller excursion P90",
                    value: String(
                        format: "%.2f",
                        balanceMetrics.rollerExcursionP90
                    )
                ),
                at: min(1, metrics.count)
            )
        }
        if let medianKnee {
            numericMetrics["median_knee_flexion_deg"] =
                medianKnee
        }
        if let trunkP90 {
            numericMetrics["trunk_excursion_p90"] = trunkP90
        }
        if let medianStance {
            numericMetrics["stance_width_body_ratio"] =
                medianStance
        }
        if let medianArm {
            numericMetrics["arm_excursion_body_ratio"] =
                medianArm
        }
        if let startSpread {
            numericMetrics["neutral_start_spread"] =
                startSpread
        }
        if let finishSpread {
            numericMetrics["neutral_finish_spread"] =
                finishSpread
        }
        if let shiftRange {
            numericMetrics["controlled_shift_range"] =
                shiftRange
        }
        if let squatDepth {
            numericMetrics["squat_flexion_p75_deg"] =
                squatDepth
        }

        if let balanceMetrics,
           balanceMetrics.sampleCount >= 60,
           balanceMetrics.meanConfidence >= 0.55,
           boardCoverageAll >= 0.50 {
            if let recovery =
                    balanceMetrics.p90RecoveryTimeMS,
               balanceMetrics.recoveryCount >= 3,
               recovery > 900 {
                return IndoBoardCoachReport(
                    headline: "Start the recovery earlier",
                    observation:
                        "Your longer deck-and-roller recoveries took over 0.9 seconds to return toward center.",
                    tip:
                        "Begin with a smaller correction before the roller travels as far from center.",
                    drill:
                        "5 slow excursions, returning toward center before the board reaches the outer zone",
                    confidence:
                        min(0.92, balanceMetrics.meanConfidence * 0.90),
                    evidenceLabel:
                        "Deck + roller image geometry · balance proxy",
                    metrics: Array(metrics.prefix(6)),
                    numericMetrics: numericMetrics
                )
            }

            if balanceMetrics.centerTimeFraction < 0.55 {
                return IndoBoardCoachReport(
                    headline: "Own the center longer",
                    observation:
                        "The roller spent less than 55% of measured time in the central deck zone.",
                    tip:
                        "Use smaller early corrections and pause briefly when the roller returns near center.",
                    drill:
                        "5 slow left/right shifts with a one-second center hold",
                    confidence:
                        min(0.92, balanceMetrics.meanConfidence * 0.88),
                    evidenceLabel:
                        "Deck + roller image geometry · balance proxy",
                    metrics: Array(metrics.prefix(6)),
                    numericMetrics: numericMetrics
                )
            }

            if balanceMetrics.edgeApproachCount >= 3 {
                return IndoBoardCoachReport(
                    headline: "Reduce repeated edge approaches",
                    observation:
                        "The roller entered the outer deck zone several times during this session.",
                    tip:
                        "Try catching the motion earlier with a smaller correction instead of waiting for a larger rescue.",
                    drill:
                        "Controlled shifts that stop short of the outer zone",
                    confidence:
                        min(0.90, balanceMetrics.meanConfidence * 0.84),
                    evidenceLabel:
                        "Deck + roller image geometry · balance proxy",
                    metrics: Array(metrics.prefix(6)),
                    numericMetrics: numericMetrics
                )
            }
        }

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
                metrics: metrics,
                numericMetrics: numericMetrics
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
                metrics: metrics,
                numericMetrics: numericMetrics
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
                metrics: metrics,
                numericMetrics: numericMetrics
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
                metrics: metrics,
                numericMetrics: numericMetrics
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
                metrics: metrics,
                numericMetrics: numericMetrics
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
            metrics: metrics,
            numericMetrics: numericMetrics
        )
    }

    private func blockSamples(
        _ id: String
    ) -> [Sample] {
        samples.filter { $0.blockID == id }
    }

    private func evaluate(
        _ intervention: IndoBoardCoachIntervention
    ) -> IndoBoardCoachExperimentResult {
        let beforeSamples = blockSamples("free-balance-a")
        let afterSamples = blockSamples("free-balance-b")

        guard beforeSamples.count >= 20,
              afterSamples.count >= 20
        else {
            return IndoBoardCoachExperimentResult(
                targetMetric: intervention.targetMetric,
                before: nil,
                after: nil,
                relativeChange: nil,
                outcome: .insufficientEvidence,
                summary:
                    "The coached retry did not contain enough clean pose evidence to judge the cue."
            )
        }

        if intervention.targetMetric == .rollerExcursionP90
            || intervention.targetMetric == .centerTimeFraction {
            let beforeCoverage = boardCoverage(
                beforeSamples,
                minimumConfidence: 0.55
            )
            let afterCoverage = boardCoverage(
                afterSamples,
                minimumConfidence: 0.55
            )

            guard beforeCoverage >= 0.60,
                  afterCoverage >= 0.60
            else {
                return IndoBoardCoachExperimentResult(
                    targetMetric:
                        intervention.targetMetric,
                    before: nil,
                    after: nil,
                    relativeChange: nil,
                    outcome: .insufficientEvidence,
                    summary:
                        "The coached retry did not keep deck-and-roller tracking visible often enough to score the board-relative cue."
                )
            }
        }

        let before: Double?
        let after: Double?

        switch intervention.targetMetric {
        case .trunkExcursionP90:
            before = percentile(
                beforeSamples.compactMap(\.trunkOffsetRatio),
                q: 0.90
            )
            after = percentile(
                afterSamples.compactMap(\.trunkOffsetRatio),
                q: 0.90
            )

        case .medianKneeFlexion:
            before = median(
                beforeSamples.compactMap(\.kneeFlexionDeg)
            )
            after = median(
                afterSamples.compactMap(\.kneeFlexionDeg)
            )

        case .pelvisMotionSpread:
            before = robustSpread(
                beforeSamples.compactMap(\.pelvisX)
            )
            after = robustSpread(
                afterSamples.compactMap(\.pelvisX)
            )

        case .rollerExcursionP90:
            before = percentile(
                beforeSamples.compactMap {
                    guard ($0.boardStateConfidence ?? 0)
                            >= 0.55
                    else {
                        return nil
                    }
                    return $0.rollerAlongDeck.map(abs)
                },
                q: 0.90
            )
            after = percentile(
                afterSamples.compactMap {
                    guard ($0.boardStateConfidence ?? 0)
                            >= 0.55
                    else {
                        return nil
                    }
                    return $0.rollerAlongDeck.map(abs)
                },
                q: 0.90
            )

        case .centerTimeFraction:
            before = centerTimeFraction(
                beforeSamples
            )
            after = centerTimeFraction(
                afterSamples
            )
        }

        guard let before,
              let after
        else {
            return IndoBoardCoachExperimentResult(
                targetMetric: intervention.targetMetric,
                before: nil,
                after: nil,
                relativeChange: nil,
                outcome: .insufficientEvidence,
                summary:
                    "MotionOS could not compute the target metric reliably enough to score the coached retry."
            )
        }

        let denominator = max(abs(before), 1e-6)
        let relativeChange = (after - before) / denominator
        let signedImprovement: Double
        switch intervention.desiredDirection {
        case .increase:
            signedImprovement = relativeChange
        case .decrease:
            signedImprovement = -relativeChange
        }

        let outcome: IndoBoardCoachExperimentOutcome
        if signedImprovement >= 0.05 {
            outcome = .improved
        } else if signedImprovement <= -0.05 {
            outcome = .oppositeDirection
        } else {
            outcome = .noClearChange
        }

        let percent = Int((abs(relativeChange) * 100).rounded())
        let metricLabel: String
        switch intervention.targetMetric {
        case .trunkExcursionP90:
            metricLabel = "upper-body excursion"
        case .medianKneeFlexion:
            metricLabel = "median knee flexion"
        case .pelvisMotionSpread:
            metricLabel = "pelvis-motion spread"
        case .rollerExcursionP90:
            metricLabel = "roller excursion"
        case .centerTimeFraction:
            metricLabel = "center time"
        }

        let summary: String
        switch outcome {
        case .improved:
            summary =
                "During the coached retry, \(metricLabel) moved about \(percent)% in the intended direction."
        case .oppositeDirection:
            summary =
                "During the coached retry, \(metricLabel) moved about \(percent)% opposite the intended direction, so this cue should not be treated as a win yet."
        case .noClearChange:
            summary =
                "The coached retry changed \(metricLabel) by only about \(percent)%, so the effect was not clear in this session."
        case .insufficientEvidence:
            summary =
                "The coached retry did not contain enough evidence to evaluate this cue."
        }

        return IndoBoardCoachExperimentResult(
            targetMetric: intervention.targetMetric,
            before: before,
            after: after,
            relativeChange: relativeChange,
            outcome: outcome,
            summary: summary
        )
    }

    private func centerTimeFraction(
        _ values: [Sample]
    ) -> Double? {
        let qualified = values.filter {
            ($0.boardStateConfidence ?? 0) >= 0.55
                && $0.rollerAlongDeck != nil
        }
        guard qualified.count >= 20,
              boardCoverage(
                values,
                minimumConfidence: 0.55
              ) >= 0.60
        else {
            return nil
        }

        let centered = qualified.filter {
            abs($0.rollerAlongDeck ?? 1)
                            <= IndoBoardBalanceThresholds.centerZone
        }.count
        return Double(centered)
            / Double(qualified.count)
    }

    private func boardCoverage(
        _ values: [Sample],
        minimumConfidence: Double
    ) -> Double {
        guard !values.isEmpty else {
            return 0
        }

        let qualified = values.filter {
            ($0.boardStateConfidence ?? 0)
                >= minimumConfidence
                && $0.rollerAlongDeck != nil
        }.count

        return Double(qualified)
            / Double(values.count)
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

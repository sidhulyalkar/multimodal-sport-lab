import Foundation

public struct GuidedProtocolStep: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let instruction: String
    public let minimumStepDurationSeconds: Int?
    public let minimumPlanElapsedSeconds: Int?
    public let allowsSkip: Bool

    public init(
        id: String,
        title: String,
        instruction: String,
        minimumStepDurationSeconds: Int? = nil,
        minimumPlanElapsedSeconds: Int? = nil,
        allowsSkip: Bool = true
    ) {
        precondition(!id.isEmpty)
        precondition(!title.isEmpty)
        precondition(
            minimumStepDurationSeconds == nil
                || minimumStepDurationSeconds! >= 0
        )
        precondition(
            minimumPlanElapsedSeconds == nil
                || minimumPlanElapsedSeconds! >= 0
        )
        self.id = id
        self.title = title
        self.instruction = instruction
        self.minimumStepDurationSeconds = minimumStepDurationSeconds
        self.minimumPlanElapsedSeconds = minimumPlanElapsedSeconds
        self.allowsSkip = allowsSkip
    }

    public func canComplete(
        stepElapsedSeconds: TimeInterval,
        planElapsedSeconds: TimeInterval
    ) -> Bool {
        if let minimumStepDurationSeconds,
           stepElapsedSeconds < Double(minimumStepDurationSeconds) {
            return false
        }
        if let minimumPlanElapsedSeconds,
           planElapsedSeconds < Double(minimumPlanElapsedSeconds) {
            return false
        }
        return true
    }
}

public struct GuidedProtocolPlan: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let title: String
    public let targetDurationSeconds: Int
    public let steps: [GuidedProtocolStep]

    public init(
        id: String,
        version: String,
        title: String,
        targetDurationSeconds: Int,
        steps: [GuidedProtocolStep]
    ) {
        precondition(!id.isEmpty)
        precondition(!version.isEmpty)
        precondition(!title.isEmpty)
        precondition(targetDurationSeconds > 0)
        precondition(!steps.isEmpty)
        precondition(Set(steps.map(\.id)).count == steps.count)
        self.id = id
        self.version = version
        self.title = title
        self.targetDurationSeconds = targetDurationSeconds
        self.steps = steps
    }

    public static let p0A = GuidedProtocolPlan(
        id: "p0-a",
        version: "motionos.p0-guided.v1",
        title: "P0-A · 10-minute Watch shakedown",
        targetDurationSeconds: 600,
        steps: [
            .init(
                id: "stationary",
                title: "Stationary baseline",
                instruction: (
                    "Sit or stand still. Do not intentionally move the Watch."
                ),
                minimumStepDurationSeconds: 60,
                allowsSkip: false
            ),
            .init(
                id: "roll",
                title: "Wrist roll",
                instruction: (
                    "Perform five slow roll repetitions. Return to neutral "
                    + "between repetitions."
                )
            ),
            .init(
                id: "pitch",
                title: "Wrist pitch",
                instruction: (
                    "Perform five slow pitch repetitions. Return to neutral "
                    + "between repetitions."
                )
            ),
            .init(
                id: "yaw",
                title: "Wrist yaw",
                instruction: (
                    "Perform five slow yaw repetitions. Return to neutral "
                    + "between repetitions."
                )
            ),
            .init(
                id: "impulses",
                title: "Three deliberate impulses",
                instruction: (
                    "Perform three obvious wrist impulses, separated by "
                    + "about five seconds."
                )
            ),
            .init(
                id: "walking",
                title: "Walk normally",
                instruction: "Walk normally for two minutes.",
                minimumStepDurationSeconds: 120,
                allowsSkip: false
            ),
            .init(
                id: "phone-lock",
                title: "Lock iPhone",
                instruction: (
                    "Lock the iPhone while the Watch workout continues. "
                    + "Unlock after at least one minute."
                ),
                minimumStepDurationSeconds: 60,
                allowsSkip: false
            ),
            .init(
                id: "phone-background",
                title: "Background MotionOS",
                instruction: (
                    "Put MotionOS in the background for at least one minute, "
                    + "then return to the app."
                ),
                minimumStepDurationSeconds: 60,
                allowsSkip: false
            ),
            .init(
                id: "temporary-separation",
                title: "Temporary phone separation",
                instruction: (
                    "Move far enough from the iPhone to lose immediate "
                    + "reachability in a safe environment, continue for "
                    + "about one minute, then return."
                ),
                minimumStepDurationSeconds: 60,
                allowsSkip: false
            ),
            .init(
                id: "duration-fill",
                title: "Reach ten minutes total",
                instruction: (
                    "Continue normal foreground capture until the total "
                    + "Watch session reaches at least ten minutes."
                ),
                minimumPlanElapsedSeconds: 600,
                allowsSkip: false
            ),
            .init(
                id: "finish",
                title: "Finish on Apple Watch",
                instruction: (
                    "Stop the workout from Apple Watch. Confirm the Watch "
                    + "journal closes and is recovered on iPhone."
                ),
                allowsSkip: false
            ),
        ]
    )

    public static let p0B = GuidedProtocolPlan(
        id: "p0-b",
        version: "motionos.p0-guided.v1",
        title: "P0-B · 30-minute Watch qualification",
        targetDurationSeconds: 1800,
        steps: [
            .init(
                id: "stationary",
                title: "Five-minute stationary baseline",
                instruction: (
                    "Sit or stand still for at least five minutes. "
                    + "Do not intentionally move the Watch."
                ),
                minimumStepDurationSeconds: 300,
                allowsSkip: false
            ),
            .init(
                id: "rotations",
                title: "Repeated wrist rotations",
                instruction: (
                    "Perform controlled roll, pitch, and yaw repetitions "
                    + "with neutral pauses between axes."
                )
            ),
            .init(
                id: "walking",
                title: "Walking block",
                instruction: (
                    "Walk normally long enough to create a sustained "
                    + "dynamic segment."
                )
            ),
            .init(
                id: "phone-lock",
                title: "Lock iPhone",
                instruction: (
                    "Lock the iPhone while Watch capture continues, then "
                    + "return after at least one minute."
                ),
                minimumStepDurationSeconds: 60,
                allowsSkip: false
            ),
            .init(
                id: "phone-background",
                title: "Background MotionOS",
                instruction: (
                    "Background the iPhone app for at least one minute, "
                    + "then return."
                ),
                minimumStepDurationSeconds: 60,
                allowsSkip: false
            ),
            .init(
                id: "temporary-separation",
                title: "Temporary separation",
                instruction: (
                    "Temporarily leave immediate phone reachability, then "
                    + "return while the Watch keeps recording."
                ),
                minimumStepDurationSeconds: 60,
                allowsSkip: false
            ),
            .init(
                id: "foreground-use",
                title: "Normal foreground use",
                instruction: (
                    "Continue ordinary foreground capture until total "
                    + "session duration reaches at least 30 minutes."
                ),
                minimumPlanElapsedSeconds: 1800,
                allowsSkip: false
            ),
            .init(
                id: "finish",
                title: "Finish and recover journal",
                instruction: (
                    "Stop from Apple Watch, then verify the iPhone receives "
                    + "the hash-verified journal."
                ),
                allowsSkip: false
            ),
        ]
    )
}

public struct GuidedProtocolProgress: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case idle
        case running
        case completed
        case cancelled
    }

    public private(set) var state: State = .idle
    public private(set) var currentStepIndex: Int = 0
    public private(set) var completedStepIDs: [String] = []
    public private(set) var skippedStepIDs: [String] = []

    public init() {}

    public mutating func start(plan: GuidedProtocolPlan) {
        guard state == .idle else { return }
        currentStepIndex = 0
        completedStepIDs = []
        skippedStepIDs = []
        state = .running
    }

    public func currentStep(
        plan: GuidedProtocolPlan
    ) -> GuidedProtocolStep? {
        guard state == .running,
              plan.steps.indices.contains(currentStepIndex)
        else {
            return nil
        }
        return plan.steps[currentStepIndex]
    }

    @discardableResult
    public mutating func completeCurrentStep(
        plan: GuidedProtocolPlan,
        stepElapsedSeconds: TimeInterval,
        planElapsedSeconds: TimeInterval
    ) -> Bool {
        guard let step = currentStep(plan: plan),
              step.canComplete(
                stepElapsedSeconds: stepElapsedSeconds,
                planElapsedSeconds: planElapsedSeconds
              )
        else {
            return false
        }

        completedStepIDs.append(step.id)
        advance(plan: plan)
        return true
    }

    @discardableResult
    public mutating func skipCurrentStep(
        plan: GuidedProtocolPlan
    ) -> Bool {
        guard let step = currentStep(plan: plan),
              step.allowsSkip
        else {
            return false
        }

        skippedStepIDs.append(step.id)
        advance(plan: plan)
        return true
    }

    public mutating func cancel() {
        guard state == .running else { return }
        state = .cancelled
    }

    public mutating func reset() {
        self = GuidedProtocolProgress()
    }

    private mutating func advance(
        plan: GuidedProtocolPlan
    ) {
        currentStepIndex += 1
        if currentStepIndex >= plan.steps.count {
            state = .completed
        }
    }
}

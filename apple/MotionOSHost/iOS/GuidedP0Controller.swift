import Combine
import Foundation
import MotionOSAppleCapture
import UIKit

struct GuidedP0EvidenceBundle: Sendable {
    let directory: URL
    let journalURL: URL
}

private struct GuidedP0OperatorEvent: Codable {
    let schemaVersion: String
    let guidanceID: String
    let sequence: UInt64
    let hostMonotonicNS: UInt64
    let wallClockUTC: String
    let planID: String
    let planVersion: String
    let kind: String
    let stepID: String?
    let stepTitle: String?
    let payload: [String: String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case guidanceID = "guidance_id"
        case sequence
        case hostMonotonicNS = "host_monotonic_ns"
        case wallClockUTC = "wall_clock_utc"
        case planID = "plan_id"
        case planVersion = "plan_version"
        case kind
        case stepID = "step_id"
        case stepTitle = "step_title"
        case payload
    }
}

@MainActor
final class GuidedP0Controller: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case p0A = "P0-A"
        case p0B = "P0-B"

        var id: String { rawValue }

        var plan: GuidedProtocolPlan {
            switch self {
            case .p0A:
                .p0A
            case .p0B:
                .p0B
            }
        }
    }

    static let schemaVersion = "motionos.guided-p0-operator.v1"

    @Published private(set) var mode: Mode = .p0A
    @Published private(set) var progress = GuidedProtocolProgress()
    @Published private(set) var guidanceID: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var stepStartedAt: Date?
    @Published private(set) var evidenceBundle: GuidedP0EvidenceBundle?
    @Published private(set) var errorMessage: String?

    var plan: GuidedProtocolPlan {
        mode.plan
    }

    var currentStep: GuidedProtocolStep? {
        progress.currentStep(plan: plan)
    }

    var isRunning: Bool {
        progress.state == .running
    }

    func selectMode(_ newMode: Mode) {
        guard progress.state == .idle
                || progress.state == .completed
                || progress.state == .cancelled
        else {
            return
        }

        if progress.state != .idle {
            reset()
        }
        mode = newMode
    }

    func start() {
        guard progress.state == .idle else { return }

        do {
            let id = Self.makeGuidanceID(planID: plan.id)
            let urls = try Self.makeEvidenceURLs(guidanceID: id)

            _ = FileManager.default.createFile(
                atPath: urls.journal.path,
                contents: nil
            )
            let handle = try FileHandle(forWritingTo: urls.journal)

            guidanceID = id
            evidenceBundle = GuidedP0EvidenceBundle(
                directory: urls.directory,
                journalURL: urls.journal
            )
            journalHandle = handle
            sequence = 0
            lastHostMonotonicNS = nil

            let now = Date()
            let monotonicNow = MonotonicClock.nowNS()
            startedAt = now
            stepStartedAt = now
            startedMonotonicNS = monotonicNow
            stepStartedMonotonicNS = monotonicNow

            try append(
                kind: "protocol_started",
                payload: [
                    "target_duration_seconds":
                        String(plan.targetDurationSeconds),
                    "timing_semantics":
                        "operator_guidance_only_not_sync_authority",
                ]
            )
            try appendStepStarted(plan.steps[0])

            progress.start(plan: plan)
            notify(.success)
            errorMessage = nil
        } catch {
            cleanupFailedStart()
            fail(error)
        }
    }

    func completeCurrentStep() {
        guard let step = currentStep else { return }

        let nowNS = MonotonicClock.nowNS()
        let stepElapsed = stepElapsedSeconds(nowNS: nowNS)
        let planElapsed = planElapsedSeconds(nowNS: nowNS)
        guard step.canComplete(
            stepElapsedSeconds: stepElapsed,
            planElapsedSeconds: planElapsed
        ) else {
            errorMessage = (
                "The current step has not reached its declared minimum yet."
            )
            notify(.warning)
            return
        }

        do {
            try append(
                kind: "step_completed",
                step: step,
                payload: [
                    "step_elapsed_seconds":
                        String(format: "%.3f", stepElapsed),
                    "plan_elapsed_seconds":
                        String(format: "%.3f", planElapsed),
                ]
            )

            guard progress.completeCurrentStep(
                plan: plan,
                stepElapsedSeconds: stepElapsed,
                planElapsedSeconds: planElapsed
            ) else {
                throw GuidanceError.transitionRejected
            }

            if progress.state == .completed {
                try append(
                    kind: "protocol_completed",
                    payload: [
                        "plan_elapsed_seconds":
                            String(format: "%.3f", planElapsed),
                        "completed_step_count":
                            String(progress.completedStepIDs.count),
                        "skipped_step_count":
                            String(progress.skippedStepIDs.count),
                    ]
                )
                try closeJournal()
                stepStartedAt = nil
                stepStartedMonotonicNS = nil
                notify(.success)
            } else {
                stepStartedAt = Date()
                stepStartedMonotonicNS = MonotonicClock.nowNS()
                try appendCurrentStepStarted()
                notify(.success)
            }
            errorMessage = nil
        } catch {
            fail(error)
        }
    }

    func skipCurrentStep() {
        guard let step = currentStep,
              step.allowsSkip
        else {
            errorMessage = "This protocol step cannot be skipped."
            notify(.warning)
            return
        }

        do {
            try append(
                kind: "step_skipped",
                step: step,
                payload: [
                    "plan_elapsed_seconds":
                        String(
                            format: "%.3f",
                            planElapsedSeconds()
                        ),
                ]
            )
            guard progress.skipCurrentStep(plan: plan) else {
                throw GuidanceError.transitionRejected
            }
            stepStartedAt = Date()
            stepStartedMonotonicNS = MonotonicClock.nowNS()

            if progress.state == .completed {
                try append(
                    kind: "protocol_completed",
                    payload: [
                        "plan_elapsed_seconds":
                            String(
                                format: "%.3f",
                                planElapsedSeconds()
                            ),
                        "completed_step_count":
                            String(progress.completedStepIDs.count),
                        "skipped_step_count":
                            String(progress.skippedStepIDs.count),
                    ]
                )
                try closeJournal()
                stepStartedAt = nil
                stepStartedMonotonicNS = nil
            } else {
                try appendCurrentStepStarted()
            }
            notify(.warning)
            errorMessage = nil
        } catch {
            fail(error)
        }
    }

    func cancel() {
        guard progress.state == .running else { return }

        do {
            let active = currentStep
            try append(
                kind: "protocol_cancelled",
                step: active,
                payload: [
                    "plan_elapsed_seconds":
                        String(
                            format: "%.3f",
                            planElapsedSeconds()
                        ),
                ]
            )
            progress.cancel()
            try closeJournal()
            stepStartedAt = nil
            stepStartedMonotonicNS = nil
            notify(.warning)
            errorMessage = nil
        } catch {
            fail(error)
        }
    }

    func reset() {
        try? journalHandle?.close()
        journalHandle = nil
        progress.reset()
        guidanceID = nil
        startedAt = nil
        stepStartedAt = nil
        startedMonotonicNS = nil
        stepStartedMonotonicNS = nil
        evidenceBundle = nil
        errorMessage = nil
        sequence = 0
        lastHostMonotonicNS = nil
    }

    func planElapsedSeconds(
        nowNS: UInt64 = MonotonicClock.nowNS()
    ) -> TimeInterval {
        guard let startedMonotonicNS,
              nowNS >= startedMonotonicNS
        else {
            return 0
        }
        return Double(nowNS - startedMonotonicNS)
            / 1_000_000_000.0
    }

    func stepElapsedSeconds(
        nowNS: UInt64 = MonotonicClock.nowNS()
    ) -> TimeInterval {
        guard let stepStartedMonotonicNS,
              nowNS >= stepStartedMonotonicNS
        else {
            return 0
        }
        return Double(nowNS - stepStartedMonotonicNS)
            / 1_000_000_000.0
    }

    func currentStepCanComplete() -> Bool {
        guard let currentStep else { return false }
        let nowNS = MonotonicClock.nowNS()
        return currentStep.canComplete(
            stepElapsedSeconds: stepElapsedSeconds(nowNS: nowNS),
            planElapsedSeconds: planElapsedSeconds(nowNS: nowNS)
        )
    }

    func remainingGateSeconds() -> TimeInterval {
        guard let step = currentStep else { return 0 }
        let nowNS = MonotonicClock.nowNS()

        var remaining: TimeInterval = 0
        if let minimum = step.minimumStepDurationSeconds {
            remaining = max(
                remaining,
                Double(minimum)
                    - stepElapsedSeconds(nowNS: nowNS)
            )
        }
        if let minimum = step.minimumPlanElapsedSeconds {
            remaining = max(
                remaining,
                Double(minimum)
                    - planElapsedSeconds(nowNS: nowNS)
            )
        }
        return max(0, remaining)
    }

    private var journalHandle: FileHandle?
    private var sequence: UInt64 = 0
    private var lastHostMonotonicNS: UInt64?
    private var startedMonotonicNS: UInt64?
    private var stepStartedMonotonicNS: UInt64?

    private func appendCurrentStepStarted() throws {
        guard let step = currentStep else { return }
        try appendStepStarted(step)
    }

    private func appendStepStarted(
        _ step: GuidedProtocolStep
    ) throws {
        try append(
            kind: "step_started",
            step: step,
            payload: [
                "instruction": step.instruction,
                "minimum_step_duration_seconds":
                    step.minimumStepDurationSeconds.map {
                        String($0)
                    } ?? "none",
                "minimum_plan_elapsed_seconds":
                    step.minimumPlanElapsedSeconds.map {
                        String($0)
                    } ?? "none",
            ]
        )
    }

    private func cleanupFailedStart() {
        try? journalHandle?.close()
        journalHandle = nil
        progress.reset()
        guidanceID = nil
        startedAt = nil
        stepStartedAt = nil
        startedMonotonicNS = nil
        stepStartedMonotonicNS = nil
        evidenceBundle = nil
        sequence = 0
        lastHostMonotonicNS = nil
    }

    private func append(
        kind: String,
        step: GuidedProtocolStep? = nil,
        payload: [String: String] = [:]
    ) throws {
        guard let guidanceID,
              let journalHandle
        else {
            throw GuidanceError.journalUnavailable
        }

        let now = MonotonicClock.nowNS()
        let monotonic = max(now, lastHostMonotonicNS ?? now)
        let event = GuidedP0OperatorEvent(
            schemaVersion: Self.schemaVersion,
            guidanceID: guidanceID,
            sequence: sequence,
            hostMonotonicNS: monotonic,
            wallClockUTC: ISO8601DateFormatter().string(from: Date()),
            planID: plan.id,
            planVersion: plan.version,
            kind: kind,
            stepID: step?.id,
            stepTitle: step?.title,
            payload: payload
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(event)
        data.append(0x0A)
        try journalHandle.write(contentsOf: data)

        lastHostMonotonicNS = monotonic
        sequence += 1
    }

    private func closeJournal() throws {
        try journalHandle?.synchronize()
        try journalHandle?.close()
        journalHandle = nil
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        notify(.error)
    }

    private func notify(
        _ type: UINotificationFeedbackGenerator.FeedbackType
    ) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }

    private static func makeGuidanceID(
        planID: String
    ) -> String {
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "guided-\(planID)-\(stamp)-"
            + UUID().uuidString.prefix(8).lowercased()
    }

    private static func makeEvidenceURLs(
        guidanceID: String
    ) throws -> (
        directory: URL,
        journal: URL
    ) {
        let manager = FileManager.default
        let documents = try manager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents
            .appendingPathComponent(
                "MotionOSGuidance",
                isDirectory: true
            )
            .appendingPathComponent(
                guidanceID,
                isDirectory: true
            )
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (
            directory,
            directory.appendingPathComponent("guided-p0-events.jsonl")
        )
    }

    enum GuidanceError: LocalizedError {
        case journalUnavailable
        case transitionRejected

        var errorDescription: String? {
            switch self {
            case .journalUnavailable:
                "The guided P0 operator journal is unavailable."
            case .transitionRejected:
                "The guided protocol state rejected a journaled transition."
            }
        }
    }
}

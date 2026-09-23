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
            startedAt = now
            stepStartedAt = now
            progress.start(plan: plan)

            try append(
                kind: "protocol_started",
                payload: [
                    "target_duration_seconds":
                        String(plan.targetDurationSeconds),
                    "timing_semantics":
                        "operator_guidance_only_not_sync_authority",
                ]
            )
            try appendCurrentStepStarted()
            notify(.success)
            errorMessage = nil
        } catch {
            fail(error)
        }
    }

    func completeCurrentStep(at date: Date = Date()) {
        guard let step = currentStep else { return }

        let stepElapsed = stepElapsedSeconds(at: date)
        let planElapsed = planElapsedSeconds(at: date)
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
                notify(.success)
            } else {
                stepStartedAt = date
                try appendCurrentStepStarted()
                notify(.success)
            }
            errorMessage = nil
        } catch {
            fail(error)
        }
    }

    func skipCurrentStep(at date: Date = Date()) {
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
                            planElapsedSeconds(at: date)
                        ),
                ]
            )
            guard progress.skipCurrentStep(plan: plan) else {
                throw GuidanceError.transitionRejected
            }
            stepStartedAt = date
            try appendCurrentStepStarted()
            notify(.warning)
            errorMessage = nil
        } catch {
            fail(error)
        }
    }

    func cancel(at date: Date = Date()) {
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
                            planElapsedSeconds(at: date)
                        ),
                ]
            )
            progress.cancel()
            try closeJournal()
            stepStartedAt = nil
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
        evidenceBundle = nil
        errorMessage = nil
        sequence = 0
        lastHostMonotonicNS = nil
    }

    func planElapsedSeconds(
        at date: Date = Date()
    ) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, date.timeIntervalSince(startedAt))
    }

    func stepElapsedSeconds(
        at date: Date = Date()
    ) -> TimeInterval {
        guard let stepStartedAt else { return 0 }
        return max(0, date.timeIntervalSince(stepStartedAt))
    }

    func currentStepCanComplete(
        at date: Date = Date()
    ) -> Bool {
        guard let currentStep else { return false }
        return currentStep.canComplete(
            stepElapsedSeconds: stepElapsedSeconds(at: date),
            planElapsedSeconds: planElapsedSeconds(at: date)
        )
    }

    func remainingGateSeconds(
        at date: Date = Date()
    ) -> TimeInterval {
        guard let step = currentStep else { return 0 }

        var remaining: TimeInterval = 0
        if let minimum = step.minimumStepDurationSeconds {
            remaining = max(
                remaining,
                Double(minimum) - stepElapsedSeconds(at: date)
            )
        }
        if let minimum = step.minimumPlanElapsedSeconds {
            remaining = max(
                remaining,
                Double(minimum) - planElapsedSeconds(at: date)
            )
        }
        return max(0, remaining)
    }

    private var journalHandle: FileHandle?
    private var sequence: UInt64 = 0
    private var lastHostMonotonicNS: UInt64?

    private func appendCurrentStepStarted() throws {
        guard let step = currentStep else { return }
        try append(
            kind: "step_started",
            step: step,
            payload: [
                "instruction": step.instruction,
                "minimum_step_duration_seconds":
                    step.minimumStepDurationSeconds.map(String.init)
                    ?? "none",
                "minimum_plan_elapsed_seconds":
                    step.minimumPlanElapsedSeconds.map(String.init)
                    ?? "none",
            ]
        )
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

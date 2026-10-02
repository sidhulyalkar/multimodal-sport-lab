import Combine
import Foundation
import MotionOSAppleCapture

@MainActor
final class MobilityChallengeCoordinator: ObservableObject {
    enum Phase: String {
        case idle
        case preparing
        case ready
        case recording
        case finalizing
        case complete
        case failed
    }

    struct Step: Identifiable, Equatable {
        let id: String
        let title: String
        let instruction: String
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval

        func contains(_ elapsed: TimeInterval) -> Bool {
            elapsed >= startSeconds && elapsed < endSeconds
        }
    }

    static let steps: [Step] = [
        .init(
            id: "settle",
            title: "Neutral",
            instruction: "Stand naturally with your full body visible.",
            startSeconds: 0,
            endSeconds: 5
        ),
        .init(
            id: "left-shoulder",
            title: "Left arm overhead",
            instruction: "Slowly raise your left arm as high as is comfortable, then lower it.",
            startSeconds: 5,
            endSeconds: 12
        ),
        .init(
            id: "right-shoulder",
            title: "Right arm overhead",
            instruction: "Slowly raise your right arm as high as is comfortable, then lower it.",
            startSeconds: 12,
            endSeconds: 19
        ),
        .init(
            id: "squat",
            title: "Comfortable squat",
            instruction: "Perform one slow squat only as deep as is comfortable, then stand.",
            startSeconds: 19,
            endSeconds: 27
        ),
        .init(
            id: "twist",
            title: "Gentle trunk rotation",
            instruction: "Keep your feet planted and rotate your torso gently left and right.",
            startSeconds: 27,
            endSeconds: 37
        ),
        .init(
            id: "finish",
            title: "Finish",
            instruction: "Return to neutral and stand still.",
            startSeconds: 37,
            endSeconds: 40
        ),
    ]

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var result: MobilityProtocolResult?
    @Published private(set) var resultURL: URL?
    @Published private(set) var personaEvidenceURL: URL?
    @Published private(set) var errorMessage: String?

    private var accumulator = MobilityProtocolAccumulator()
    private var loopTask: Task<Void, Never>?

    var elapsedSeconds: TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, Date().timeIntervalSince(startedAt))
    }

    var completionFraction: Double {
        min(
            1,
            elapsedSeconds
                / MobilityProtocolAccumulator.targetDurationSeconds
        )
    }

    var currentStep: Step? {
        Self.steps.first {
            $0.contains(elapsedSeconds)
        }
    }

    func prepare(
        camera: CameraCaptureController
    ) async {
        phase = .preparing
        errorMessage = nil

        if camera.phase == .idle
            || camera.phase == .failed
            || camera.phase == .denied
            || camera.phase == .evidenceReady {
            await camera.prepare()
        }

        guard camera.phase == .ready
                || camera.phase == .evidenceReady
        else {
            fail(
                camera.errorMessage
                    ?? "The iPhone camera must be ready before the Mobility challenge."
            )
            return
        }

        phase = .ready
    }

    func start(
        camera: CameraCaptureController,
        personaEvidence: PersonaEvidenceLibrary
    ) async {
        if phase != .ready {
            await prepare(camera: camera)
        }
        guard phase == .ready else { return }

        accumulator = MobilityProtocolAccumulator()
        result = nil
        resultURL = nil
        personaEvidenceURL = nil
        errorMessage = nil
        startedAt = nil
        phase = .recording

        await camera.startRecording()
        guard camera.phase == .recording else {
            fail(
                camera.errorMessage
                    ?? "The Mobility challenge camera could not start."
            )
            return
        }

        startedAt = Date()
        startLoop(
            camera: camera,
            personaEvidence: personaEvidence
        )
    }

    func finish(
        camera: CameraCaptureController,
        personaEvidence: PersonaEvidenceLibrary
    ) async {
        guard phase == .recording else { return }

        phase = .finalizing
        loopTask?.cancel()
        loopTask = nil
        consumeLatestFrame(camera)

        await camera.stopRecording()

        let challengeID = Self.makeChallengeID()
        let result = accumulator.result(
            challengeID: challengeID,
            capturedAt: startedAt ?? Date(),
            cameraSessionID:
                camera.sessionID ?? "camera-unknown"
        )
        self.result = result

        do {
            resultURL = try persist(result)
        } catch {
            fail(
                "Mobility result could not be saved: "
                    + error.localizedDescription
            )
            return
        }

        let evidence = result.personaEvidence()
        personaEvidenceURL = personaEvidence.save(
            evidence
        )

        if !result.hasUsableCoverage {
            errorMessage = (
                "The recording was preserved, but one or more movement windows "
                    + "did not contain enough complete pose geometry to contribute "
                    + "to the Fitness Persona."
            )
        } else if personaEvidenceURL == nil {
            errorMessage =
                personaEvidence.errorMessage
                    ?? "The Persona evidence record could not be saved."
        } else {
            errorMessage = nil
        }

        phase = .complete
    }

    func reset() {
        guard phase != .recording
                && phase != .finalizing
        else {
            return
        }

        loopTask?.cancel()
        loopTask = nil
        accumulator = MobilityProtocolAccumulator()
        startedAt = nil
        result = nil
        resultURL = nil
        personaEvidenceURL = nil
        errorMessage = nil
        phase = .idle
    }

    private func startLoop(
        camera: CameraCaptureController,
        personaEvidence: PersonaEvidenceLibrary
    ) {
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.phase == .recording
                else {
                    return
                }

                self.consumeLatestFrame(camera)

                if self.elapsedSeconds
                    >= MobilityProtocolAccumulator.targetDurationSeconds {
                    await self.finish(
                        camera: camera,
                        personaEvidence: personaEvidence
                    )
                    return
                }

                try? await Task.sleep(
                    for: .milliseconds(80)
                )
            }
        }
    }

    private func consumeLatestFrame(
        _ camera: CameraCaptureController
    ) {
        guard let frame = camera.latestPoseFrame else {
            return
        }

        _ = accumulator.observe(
            frame,
            elapsedSeconds: elapsedSeconds
        )
    }

    private func persist(
        _ result: MobilityProtocolResult
    ) throws -> URL {
        let root = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(
            "MotionOSChallenges",
            isDirectory: true
        )
        .appendingPathComponent(
            "mobility",
            isDirectory: true
        )
        .appendingPathComponent(
            result.challengeID,
            isDirectory: true
        )

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let url = root.appendingPathComponent(
            "mobility-result.json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(result).write(
            to: url,
            options: .atomic
        )
        return url
    }

    private func fail(
        _ message: String
    ) {
        loopTask?.cancel()
        loopTask = nil
        phase = .failed
        errorMessage = message
    }

    private static func makeChallengeID() -> String {
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "mobility-\(stamp)-\(UUID().uuidString.prefix(6).lowercased())"
    }
}

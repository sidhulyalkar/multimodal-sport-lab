import Combine
import Foundation
import MotionOSAppleCapture

@MainActor
final class PowerChallengeCoordinator: ObservableObject {
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
            title: "Settle",
            instruction: "Stand comfortably with your whole body and both feet visible.",
            startSeconds: 0,
            endSeconds: 5
        ),
        .init(
            id: "jump-1",
            title: "Jump 1",
            instruction: "Make one comfortable countermovement jump, then land and settle.",
            startSeconds: 5,
            endSeconds: 10
        ),
        .init(
            id: "recover-1",
            title: "Recover",
            instruction: "Stand naturally and prepare for the next attempt.",
            startSeconds: 10,
            endSeconds: 13
        ),
        .init(
            id: "jump-2",
            title: "Jump 2",
            instruction: "Repeat one comfortable countermovement jump.",
            startSeconds: 13,
            endSeconds: 18
        ),
        .init(
            id: "recover-2",
            title: "Recover",
            instruction: "Settle and prepare for the final attempt.",
            startSeconds: 18,
            endSeconds: 21
        ),
        .init(
            id: "jump-3",
            title: "Jump 3",
            instruction: "Make the final comfortable countermovement jump, then settle.",
            startSeconds: 21,
            endSeconds: 26
        ),
        .init(
            id: "finish",
            title: "Finish",
            instruction: "Stand still while MotionOS closes the challenge.",
            startSeconds: 26,
            endSeconds: 28
        ),
    ]

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var result: PowerProtocolResult?
    @Published private(set) var resultURL: URL?
    @Published private(set) var personaEvidenceURL: URL?
    @Published private(set) var errorMessage: String?

    private var accumulator = PowerProtocolAccumulator()
    private var loopTask: Task<Void, Never>?

    var elapsedSeconds: TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, Date().timeIntervalSince(startedAt))
    }

    var completionFraction: Double {
        min(
            1,
            elapsedSeconds
                / PowerProtocolAccumulator.targetDurationSeconds
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
                "The iPhone camera must be ready before the Power challenge."
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

        accumulator = PowerProtocolAccumulator()
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
                    ?? "The Power challenge camera could not start."
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
        let capturedAt = startedAt ?? Date()
        let cameraSessionID =
            camera.sessionID ?? "camera-unknown"

        let result = accumulator.result(
            challengeID: challengeID,
            capturedAt: capturedAt,
            cameraSessionID: cameraSessionID
        )
        self.result = result

        do {
            resultURL = try persist(result)
        } catch {
            fail(
                "Power result could not be saved: "
                    + error.localizedDescription
            )
            return
        }

        let evidence = result.personaEvidence()
        personaEvidenceURL = personaEvidence.save(
            evidence
        )

        if result.validAttemptCount < 2 {
            errorMessage = (
                "The recording was preserved, but fewer than two attempts "
                    + "contained enough camera-space geometry to contribute "
                    + "to the Fitness Persona. Reframe and repeat when ready."
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
        accumulator = PowerProtocolAccumulator()
        result = nil
        resultURL = nil
        personaEvidenceURL = nil
        startedAt = nil
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
                    >= PowerProtocolAccumulator.targetDurationSeconds {
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
        _ result: PowerProtocolResult
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
            "power",
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
            "power-result.json"
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
        return "power-\(stamp)-\(UUID().uuidString.prefix(6).lowercased())"
    }
}

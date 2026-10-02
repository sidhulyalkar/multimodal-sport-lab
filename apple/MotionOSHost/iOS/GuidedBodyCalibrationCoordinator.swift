import Combine
import Foundation
import MotionOSAppleCapture

@MainActor
final class GuidedBodyCalibrationCoordinator: ObservableObject {
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

    static let targetDurationSeconds: TimeInterval = 40

    static let steps: [Step] = [
        .init(
            id: "neutral",
            title: "Neutral stance",
            instruction: "Stand tall, face the camera, and keep your full body visible.",
            startSeconds: 0,
            endSeconds: 8
        ),
        .init(
            id: "arms",
            title: "Arms out",
            instruction: "Raise both arms comfortably to the sides so shoulders, elbows, and wrists are clear.",
            startSeconds: 8,
            endSeconds: 16
        ),
        .init(
            id: "left-quarter",
            title: "Quarter turn left",
            instruction: "Turn about 45° left while keeping both feet and both arms visible.",
            startSeconds: 16,
            endSeconds: 24
        ),
        .init(
            id: "right-quarter",
            title: "Quarter turn right",
            instruction: "Turn through center to about 45° right, keeping your whole body in frame.",
            startSeconds: 24,
            endSeconds: 32
        ),
        .init(
            id: "bend",
            title: "Shallow bend",
            instruction: "Face front and make two slow shallow knee bends, then finish standing tall.",
            startSeconds: 32,
            endSeconds: 40
        ),
    ]

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var progress =
        BodyCalibrationProgress(
            framesSeen: 0,
            acceptedFrames: 0,
            parameterSampleCounts: [:]
        )
    @Published private(set) var result: BodyCalibrationResult?
    @Published private(set) var modelURL: URL?
    @Published private(set) var errorMessage: String?

    private var accumulator = BodyCalibrationAccumulator()
    private var captureTask: Task<Void, Never>?
    private var lastConsumedFrameKey: String?

    var elapsedSeconds: TimeInterval {
        guard let startedAt else { return 0 }
        return max(
            0,
            Date().timeIntervalSince(startedAt)
        )
    }

    var completionFraction: Double {
        min(
            1,
            elapsedSeconds / Self.targetDurationSeconds
        )
    }

    var currentStep: Step? {
        Self.steps.first {
            $0.contains(elapsedSeconds)
        }
    }

    var canSave: Bool {
        accumulator.canFinalize
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
                "The iPhone camera must be ready before body calibration."
            )
            return
        }

        phase = .ready
    }

    func start(
        camera: CameraCaptureController,
        bodyModels: PersonalBodyModelCoordinator
    ) async {
        if phase != .ready {
            await prepare(camera: camera)
        }
        guard phase == .ready else { return }

        accumulator = BodyCalibrationAccumulator()
        progress = accumulator.progress
        result = nil
        modelURL = nil
        errorMessage = nil
        lastConsumedFrameKey = nil
        startedAt = nil
        phase = .recording

        await camera.startRecording()
        guard camera.phase == .recording else {
            fail(
                camera.errorMessage
                    ?? "The calibration camera could not start recording."
            )
            return
        }

        startedAt = Date()
        startCaptureLoop(
            camera: camera,
            bodyModels: bodyModels
        )
    }

    func finish(
        camera: CameraCaptureController,
        bodyModels: PersonalBodyModelCoordinator
    ) async {
        guard phase == .recording else { return }

        phase = .finalizing
        captureTask?.cancel()
        captureTask = nil

        consumeLatestFrame(camera)

        await camera.stopRecording()

        do {
            let now = Date()
            let versionID = Self.makeVersionID(now)
            let sourceID =
                camera.sessionID
                    ?? "vision-calibration-unknown"

            let result = try accumulator.finalize(
                versionID: versionID,
                calibratedAt: now,
                sourceID: sourceID
            )
            self.result = result
            self.progress = accumulator.progress
            self.modelURL = bodyModels.save(result)

            guard modelURL != nil else {
                fail(
                    bodyModels.errorMessage
                        ?? "The calibrated body model could not be saved."
                )
                return
            }

            phase = .complete
            errorMessage = nil
        } catch {
            fail(error.localizedDescription)
        }
    }

    func reset() {
        guard phase != .recording
                && phase != .finalizing
        else {
            return
        }

        captureTask?.cancel()
        captureTask = nil
        accumulator = BodyCalibrationAccumulator()
        progress = accumulator.progress
        result = nil
        modelURL = nil
        startedAt = nil
        lastConsumedFrameKey = nil
        errorMessage = nil
        phase = .idle
    }

    private func startCaptureLoop(
        camera: CameraCaptureController,
        bodyModels: PersonalBodyModelCoordinator
    ) {
        captureTask?.cancel()
        captureTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.phase == .recording
                else {
                    return
                }

                self.consumeLatestFrame(camera)

                if self.elapsedSeconds
                    >= Self.targetDurationSeconds {
                    await self.finish(
                        camera: camera,
                        bodyModels: bodyModels
                    )
                    return
                }

                try? await Task.sleep(
                    for: .milliseconds(100)
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

        let key =
            frame.sessionID
                + ":"
                + String(frame.sequence)
        guard key != lastConsumedFrameKey else {
            return
        }
        lastConsumedFrameKey = key

        _ = accumulator.observe(frame)
        progress = accumulator.progress
    }

    private func fail(
        _ message: String
    ) {
        captureTask?.cancel()
        captureTask = nil
        phase = .failed
        errorMessage = message
    }

    private static func makeVersionID(
        _ date: Date
    ) -> String {
        let stamp = ISO8601DateFormatter()
            .string(from: date)
            .replacingOccurrences(of: ":", with: "")
        return "body-\(stamp)-\(UUID().uuidString.prefix(6).lowercased())"
    }
}

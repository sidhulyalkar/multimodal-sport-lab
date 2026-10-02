import AVFoundation
import Combine
import Foundation
import MotionOSAppleCapture
import UIKit

@MainActor
final class CameraCaptureController: ObservableObject {
    enum Phase: String {
        case idle
        case authorizing
        case ready
        case recording
        case finalizing
        case evidenceReady = "evidence ready"
        case denied
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var configuration: CameraCaptureConfiguration?
    @Published private(set) var sessionID: String?
    @Published private(set) var evidenceBundle: CameraEvidenceBundle?
    @Published private(set) var liveStats: CameraLiveCaptureStats?
    @Published private(set) var latestPoseFrame: BodyMovementFrame?
    @Published private(set) var latestPoseReceivedAt: Date?
    @Published private(set) var errorMessage: String?

    private let pipeline = CameraCapturePipeline()
    private var statsTask: Task<Void, Never>?
    private var poseTask: Task<Void, Never>?

    var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    var previewSession: AVCaptureSession {
        pipeline.captureSessionForPreview
    }

    func prepare() async {
        stopLivePolling()
        errorMessage = nil

        // Preview preparation starts a new capture opportunity. Never let a
        // prior sealed camera bundle or session identifier leak into a later
        // product run that fails before recording actually starts.
        sessionID = nil
        evidenceBundle = nil
        liveStats = nil
        latestPoseFrame = nil
        latestPoseReceivedAt = nil

        do {
            let authorized = try await ensureAuthorization()
            guard authorized else {
                phase = .denied
                return
            }

            configuration = try await pipeline.startPreview()
            phase = .ready
        } catch {
            fail(error)
        }
    }

    func startRecording() async {
        errorMessage = nil
        evidenceBundle = nil
        liveStats = nil
        latestPoseFrame = nil
        latestPoseReceivedAt = nil

        do {
            let authorized = try await ensureAuthorization()
            guard authorized else {
                phase = .denied
                return
            }

            let sessionID = Self.makeSessionID()
            self.sessionID = sessionID
            configuration = try await pipeline.startRecording(
                sessionID: sessionID,
                hostModel: UIDevice.current.model,
                hostOSVersion: UIDevice.current.systemVersion
            )
            phase = .recording
            startLivePolling()
        } catch {
            sessionID = nil
            fail(error)
        }
    }

    func stopRecording() async {
        guard phase == .recording else { return }
        phase = .finalizing
        errorMessage = nil
        stopLivePolling()

        do {
            liveStats = await pipeline.liveStats()
            evidenceBundle = try await pipeline.stopRecording()
            phase = .evidenceReady
        } catch {
            fail(error)
        }
    }

    private func startLivePolling() {
        stopLivePolling()

        statsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let stats = await self.pipeline.liveStats()
                guard !Task.isCancelled else { return }
                self.liveStats = stats
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        // Vision pose is already computed on the camera output queue. Polling
        // the latest completed frame at 10 Hz adds no additional Vision work
        // and keeps the 3D body scene responsive without touching evidence.
        poseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let nextPose = await self.pipeline.livePoseFrame()
                guard !Task.isCancelled else { return }
                if nextPose?.sessionID != self.latestPoseFrame?.sessionID
                    || nextPose?.sequence != self.latestPoseFrame?.sequence {
                    self.latestPoseFrame = nextPose
                    self.latestPoseReceivedAt =
                        nextPose == nil ? nil : Date()
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopLivePolling() {
        statsTask?.cancel()
        poseTask?.cancel()
        statsTask = nil
        poseTask = nil
    }

    private func ensureAuthorization() async throws -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            phase = .authorizing
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                phase = .denied
            }
            return granted
        case .denied, .restricted:
            phase = .denied
            return false
        @unknown default:
            phase = .denied
            return false
        }
    }

    private func fail(_ error: Error) {
        stopLivePolling()
        phase = .failed
        errorMessage = error.localizedDescription
    }

    private static func makeSessionID() -> String {
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "p5a-camera-\(stamp)-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

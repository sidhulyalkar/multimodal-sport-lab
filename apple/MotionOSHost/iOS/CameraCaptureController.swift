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
    @Published private(set) var latestIndoBoardState:
        IndoBoardBalanceState?
    @Published private(set) var latestIndoBoardEquipment:
        IndoBoardEquipmentObservation?
    @Published private(set) var latestVisibleIndoBoardFiducials:
        [IndoBoardFiducialMarkerID] = []
    @Published private(set) var latestIndoBoardStateReceivedAt:
        Date?
    @Published private(set) var indoBoardTrackingHealth:
        IndoBoardLiveTrackingHealth = .empty
    @Published private(set) var framingAssessment:
        CameraFramingAssessment = .waiting
    @Published private(set) var stanceAssessment:
        IndoBoardStanceAssessment = .waiting
    @Published private(set) var indoCoachReport:
        IndoBoardCoachReport?
    @Published private(set) var indoCoachIntervention:
        IndoBoardCoachIntervention?
    @Published private(set) var latestIndoPrimitive:
        IndoBoardPrimitiveObservation?
    @Published private(set) var errorMessage: String?

    private let pipeline = CameraCapturePipeline()
    private let stanceGate = IndoBoardStanceGate()
    private let indoCoach = IndoBoardCoachEngine()
    private let indoPrimitiveDetector =
        IndoBoardPrimitiveDetector()
    private let indoBoardTrackingWindow =
        IndoBoardLiveTrackingWindow()
    private var indoCoachStartedAt: Date?
    private var statsTask: Task<Void, Never>?
    private var poseTask: Task<Void, Never>?
    private var lastProcessedPoseSessionID: String?
    private var lastProcessedPoseSequence: UInt64?

    private static let livePoseStaleSeconds: TimeInterval = 0.80
    private static let liveBoardStaleSeconds: TimeInterval = 0.80

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
        latestIndoBoardState = nil
        latestIndoBoardEquipment = nil
        latestVisibleIndoBoardFiducials = []
        latestIndoBoardStateReceivedAt = nil
        indoBoardTrackingHealth = .empty
        indoBoardTrackingWindow.reset()
        lastProcessedPoseSessionID = nil
        lastProcessedPoseSequence = nil
        framingAssessment = .waiting
        stanceAssessment = .waiting
        stanceGate.reset()
        resetIndoCoachingSession()

        do {
            let authorized = try await ensureAuthorization()
            guard authorized else {
                phase = .denied
                return
            }

            configuration = try await pipeline.startPreview()
            phase = .ready
            startLivePolling()
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
        latestIndoBoardState = nil
        latestIndoBoardEquipment = nil
        latestVisibleIndoBoardFiducials = []
        latestIndoBoardStateReceivedAt = nil
        indoBoardTrackingHealth = .empty
        indoBoardTrackingWindow.reset()
        lastProcessedPoseSessionID = nil
        lastProcessedPoseSequence = nil
        framingAssessment = .waiting
        stanceAssessment = .waiting
        stanceGate.reset()
        resetIndoCoachingSession()

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

        // Vision pose is already computed on the camera output queue.
        // Polling is intentionally faster than the detector, so only process a
        // pose when its session/sequence identity changes. Re-processing the
        // same frame would inflate coaching samples and repeatedly reset the
        // stance gate because device timestamps are identical.
        poseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let nextPose = await self.pipeline.livePoseFrame()
                guard !Task.isCancelled else { return }

                let now = Date()
                let isNewPose: Bool = {
                    guard let nextPose else {
                        return false
                    }
                    return nextPose.sessionID
                            != self.lastProcessedPoseSessionID
                        || nextPose.sequence
                            != self.lastProcessedPoseSequence
                }()

                if isNewPose,
                   let nextPose {
                    self.lastProcessedPoseSessionID =
                        nextPose.sessionID
                    self.lastProcessedPoseSequence =
                        nextPose.sequence

                    let framing =
                        CameraFramingAssessment.evaluate(nextPose)
                    self.framingAssessment = framing
                    self.stanceAssessment =
                        self.stanceGate.update(
                            frame: nextPose,
                            framing: framing
                        )

                    if let startedAt =
                            self.indoCoachStartedAt {
                        let elapsed = max(
                            0,
                            now.timeIntervalSince(startedAt)
                        )
                        self.indoCoach.ingest(
                            frame: nextPose,
                            elapsedSeconds: elapsed
                        )
                        self.latestIndoPrimitive =
                            self.indoPrimitiveDetector.ingest(
                                frame: nextPose,
                                protocolBlockID:
                                    IndoBoardProductProtocol
                                        .activeBlock(
                                            at: elapsed
                                        )?.id
                            )
                    }

                    self.latestPoseFrame = nextPose
                    self.latestPoseReceivedAt = now
                    self.latestVisibleIndoBoardFiducials =
                        nextPose.indoBoardVisibleFiducials
                            ?? []

                    let boardState =
                        nextPose.indoBoardBalanceState
                    self.indoBoardTrackingHealth =
                        self.indoBoardTrackingWindow.ingest(
                            boardState
                        )

                    if let boardState,
                       let equipment =
                            nextPose.indoBoardEquipment {
                        self.latestIndoBoardState =
                            boardState
                        self.latestIndoBoardEquipment =
                            equipment
                        self.latestIndoBoardStateReceivedAt =
                            now
                    }
                }

                if let receivedAt =
                        self.latestPoseReceivedAt,
                   now.timeIntervalSince(receivedAt)
                        > Self.livePoseStaleSeconds {
                    self.latestPoseFrame = nil
                    self.latestPoseReceivedAt = nil
                    self.latestVisibleIndoBoardFiducials = []
                    self.framingAssessment = .waiting
                    self.stanceAssessment = .waiting
                    self.stanceGate.reset()
                    self.indoBoardTrackingWindow.reset()
                    self.indoBoardTrackingHealth = .empty
                }

                if let receivedAt =
                        self.latestIndoBoardStateReceivedAt,
                   now.timeIntervalSince(receivedAt)
                        > Self.liveBoardStaleSeconds {
                    self.latestIndoBoardState = nil
                    self.latestIndoBoardEquipment = nil
                    self.latestIndoBoardStateReceivedAt = nil
                }

                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func beginIndoCoachingSession() {
        indoCoach.reset()
        indoPrimitiveDetector.reset()
        indoCoachReport = nil
        indoCoachIntervention = nil
        latestIndoPrimitive = nil
        indoCoachStartedAt = Date()
    }

    @discardableResult
    func prepareIndoCoachIntervention()
        -> IndoBoardCoachIntervention? {
        if let indoCoachIntervention {
            return indoCoachIntervention
        }

        let intervention = indoCoach.makeIntervention()
        indoCoachIntervention = intervention
        return intervention
    }

    func finishIndoCoachingSession() {
        guard indoCoachStartedAt != nil else {
            return
        }
        indoCoachReport = indoCoach.makeReport(
            intervention: indoCoachIntervention
        )
        indoCoachStartedAt = nil
    }

    func resetIndoCoachingSession() {
        indoCoachStartedAt = nil
        indoCoachReport = nil
        indoCoachIntervention = nil
        latestIndoPrimitive = nil
        latestIndoBoardState = nil
        latestIndoBoardEquipment = nil
        latestVisibleIndoBoardFiducials = []
        latestIndoBoardStateReceivedAt = nil
        indoBoardTrackingWindow.reset()
        indoBoardTrackingHealth = .empty
        indoCoach.reset()
        indoPrimitiveDetector.reset()
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

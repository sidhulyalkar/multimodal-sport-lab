import AVFoundation
import Combine
import Foundation
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
    @Published private(set) var evidenceBundle: CameraEvidenceBundle?
    @Published private(set) var errorMessage: String?

    private let pipeline = CameraCapturePipeline()

    var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func prepare() async {
        errorMessage = nil
        do {
            let authorized = try await ensureAuthorization()
            guard authorized else {
                phase = .denied
                return
            }

            configuration = try await pipeline.configure()
            phase = .ready
        } catch {
            fail(error)
        }
    }

    func startRecording() async {
        errorMessage = nil
        evidenceBundle = nil

        do {
            let authorized = try await ensureAuthorization()
            guard authorized else {
                phase = .denied
                return
            }

            let sessionID = Self.makeSessionID()
            configuration = try await pipeline.startRecording(
                sessionID: sessionID,
                hostModel: UIDevice.current.model,
                hostOSVersion: UIDevice.current.systemVersion
            )
            phase = .recording
        } catch {
            fail(error)
        }
    }

    func stopRecording() async {
        guard phase == .recording else { return }
        phase = .finalizing
        errorMessage = nil

        do {
            evidenceBundle = try await pipeline.stopRecording()
            phase = .evidenceReady
        } catch {
            fail(error)
        }
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

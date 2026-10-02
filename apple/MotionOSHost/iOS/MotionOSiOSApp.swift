import MotionOSAppleCapture
import SwiftUI
import UIKit

@main
struct MotionOSiOSApp: App {
    @StateObject private var coordinator = PhoneSessionCoordinator()
    @StateObject private var podController = EquipmentPodController()
    @StateObject private var cameraController = CameraCaptureController()
    @StateObject private var fieldRun = FieldRunCoordinator()
    @StateObject private var guidedP0 = GuidedP0Controller()
    @StateObject private var indoBoardSession =
        IndoBoardSessionCoordinator()
    @StateObject private var runLibrary = ProductRunLibrary()

    var body: some Scene {
        WindowGroup {
            PhoneContentView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.inbox)
                .environmentObject(podController)
                .environmentObject(cameraController)
                .environmentObject(fieldRun)
                .environmentObject(guidedP0)
                .environmentObject(indoBoardSession)
                .environmentObject(runLibrary)
                .task {
                    coordinator.inbox.refreshCatalog()
                    runLibrary.refresh()
                }
                .task {
                    while !Task.isCancelled {
                        publishIndoRemoteStatus()
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
                .onChange(
                    of: coordinator.latestIndoRemoteCommand?.requestID
                ) { _, _ in
                    guard let command =
                            coordinator.latestIndoRemoteCommand
                    else {
                        return
                    }
                    Task {
                        await handleIndoRemoteCommand(command)
                    }
                }
                .onReceive(
                    coordinator.inbox.$latestSessionID
                ) { _ in
                    runLibrary.refresh()
                }
                .onChange(
                    of: indoBoardSession.phase
                ) { _, phase in
                    if phase == .sealed {
                        runLibrary.refresh()
                    }
                }
        }
    }

    private func publishIndoRemoteStatus(
        force: Bool = false
    ) {
        _ = coordinator.publishIndoRemoteStatus(
            makeIndoRemoteStatus(),
            force: force
        )
    }

    private func makeIndoRemoteStatus() -> IndoBoardRemoteStatus {
        let framing = cameraController.framingAssessment
        let stance = cameraController.stanceAssessment
        let battery = coordinator.iPhoneBatteryLevel.map {
            (Double(Int(($0 * 100).rounded())) / 100.0)
        }
        let storageGB = coordinator.iPhoneAvailableStorageBytes.map {
            let value = Double($0) / 1_000_000_000.0
            return (value * 10).rounded() / 10.0
        }

        return IndoBoardRemoteStatus(
            cameraPhase: cameraController.phase.rawValue,
            framingState: framing.state.rawValue,
            framingScore: framing.score,
            framingTitle: framing.title,
            framingInstruction: framing.instruction,
            stanceState: stance.state.rawValue,
            stanceProgressPercent:
                Int((stance.progress * 100).rounded()),
            stanceTitle: stance.title,
            sessionPhase: indoBoardSession.phase.rawValue,
            sessionInstruction:
                indoBoardSession.phase == .running
                    ? indoBoardSession.currentInstruction
                    : nil,
            countdownRemaining: indoBoardSession.countdownRemaining,
            startReady: indoRemoteStartBlocker() == nil,
            startBlocker: indoRemoteStartBlocker(),
            phoneBatteryFraction: battery,
            phoneStorageGB: storageGB
        )
    }

    private func indoRemoteStartBlocker() -> String? {
        if !coordinator.watchReachable {
            return "Keep MotionOS open on the iPhone."
        }
        if !indoBoardSession.watchWorkoutAccessReady(coordinator) {
            return "Enable Health access on the Watch."
        }

        switch cameraController.phase {
        case .idle:
            return "Start camera setup from the Watch."
        case .authorizing:
            return "Allow camera access on the iPhone."
        case .denied:
            return "Camera access is disabled on the iPhone."
        case .failed:
            return cameraController.errorMessage
                ?? "The iPhone camera needs attention."
        case .recording, .finalizing:
            return "A camera recording is already active."
        case .evidenceReady:
            return "Prepare the camera for the next session."
        case .ready:
            break
        }

        if !indoBoardSession.cameraProfileReady(cameraController) {
            return "The camera capture profile is not ready."
        }

        if cameraController.framingAssessment.state != .ready {
            return cameraController.framingAssessment.instruction
        }

        if cameraController.stanceAssessment.state != .stable {
            return cameraController.stanceAssessment.instruction
        }

        if let battery = coordinator.iPhoneBatteryLevel,
           battery < 0.20 {
            return "Charge the iPhone above 20%."
        }

        if let storage = coordinator.iPhoneAvailableStorageBytes,
           storage < 5_000_000_000 {
            return "Free at least 5 GB on the iPhone."
        }

        switch indoBoardSession.phase {
        case .starting:
            return "The session is starting."
        case .countdown:
            return "Countdown in progress."
        case .running:
            return "The session is already recording."
        case .finishing, .watchStopRequired:
            return "Finish the current session first."
        case .preparing:
            return "MotionOS is checking the setup."
        case .failed:
            return indoBoardSession.errorMessage
                ?? "The previous setup attempt needs attention."
        case .idle, .ready, .sealed:
            return nil
        }
    }

    private func handleIndoRemoteCommand(
        _ command: IndoBoardRemoteCommand
    ) async {
        switch command.action {
        case .refreshStatus:
            publishIndoRemoteStatus(force: true)
            _ = coordinator.acknowledgeIndoRemoteCommand(
                command,
                accepted: true
            )

        case .prepareCamera:
            guard cameraController.phase != .recording,
                  cameraController.phase != .finalizing
            else {
                _ = coordinator.acknowledgeIndoRemoteCommand(
                    command,
                    accepted: false,
                    message: "A camera recording is already active."
                )
                return
            }

            if indoBoardSession.phase == .sealed
                || indoBoardSession.phase == .failed {
                indoBoardSession.reset()
            }
            await cameraController.prepare()
            if cameraController.phase == .ready {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            let accepted = cameraController.phase == .ready
            _ = coordinator.acknowledgeIndoRemoteCommand(
                command,
                accepted: accepted,
                message: accepted
                    ? "Camera preview is live."
                    : cameraController.errorMessage
            )
            publishIndoRemoteStatus(force: true)

        case .startSession:
            if let blocker = indoRemoteStartBlocker() {
                _ = coordinator.acknowledgeIndoRemoteCommand(
                    command,
                    accepted: false,
                    message: blocker
                )
                publishIndoRemoteStatus(force: true)
                return
            }

            await indoBoardSession.prepare(
                phone: coordinator,
                camera: cameraController
            )
            guard indoBoardSession.phase == .ready else {
                _ = coordinator.acknowledgeIndoRemoteCommand(
                    command,
                    accepted: false,
                    message: indoBoardSession.errorMessage
                        ?? "MotionOS could not arm the session."
                )
                publishIndoRemoteStatus(force: true)
                return
            }

            await indoBoardSession.start(
                phone: coordinator,
                camera: cameraController,
                fieldRun: fieldRun,
                pod: podController
            )
            let accepted =
                indoBoardSession.phase == .running
                    || indoBoardSession.phase == .countdown
                    || indoBoardSession.phase == .starting
            _ = coordinator.acknowledgeIndoRemoteCommand(
                command,
                accepted: accepted,
                message: accepted
                    ? "Indo Board capture started."
                    : indoBoardSession.errorMessage
            )
            publishIndoRemoteStatus(force: true)

        case .finishSession:
            guard indoBoardSession.phase == .running
                    || indoBoardSession.phase == .countdown
            else {
                _ = coordinator.acknowledgeIndoRemoteCommand(
                    command,
                    accepted: false,
                    message: "No Indo Board session is recording."
                )
                publishIndoRemoteStatus(force: true)
                return
            }

            await indoBoardSession.finish(
                phone: coordinator,
                camera: cameraController,
                fieldRun: fieldRun,
                pod: podController
            )
            let accepted =
                indoBoardSession.phase == .sealed
                    || indoBoardSession.phase == .watchStopRequired
            _ = coordinator.acknowledgeIndoRemoteCommand(
                command,
                accepted: accepted,
                message: accepted
                    ? "Capture finished and evidence is being sealed."
                    : indoBoardSession.errorMessage
            )
            publishIndoRemoteStatus(force: true)

        case .resetSession:
            guard indoBoardSession.phase != .running,
                  indoBoardSession.phase != .countdown,
                  indoBoardSession.phase != .starting,
                  indoBoardSession.phase != .finishing,
                  indoBoardSession.phase != .watchStopRequired
            else {
                _ = coordinator.acknowledgeIndoRemoteCommand(
                    command,
                    accepted: false,
                    message: "Finish the current session first."
                )
                return
            }

            indoBoardSession.reset()
            await cameraController.prepare()
            UIApplication.shared.isIdleTimerDisabled =
                cameraController.phase == .ready
            _ = coordinator.acknowledgeIndoRemoteCommand(
                command,
                accepted: cameraController.phase == .ready,
                message: cameraController.phase == .ready
                    ? "Ready to set up the next session."
                    : cameraController.errorMessage
            )
            publishIndoRemoteStatus(force: true)
        }
    }
}

import SwiftUI

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
    @StateObject private var fitnessPersona =
        FitnessPersonaCoordinator()
    @StateObject private var healthData =
        HealthDataCoordinator()

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
                .environmentObject(fitnessPersona)
                .environmentObject(healthData)
                .task {
                    coordinator.inbox.refreshCatalog()
                    runLibrary.refresh()
                }
                .onReceive(
                    coordinator.inbox.$latestSessionID
                ) { _ in
                    runLibrary.refresh()
                }
                .onReceive(runLibrary.$runs) { runs in
                    fitnessPersona.rebuild(from: runs)
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
}

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
    @StateObject private var bodyModels =
        PersonalBodyModelCoordinator()
    @StateObject private var bodyCalibration =
        GuidedBodyCalibrationCoordinator()
    @StateObject private var personaEvidence =
        PersonaEvidenceLibrary()
    @StateObject private var powerChallenge =
        PowerChallengeCoordinator()
    @StateObject private var mobilityChallenge =
        MobilityChallengeCoordinator()
    @StateObject private var ghostComparison =
        GhostComparisonCoordinator()

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
                .environmentObject(bodyModels)
                .environmentObject(bodyCalibration)
                .environmentObject(personaEvidence)
                .environmentObject(powerChallenge)
                .environmentObject(mobilityChallenge)
                .environmentObject(ghostComparison)
                .task {
                    coordinator.inbox.refreshCatalog()
                    runLibrary.refresh()
                    personaEvidence.refresh()
                }
                .onReceive(
                    coordinator.inbox.$latestSessionID
                ) { _ in
                    runLibrary.refresh()
                }
                .onReceive(runLibrary.$runs) { runs in
                    fitnessPersona.rebuild(
                        from: runs,
                        supplementalEvidence:
                            personaEvidence.evidence,
                        bodyModelVersion:
                            bodyModels.latestModel?.versionID
                    )
                }
                .onReceive(bodyModels.$latestModel) { model in
                    fitnessPersona.rebuild(
                        from: runLibrary.runs,
                        supplementalEvidence:
                            personaEvidence.evidence,
                        bodyModelVersion: model?.versionID
                    )
                }
                .onReceive(personaEvidence.$evidence) { evidence in
                    fitnessPersona.rebuild(
                        from: runLibrary.runs,
                        supplementalEvidence: evidence,
                        bodyModelVersion:
                            bodyModels.latestModel?.versionID
                    )
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

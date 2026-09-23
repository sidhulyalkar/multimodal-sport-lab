import SwiftUI

@main
struct MotionOSiOSApp: App {
    @StateObject private var coordinator = PhoneSessionCoordinator()
    @StateObject private var podController = EquipmentPodController()
    @StateObject private var cameraController = CameraCaptureController()
    @StateObject private var fieldRun = FieldRunCoordinator()
    @StateObject private var guidedP0 = GuidedP0Controller()

    var body: some Scene {
        WindowGroup {
            PhoneContentView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.inbox)
                .environmentObject(podController)
                .environmentObject(cameraController)
                .environmentObject(fieldRun)
                .environmentObject(guidedP0)
        }
    }
}

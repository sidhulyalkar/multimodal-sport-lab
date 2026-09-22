import SwiftUI

@main
struct MotionOSiOSApp: App {
    @StateObject private var coordinator = PhoneSessionCoordinator()
    @StateObject private var podController = EquipmentPodController()
    @StateObject private var cameraController = PhoneCameraController()

    var body: some Scene {
        WindowGroup {
            PhoneContentView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.inbox)
                .environmentObject(podController)
                .environmentObject(cameraController)
        }
    }
}

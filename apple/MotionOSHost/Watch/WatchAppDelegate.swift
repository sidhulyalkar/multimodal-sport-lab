import HealthKit
import WatchKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Task { @MainActor in
            WatchSessionController.shared.applicationDidBecomeActive()
        }
    }

    func applicationDidBecomeActive() {
        Task { @MainActor in
            WatchSessionController.shared.applicationDidBecomeActive()
        }
    }

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in
            await WatchSessionController.shared.start(
                configuration: workoutConfiguration
            )
        }
    }
}

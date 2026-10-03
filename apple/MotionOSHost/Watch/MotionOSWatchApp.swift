import SwiftUI
import WatchKit

@main
struct MotionOSWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @WKApplicationDelegateAdaptor var appDelegate: WatchAppDelegate
    @StateObject private var controller = WatchSessionController.shared

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(controller)
                .task {
                    controller.applicationDidBecomeActive()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    controller.applicationDidBecomeActive()
                }
        }
    }
}

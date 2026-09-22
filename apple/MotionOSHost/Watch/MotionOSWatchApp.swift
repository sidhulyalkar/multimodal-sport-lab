import SwiftUI
import WatchKit

@main
struct MotionOSWatchApp: App {
    @WKApplicationDelegateAdaptor var appDelegate: WatchAppDelegate
    @StateObject private var controller = WatchSessionController.shared

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(controller)
        }
    }
}

import SwiftUI

struct PhoneContentView: View {
    @State private var selectedTab: MotionOSTab = .observe

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ObserveHomeView(
                    selectedTab: $selectedTab
                )
            }
            .tag(MotionOSTab.observe)
            .tabItem {
                Label(
                    "Observe",
                    systemImage: "waveform.path.ecg"
                )
            }

            NavigationStack {
                CaptureHomeView()
            }
            .tag(MotionOSTab.capture)
            .tabItem {
                Label(
                    "Capture",
                    systemImage: "record.circle"
                )
            }

            NavigationStack {
                BodyIntelligenceView()
            }
            .tag(MotionOSTab.body)
            .tabItem {
                Label(
                    "Body",
                    systemImage: "figure.stand"
                )
            }

            NavigationStack {
                SessionLibraryView()
            }
            .tag(MotionOSTab.sessions)
            .tabItem {
                Label(
                    "Sessions",
                    systemImage: "clock.arrow.circlepath"
                )
            }

            NavigationStack {
                DeviceHubView()
            }
            .tag(MotionOSTab.devices)
            .tabItem {
                Label(
                    "Devices",
                    systemImage: "sensor.tag.radiowaves.forward"
                )
            }
        }
        .tint(.indigo)
    }
}

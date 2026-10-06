import SwiftUI

struct PhoneContentView: View {
    @AppStorage("motionos.first-run.completed.v1")
    private var firstRunCompleted = false

    @State private var selectedTab: MotionOSTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ObserveHomeView(
                    selectedTab: $selectedTab
                )
            }
            .tag(MotionOSTab.home)
            .tabItem {
                Label(
                    "Home",
                    systemImage: "house.fill"
                )
            }

            NavigationStack {
                CaptureHomeView()
            }
            .tag(MotionOSTab.record)
            .tabItem {
                Label(
                    "Record",
                    systemImage: "record.circle"
                )
            }

            NavigationStack {
                ProgressHomeView(
                    selectedTab: $selectedTab
                )
            }
            .tag(MotionOSTab.progress)
            .tabItem {
                Label(
                    "Progress",
                    systemImage: "chart.line.uptrend.xyaxis"
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
        }
        .tint(.indigo)
        .fullScreenCover(
            isPresented: Binding(
                get: { !firstRunCompleted },
                set: { presented in
                    if !presented {
                        firstRunCompleted = true
                    }
                }
            )
        ) {
            MotionOSFirstRunView {
                firstRunCompleted = true
            }
        }
    }
}

import SwiftUI

enum MotionOSTab: Hashable {
    case home
    case record
    case progress
    case sessions
}

struct ObserveHomeView: View {
    @Binding var selectedTab: MotionOSTab

    @EnvironmentObject private var phone: PhoneSessionCoordinator
    @EnvironmentObject private var inbox: PhoneJournalInbox
    @EnvironmentObject private var indoBoard: IndoBoardSessionCoordinator
    @EnvironmentObject private var profiles: AthleteProfileStore

    @State private var showDevices = false
    @State private var showProfiles = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                header

                LiveObservatoryView(
                    style: .hero,
                    onStartCapture: { selectedTab = .record },
                    onOpenDevices: { showDevices = true }
                )

                if profiles.profiles.count > 1 {
                    activeProfileCard
                }

                if indoBoardActive {
                    activeProductSession
                } else if profiles.profiles.count == 1
                    && inbox.latestSessionID != nil
                    && !phone.observation().observatory.isRecordingActive {
                    SessionLensCard()
                }
            }
            .motionOSPageWidth()
            .padding(
                .horizontal,
                MotionOSDesign.pageHorizontalPadding
            )
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .background {
            MotionOSPageBackground()
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showDevices) {
            DeviceHubView()
        }
        .sheet(isPresented: $showProfiles) {
            AthleteProfileView()
                .environmentObject(profiles)
        }
        .refreshable {
            phone.refreshWatchState()
            phone.refreshHostReadiness()
            inbox.refreshCatalog()
        }
        .task {
            phone.refreshWatchState()
            phone.refreshHostReadiness()
            inbox.refreshCatalog()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            MotionOSMark(size: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("MotionOS")
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text("Your movement, over time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                showDevices = true
            } label: {
                Image(systemName: "sensor.tag.radiowaves.forward")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(
                        Color.primary.opacity(0.05),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Devices and setup")

            MotionOSStatusPill(
                title: phone.watchStatus.title,
                tint: phone.watchStatus.tint
            )
        }
        .padding(.horizontal, 2)
    }

    private var activeProfileCard: some View {
        Button {
            showProfiles = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.indigo)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Active profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(profiles.activeProfile.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                Spacer()

                Text("Switch")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(indoBoardActive)
        .cardStyle()
        .accessibilityHint(
            indoBoardActive
                ? "Finish the active session before switching profiles"
                : "Switch who new sessions belong to"
        )
    }

    private var indoBoardActive: Bool {
        indoBoard.phase == .starting
            || indoBoard.phase == .running
            || indoBoard.phase == .finishing
    }

    private var activeProductSession: some View {
        Button {
            selectedTab = .record
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "figure.surfing")
                    .font(.title3)
                    .foregroundStyle(.indigo)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Indo Board session")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(indoBoard.currentInstruction)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Text("OPEN")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.indigo)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
        .accessibilityHint("Opens the active recording")
    }
}

struct CaptureHomeView: View {
    @EnvironmentObject private var phone: PhoneSessionCoordinator
    @EnvironmentObject private var camera: CameraCaptureController
    @EnvironmentObject private var pod: EquipmentPodController
    @EnvironmentObject private var indoBoard: IndoBoardSessionCoordinator

    @State private var showAdvanced = false

    private let activity = MotionOSActivityCatalog.indoBoard

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                activityIntro
                primaryWorkflow
                advancedTools
            }
            .motionOSPageWidth()
            .padding(
                .horizontal,
                MotionOSDesign.pageHorizontalPadding
            )
            .padding(.top, 4)
            .padding(.bottom, 36)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Record")
        .navigationBarTitleDisplayMode(.large)
    }

    private var activityIntro: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Choose an activity")
                .font(.headline)

            Text(
                "MotionOS guides the setup for each supported activity and "
                    + "only asks for the devices it needs."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primaryWorkflow: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(
                        cornerRadius: 16,
                        style: .continuous
                    )
                    .fill(
                        LinearGradient(
                            colors: [
                                activity.accent,
                                .cyan,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 58, height: 58)

                    Image(systemName: activity.systemImage)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(activity.title)
                            .font(.title2.weight(.bold))

                        Text("AVAILABLE")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Color.green.opacity(0.1),
                                in: Capsule()
                            )
                    }

                    Text(activity.subtitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text(
                        "(activity.sessionSummary) · "
                            + activity.requirementSummary
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            NavigationLink {
                IndoBoardSessionView()
            } label: {
                Label(
                    indoBoardInProgress
                        ? "Resume Session"
                        : "Get Ready",
                    systemImage: indoBoardInProgress
                        ? "record.circle.fill"
                        : "arrow.right.circle.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(indoBoardInProgress ? .red : activity.accent)
        }
        .cardStyle()
    }

    private var indoBoardInProgress: Bool {
        switch indoBoard.phase {
        case .starting, .running, .finishing, .watchStopRequired:
            true
        default:
            false
        }
    }

    private var advancedTools: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(spacing: 0) {
                NavigationLink {
                    WatchCaptureToolsView()
                } label: {
                    toolRow(
                        title: "Apple Watch details",
                        subtitle: phone.watchStatus.title,
                        symbol: "applewatch",
                        tint: phone.watchStatus.tint
                    )
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 44)

                NavigationLink {
                    CameraCaptureCard()
                } label: {
                    toolRow(
                        title: "iPhone camera details",
                        subtitle: camera.phase.rawValue.capitalized,
                        symbol: "camera.fill",
                        tint: .secondary
                    )
                }
                .buttonStyle(.plain)

                if pod.backendAvailable {
                    Divider().padding(.leading, 44)

                    NavigationLink {
                        EquipmentPodCard()
                    } label: {
                        toolRow(
                            title: "Equipment sensor",
                            subtitle: pod.phase.rawValue.capitalized,
                            symbol: "sensor.tag.radiowaves.forward",
                            tint: .secondary
                        )
                    }
                    .buttonStyle(.plain)
                }

                Divider().padding(.leading, 44)

                NavigationLink {
                    DeviceHubView()
                } label: {
                    toolRow(
                        title: "All devices & diagnostics",
                        subtitle: "Connections, storage, and technical checks",
                        symbol: "gearshape.2",
                        tint: .secondary
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
        } label: {
            Label(
                "Advanced setup",
                systemImage: "slider.horizontal.3"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minHeight: 44, alignment: .leading)
        }
        .tint(.secondary)
        .cardStyle()
    }

    private func toolRow(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(
                    tint == .secondary
                        ? Color.secondary
                        : tint
                )
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

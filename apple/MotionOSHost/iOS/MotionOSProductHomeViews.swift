import SwiftUI

enum MotionOSTab: Hashable {
    case observe
    case capture
    case sessions
    case devices
}

struct ObserveHomeView: View {
    @Binding var selectedTab: MotionOSTab

    @EnvironmentObject private var phone: PhoneSessionCoordinator
    @EnvironmentObject private var inbox: PhoneJournalInbox
    @EnvironmentObject private var indoBoard: IndoBoardSessionCoordinator

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                header

                LiveObservatoryView(
                    style: .hero,
                    onStartCapture: { selectedTab = .capture },
                    onOpenDevices: { selectedTab = .devices }
                )

                if indoBoardActive {
                    activeProductSession
                } else if inbox.latestSessionID != nil
                    && !phone.observation().observatory.isRecordingActive {
                    SessionLensCard()
                }
            }
            .motionOSPageWidth()
            .padding(.horizontal, MotionOSDesign.pageHorizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .background {
            MotionOSPageBackground()
        }
        .toolbar(.hidden, for: .navigationBar)
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

    /// The page title and the one primary Watch status.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            MotionOSMark(size: 34)
                .accessibilityHidden(true)
            Text("MotionOS")
                .font(.largeTitle.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            MotionOSStatusPill(
                title: phone.watchStatus.title,
                tint: phone.watchStatus.tint
            )
        }
        .padding(.horizontal, 2)
    }

    private var indoBoardActive: Bool {
        indoBoard.phase == .starting
            || indoBoard.phase == .running
            || indoBoard.phase == .finishing
    }

    private var activeProductSession: some View {
        Button {
            selectedTab = .capture
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
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
        .accessibilityHint("Opens the capture workspace")
    }
}

struct CaptureHomeView: View {
    @EnvironmentObject private var phone: PhoneSessionCoordinator
    @EnvironmentObject private var camera: CameraCaptureController
    @EnvironmentObject private var pod: EquipmentPodController
    @EnvironmentObject private var indoBoard: IndoBoardSessionCoordinator

    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                primaryWorkflow
                advancedTools
            }
            .motionOSPageWidth()
            .padding(.horizontal, MotionOSDesign.pageHorizontalPadding)
            .padding(.top, 4)
            .padding(.bottom, 36)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.large)
    }

    private var primaryWorkflow: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.indigo, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 56, height: 56)
                    Image(systemName: "figure.surfing")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Indo Board")
                        .font(.title2.weight(.bold))
                    Text("2-minute balance session · Watch + iPhone video")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            NavigationLink {
                IndoBoardSessionView()
            } label: {
                Label(
                    indoBoardInProgress ? "Open Session" : "Set Up Session",
                    systemImage: indoBoardInProgress
                        ? "record.circle.fill"
                        : "arrow.right.circle.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(indoBoardInProgress ? .red : .indigo)
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
                        title: "Apple Watch capture & qualification",
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
                        title: "iPhone camera evidence",
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
                            title: "Equipment pod",
                            subtitle: pod.phase.rawValue.capitalized,
                            symbol: "sensor.tag.radiowaves.forward",
                            tint: .secondary
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 10)
        } label: {
            Label("Advanced", systemImage: "wrench.and.screwdriver")
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
                .foregroundStyle(tint == .secondary ? Color.secondary : tint)
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

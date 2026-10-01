import SwiftUI

enum MotionOSTab: Hashable {
    case observe
    case capture
    case body
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
                SensorSourceStrip()
                LiveTelemetryDeck()
                captureShortcut

                if inbox.latestSessionID != nil {
                    SessionLensCard()
                }

                philosophy
            }
            .motionOSPageWidth()
            .padding(.horizontal, MotionOSDesign.pageHorizontalPadding)
            .padding(.top, 10)
            .padding(.bottom, 36)
        }
        .background {
            MotionOSPageBackground()
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
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                MotionOSMark(size: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text("MotionOS")
                        .font(.title2.weight(.bold))
                    Text("MOVEMENT OBSERVATORY")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    phone.refreshWatchState()
                    phone.refreshHostReadiness()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(
                            .ultraThinMaterial,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh MotionOS status")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("See the body in motion.")
                    .font(
                        .system(
                            .largeTitle,
                            design: .rounded,
                            weight: .bold
                        )
                    )
                    .minimumScaleFactor(0.82)

                Text(
                    "Live signal quality, movement telemetry, and sealed "
                        + "evidence in one view."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    MotionOSStatusBadge(
                        title: watchLabel,
                        systemImage: "applewatch",
                        color: watchColor
                    )
                    MotionOSStatusBadge(
                        title: phone.state.rawValue.capitalized,
                        systemImage: stateSymbol,
                        color: stateColor
                    )
                    if let latest = inbox.sessions.first {
                        MotionOSStatusBadge(
                            title: latest.summary == nil
                                ? "Evidence saved"
                                : "Session ready",
                            systemImage: "checkmark.seal",
                            color: .green
                        )
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    MotionOSStatusBadge(
                        title: watchLabel,
                        systemImage: "applewatch",
                        color: watchColor
                    )
                    MotionOSStatusBadge(
                        title: phone.state.rawValue.capitalized,
                        systemImage: stateSymbol,
                        color: stateColor
                    )
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private var captureShortcut: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Next measurement",
                subtitle: shortcutSubtitle,
                systemImage: "figure.surfing",
                accent: indoBoard.phase == .running
                    ? .red
                    : .indigo
            )

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Indo Board · M0")
                        .font(.headline)
                    Text(
                        indoBoard.phase == .running
                            ? "Session recording now"
                            : "Watch + iPhone video + protocol + sync cues"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    selectedTab = .capture
                } label: {
                    Label(
                        indoBoard.phase == .running
                            ? "Open"
                            : "Capture",
                        systemImage: "arrow.right.circle.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
            }

            if indoBoard.phase == .running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = indoBoard.startedAt.map {
                        context.date.timeIntervalSince($0)
                    } ?? 0
                    ProgressView(
                        value: min(
                            1,
                            elapsed
                                / IndoBoardSessionCoordinator
                                    .targetDurationSeconds
                        )
                    )
                    .tint(.red)
                }
            }
        }
        .cardStyle()
    }

    private var philosophy: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 3) {
                Text("Evidence first")
                    .font(.subheadline.weight(.semibold))
                Text(
                    "The beautiful layer is a view over preserved evidence. "
                        + "MotionOS keeps raw sensor journals and native clocks "
                        + "authoritative underneath every graph."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var shortcutSubtitle: String {
        switch indoBoard.phase {
        case .idle:
            "Run the complete intended product workflow"
        case .preparing:
            "Checking devices"
        case .ready:
            "Preflight complete"
        case .starting:
            "Starting sources"
        case .running:
            indoBoard.currentInstruction
        case .finishing:
            "Sealing the current session"
        case .watchStopRequired:
            "Stop the Watch to close its journal"
        case .sealed:
            "Latest session is sealed"
        case .failed:
            "Review capture issue"
        }
    }

    private var watchLabel: String {
        if phone.watchReachable {
            return "Watch live"
        }
        if phone.hasRecentWatchPresence() {
            return "Watch handshake"
        }
        if phone.watchAppInstalled {
            return "Watch installed"
        }
        return "Watch offline"
    }

    private var watchColor: Color {
        phone.watchAppInstalled ? .green : .yellow
    }

    private var stateSymbol: String {
        switch phone.state {
        case .running:
            "record.circle.fill"
        case .paused:
            "pause.circle.fill"
        case .failed, .disconnected:
            "exclamationmark.triangle.fill"
        case .launchingWatch, .waitingForMirror, .authorizing:
            "clock.fill"
        default:
            "circle.fill"
        }
    }

    private var stateColor: Color {
        switch phone.state {
        case .running:
            .green
        case .paused, .launchingWatch, .waitingForMirror, .authorizing:
            .yellow
        case .failed, .disconnected:
            .red
        default:
            .secondary
        }
    }
}

struct CaptureHomeView: View {
    @EnvironmentObject private var phone: PhoneSessionCoordinator
    @EnvironmentObject private var camera: CameraCaptureController
    @EnvironmentObject private var pod: EquipmentPodController
    @EnvironmentObject private var indoBoard: IndoBoardSessionCoordinator

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                header
                primaryWorkflow
                secondaryWorkflows
                capturePrinciples
            }
            .motionOSPageWidth()
            .padding(.horizontal, MotionOSDesign.pageHorizontalPadding)
            .padding(.top, 10)
            .padding(.bottom, 36)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Capture")
                .font(.largeTitle.weight(.bold))
            Text(
                "Choose the movement experiment. MotionOS handles the sensor "
                    + "orchestration and keeps every source auditable."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    private var primaryWorkflow: some View {
        NavigationLink {
            IndoBoardSessionView()
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(
                            cornerRadius: 18,
                            style: .continuous
                        )
                        .fill(
                            LinearGradient(
                                colors: [.indigo, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 62, height: 62)

                        Image(systemName: "figure.surfing")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Indo Board")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)
                        Text("Complete M0 session")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 6)

                    MotionOSStatusBadge(
                        title: indoBoard.phase.rawValue.uppercased(),
                        systemImage: indoBoard.phase == .running
                            ? "record.circle.fill"
                            : "arrow.right",
                        color: indoBoard.phase == .running
                            ? .red
                            : .indigo
                    )
                }

                Text(
                    "Two-minute structured balance capture with Apple Watch, "
                        + "iPhone video, operator protocol evidence, and "
                        + "Watch-journaled synchronization cues."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 7) {
                    feature("Watch", "applewatch")
                    feature("Vision", "video.fill")
                    feature("Sync", "waveform.path")
                    feature("2:00", "timer")
                }

                HStack {
                    Label(
                        "Open capture workspace",
                        systemImage: "record.circle"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.indigo)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    private var secondaryWorkflows: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Calibration & tools",
                subtitle: "Focused workflows for qualifying individual sensors",
                systemImage: "wrench.and.screwdriver",
                accent: .cyan
            )

            NavigationLink {
                WatchCaptureToolsView()
            } label: {
                workflowRow(
                    title: "Apple Watch",
                    subtitle: watchSubtitle,
                    symbol: "applewatch.radiowaves.left.and.right",
                    color: phone.watchAppInstalled ? .green : .yellow
                )
            }
            .buttonStyle(.plain)

            Divider()

            NavigationLink {
                CameraCaptureCard()
            } label: {
                workflowRow(
                    title: "Camera",
                    subtitle: camera.phase.rawValue.capitalized,
                    symbol: "camera.fill",
                    color: cameraColor
                )
            }
            .buttonStyle(.plain)

            Divider()

            NavigationLink {
                EquipmentPodCard()
            } label: {
                workflowRow(
                    title: "Equipment pod",
                    subtitle: pod.phase.rawValue.capitalized,
                    symbol: "sensor.tag.radiowaves.forward",
                    color: podColor
                )
            }
            .buttonStyle(.plain)
        }
        .cardStyle()
    }

    private var capturePrinciples: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "What production means here",
                systemImage: "checkmark.shield"
            )
            .font(.headline)

            Text(
                "Capture workflows should make the intended task obvious, "
                    + "show readiness before recording, surface live quality "
                    + "without fabricating certainty, and finish by sealing "
                    + "evidence rather than merely stopping a UI animation."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func feature(
        _ title: String,
        _ symbol: String
    ) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Color.primary.opacity(0.045),
                in: Capsule()
            )
    }

    private func workflowRow(
        title: String,
        subtitle: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.10))
                    .frame(width: 38, height: 38)
                Image(systemName: symbol)
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var watchSubtitle: String {
        if phone.watchReachable {
            return "Live link · capture ready"
        }
        if phone.watchAppInstalled {
            return "Installed · open Watch for live link"
        }
        return "Needs companion setup"
    }

    private var cameraColor: Color {
        switch camera.phase {
        case .ready, .evidenceReady:
            .green
        case .recording:
            .red
        case .authorizing, .finalizing:
            .yellow
        case .denied, .failed:
            .red
        case .idle:
            .secondary
        }
    }

    private var podColor: Color {
        switch pod.phase {
        case .ready, .evidenceReady:
            .green
        case .previewing, .recording:
            .cyan
        case .scanning, .connecting, .recovering, .downloading:
            .yellow
        case .linkLost, .failed:
            .red
        case .idle:
            .secondary
        }
    }
}

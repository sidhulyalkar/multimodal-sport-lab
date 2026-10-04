import MotionOSAppleCapture
import SwiftUI

/// Devices: one row per device, one status, one actionable description.
/// Pairing, reachability, builds, and transfer counters live in each
/// device's Advanced details.
struct DeviceHubView: View {
    @EnvironmentObject private var phone: PhoneSessionCoordinator
    @EnvironmentObject private var pod: EquipmentPodController
    @EnvironmentObject private var camera: CameraCaptureController
    @EnvironmentObject private var indoBoard: IndoBoardSessionCoordinator

    var body: some View {
        List {
            Section("Core") {
                NavigationLink {
                    WatchDeviceDetailView()
                } label: {
                    DeviceRow(
                        title: "Apple Watch",
                        detail: watchDetail,
                        symbol: "applewatch",
                        status: phone.watchStatus.badge,
                        tint: phone.watchStatus.tint
                    )
                }

                NavigationLink {
                    PhoneDeviceDetailView()
                } label: {
                    DeviceRow(
                        title: "iPhone",
                        detail: phoneDetail,
                        symbol: "iphone",
                        status: phoneReady ? "READY" : "CHECK",
                        tint: phoneReady ? .green : .orange
                    )
                }
            }

            Section("Qualification") {
                NavigationLink {
                    SystemsLabView()
                } label: {
                    DeviceRow(
                        title: "Systems Lab",
                        detail: "Sensing, preview, power, and transfer evidence",
                        symbol: "waveform.path.ecg.rectangle",
                        status: qualificationStatus,
                        tint: qualificationTint
                    )
                }
            }

            Section("Optional sources") {
                NavigationLink {
                    CameraDeviceDetailView()
                } label: {
                    DeviceRow(
                        title: "iPhone Camera",
                        detail: cameraStatus.detail,
                        symbol: "camera.fill",
                        status: cameraStatus.badge,
                        tint: cameraStatus.tint
                    )
                }

                NavigationLink {
                    ExternalCameraDetailView()
                } label: {
                    DeviceRow(
                        title: "External Camera",
                        detail: "DJI Osmo Action 4 · start manually, import after",
                        symbol: "video.fill",
                        status: indoBoard.externalCameraConfirmed
                            ? "ENABLED"
                            : "OPTIONAL",
                        tint: indoBoard.externalCameraConfirmed
                            ? .green
                            : .secondary
                    )
                }

                NavigationLink {
                    PodDeviceDetailView()
                } label: {
                    DeviceRow(
                        title: "Equipment Pod",
                        detail: podStatus.detail,
                        symbol: "sensor.tag.radiowaves.forward",
                        status: podStatus.badge,
                        tint: podStatus.tint
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            phone.refreshWatchState()
            phone.refreshHostReadiness()
        }
        .task {
            phone.refreshWatchState()
            phone.refreshHostReadiness()
        }
    }

    private var watchDetail: String {
        if phone.watchStatus == .ready && !phone.watchTwoWayLinkVerified {
            return "MotionOS detected on Apple Watch"
        }
        return phone.watchStatus.detail
    }

    private var phoneReady: Bool {
        (phone.iPhoneBatteryLevel ?? 1) >= 0.20
            && (phone.iPhoneAvailableStorageBytes ?? .max) >= 5_000_000_000
    }

    private var phoneDetail: String {
        if let battery = phone.iPhoneBatteryLevel, battery < 0.20 {
            return String(format: "Battery %.0f%% · charge before capture", battery * 100)
        }
        if let free = phone.iPhoneAvailableStorageBytes, free < 5_000_000_000 {
            return "Low storage · free space before capture"
        }
        return "Coordinates capture and stores sessions"
    }

    private var qualificationStatus: String {
        if let report = phone.systemsLabCurrentReport,
           report.endedAt == nil {
            return "RUNNING"
        }
        if phone.systemsLabLatestCompletedReport?.journalReceivedAt != nil {
            return "VERIFIED"
        }
        if phone.systemsLabLatestCompletedReport != nil {
            return "SAVED"
        }
        return "READY"
    }

    private var qualificationTint: Color {
        switch qualificationStatus {
        case "RUNNING":
            return .green
        case "VERIFIED":
            return .blue
        default:
            return .secondary
        }
    }

    private var cameraStatus: DeviceStatus {
        DeviceStatus.camera(camera.phase)
    }

    private var podStatus: DeviceStatus {
        DeviceStatus.pod(pod.phase)
    }
}

struct DeviceStatus {
    let badge: String
    let detail: String
    let tint: Color

    static func camera(_ phase: CameraCaptureController.Phase) -> DeviceStatus {
        switch phase {
        case .idle:
            DeviceStatus(badge: "OFF", detail: "Prepared automatically for a session", tint: .secondary)
        case .authorizing:
            DeviceStatus(badge: "CHECKING", detail: "Requesting camera access", tint: .secondary)
        case .ready, .evidenceReady:
            DeviceStatus(badge: "READY", detail: "Video, frame timing, and pose", tint: .green)
        case .recording:
            DeviceStatus(badge: "RECORDING", detail: "Recording video evidence", tint: .red)
        case .finalizing:
            DeviceStatus(badge: "SAVING", detail: "Sealing the video", tint: .secondary)
        case .denied:
            DeviceStatus(badge: "NEEDS PERMISSION", detail: "Allow camera access in Settings", tint: .orange)
        case .failed:
            DeviceStatus(badge: "ISSUE", detail: "Open details to retry the camera", tint: .orange)
        }
    }

    static func pod(_ phase: EquipmentPodController.Phase) -> DeviceStatus {
        switch phase {
        case .idle:
            DeviceStatus(badge: "NOT CONNECTED", detail: "MetaMotionS board IMU", tint: .secondary)
        case .scanning, .connecting:
            DeviceStatus(badge: "CONNECTING", detail: "Looking for the pod", tint: .secondary)
        case .recovering, .downloading:
            DeviceStatus(badge: "SYNCING", detail: "Downloading pod data", tint: .secondary)
        case .ready, .previewing, .evidenceReady:
            DeviceStatus(badge: "READY", detail: "MetaMotionS board IMU", tint: .green)
        case .recording:
            DeviceStatus(badge: "RECORDING", detail: "Logging on the pod", tint: .red)
        case .linkLost:
            DeviceStatus(badge: "LINK LOST", detail: "The pod keeps logging; reconnect to sync", tint: .orange)
        case .failed:
            DeviceStatus(badge: "ISSUE", detail: "Open details to reconnect", tint: .orange)
        }
    }
}

private struct DeviceRow: View {
    let title: String
    let detail: String
    let symbol: String
    let status: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint == .secondary ? Color.secondary : tint)
                .frame(width: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Text(status)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint == .secondary ? Color.secondary : tint)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// A plain diagnostic key/value row for Advanced details.
struct DiagnosticRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Advanced details

private struct WatchDeviceDetailView: View {
    @EnvironmentObject private var phone: PhoneSessionCoordinator
    @EnvironmentObject private var inbox: PhoneJournalInbox

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let observation = phone.observation(at: context.date)
            List {
                Section {
                    LabeledContent("Status") {
                        MotionOSStatusPill(
                            title: observation.link.title,
                            tint: observation.link.tint
                        )
                    }
                    Text(observation.link.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Connection") {
                    DiagnosticRow(
                        "WCSession",
                        phone.watchConnectivityActivationState
                    )
                    if let error = phone.watchConnectivityActivationError {
                        DiagnosticRow("Activation error", error)
                    }
                    DiagnosticRow("System pairing", phone.watchPaired ? "paired" : "not paired")
                    DiagnosticRow(
                        "Watch app installed",
                        phone.systemWatchAppInstalled ? "yes" : "not reported"
                    )
                    DiagnosticRow("Live reachability", phone.watchReachable ? "reachable" : "not reachable")
                    DiagnosticRow("Two-way app check", phone.watchTwoWayLinkVerified ? "verified" : "pending")
                    DiagnosticRow(
                        "iPhone bundle",
                        Bundle.main.bundleIdentifier ?? "unknown"
                    )
                    DiagnosticRow(
                        "Last detected",
                        phone.watchPresence.map {
                            $0.receivedAt.formatted(date: .omitted, time: .standard)
                        } ?? "never"
                    )
                    DiagnosticRow("Mirrored workout", phone.state.rawValue)
                }

                if let presence = phone.watchPresence {
                    Section("Apple Watch") {
                        DiagnosticRow("watchOS", presence.watchSystemVersion)
                        DiagnosticRow("Watch bundle", presence.bundleID)
                        DiagnosticRow("MotionOS", "v\(presence.appVersion) · build \(presence.appBuild)")
                        DiagnosticRow("Health access", presence.healthAuthorization)
                        DiagnosticRow("Capture state", presence.captureState)
                        if let battery = presence.watchBatteryLevel {
                            DiagnosticRow("Battery", String(format: "%.0f%%", battery * 100))
                        }
                    }
                }

                Section("Live preview") {
                    let diagnostics = phone.liveTelemetry.diagnostics
                    DiagnosticRow("Observatory", observation.observatory.badge.lowercased())
                    DiagnosticRow("Packets shown", "\(diagnostics.appended)")
                    DiagnosticRow("Packets missed", "\(diagnostics.missingSequences)")
                    DiagnosticRow(
                        "Ignored",
                        "\(diagnostics.duplicates) dup · \(diagnostics.outOfOrder) late · "
                            + "\(diagnostics.retiredSessionPackets) old · \(diagnostics.invalidPackets) invalid"
                    )
                    if let frame = phone.liveTelemetry.latest {
                        DiagnosticRow(
                            "Last packet",
                            String(format: "%.1f s ago", max(0, context.date.timeIntervalSince(frame.receivedAt)))
                        )
                    }
                }

                Section("Transfers") {
                    DiagnosticRow("Watch sessions on iPhone", "\(inbox.sessions.count)")
                }

                Section {
                    Button {
                        phone.runWatchLinkCheck()
                    } label: {
                        Label("Check Watch Again", systemImage: "arrow.clockwise")
                    }
                } footer: {
                    Text("Live preview is lossy. Sealed Watch journals are transferred and verified separately.")
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
        .task { phone.refreshWatchState() }
    }
}

private struct PhoneDeviceDetailView: View {
    @EnvironmentObject private var phone: PhoneSessionCoordinator

    var body: some View {
        List {
            Section {
                DiagnosticRow(
                    "Battery",
                    phone.iPhoneBatteryLevel.map { String(format: "%.0f%%", $0 * 100) } ?? "unknown"
                )
                DiagnosticRow(
                    "Free storage",
                    phone.iPhoneAvailableStorageBytes.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? "unknown"
                )
                DiagnosticRow("Mirrored workout", phone.state.rawValue)
            } footer: {
                Text("Capture preflight asks for 20% battery and 5 GB free as operator margins, not qualification criteria.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .task { phone.refreshHostReadiness() }
    }
}

private struct CameraDeviceDetailView: View {
    @EnvironmentObject private var camera: CameraCaptureController

    var body: some View {
        List {
            Section {
                let status = DeviceStatus.camera(camera.phase)
                LabeledContent("Status") {
                    MotionOSStatusPill(title: status.badge.capitalized, tint: status.tint)
                }
            }

            if let config = camera.configuration {
                Section("Capture profile") {
                    DiagnosticRow("Camera", config.localizedName)
                    DiagnosticRow("Format", "\(config.formatWidth)×\(config.formatHeight)")
                    DiagnosticRow(
                        "Frame rate",
                        String(
                            format: "%.0f fps %@",
                            config.configuredFrameRate,
                            config.frameRateLocked ? "locked" : "unlocked"
                        )
                    )
                    DiagnosticRow(
                        "Stabilization",
                        config.stabilizationLockedOff ? "off" : config.preferredVideoStabilizationMode
                    )
                    DiagnosticRow("Intrinsics", config.intrinsicDeliveryEnabled ? "enabled" : "unavailable")
                }
            }

            Section {
                NavigationLink {
                    CameraCaptureCard()
                } label: {
                    Label("Camera Setup & Evidence", systemImage: "slider.horizontal.3")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("iPhone Camera")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ExternalCameraDetailView: View {
    @EnvironmentObject private var indoBoard: IndoBoardSessionCoordinator

    var body: some View {
        List {
            Section {
                DiagnosticRow("Model", "DJI Osmo Action 4")
                DiagnosticRow("Profile", "4K · 60 fps")
                DiagnosticRow("Stabilization", "EIS off")
                DiagnosticRow("Field of view", "Standard (Dewarp)")
                DiagnosticRow("Control", "DJI Mimo / Bluetooth remote")
                DiagnosticRow("Capture", "roll before mount · auto-trim later")
                DiagnosticRow("Sync", "3 shared Watch motion cues")
                DiagnosticRow(
                    "This session",
                    indoBoard.externalCameraConfirmed
                        ? "recording confirmed"
                        : (
                            indoBoard.requiresExternalCamera
                                ? "awaiting confirmation"
                                : "not used"
                        )
                )
            } footer: {
                Text(
                    "MotionOS does not claim a direct Action 4 control API. "
                        + "For reliable capture, start the camera before mounting "
                        + "or from DJI's Bluetooth remote, leave it rolling, and "
                        + "import the untouched movie after the run."
                )
            }

            Section("Placement") {
                DiagnosticRow("Tripod", "fixed for the entire run")
                DiagnosticRow("Rider", "head, hands, hips, knees, feet visible")
                DiagnosticRow("Equipment", "full deck + roller visible")
                DiagnosticRow("Second view", "45–90° offset from iPhone")
            } footer: {
                Text(
                    "The second view is teacher/calibration evidence. Exact "
                        + "camera extrinsics are estimated and verified after import; "
                        + "the app should never invent geometry from nominal placement."
                )
            }

            Section {
                NavigationLink {
                    IndoBoardSessionView()
                } label: {
                    Label("Open Capture Setup", systemImage: "scope")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("External Camera")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PodDeviceDetailView: View {
    @EnvironmentObject private var pod: EquipmentPodController

    var body: some View {
        List {
            Section {
                let status = DeviceStatus.pod(pod.phase)
                LabeledContent("Status") {
                    MotionOSStatusPill(title: status.badge.capitalized, tint: status.tint)
                }
            }

            if let metadata = pod.deviceMetadata {
                Section("Sensor") {
                    DiagnosticRow("Model", metadata.model)
                    DiagnosticRow("Firmware", metadata.firmwareRevision)
                    DiagnosticRow("Requested accel", String(format: "%.0f Hz", metadata.requestedAccelHz))
                    DiagnosticRow("Requested gyro", String(format: "%.0f Hz", metadata.requestedGyroHz))
                }
            }

            Section {
                NavigationLink {
                    EquipmentPodCard()
                } label: {
                    Label("Equipment Pod Setup", systemImage: "dot.radiowaves.left.and.right")
                }
            } footer: {
                Text("Optional for Watch + iPhone sessions.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Equipment Pod")
        .navigationBarTitleDisplayMode(.inline)
    }
}

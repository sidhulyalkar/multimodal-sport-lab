import SwiftUI

struct DeviceHubView: View {
    @EnvironmentObject private var phone: PhoneSessionCoordinator
    @EnvironmentObject private var pod: EquipmentPodController
    @EnvironmentObject private var camera: CameraCaptureController
    @EnvironmentObject private var indoBoard: IndoBoardSessionCoordinator

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                header
                watchCard
                phoneCard
                cameraCard
                action4Card
                podCard
                evidencePrinciple
            }
            .motionOSPageWidth()
            .padding(.horizontal, MotionOSDesign.pageHorizontalPadding)
            .padding(.top, 10)
            .padding(.bottom, 36)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            phone.refreshWatchState()
            phone.refreshHostReadiness()
        }
        .task {
            phone.refreshWatchState()
            phone.refreshHostReadiness()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Devices")
                .font(.largeTitle.weight(.bold))
            Text(
                "The sensor fabric behind MotionOS. Configure hardware here, "
                    + "then let capture workflows orchestrate it."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            SensorSourceStrip()
        }
        .padding(.horizontal, 2)
    }

    private var watchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceHeader(
                title: "Apple Watch",
                subtitle: "Primary continuous wrist sensor",
                symbol: "applewatch",
                color: watchColor,
                state: watchState
            )

            deviceRow(
                "Companion",
                phone.watchAppInstalled
                    ? (
                        phone.hasRecentWatchPresence()
                            ? "handshake confirmed"
                            : "installed"
                    )
                    : "not confirmed"
            )
            deviceRow(
                "Link",
                phone.watchReachable
                    ? "live"
                    : "background / unavailable"
            )

            if let presence = phone.watchPresence {
                deviceRow(
                    "WatchOS",
                    presence.watchSystemVersion
                )
                deviceRow(
                    "MotionOS",
                    "v\(presence.appVersion) · build \(presence.appBuild)"
                )
                deviceRow(
                    "Workout access",
                    presence.healthAuthorization
                )
                if let battery = presence.watchBatteryLevel {
                    deviceRow(
                        "Battery",
                        String(format: "%.0f%%", battery * 100)
                    )
                }
            }

            if phone.watchAppInstalled
                && !phone.systemWatchAppInstalled {
                Label(
                    "MotionOS handshake proves the Watch app is present even "
                        + "though the system install flag is stale.",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            }

            Button {
                phone.refreshWatchState()
            } label: {
                Label(
                    "Refresh Watch State",
                    systemImage: "arrow.clockwise"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
    }

    private var phoneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceHeader(
                title: "iPhone",
                subtitle: "Coordinator, camera, inbox, and local evidence store",
                symbol: "iphone",
                color: .indigo,
                state: "ready"
            )

            deviceRow(
                "Battery",
                phone.iPhoneBatteryLevel.map {
                    String(format: "%.0f%%", $0 * 100)
                } ?? "unknown"
            )
            deviceRow(
                "Free storage",
                phone.iPhoneAvailableStorageBytes.map {
                    ByteCountFormatter.string(
                        fromByteCount: $0,
                        countStyle: .file
                    )
                } ?? "unknown"
            )
            deviceRow(
                "Workout state",
                phone.state.rawValue
            )

            Label(
                "Development preflight uses 20% battery and 5 GB free as "
                    + "operator margins, not qualification criteria.",
                systemImage: "info.circle"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceHeader(
                title: "iPhone Camera",
                subtitle: "Video + frame timing + Vision evidence",
                symbol: "camera.fill",
                color: cameraColor,
                state: camera.phase.rawValue
            )

            if let config = camera.configuration {
                deviceRow(
                    "Camera",
                    config.localizedName
                )
                deviceRow(
                    "Format",
                    "\(config.formatWidth)×\(config.formatHeight)"
                )
                deviceRow(
                    "Frame rate",
                    String(
                        format: "%.0f fps %@",
                        config.configuredFrameRate,
                        config.frameRateLocked ? "locked" : "unlocked"
                    )
                )
                deviceRow(
                    "Stabilization",
                    config.stabilizationLockedOff
                        ? "off"
                        : config.preferredVideoStabilizationMode
                )
                deviceRow(
                    "Intrinsics",
                    config.intrinsicDeliveryEnabled
                        ? "enabled"
                        : "unavailable"
                )
            } else {
                Text(
                    "Prepare the camera once to inspect the selected physical "
                        + "device and capture format."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            NavigationLink {
                CameraCaptureCard()
            } label: {
                Label(
                    "Camera Setup & Evidence",
                    systemImage: "slider.horizontal.3"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
    }

    private var action4Card: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceHeader(
                title: "DJI Osmo Action 4",
                subtitle: "External recorded multiview source",
                symbol: "video.fill",
                color: indoBoard.externalCameraConfirmed
                    ? .green
                    : .secondary,
                state: indoBoard.externalCameraConfirmed
                    ? "confirmed"
                    : "manual"
            )

            deviceRow("Capture", "4K · 60 fps")
            deviceRow("Stabilization", "EIS off")
            deviceRow("FOV", "Standard (Dewarp)")
            deviceRow("Control", "manual start / import")

            Label(
                "MotionOS does not pretend this camera has a live control "
                    + "link. Start it manually, keep the rig fixed, then import "
                    + "the untouched movie into the sealed product session.",
                systemImage: "info.circle"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)

            NavigationLink {
                IndoBoardSessionView()
            } label: {
                Label(
                    "Open Multiview Capture",
                    systemImage: "scope"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
    }

    private var podCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceHeader(
                title: "Equipment Pod",
                subtitle: "MetaMotionS equipment-frame IMU",
                symbol: "sensor.tag.radiowaves.forward",
                color: podColor,
                state: pod.phase.rawValue
            )

            if let metadata = pod.deviceMetadata {
                deviceRow("Model", metadata.model)
                deviceRow(
                    "Firmware",
                    metadata.firmwareRevision
                )
                deviceRow(
                    "Requested accel",
                    String(format: "%.0f Hz", metadata.requestedAccelHz)
                )
                deviceRow(
                    "Requested gyro",
                    String(format: "%.0f Hz", metadata.requestedGyroHz)
                )
            } else {
                Text(
                    "Optional for the first Watch + camera Indo Board product "
                        + "session. Add it after the core capture is clean."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            NavigationLink {
                EquipmentPodCard()
            } label: {
                Label(
                    "Equipment Pod Setup",
                    systemImage: "dot.radiowaves.left.and.right"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
    }

    private var evidencePrinciple: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "One product, independent evidence",
                systemImage: "point.3.connected.trianglepath.dotted"
            )
            .font(.headline)

            Text(
                "MotionOS coordinates devices without pretending they share "
                    + "a clock or measurement model. Each sensor preserves its "
                    + "native evidence first; synchronization and interpretation "
                    + "remain explicit downstream steps."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func deviceHeader(
        title: String,
        subtitle: String,
        symbol: String,
        color: Color,
        state: String
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: 12,
                    style: .continuous
                )
                .fill(color.opacity(0.10))
                .frame(width: 42, height: 42)
                Image(systemName: symbol)
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(state.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    private func deviceRow(
        _ title: String,
        _ value: String
    ) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var watchState: String {
        if phone.watchReachable {
            return "live"
        }
        if phone.hasRecentWatchPresence() {
            return "handshake"
        }
        if phone.watchAppInstalled {
            return "installed"
        }
        return "offline"
    }

    private var watchColor: Color {
        phone.watchAppInstalled ? .green : .yellow
    }

    private var cameraColor: Color {
        switch camera.phase {
        case .ready, .evidenceReady:
            .green
        case .recording:
            .red
        case .authorizing, .finalizing:
            .yellow
        case .failed, .denied:
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

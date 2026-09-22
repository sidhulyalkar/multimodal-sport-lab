import SwiftUI

struct EquipmentPodCard: View {
    @EnvironmentObject private var pod: EquipmentPodController
    @State private var confirmClearAndArm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Equipment pod / P1", systemImage: "sensor.tag.radiowaves.forward")
                    .font(.headline)
                Spacer()
                Text(pod.phase.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(phaseColor)
            }

            if let metadata = pod.deviceMetadata {
                deviceSummary(metadata)
            } else {
                discoveryControls
            }

            if pod.deviceMetadata != nil {
                captureControls
                previewReadout
            }

            if pod.phase == .downloading {
                ProgressView(value: pod.downloadProgress)
                Text(
                    "Recovering both flash streams before any destructive clear."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let bundle = pod.evidenceBundle {
                evidence(bundle)
            }

            if let error = pod.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
        .confirmationDialog(
            "Clear existing pod flash and arm a new recording?",
            isPresented: $confirmClearAndArm,
            titleVisibility: .visible
        ) {
            Button(
                "Clear Flash & Arm",
                role: .destructive
            ) {
                Task {
                    await pod.armRecording(
                        clearExistingFlash: true
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Only use this after prior pod evidence has been recovered. Existing on-board logs cannot be restored after clearing."
            )
        }
    }

    private var discoveryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    if pod.phase == .scanning {
                        pod.stopScanning()
                    } else {
                        pod.startScanning()
                    }
                } label: {
                    Label(
                        pod.phase == .scanning ? "Stop Scan" : "Scan for MetaMotionS",
                        systemImage: pod.phase == .scanning
                            ? "stop.circle"
                            : "dot.radiowaves.left.and.right"
                    )
                }
                .buttonStyle(.borderedProminent)

                if pod.phase == .scanning {
                    ProgressView()
                }
            }

            if pod.candidates.isEmpty,
               pod.phase == .scanning {
                Text("Looking for nearby MetaWear devices…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(pod.candidates) { candidate in
                Button {
                    Task {
                        await pod.connect(candidate)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.name)
                                .font(.subheadline.weight(.medium))
                            Text(candidate.id.uuidString)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let rssi = candidate.rssi {
                            Text("\(rssi) dBm")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var captureControls: some View {
        switch pod.phase {
        case .ready, .evidenceReady:
            HStack {
                Button {
                    Task { await pod.startPreview() }
                } label: {
                    Label("Preview", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await pod.armRecording(
                            clearExistingFlash: false
                        )
                    }
                } label: {
                    Label("Arm Flash Log", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
            }

            HStack {
                Button(role: .destructive) {
                    confirmClearAndArm = true
                } label: {
                    Label(
                        "Clear Flash & Arm",
                        systemImage: "trash.circle"
                    )
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await pod.disconnect() }
                } label: {
                    Text("Disconnect")
                }
                .buttonStyle(.bordered)
            }

        case .previewing:
            Button {
                Task { await pod.stopPreview() }
            } label: {
                Label("Stop Preview", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

        case .recording:
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Flash logger armed. BLE may disappear without ending the board recording.",
                    systemImage: "internaldrive.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)

                Button {
                    Task { await pod.stopRecoverAndExport() }
                } label: {
                    Label(
                        "Stop, Recover & Export",
                        systemImage: "square.and.arrow.down"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

        case .linkLost:
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Control link lost. Treat the flash logger as still authoritative.",
                    systemImage: "antenna.radiowaves.left.and.right.slash"
                )
                .font(.caption)
                .foregroundStyle(.yellow)

                Button {
                    Task { await pod.reconnectForRecovery() }
                } label: {
                    Label(
                        "Reconnect & Recover Logger Registry",
                        systemImage: "arrow.clockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

        case .failed:
            Button {
                Task { await pod.disconnect() }
            } label: {
                Label("Reset Connection", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var previewReadout: some View {
        if pod.phase == .previewing {
            VStack(alignment: .leading, spacing: 5) {
                Text("BLE preview · host arrival timestamps only")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let accel = pod.latestAccel {
                    vectorRow(
                        "accel",
                        vector: accel,
                        unit: "m/s²"
                    )
                }
                if let gyro = pod.latestGyro {
                    vectorRow(
                        "gyro",
                        vector: gyro,
                        unit: "rad/s"
                    )
                }
            }
        }
    }

    private func deviceSummary(
        _ metadata: MetaMotionDeviceMetadata
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metadata.model)
                .font(.subheadline.weight(.semibold))
            Text(
                "HW \(metadata.hardwareRevision) · FW \(metadata.firmwareRevision)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(
                "Accel \(Int(metadata.requestedAccelHz)) Hz ±\(Int(metadata.requestedAccelRangeG))g · Gyro \(Int(metadata.requestedGyroHz)) Hz ±\(Int(metadata.requestedGyroRangeDPS)) dps"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func evidence(
        _ bundle: MetaMotionEvidenceBundle
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Recovered pod evidence is durable",
                systemImage: "checkmark.seal.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.green)

            Text(bundle.directory.lastPathComponent)
                .font(.system(.caption2, design: .monospaced))

            ShareLink(
                items: [
                    bundle.journalURL,
                    bundle.metadataURL,
                ]
            ) {
                Label(
                    "Share P1 evidence files",
                    systemImage: "square.and.arrow.up"
                )
            }
        }
    }

    private func vectorRow(
        _ label: String,
        vector: MetaMotionVector,
        unit: String
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 42, alignment: .leading)
            Text(
                String(
                    format: "%+.2f  %+.2f  %+.2f %@",
                    vector.x,
                    vector.y,
                    vector.z,
                    unit
                )
            )
            .font(.system(.caption, design: .monospaced))
        }
    }

    private var phaseColor: Color {
        switch pod.phase {
        case .ready, .evidenceReady:
            .green
        case .previewing, .recording:
            .blue
        case .scanning, .connecting, .recovering, .downloading:
            .yellow
        case .linkLost, .failed:
            .red
        default:
            .secondary
        }
    }
}

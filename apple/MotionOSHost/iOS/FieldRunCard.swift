import SwiftUI

struct FieldRunCard: View {
    @EnvironmentObject private var watch: PhoneSessionCoordinator
    @EnvironmentObject private var pod: EquipmentPodController
    @EnvironmentObject private var camera: CameraCaptureController
    @EnvironmentObject private var fieldRun: FieldRunCoordinator

    @State private var insolesArmed = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            readiness

            if fieldRun.phase == .running {
                syncMarkers
                movementBlocks
                annotations
                stopControl
            } else {
                startControl
            }

            if let bundle = fieldRun.evidenceBundle {
                evidence(bundle)
            }

            if let error = fieldRun.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(
                    "Combined Longboard Run",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .font(.headline)

                Spacer()

                Text(fieldRun.phase.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(phaseColor)
            }

            Text(
                "Operator ledger only. Sensor clocks remain independent; "
                    + "physical motion creates synchronization evidence."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let runID = fieldRun.runID {
                Text(runID)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 8) {
            readinessRow(
                "Watch recording",
                ready: watchReady,
                detail: watch.state.rawValue
            )
            readinessRow(
                "Pod flash recording",
                ready: podReady,
                detail: pod.phase.rawValue
            )
            readinessRow(
                "Camera recording",
                ready: cameraReady,
                detail: camera.phase.rawValue
            )

            Toggle(
                "External insoles armed",
                isOn: $insolesArmed
            )
            .disabled(fieldRun.phase == .running)

            Text(
                "The insole toggle is a manual acknowledgement until "
                    + "licensed direct SDK control exists."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var startControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    await fieldRun.start(state: snapshot)
                }
            } label: {
                Label(
                    "Start Combined Run Ledger",
                    systemImage: "play.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)

            if !canStart {
                Text(startBlockers)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var syncMarkers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Physical synchronization landmarks")
                .font(.subheadline.weight(.semibold))

            Text(
                "Tap immediately before performing one distinctive "
                    + "whole-body + board-coupled motion. The button time "
                    + "is only an approximate locator."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(["start", "middle", "end"], id: \.self) { label in
                Button {
                    Task {
                        await fieldRun.markSync(
                            label,
                            state: snapshot
                        )
                    }
                } label: {
                    HStack {
                        Label(
                            "Mark \(label.uppercased()) + perform physical motion",
                            systemImage: fieldRun.syncMarkers.contains(label)
                                ? "checkmark.circle.fill"
                                : "waveform.path.ecg"
                        )
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(fieldRun.syncMarkers.contains(label))
            }
        }
    }

    private var movementBlocks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Movement protocol")
                .font(.subheadline.weight(.semibold))

            ForEach(
                FieldRunCoordinator.movementBlocks,
                id: \.id
            ) { block in
                HStack(spacing: 8) {
                    Image(
                        systemName: fieldRun.completedBlockIDs.contains(
                            block.id
                        )
                            ? "checkmark.circle.fill"
                            : (
                                fieldRun.activeBlockID == block.id
                                    ? "record.circle.fill"
                                    : "circle"
                            )
                    )
                    .foregroundStyle(
                        fieldRun.completedBlockIDs.contains(block.id)
                            ? .green
                            : (
                                fieldRun.activeBlockID == block.id
                                    ? .red
                                    : .secondary
                            )
                    )

                    Text(block.label)
                        .font(.caption)

                    Spacer()

                    if fieldRun.completedBlockIDs.contains(block.id) {
                        Text("done")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if fieldRun.activeBlockID == block.id {
                        Button("Complete") {
                            Task {
                                await fieldRun.completeBlock(
                                    id: block.id,
                                    state: snapshot
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button("Begin") {
                            Task {
                                await fieldRun.beginBlock(
                                    id: block.id,
                                    state: snapshot
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(fieldRun.activeBlockID != nil)
                    }
                }
            }
        }
    }

    private var annotations: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Operator annotations")
                .font(.subheadline.weight(.semibold))

            TextField(
                "e.g. camera mount bumped / right insole dropout",
                text: $note,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)

            HStack {
                Button("Add note") {
                    let value = note
                    note = ""
                    Task {
                        await fieldRun.addNote(
                            value,
                            state: snapshot
                        )
                    }
                }
                .buttonStyle(.bordered)
                .disabled(note.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty)

                Button("Mark failure") {
                    let value = note
                    note = ""
                    Task {
                        await fieldRun.recordFailure(
                            value,
                            state: snapshot
                        )
                    }
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(note.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty)
            }
        }
    }

    private var stopControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            if missingRequiredMarkers {
                Text(
                    "Before stopping, record START / MIDDLE / END physical "
                        + "sync markers unless the run failed early."
                )
                .font(.caption)
                .foregroundStyle(.yellow)
            }

            Button {
                Task {
                    await fieldRun.stop(state: snapshot)
                }
            } label: {
                Label(
                    "Stop & Seal Field-Run Ledger",
                    systemImage: "stop.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private func evidence(
        _ bundle: FieldRunEvidenceBundle
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Operator evidence sealed",
                systemImage: "checkmark.seal.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.green)

            Text(bundle.directory.lastPathComponent)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)

            ShareLink(
                items: [
                    bundle.ledgerURL,
                    bundle.metadataURL,
                ]
            ) {
                Label(
                    "Share field-run ledger + metadata",
                    systemImage: "square.and.arrow.up"
                )
            }
        }
    }

    private func readinessRow(
        _ title: String,
        ready: Bool,
        detail: String
    ) -> some View {
        HStack {
            Image(
                systemName: ready
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle"
            )
            .foregroundStyle(ready ? .green : .yellow)

            Text(title)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var watchReady: Bool {
        watch.state == .running
    }

    private var podReady: Bool {
        pod.phase == .recording || pod.phase == .linkLost
    }

    private var cameraReady: Bool {
        camera.phase == .recording
    }

    private var canStart: Bool {
        watchReady && podReady && cameraReady && insolesArmed
    }

    private var startBlockers: String {
        var blockers: [String] = []
        if !watchReady { blockers.append("Watch not recording") }
        if !podReady { blockers.append("pod flash not recording") }
        if !cameraReady { blockers.append("camera not recording") }
        if !insolesArmed { blockers.append("insoles not acknowledged") }
        return blockers.joined(separator: " · ")
    }

    private var missingRequiredMarkers: Bool {
        !["start", "middle", "end"].allSatisfy(
            fieldRun.syncMarkers.contains
        )
    }

    private var snapshot: FieldRunStateSnapshot {
        FieldRunStateSnapshot(
            watch: watch.state.rawValue,
            equipmentPod: pod.phase.rawValue,
            camera: camera.phase.rawValue,
            insoles: insolesArmed ? "armed_external" : "not_armed"
        )
    }

    private var phaseColor: Color {
        switch fieldRun.phase {
        case .running:
            .red
        case .evidenceReady:
            .green
        case .finalizing:
            .yellow
        case .failed:
            .red
        case .idle:
            .secondary
        }
    }
}

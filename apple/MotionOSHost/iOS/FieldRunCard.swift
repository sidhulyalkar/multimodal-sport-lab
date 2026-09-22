import SwiftUI

struct FieldRunCard: View {
    @EnvironmentObject private var fieldRun: FieldRunCoordinator
    @EnvironmentObject private var phone: PhoneSessionCoordinator
    @EnvironmentObject private var inbox: PhoneJournalInbox
    @EnvironmentObject private var pod: EquipmentPodController
    @EnvironmentObject private var camera: CameraCaptureController

    @State private var failureNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            runIdentity
            phaseControls

            if fieldRun.phase == .running {
                syncControls
                protocolBlocks
                failureControls
            }

            if let bundle = fieldRun.evidenceBundle {
                sealedEvidence(bundle)
            }

            if let error = fieldRun.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text(
                "Operator timestamps document protocol intent only. "
                    + "Physical landmarks and device-native clocks remain "
                    + "the synchronization authority."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var header: some View {
        HStack {
            Label(
                "First-ride field coordinator",
                systemImage: "point.topleft.down.curvedto.point.bottomright.up"
            )
            .font(.headline)

            Spacer()

            Text(fieldRun.phase.rawValue.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(phaseColor)
        }
    }

    @ViewBuilder
    private var runIdentity: some View {
        if let runID = fieldRun.runID {
            VStack(alignment: .leading, spacing: 4) {
                Text(runID)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(
                    "\(fieldRun.eventCount) operator event(s) · "
                        + "\(fieldRun.completedBlockIDs.count)"
                        + "/\(fieldRun.protocolBlocks.count) blocks complete"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        } else {
            Text(
                "Creates one run-level operator record while Watch, pod, "
                    + "insoles, and camera keep independent source clocks."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var phaseControls: some View {
        switch fieldRun.phase {
        case .idle, .sealed, .failed:
            Button {
                fieldRun.createRun()
            } label: {
                Label(
                    "Create & Arm Longboard Run",
                    systemImage: "flag.checkered"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

        case .armed:
            readinessSummary

            Button {
                fieldRun.startRun(readiness: readinessSnapshot)
            } label: {
                Label(
                    "Start Operator Run",
                    systemImage: "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                fieldRun.seal(readiness: readinessSnapshot)
            } label: {
                Label(
                    "Seal Without Starting",
                    systemImage: "seal"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

        case .running:
            readinessSummary

            Button(role: .destructive) {
                fieldRun.seal(readiness: readinessSnapshot)
            } label: {
                Label(
                    "Seal Operator Evidence",
                    systemImage: "lock.doc"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

        case .sealing:
            HStack {
                ProgressView()
                Text("Hashing and sealing operator evidence…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var readinessSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            readinessRow(
                "Watch",
                value: phone.state.rawValue,
                ready: phone.watchPaired && phone.watchAppInstalled
            )
            readinessRow(
                "Pod",
                value: pod.phase.rawValue,
                ready: [.ready, .previewing, .recording, .linkLost]
                    .contains(pod.phase)
            )
            readinessRow(
                "Camera",
                value: camera.phase.rawValue,
                ready: [.ready, .recording].contains(camera.phase)
            )
            readinessRow(
                "Watch journal recovered",
                value: inbox.latestSessionID ?? "not yet",
                ready: inbox.latestJournalURL != nil
            )
        }
    }

    private var syncControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Physical sync cue annotations")
                .font(.subheadline.weight(.semibold))

            HStack {
                syncButton("start")
                syncButton("middle")
                syncButton("end")
            }

            Text(
                "Press immediately before/after performing the distinctive "
                    + "whole-body + board motion. These button times are "
                    + "navigation notes, not fitted correspondences."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var protocolBlocks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Longboard calibration blocks")
                .font(.subheadline.weight(.semibold))

            ForEach(fieldRun.protocolBlocks) { block in
                HStack(alignment: .top, spacing: 10) {
                    Image(
                        systemName: fieldRun.completedBlockIDs.contains(block.id)
                            ? "checkmark.circle.fill"
                            : fieldRun.activeBlockID == block.id
                                ? "record.circle.fill"
                                : "circle"
                    )
                    .foregroundStyle(
                        fieldRun.completedBlockIDs.contains(block.id)
                            ? .green
                            : fieldRun.activeBlockID == block.id
                                ? .red
                                : .secondary
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(block.label)
                            .font(.subheadline.weight(.medium))
                        Text(block.instruction)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if fieldRun.completedBlockIDs.contains(block.id) {
                        Text("done")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else if fieldRun.activeBlockID == block.id {
                        Button("Complete") {
                            fieldRun.completeBlock(block.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button("Start") {
                            fieldRun.startBlock(block.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var failureControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Failure / anomaly note")
                .font(.subheadline.weight(.semibold))

            TextField(
                "e.g. camera mount moved during right carves",
                text: $failureNote,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)

            Button {
                let note = failureNote
                fieldRun.addFailureNote(note)
                if fieldRun.errorMessage == nil {
                    failureNote = ""
                }
            } label: {
                Label(
                    "Record Failure Note",
                    systemImage: "exclamationmark.bubble"
                )
            }
            .buttonStyle(.bordered)

            if fieldRun.failureNoteCount > 0 {
                Text(
                    "\(fieldRun.failureNoteCount) failure note(s) recorded. "
                        + "They remain blockers in the later run report."
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
        }
    }

    private func sealedEvidence(
        _ bundle: OperatorEvidenceBundle
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
                    bundle.journalURL,
                    bundle.metadataURL,
                ]
            ) {
                Label(
                    "Share operator journal + metadata",
                    systemImage: "square.and.arrow.up"
                )
            }
        }
    }

    private func syncButton(_ label: String) -> some View {
        Button {
            fieldRun.markSyncCue(label)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: cueRecorded(label) ? "checkmark.circle.fill" : "waveform.path")
                Text(label.capitalized)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func cueRecorded(_ label: String) -> Bool {
        fieldRun.syncCueLabels.contains(label)
    }

    private func readinessRow(
        _ title: String,
        value: String,
        ready: Bool
    ) -> some View {
        HStack {
            Image(
                systemName: ready
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle"
            )
            .foregroundStyle(ready ? .green : .yellow)

            Text(title)
                .font(.caption)

            Spacer()

            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var readinessSnapshot: [String: String] {
        [
            "watch_paired": String(phone.watchPaired),
            "watch_app_installed": String(phone.watchAppInstalled),
            "watch_reachable": String(phone.watchReachable),
            "watch_workout_state": phone.state.rawValue,
            "watch_recovered_session_id":
                inbox.latestSessionID ?? "none",
            "watch_journal_present":
                String(inbox.latestJournalURL != nil),
            "pod_phase": pod.phase.rawValue,
            "pod_evidence_present":
                String(pod.evidenceBundle != nil),
            "camera_phase": camera.phase.rawValue,
            "camera_evidence_present":
                String(camera.evidenceBundle != nil),
            "camera_intrinsics_enabled": String(
                camera.configuration?.intrinsicDeliveryEnabled ?? false
            ),
        ]
    }

    private var phaseColor: Color {
        switch fieldRun.phase {
        case .running:
            .red
        case .armed, .sealing:
            .yellow
        case .sealed:
            .green
        case .failed:
            .red
        case .idle:
            .secondary
        }
    }
}

import MotionOSAppleCapture
import SwiftUI
import UniformTypeIdentifiers

struct IndoBoardSessionView: View {
    @EnvironmentObject private var phone: PhoneSessionCoordinator
    @EnvironmentObject private var camera: CameraCaptureController
    @EnvironmentObject private var pod: EquipmentPodController
    @EnvironmentObject private var fieldRun: FieldRunCoordinator
    @EnvironmentObject private var session: IndoBoardSessionCoordinator
    @EnvironmentObject private var runLibrary: ProductRunLibrary
    @State private var importingExternalVideo = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                hero
                phaseContent

                if let error = session.errorMessage
                    ?? fieldRun.errorMessage
                    ?? camera.errorMessage {
                    errorCard(error)
                }

                if session.phase != .running
                    && session.phase != .finishing {
                    methodology
                }
            }
            .motionOSPageWidth()
            .padding(.horizontal, MotionOSDesign.pageHorizontalPadding)
            .padding(.top, 10)
            .padding(.bottom, 36)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Indo Board")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            phone.refreshWatchState()
            phone.refreshHostReadiness()
            if fieldRun.protocolKind != .indoBoard
                && session.phase != .running {
                session.reset()
            }
        }
        .onChange(
            of: fieldRun.phase
        ) { _, phase in
            if phase == .sealed {
                runLibrary.refresh()
            }
        }
        .onChange(
            of: phone.lastSessionSyncAcknowledgment
        ) { _, acknowledgment in
            guard let acknowledgment else { return }
            session.acknowledge(
                acknowledgment,
                fieldRun: fieldRun
            )
        }
        .fileImporter(
            isPresented: $importingExternalVideo,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let sourceURL = try result.get().first,
                      let bundle = fieldRun.evidenceBundle,
                      let runID = fieldRun.runID
                else {
                    return
                }

                Task {
                    await session.importExternalVideo(
                        from: sourceURL,
                        runDirectory: bundle.directory,
                        runID: runID
                    )
                    runLibrary.refresh()
                }
            } catch {
                // The coordinator owns product-facing import errors. A user
                // cancellation requires no error surface.
            }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch session.phase {
        case .idle, .preparing, .ready, .failed:
            captureModeCard
            sourcePreflight

            if camera.phase == .ready
                || camera.phase == .recording {
                IndoBoardFramingCard()
            }

            sessionControl

        case .starting, .countdown:
            sessionControl

        case .running, .finishing:
            sessionControl
            IndoBoardProtocolRibbon()
            BodyMovementSceneCard()
            IndoBoardLiveSignalCard()
            liveProtocol

        case .watchStopRequired:
            recoveryCard

        case .sealed:
            sealedSummary
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    RoundedRectangle(
                        cornerRadius: 16,
                        style: .continuous
                    )
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.indigo.opacity(0.92),
                                Color.cyan.opacity(0.78),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)

                    Image(systemName: "figure.surfing")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Indo Board Session")
                        .font(.title2.weight(.bold))
                    Text(
                        "M0 · 2 min · "
                            + session.captureMode.displayName
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                MotionOSStatusBadge(
                    title: phaseLabel,
                    systemImage: phaseSymbol,
                    color: phaseColor
                )
            }

            if session.phase != .running
                && session.phase != .finishing {
                Text(
                    "Record Apple Watch motion + physiology, iPhone video, "
                        + "operator protocol events, and journal-backed sync cues "
                        + "as one coordinated product session."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    featurePill("Watch", "applewatch")
                    featurePill("iPhone Vision", "video.fill")
                    featurePill("120 s", "timer")
                }
            }
        }
        .cardStyle()
    }

    private var captureModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Capture sources",
                subtitle: "Watch + iPhone are the core session",
                systemImage: "point.3.connected.trianglepath.dotted",
                accent: .purple
            )

            HStack(spacing: 8) {
                requirementPill(
                    "Watch",
                    symbol: "applewatch",
                    required: true
                )
                requirementPill(
                    "iPhone Vision",
                    symbol: "camera.fill",
                    required: true
                )
            }

            Divider()

            Toggle(
                isOn: externalCameraEnabled
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add external calibration camera")
                        .font(.subheadline.weight(.semibold))
                    Text(
                        "Optional high-fidelity teacher view. For the current "
                            + "Action 4 workflow, start the camera manually and "
                            + "import the untouched movie after the session."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(
                session.phase == .starting
                    || session.phase == .running
                    || session.phase == .finishing
                    || session.phase == .watchStopRequired
            )

            if session.requiresExternalCamera {
                Label(
                    "Action 4 · 4K 16:9 · 60 fps · EIS off · fixed tripod",
                    systemImage: "video.fill"
                )
                .font(.caption)
                .foregroundStyle(.purple)
            }
        }
        .cardStyle()
    }

    private var sourcePreflight: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Session preflight",
                subtitle: preflightSubtitle,
                systemImage: "checklist.checked",
                accent: preflightReady ? .green : .yellow
            )

            Divider()

            readinessRow(
                title: "Apple Watch",
                detail: watchPreflightDetail,
                ready: watchPreflightReady,
                symbol: "applewatch"
            )

            readinessRow(
                title: "iPhone camera",
                detail: cameraDetail,
                ready: (
                    camera.phase == .ready
                        || camera.phase == .evidenceReady
                        || camera.phase == .recording
                ) && session.cameraProfileReady(camera),
                symbol: "camera.fill"
            )

            readinessRow(
                title: "Battery",
                detail: phone.iPhoneBatteryLevel.map {
                    String(format: "%.0f%%", $0 * 100)
                } ?? "unknown",
                ready: (phone.iPhoneBatteryLevel ?? 0) >= 0.20,
                symbol: "battery.100percent"
            )

            readinessRow(
                title: "Storage",
                detail: phone.iPhoneAvailableStorageBytes.map {
                    ByteCountFormatter.string(
                        fromByteCount: $0,
                        countStyle: .file
                    )
                } ?? "unknown",
                ready: (phone.iPhoneAvailableStorageBytes ?? 0)
                    >= 5_000_000_000,
                symbol: "internaldrive"
            )

            HStack(spacing: 8) {
                Button {
                    Task {
                        await session.prepare(
                            phone: phone,
                            camera: camera
                        )
                    }
                } label: {
                    Label(
                        "Refresh Checks",
                        systemImage: "arrow.clockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if camera.phase == .ready
                    || camera.phase == .evidenceReady {
                    NavigationLink {
                        CameraCaptureCard()
                    } label: {
                        Label(
                            "Camera",
                            systemImage: "camera"
                        )
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var sessionControl: some View {
        VStack(alignment: .leading, spacing: 13) {
            MotionOSSectionHeader(
                title: controlTitle,
                subtitle: controlSubtitle,
                systemImage: controlSymbol,
                accent: phaseColor
            )

            switch session.phase {
            case .idle, .failed:
                Button {
                    Task {
                        await session.prepare(
                            phone: phone,
                            camera: camera
                        )
                    }
                } label: {
                    Label(
                        "Prepare Session",
                        systemImage: "wand.and.stars"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .preparing:
                progressRow(
                    "Checking Watch, camera, battery, and storage"
                )

            case .ready:
                Button {
                    Task {
                        await session.start(
                            phone: phone,
                            camera: camera,
                            fieldRun: fieldRun,
                            pod: pod
                        )
                    }
                } label: {
                    HStack {
                        Image(systemName: "record.circle.fill")
                        Text("Start Complete Session")
                            .fontWeight(.semibold)
                        Spacer()
                        Text("2:00")
                            .font(.system(.body, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!preflightReady)

                Text(
                    "MotionOS starts the Watch workout first, waits for the "
                        + "mirrored running state, then starts iPhone video "
                        + "and seals the operator protocol around the same run."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

            case .starting:
                progressRow(
                    "Starting Watch first, then camera and protocol evidence"
                )

            case .countdown:
                VStack(spacing: 8) {
                    Text("\(session.countdownRemaining ?? 1)")
                        .font(
                            .system(
                                size: 52,
                                weight: .bold,
                                design: .rounded
                            )
                        )
                        .monospacedDigit()
                    Text("Settle into your natural stance")
                        .font(.headline)
                    Text(
                        "Watch and camera pre-roll are already capturing. "
                            + "The 2-minute protocol clock starts after the countdown."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

            case .running:
                runningControl

            case .finishing:
                progressRow(
                    "Stopping Watch, sealing video, and closing operator evidence"
                )

            case .watchStopRequired:
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "Stop MotionOS on the Watch",
                        systemImage: "applewatch"
                    )
                    .font(.headline)
                    .foregroundStyle(.yellow)

                    Text(
                        "The camera and operator evidence are sealed, but "
                            + "the phone could not confirm Watch shutdown. "
                            + "Stop the workout on the Watch so its journal "
                            + "can close and transfer."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button {
                        session.recheckWatchStop(phone: phone)
                    } label: {
                        Label(
                            "Recheck Watch",
                            systemImage: "arrow.clockwise"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .sealed:
                Label(
                    "Session evidence sealed",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.headline)
                .foregroundStyle(.green)

                Button {
                    session.reset()
                } label: {
                    Label(
                        "Ready Another Session",
                        systemImage: "arrow.counterclockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .cardStyle()
    }

    private var runningControl: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = session.startedAt.map {
                max(0, context.date.timeIntervalSince($0))
            } ?? 0
            let fraction = min(
                1,
                elapsed
                    / IndoBoardSessionCoordinator
                        .targetDurationSeconds
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        Circle()
                            .stroke(
                                Color.primary.opacity(0.08),
                                lineWidth: 7
                            )
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(
                                LinearGradient(
                                    colors: [.indigo, .cyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                style: StrokeStyle(
                                    lineWidth: 7,
                                    lineCap: .round
                                )
                            )
                            .rotationEffect(.degrees(-90))

                        VStack(spacing: 0) {
                            Text(duration(elapsed))
                                .font(
                                    .system(
                                        .title3,
                                        design: .rounded,
                                        weight: .bold
                                    )
                                )
                                .monospacedDigit()
                            Text("/ 2:00")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 92, height: 92)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("NOW")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(session.instruction(at: elapsed))
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                syncCueRow

                Button(role: .destructive) {
                    Task {
                        await session.finish(
                            phone: phone,
                            camera: camera,
                            fieldRun: fieldRun,
                            pod: pod
                        )
                    }
                } label: {
                    Label(
                        elapsed
                            >= IndoBoardProductProtocol
                                .targetDurationSeconds
                            ? "Finish & Seal Session"
                            : "Stop Early & Preserve Attempt",
                        systemImage: "stop.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var syncCueRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("JOURNAL-BACKED SYNC")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(
                    "\(session.cueReceipts.count)/3"
                )
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(
                    session.cueReceipts.count >= 3
                        ? Color.green
                        : Color.secondary
                )
            }

            HStack(spacing: 7) {
                syncStatus("start", title: "Start")
                syncStatus("middle", title: "Middle")
                syncStatus("end", title: "End")
            }

            Text(
                session.pendingCueID == nil
                    ? "Cues are sent automatically near 0:12, 0:50, and 1:50. When the Watch taps you and shows SYNC · MOVE NOW, make one quick arm gesture while keeping the board near neutral."
                    : "Waiting for the Watch to journal and acknowledge the automatic cue…"
            )
            .font(.caption2)
            .foregroundStyle(
                session.pendingCueID == nil
                    ? Color.secondary
                    : Color.yellow
            )
        }
        .padding(12)
        .background(
            Color.cyan.opacity(0.055),
            in: RoundedRectangle(
                cornerRadius: 16,
                style: .continuous
            )
        )
    }

    private func syncStatus(
        _ label: String,
        title: String
    ) -> some View {
        let acknowledged =
            session.acknowledgedCueLabels.contains(label)
        let waiting = session.pendingCueID != nil && !acknowledged

        return VStack(spacing: 4) {
            Image(
                systemName: acknowledged
                    ? "checkmark.circle.fill"
                    : waiting
                        ? "clock.fill"
                        : "circle"
            )
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(
            acknowledged
                ? .green
                : waiting
                    ? .yellow
                    : .secondary
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            (
                acknowledged
                    ? Color.green
                    : waiting
                        ? Color.yellow
                        : Color.secondary
            )
            .opacity(0.07),
            in: RoundedRectangle(
                cornerRadius: 10,
                style: .continuous
            )
        )
    }

    private var liveProtocol: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Protocol",
                subtitle: "Repeatable blocks for useful product feedback and later comparison",
                systemImage: "list.number",
                accent: .indigo
            )

            ForEach(
                Array(
                    fieldRun.protocolBlocks.enumerated()
                ),
                id: \.element.id
            ) { index, block in
                protocolRow(
                    index: index + 1,
                    block: block
                )
            }

            Text(
                "MotionOS advances these blocks automatically from the "
                    + "two-minute protocol so you do not need to touch the "
                    + "phone while balancing. Operator block timestamps "
                    + "document protocol intent only; Watch/device clocks "
                    + "remain the measurement authority."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func protocolRow(
        index: Int,
        block: FieldProtocolBlock
    ) -> some View {
        let complete =
            fieldRun.completedBlockIDs.contains(block.id)
        let active = fieldRun.activeBlockID == block.id

        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        complete
                            ? Color.green.opacity(0.14)
                            : active
                                ? Color.cyan.opacity(0.14)
                                : Color.primary.opacity(0.05)
                    )
                    .frame(width: 30, height: 30)

                if complete {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                } else {
                    Text("\(index)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(
                            active ? .cyan : .secondary
                        )
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(block.label)
                    .font(.subheadline.weight(.semibold))
                Text(block.instruction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            if complete {
                Text("DONE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.green)
            } else if active {
                Text("NOW")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        Color.cyan.opacity(0.10),
                        in: Capsule()
                    )
            } else if session.phase == .running {
                Text("UP NEXT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var sealedSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: session.outcome == .aborted
                    ? "Attempt preserved"
                    : "Capture sealed",
                subtitle: session.outcome == .aborted
                    ? "Stopped early or failed to start; available evidence remains inspectable"
                    : "Raw sources remain independent and hashable",
                systemImage: session.outcome == .aborted
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.seal.fill",
                accent: session.outcome == .aborted
                    ? .yellow
                    : .green
            )

            if session.outcome == .aborted {
                Label(
                    "This attempt is excluded from longitudinal comparisons.",
                    systemImage: "chart.line.downtrend.xyaxis"
                )
                .font(.caption)
                .foregroundStyle(.yellow)
            }

            VStack(spacing: 8) {
                completionRow(
                    "Operator protocol",
                    detail: fieldRun.phase == .sealed
                        ? "sealed"
                        : fieldRun.phase.rawValue,
                    complete: fieldRun.phase == .sealed,
                    symbol: "list.clipboard.fill"
                )
                completionRow(
                    "iPhone camera",
                    detail: camera.evidenceBundle != nil
                        ? "video + frame evidence"
                        : camera.phase.rawValue,
                    complete: camera.evidenceBundle != nil,
                    symbol: "camera.fill"
                )
                completionRow(
                    "Apple Watch",
                    detail: watchEvidenceReady
                        ? "journal verified on iPhone"
                        : "waiting for transfer / verification",
                    complete: watchEvidenceReady,
                    symbol: "applewatch"
                )

                if session.requiresExternalCamera
                    || session.externalCameraConfirmed {
                    completionRow(
                        "Action 4",
                        detail: session.externalVideoEvidence != nil
                            ? "original movie hash-bound"
                            : "awaiting original movie import",
                        complete: session.externalVideoEvidence != nil,
                        symbol: "video.fill"
                    )
                }
            }
            .padding(11)
            .background(
                Color.primary.opacity(0.035),
                in: RoundedRectangle(
                    cornerRadius: 15,
                    style: .continuous
                )
            )

            if let run = currentRunRecord {
                NavigationLink {
                    ProductRunDetailView(run: run)
                } label: {
                    Label(
                        session.outcome == .aborted
                            ? "Review Preserved Attempt"
                            : "Review Complete Session",
                        systemImage: "chart.xyaxis.line"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if !watchEvidenceReady {
                Label(
                    "Session review will fill in automatically when the "
                        + "Watch journal reaches the iPhone.",
                    systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let bundle = fieldRun.evidenceBundle {
                Label(
                    bundle.directory.lastPathComponent,
                    systemImage: "doc.text"
                )
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

                ShareLink(
                    items: [
                        bundle.journalURL,
                        bundle.metadataURL,
                    ]
                ) {
                    Label(
                        "Share operator evidence",
                        systemImage: "square.and.arrow.up"
                    )
                }
            }

            if let cameraBundle = camera.evidenceBundle {
                ShareLink(
                    items: [
                        cameraBundle.videoURL,
                        cameraBundle.journalURL,
                        cameraBundle.metadataURL,
                    ]
                ) {
                    Label(
                        "Share camera evidence",
                        systemImage: "video"
                    )
                }
            }

            if let manifestURL = session.productManifestURL {
                ShareLink(item: manifestURL) {
                    Label(
                        "Share product session manifest",
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                }
            }

            if session.externalCameraConfirmed {
                Divider()

                if let external = session.externalVideoEvidence {
                    Label(
                        "Action 4 evidence verified",
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)

                    Text(
                        external.originalFilename
                            + " · "
                            + ByteCountFormatter.string(
                                fromByteCount: Int64(
                                    external.byteCount
                                ),
                                countStyle: .file
                            )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text(
                        String(external.sha256.prefix(16)) + "…"
                    )
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                    ShareLink(
                        items: [
                            external.videoURL,
                            external.metadataURL,
                        ]
                    ) {
                        Label(
                            "Share external camera evidence",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                } else {
                    Button {
                        importingExternalVideo = true
                    } label: {
                        Label(
                            "Import Original Action 4 Movie",
                            systemImage: "video.badge.plus"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Text(
                        "MotionOS copies the untouched movie into this run "
                            + "and records its SHA-256 + byte count. "
                            + "No transcoding occurs during import."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            if session.cueReceipts.count < 3 {
                Label(
                    "Only \(session.cueReceipts.count)/3 sync cues were Watch-acknowledged.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.yellow)
            } else {
                Label(
                    "3/3 sync cues were journaled on Watch",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            }

            Divider()

            if session.externalCameraConfirmed
                && session.externalVideoEvidence == nil {
                Button {
                    session.reset()
                    runLibrary.refresh()
                } label: {
                    Label(
                        "Start Another Without Action 4",
                        systemImage: "arrow.counterclockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Text(
                    "The current run stays preserved in Sessions with its "
                        + "planned Action 4 source marked incomplete."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Button {
                    session.reset()
                    runLibrary.refresh()
                } label: {
                    Label(
                        "Prepare Another Session",
                        systemImage: "arrow.counterclockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .cardStyle()
    }

    private var currentRunRecord: ProductRunRecord? {
        guard let runID = fieldRun.runID else {
            return nil
        }
        return runLibrary.runs.first {
            $0.runID == runID
        }
    }

    private var watchEvidenceReady: Bool {
        if currentRunRecord?.watchJournalURL != nil {
            return true
        }
        guard let runID = fieldRun.runID else {
            return false
        }
        return phone.inbox.latestProductRunID == runID
    }

    private func completionRow(
        _ title: String,
        detail: String,
        complete: Bool,
        symbol: String
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(
                    complete ? .green : .yellow
                )
                .frame(width: 20)

            Text(title)
                .font(.subheadline.weight(.medium))

            Spacer(minLength: 8)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)

            Image(
                systemName: complete
                    ? "checkmark.circle.fill"
                    : "clock"
            )
            .foregroundStyle(
                complete ? .green : .yellow
            )
        }
    }

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Finish Watch capture",
                subtitle: "The iPhone and operator evidence are already sealed",
                systemImage: "applewatch.radiowaves.left.and.right",
                accent: .yellow
            )

            Text(
                "MotionOS could not confirm that the Watch workout stopped. "
                    + "Open MotionOS on the Watch, stop the capture there, "
                    + "then recheck. Do not start another product session "
                    + "until the Watch has left its running state."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                session.recheckWatchStop(phone: phone)
            } label: {
                Label(
                    "Recheck Watch",
                    systemImage: "arrow.clockwise"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .cardStyle()
    }

    private var methodology: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Measurement boundary",
                systemImage: "scope"
            )
            .font(.subheadline.weight(.semibold))

            Text(
                "This product session records and preserves raw Watch, "
                    + "camera, and operator evidence. Live movement values "
                    + "are derived observability signals. Camera-rich "
                    + "biomechanics metrics remain gated on calibration and "
                    + "post-session quality checks."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Label(
                "Use a clear area and stable support or spotter for early Indo Board runs.",
                systemImage: "figure.stand"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func featurePill(
        _ title: String,
        _ symbol: String
    ) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Color.primary.opacity(0.045),
                in: Capsule()
            )
    }

    private func requirementPill(
        _ title: String,
        symbol: String,
        required: Bool
    ) -> some View {
        Label(
            required ? title : "\(title) optional",
            systemImage: symbol
        )
        .font(.caption2.weight(.semibold))
        .foregroundStyle(required ? .primary : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            (required ? Color.purple : Color.secondary)
                .opacity(0.08),
            in: Capsule()
        )
    }

    private func readinessRow(
        title: String,
        detail: String,
        ready: Bool,
        symbol: String
    ) -> some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(
                        (ready ? Color.green : Color.yellow)
                            .opacity(0.10)
                    )
                    .frame(width: 30, height: 30)
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        ready ? .green : .yellow
                    )
            }

            Text(title)
                .font(.subheadline)

            Spacer(minLength: 6)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func progressRow(
        _ title: String
    ) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func errorCard(
        _ message: String
    ) -> some View {
        Label {
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        .cardStyle()
    }

    private var cameraDetail: String {
        guard let configuration = camera.configuration else {
            return camera.phase.rawValue
        }

        if session.cameraProfileReady(camera) {
            return String(
                format: "%dx%d · %.0f fps · stab off",
                configuration.formatWidth,
                configuration.formatHeight,
                configuration.configuredFrameRate
            )
        }

        return "profile needs review"
    }

    private var watchPreflightReady: Bool {
        phone.watchConnectionReady
            && session.watchCaptureAvailable(phone)
            && session.watchWorkoutAccessReady(phone)
    }

    private var watchPreflightDetail: String {
        if !phone.watchConnectionReady {
            return phone.watchStatus.detail
        }
        if !session.watchCaptureAvailable(phone) {
            return session.watchCaptureAvailabilityDetail(phone)
        }
        if !session.watchWorkoutAccessReady(phone) {
            return "Open MotionOS on Watch and enable Health"
        }
        return "Ready"
    }

    private var externalCameraEnabled: Binding<Bool> {
        Binding(
            get: {
                session.requiresExternalCamera
                    && session.externalCameraConfirmed
            },
            set: { enabled in
                session.captureMode = enabled
                    ? .multiviewCalibration
                    : .watchAndPhone
                session.externalCameraConfirmed = enabled
            }
        )
    }

    private var preflightReady: Bool {
        watchPreflightReady
            && (
                camera.phase == .ready
                    || camera.phase == .evidenceReady
            )
            && session.cameraProfileReady(camera)
            && (phone.iPhoneBatteryLevel ?? 0) >= 0.20
            && (phone.iPhoneAvailableStorageBytes ?? 0)
                >= 5_000_000_000
            && (
                !session.requiresExternalCamera
                    || session.externalCameraConfirmed
            )
    }

    private var preflightSubtitle: String {
        preflightReady
            ? "Required sources are ready for a coordinated run"
            : "Resolve the yellow items before starting"
    }

    private var phaseLabel: String {
        switch session.phase {
        case .idle:
            "NEW"
        case .preparing:
            "CHECKING"
        case .ready:
            "READY"
        case .starting:
            "STARTING"
        case .countdown:
            "COUNTDOWN"
        case .running:
            "RECORDING"
        case .finishing:
            "SEALING"
        case .watchStopRequired:
            "WATCH STOP"
        case .sealed:
            "SEALED"
        case .failed:
            "CHECK"
        }
    }

    private var phaseSymbol: String {
        switch session.phase {
        case .running:
            "record.circle.fill"
        case .sealed:
            "checkmark.seal.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .watchStopRequired:
            "applewatch"
        case .preparing, .starting, .countdown, .finishing:
            "clock.fill"
        default:
            "figure.surfing"
        }
    }

    private var phaseColor: Color {
        switch session.phase {
        case .running:
            .red
        case .ready, .sealed:
            .green
        case .preparing, .starting, .countdown, .finishing,
                .watchStopRequired:
            .yellow
        case .failed:
            .red
        case .idle:
            .indigo
        }
    }

    private var controlTitle: String {
        switch session.phase {
        case .idle, .failed:
            "Prepare capture"
        case .preparing:
            "Running preflight"
        case .ready:
            "Ready to record"
        case .starting:
            "Starting sources"
        case .countdown:
            "Get ready"
        case .running:
            "Session live"
        case .finishing:
            "Sealing evidence"
        case .watchStopRequired:
            "Finish Watch capture"
        case .sealed:
            "Session complete"
        }
    }

    private var controlSubtitle: String {
        switch session.phase {
        case .idle, .failed:
            "One workflow coordinates the sources without merging their native clocks"
        case .preparing:
            "MotionOS is checking required capture conditions"
        case .ready:
            "Watch first, camera second, protocol evidence third"
        case .starting:
            "Waiting for the Watch workout before video capture begins"
        case .countdown:
            "Pre-roll is recording; the protocol starts when the countdown ends"
        case .running:
            "Follow the protocol and collect three journal-backed sync cues"
        case .finishing:
            "Each source closes into its own durable evidence artifact"
        case .watchStopRequired:
            "The Watch journal still needs a manual stop before this run is fully closed"
        case .sealed:
            "Review the recovered Watch session in Sessions when transfer completes"
        }
    }

    private var controlSymbol: String {
        switch session.phase {
        case .running:
            "waveform.path.ecg"
        case .sealed:
            "checkmark.seal.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .watchStopRequired:
            "applewatch"
        default:
            "record.circle"
        }
    }

    private func duration(
        _ seconds: TimeInterval
    ) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(
            format: "%02d:%02d",
            value / 60,
            value % 60
        )
    }
}

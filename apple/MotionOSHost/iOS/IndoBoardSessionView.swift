import MotionOSAppleCapture
import PhotosUI
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
    @State private var selectedExternalVideoItem: PhotosPickerItem?
    @State private var showMeasurementDetails = false
    @State private var showSessionOptions = false

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
                camera: camera,
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
        .onChange(of: selectedExternalVideoItem) { _, item in
            guard let item else { return }
            Task {
                defer { selectedExternalVideoItem = nil }
                do {
                    guard let movie = try await item.loadTransferable(
                        type: ImportedMovie.self
                    ) else {
                        return
                    }
                    await importExternalMovie(movie.url)
                    try? FileManager.default.removeItem(at: movie.url)
                } catch {
                    // PhotosPicker transfer failures are intentionally kept
                    // separate from the sealed source evidence. The Files
                    // importer remains available as a fallback.
                }
            }
        }
    }

    @MainActor
    private func importExternalMovie(_ sourceURL: URL) async {
        guard let bundle = fieldRun.evidenceBundle,
              let runID = fieldRun.runID
        else {
            return
        }
        await session.importExternalVideo(
            from: sourceURL,
            runDirectory: bundle.directory,
            runID: runID
        )
        runLibrary.refresh()
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
                    Text("Guided 2-minute balance session")
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
                    "MotionOS checks your Watch and camera, helps frame your "
                        + "body and board, then records them together."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    featurePill("Watch", "applewatch")
                    featurePill("iPhone", "video.fill")
                    featurePill("2 min", "timer")
                }
            }
        }
        .cardStyle()
    }

    private var captureModeCard: some View {
        DisclosureGroup(isExpanded: $showSessionOptions) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    requirementPill(
                        "Apple Watch",
                        symbol: "applewatch",
                        required: true
                    )
                    requirementPill(
                        "iPhone camera",
                        symbol: "camera.fill",
                        required: true
                    )
                }

                Divider()

                NavigationLink {
                    IndoBoardMarkerSetupView()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "qrcode.viewfinder")
                            .foregroundStyle(.cyan)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Board tracking (beta)")
                                .font(.subheadline.weight(.semibold))
                            Text(
                                "Optional markers can improve board-relative "
                                    + "measurements."
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                Divider()

                Toggle(
                    isOn: externalCameraEnabled
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Add an external camera")
                            .font(.subheadline.weight(.semibold))
                        Text(
                            "Optional. A second fixed view can improve later "
                                + "calibration and 3D analysis."
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                .disabled(
                    session.phase == .starting
                        || session.phase == .running
                        || session.phase == .finishing
                        || session.phase == .watchStopRequired
                )

                if session.requiresExternalCamera {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Action camera setup",
                            systemImage: "video.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)

                        Text(
                            "Use a fixed tripod and keep your full body, both "
                                + "feet, board, roller, and recovery space in "
                                + "frame. Start recording before stepping on."
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        Toggle(
                            "External camera is recording",
                            isOn: $session.externalCameraConfirmed
                        )
                        .font(.subheadline.weight(.semibold))

                        Text(
                            "MotionOS aligns the imported video after the "
                                + "session. The camera does not need to be "
                                + "connected live."
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("Session options")
                    .font(.subheadline.weight(.semibold))
                Text("Required devices are checked automatically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.secondary)
        .cardStyle()
    }

    private var sourcePreflight: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Ready check",
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

            boardTrackingRow

            if session.requiresExternalCamera {
                readinessRow(
                    title: "Action 4",
                    detail: session.externalCameraConfirmed
                        ? "recording confirmed · fixed tripod"
                        : "roll / voice-start / use DJI remote, then confirm",
                    ready: session.externalCameraConfirmed,
                    symbol: "video.fill"
                )
            }

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

    private var boardTrackingRow: some View {
        let health = camera.indoBoardTrackingHealth
        let hasEvidence = health.trackedSampleCount > 0
        let stable = health.isStable
        let accent: Color =
            stable
                ? .green
                : (hasEvidence ? .yellow : .secondary)

        let detail: String = {
            guard health.sampleCount > 0 else {
                return "optional · body-only beta still available"
            }
            guard hasEvidence else {
                return "no deck + roller observations in the recent window"
            }
            return String(
                format:
                    "%.0f%% visible · %.0f%% confidence",
                health.coverageFraction * 100,
                health.meanConfidence * 100
            )
        }()

        return HStack(spacing: 9) {
            Image(
                systemName:
                    stable
                        ? "viewfinder.circle.fill"
                        : "viewfinder"
            )
            .foregroundStyle(accent)
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    stable
                        ? "Board tracking stable"
                        : (
                            hasEvidence
                                ? "Board tracking intermittent"
                                : "Board tracking"
                        )
                )
                .font(.subheadline.weight(.medium))

                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if hasEvidence {
                    Text(
                        "Tracking: \(equipmentSourceLabel(camera.latestIndoBoardState))"
                            + " · Coaching: "
                            + equipmentSourceLabel(
                                camera.latestIndoBoardCoachingState,
                                fallback: "body pose only"
                            )
                    )
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if stable {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("OPTIONAL")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func equipmentSourceLabel(
        _ state: IndoBoardBalanceState?,
        fallback: String = "none"
    ) -> String {
        guard let state else {
            return fallback
        }

        switch state.provenance {
        case .fiducialMeasured:
            return "QR measured"
        case .manualAnnotated:
            return "reviewed"
        case .modelEstimated:
            return "markerless model"
        case .geometricProxy:
            return "geometric proxy"
        }
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
                        "Check My Setup",
                        systemImage: "checkmark.circle"
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
                        Text("Start Session")
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
                    "Your Watch and iPhone will start together after a short "
                        + "countdown. You do not need to touch the phone while "
                        + "balancing."
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
                            ? "Finish Session"
                            : "Stop Early",
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
                Text("SYNC GESTURES")
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
                    ? "When the Watch taps you, make one quick arm gesture while keeping the board near neutral. MotionOS uses these moments to align recordings."
                    : "Waiting for the Watch to confirm the cue…"
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
                title: "Session plan",
                subtitle: "The same short blocks each time make progress easier to compare",
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
                "MotionOS advances automatically so you can stay focused on "
                    + "the board. The same sequence is reused for comparable "
                    + "future sessions."
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
                    ? "Attempt saved"
                    : "Session saved",
                subtitle: session.outcome == .aborted
                    ? "Stopped early. Any recordings already captured are still available."
                    : "Your Watch and camera recordings are saved for review.",
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
                    "Session plan",
                    detail: fieldRun.phase == .sealed
                        ? "Saved"
                        : fieldRun.phase.rawValue.capitalized,
                    complete: fieldRun.phase == .sealed,
                    symbol: "list.clipboard.fill"
                )
                completionRow(
                    "iPhone camera",
                    detail: camera.evidenceBundle != nil
                        ? "Video saved"
                        : camera.phase.rawValue.capitalized,
                    complete: camera.evidenceBundle != nil,
                    symbol: "camera.fill"
                )
                completionRow(
                    "Apple Watch",
                    detail: watchEvidenceReady
                        ? "Data saved"
                        : "Still syncing",
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

            if let coach = camera.indoCoachReport {
                coachSummaryCard(coach)
            }

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
                    PhotosPicker(
                        selection: $selectedExternalVideoItem,
                        matching: .videos
                    ) {
                        Label(
                            "Choose Action 4 Movie from Photos",
                            systemImage: "photo.on.rectangle.angled"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        importingExternalVideo = true
                    } label: {
                        Label(
                            "Choose Movie from Files / SD Card",
                            systemImage: "externaldrive.badge.plus"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Text(
                        "Choose the original video from Photos or Files. "
                            + "MotionOS keeps the original recording and aligns it "
                            + "with this session after import."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            if session.cueReceipts.count < 3 {
                Label(
                    "Timing needs review · \(session.cueReceipts.count)/3 alignment gestures captured.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.yellow)
            } else {
                Label(
                    "Timing checks captured",
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
                        "Start Another Without External Camera",
                        systemImage: "arrow.counterclockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Text(
                    "This session stays in Sessions. The optional external "
                        + "camera will simply remain incomplete."
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

    private func coachSummaryCard(
        _ coach: IndoBoardCoachReport
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.13))
                        .frame(width: 38, height: 38)
                    Image(systemName: "figure.mind.and.body")
                        .foregroundStyle(.cyan)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("EXPERIMENTAL SESSION CUE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(coach.headline)
                        .font(.headline)
                }

                Spacer()
            }

            Text(coach.observation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let quality =
                    boardTrackingQuality(coach) {
                boardTrackingQualityCard(quality)
            }

            if let experiment = coach.experimentResult {
                HStack(alignment: .top, spacing: 9) {
                    Image(
                        systemName: experimentSymbol(
                            experiment.outcome
                        )
                    )
                    .foregroundStyle(
                        experimentColor(
                            experiment.outcome
                        )
                    )
                    .frame(width: 22)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            experimentTitle(
                                experiment.outcome
                            )
                        )
                        .font(.caption.weight(.bold))

                        Text(experiment.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                    }
                }
                .padding(10)
                .background(
                    experimentColor(experiment.outcome)
                        .opacity(0.08),
                    in: RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                Label("TRY NEXT", systemImage: "lightbulb.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.cyan)
                Text(coach.tip)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Label("REPEAT WITH", systemImage: "repeat")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.indigo)
                Text(coach.drill)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !coach.metrics.isEmpty {
                Divider()

                ForEach(coach.metrics.prefix(4)) { metric in
                    HStack {
                        Text(metric.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(metric.value)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Why this appeared")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(coach.evidenceLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(
                    "Experimental guidance is separate from the new personal "
                        + "baseline and session-delta pipeline until that "
                        + "interpretation layer is explicitly connected."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [
                    Color.cyan.opacity(0.08),
                    Color.indigo.opacity(0.05),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(
                cornerRadius: 18,
                style: .continuous
            )
        )
    }

    private struct BoardTrackingQuality {
        let sampleCount: Int
        let coverage: Double
        let confidence: Double
        let firstBalanceCoverage: Double?
        let secondBalanceCoverage: Double?

        var usableForBoardCoaching: Bool {
            sampleCount
                >= IndoBoardEvidenceQualityThresholds
                    .minimumSessionSamples
                && coverage
                    >= IndoBoardEvidenceQualityThresholds
                        .minimumSessionCoverage
                && confidence
                    >= IndoBoardEvidenceQualityThresholds
                        .minimumStateConfidence
        }
    }

    private func boardTrackingQuality(
        _ coach: IndoBoardCoachReport
    ) -> BoardTrackingQuality? {
        let values = coach.numericMetrics
        guard let samples = values["board_sample_count"],
              let coverage =
                values["board_state_coverage_fraction"],
              let confidence =
                values["board_state_confidence"]
        else {
            return nil
        }

        return BoardTrackingQuality(
            sampleCount: max(0, Int(samples.rounded())),
            coverage: min(1, max(0, coverage)),
            confidence: min(1, max(0, confidence)),
            firstBalanceCoverage:
                values[
                    "board_free_balance_a_coverage_fraction"
                ],
            secondBalanceCoverage:
                values[
                    "board_free_balance_b_coverage_fraction"
                ]
        )
    }

    @ViewBuilder
    private func boardTrackingQualityCard(
        _ quality: BoardTrackingQuality
    ) -> some View {
        let usable = quality.usableForBoardCoaching
        let accent: Color = usable ? .green : .yellow

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    usable
                        ? "Board-relative evidence usable"
                        : "Board tracking was partial",
                    systemImage:
                        usable
                            ? "checkmark.shield.fill"
                            : "viewfinder.circle"
                )
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)

                Spacer()

                Text(
                    String(
                        format: "%.0f%% coverage",
                        quality.coverage * 100
                    )
                )
                .font(
                    .system(
                        .caption2,
                        design: .monospaced
                    )
                )
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                trackingQualityMetric(
                    "Samples",
                    "\(quality.sampleCount)"
                )
                trackingQualityMetric(
                    "Confidence",
                    String(
                        format: "%.0f%%",
                        quality.confidence * 100
                    )
                )
                trackingQualityMetric(
                    "Coverage",
                    String(
                        format: "%.0f%%",
                        quality.coverage * 100
                    )
                )
            }

            if let first = quality.firstBalanceCoverage,
               let second = quality.secondBalanceCoverage {
                Text(
                    String(
                        format:
                            "Balance blocks · first %.0f%% · coached retry %.0f%%",
                        first * 100,
                        second * 100
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Text(
                usable
                    ? "Deck-relative metrics met this beta run's minimum sample, confidence, and visibility gates."
                    : "The raw geometry is preserved, but MotionOS falls back to body-pose coaching when board visibility is too sparse."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            accent.opacity(0.07),
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
    }

    private func trackingQualityMetric(
        _ label: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(
                    .system(
                        .caption,
                        design: .monospaced,
                        weight: .semibold
                    )
                )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(
                cornerRadius: 9,
                style: .continuous
            )
        )
    }

    private func experimentTitle(
        _ outcome: IndoBoardCoachExperimentOutcome
    ) -> String {
        switch outcome {
        case .improved:
            return "This cue helped this attempt"
        case .oppositeDirection:
            return "This cue moved the target the wrong way"
        case .noClearChange:
            return "No clear cue effect yet"
        case .insufficientEvidence:
            return "Cue effect not scored"
        }
    }

    private func experimentSymbol(
        _ outcome: IndoBoardCoachExperimentOutcome
    ) -> String {
        switch outcome {
        case .improved:
            return "checkmark.circle.fill"
        case .oppositeDirection:
            return "arrow.uturn.backward.circle.fill"
        case .noClearChange:
            return "equal.circle.fill"
        case .insufficientEvidence:
            return "questionmark.circle.fill"
        }
    }

    private func experimentColor(
        _ outcome: IndoBoardCoachExperimentOutcome
    ) -> Color {
        switch outcome {
        case .improved:
            return .green
        case .oppositeDirection:
            return .orange
        case .noClearChange:
            return .secondary
        case .insufficientEvidence:
            return .secondary
        }
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
        DisclosureGroup(
            "How measurements work",
            isExpanded: $showMeasurementDetails
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Raw Watch, camera, and operator evidence stays preserved. "
                        + "Live movement values are derived signals. Stronger "
                        + "biomechanics claims remain gated on calibration and "
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
            .padding(.top, 8)
        }
        .font(.subheadline.weight(.semibold))
        .tint(.secondary)
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
            },
            set: { enabled in
                session.captureMode = enabled
                    ? .multiviewCalibration
                    : .watchAndPhone
                // Selecting the source does not prove it is recording.
                // Require a separate operator confirmation after the camera
                // has actually been started.
                session.externalCameraConfirmed = false
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

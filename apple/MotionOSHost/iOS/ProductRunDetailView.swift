import Charts
import MotionOSAppleCapture
import SwiftUI

struct ProductRunDetailView: View {
    let run: ProductRunRecord

    @EnvironmentObject private var library: ProductRunLibrary

    @State private var perceivedStability = 3
    @State private var perceivedEffort = 3
    @State private var movementNotes = ""
    @State private var productNotes = ""
    @State private var coachUsefulness:
        ProductSessionCoachUsefulness?
    @State private var coachTriedCue: Bool?
    @State private var savedFeedback:
        ProductSessionFeedback?
    @State private var feedbackError: String?
    @State private var showTechnicalDetails = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                hero

                if let context = run.productManifest?.context {
                    sessionContext(context)
                }

                if run.cameraVideoURL != nil,
                   run.cameraJournalURL != nil {
                    replayEntry
                }

                if let summary = run.watchSummary {
                    watchSummary(summary)
                    MotionFingerprintCard(summary: summary)
                    PreviousRunComparisonCard(run: run)
                }

                if let coach = run.productManifest?.coachSummary {
                    coachSummary(coach)

                    if let previous = previousCoachSummary {
                        coachProgressCard(
                            current: coach,
                            previous: previous
                        )
                    }
                }

                feedback
                technicalDetailsControl

                if showTechnicalDetails {
                    sourceMap
                    protocolEvidence
                    evidence
                }
            }
            .motionOSPageWidth()
            .padding(.horizontal, MotionOSDesign.pageHorizontalPadding)
            .padding(.vertical, 12)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle(
            run.protocolKind == FieldProtocolKind.indoBoard.rawValue
                ? "Indo Board"
                : "Session"
        )
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadFeedback()
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(
                        cornerRadius: 16,
                        style: .continuous
                    )
                    .fill(
                        LinearGradient(
                            colors: [.indigo, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 54, height: 54)

                    Image(
                        systemName:
                            run.protocolKind
                                == FieldProtocolKind
                                    .indoBoard.rawValue
                                ? "figure.surfing"
                                : "figure.outdoor.cycle"
                    )
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayProtocolName(run.protocolKind))
                        .font(.title2.weight(.bold))

                    if let date = run.startedAt ?? run.sealedAt {
                        Text(
                            date.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                MotionOSStatusBadge(
                    title: run.outcome == .completed
                        ? "SAVED"
                        : "STOPPED EARLY",
                    systemImage: run.outcome == .completed
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill",
                    color: run.outcome == .completed
                        ? .green
                        : .yellow
                )
            }

            HStack(spacing: 8) {
                sessionSourcePill(
                    "Watch",
                    symbol: "applewatch",
                    ready: run.watchJournalURL != nil
                )
                sessionSourcePill(
                    "Video",
                    symbol: "video.fill",
                    ready: run.cameraVideoURL != nil
                )
                sessionSourcePill(
                    "Timing",
                    symbol: "clock.arrow.2.circlepath",
                    ready: run.syncComplete
                )
            }

            if run.outcome == .aborted {
                Text(
                    "This attempt is kept for review but excluded from "
                        + "longitudinal comparisons."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private func sessionContext(
        _ context: ProductSessionManifest.SessionContext
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MotionOSSectionHeader(
                title: "Session setup",
                subtitle: "Used to keep personal comparisons like-for-like",
                systemImage: "person.crop.circle",
                accent: .indigo
            )

            if let stance = context.dimensions["stance"] {
                HStack(spacing: 10) {
                    Image(systemName: "shoeprints.fill")
                        .foregroundStyle(.indigo)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Foot position")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(displayStance(stance))
                            .font(.subheadline.weight(.semibold))
                    }

                    Spacer()
                }

                if stance
                    == IndoBoardStancePreference
                        .variesOrUnsure.rawValue {
                    Text(
                        "This session is still saved normally. MotionOS should "
                            + "abstain from stance-specific personal comparisons "
                            + "until the setup is declared more precisely."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .cardStyle()
    }

    private func displayStance(
        _ raw: String
    ) -> String {
        IndoBoardStancePreference(rawValue: raw)?.title
            ?? raw
                .replacingOccurrences(of: "_", with: " ")
                .localizedCapitalized
    }

    private func sessionSourcePill(
        _ title: String,
        symbol: String,
        ready: Bool
    ) -> some View {
        Label(
            ready ? title : "\(title) pending",
            systemImage: ready
                ? "checkmark.circle.fill"
                : symbol
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(ready ? Color.green : Color.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            (ready ? Color.green : Color.secondary).opacity(0.07),
            in: RoundedRectangle(
                cornerRadius: 11,
                style: .continuous
            )
        )
    }

    private var technicalDetailsControl: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showTechnicalDetails.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Technical details")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(
                        "Sources, synchronization, protocol records, and "
                            + "provenance"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(
                    systemName: showTechnicalDetails
                        ? "chevron.up"
                        : "chevron.down"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
        .accessibilityLabel(
            showTechnicalDetails
                ? "Hide technical details"
                : "Show technical details"
        )
    }

    private var sourceMap: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Recording sources",
                subtitle: "Technical source and provenance status for this session",
                systemImage: "point.3.connected.trianglepath.dotted",
                accent: .cyan
            )

            sourceRow(
                "Session protocol",
                symbol: "list.clipboard.fill",
                ready: true,
                detail: "sealed"
            )
            sourceRow(
                "Apple Watch",
                symbol: "applewatch",
                ready: run.watchJournalURL != nil,
                detail: run.watchJournalURL != nil
                    ? "recording available"
                    : "waiting for sync"
            )
            sourceRow(
                "iPhone camera",
                symbol: "camera.fill",
                ready: run.cameraVideoURL != nil,
                detail: run.cameraVideoURL != nil
                    ? "video available"
                    : "not available"
            )
            sourceRow(
                "Action 4",
                symbol: "video.fill",
                ready: run.externalVideoURL != nil,
                detail: run.externalVideoURL != nil
                    ? (
                        run.externalPoseTrackURL != nil
                            ? "original + reviewed alignment + source pose"
                            : (
                                run.externalAlignmentURL != nil
                                    ? "original + reviewed alignment"
                                    : (
                                    run.externalSyncProposalURL != nil
                                        ? "original + sync proposal"
                                        : "original hash-bound"
                                )
                            )
                    )
                    : (
                        run.productManifest?.externalCameraExpected == true
                            ? "required · awaiting import"
                            : "optional / not imported"
                    )
            )

            Text(
                "These technical records keep each source traceable. Timing "
                    + "status is reported separately from source availability."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var replayEntry: some View {
        NavigationLink {
            ProductRunReplayView(run: run)
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(
                        cornerRadius: 14,
                        style: .continuous
                    )
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(0.16),
                                Color.indigo.opacity(0.10),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 50)

                    Image(systemName: "play.rectangle.fill")
                        .font(.title3)
                        .foregroundStyle(.cyan)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Replay movement")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(
                        run.externalPoseTrackURL != nil
                            ? "Action 4 source pose · synchronized 3D body"
                            : (
                                run.externalAlignmentURL != nil
                                    ? "iPhone + reviewed Action 4 timing · 3D body"
                                    : (
                                    run.externalVideoURL != nil
                                        ? "iPhone pose replay · Action 4 original available"
                                        : "Video · body · balance · coaching"
                                )
                            )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
    }

    private var protocolEvidence: some View {
        VStack(alignment: .leading, spacing: 10) {
            MotionOSSectionHeader(
                title: "Session timing details",
                subtitle:
                    "\(run.completedBlockIDs.count) blocks recorded · "
                    + "\(run.syncCueLabels.count) alignment gestures captured",
                systemImage: "list.number",
                accent: run.syncComplete ? .green : .yellow
            )

            if run.completedBlockIDs.isEmpty {
                Text("No completed protocol blocks were sealed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 7) {
                    ForEach(
                        run.completedBlockIDs,
                        id: \.self
                    ) { id in
                        Label(
                            humanize(id),
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            Color.green.opacity(0.08),
                            in: Capsule()
                        )
                    }
                }
            }
        }
        .cardStyle()
    }

    private func watchSummary(
        _ summary: WatchSessionSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Movement snapshot",
                subtitle: "Descriptive Watch signals from this session",
                systemImage: "waveform.path.ecg",
                accent: .indigo
            )

            HStack(spacing: 8) {
                summaryMetric(
                    "Duration",
                    duration(summary.imu.durationSeconds)
                )
                summaryMetric(
                    "Movement",
                    summary.motion.userAccelerationRMSG.map {
                        String(format: "%.2f g", $0)
                    } ?? "—"
                )
                summaryMetric(
                    "Heart",
                    summary.heartRate.meanBPM.map {
                        "\(Int($0.rounded()))"
                    } ?? "—"
                )
            }

            if !summary.trace.isEmpty {
                Chart(summary.trace, id: \.elapsedSeconds) {
                    point in
                    AreaMark(
                        x: .value(
                            "Time",
                            point.elapsedSeconds
                        ),
                        y: .value(
                            "User acceleration",
                            point.meanUserAccelerationG
                        )
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.indigo.opacity(0.24),
                                Color.cyan.opacity(0.02),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value(
                            "Time",
                            point.elapsedSeconds
                        ),
                        y: .value(
                            "User acceleration",
                            point.meanUserAccelerationG
                        )
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.indigo)
                }
                .chartXAxis {
                    AxisMarks(
                        values: .automatic(desiredCount: 4)
                    )
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 180)
            }

            Text(summary.claimBoundary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private var previousCoachSummary:
        ProductSessionManifest.CoachSummary? {
        let currentDate =
            run.sealedAt ?? run.startedAt ?? .distantFuture

        return library.runs.first { candidate in
            guard candidate.runID != run.runID,
                  candidate.protocolKind == run.protocolKind,
                  candidate.protocolVersion == run.protocolVersion,
                  let candidateDate =
                    candidate.sealedAt ?? candidate.startedAt,
                  candidateDate < currentDate,
                  candidate.productManifest?
                    .coachSummary?
                    .numericMetrics?
                    .isEmpty == false
            else {
                return false
            }
            return true
        }
        .flatMap { $0.productManifest?.coachSummary }
    }

    private func coachProgressCard(
        current: ProductSessionManifest.CoachSummary,
        previous: ProductSessionManifest.CoachSummary
    ) -> some View {
        let currentMetrics = current.numericMetrics ?? [:]
        let previousMetrics = previous.numericMetrics ?? [:]

        return VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Personal Progress",
                subtitle:
                    "Current session vs your previous comparable INDO BOARD capture",
                systemImage: "chart.line.uptrend.xyaxis",
                accent: .green
            )

            if let currentSpread =
                    currentMetrics["neutral_finish_spread"],
               let previousSpread =
                    previousMetrics["neutral_finish_spread"] {
                personalMetricRow(
                    title: "Neutral motion spread",
                    current: currentSpread,
                    previous: previousSpread,
                    format: "%.3f",
                    lowerIsQuieter: true
                )
            }

            if let currentChanges =
                    currentMetrics[
                        "correction_direction_changes"
                    ],
               let previousChanges =
                    previousMetrics[
                        "correction_direction_changes"
                    ] {
                personalMetricRow(
                    title: "Direction-change proxy",
                    current: currentChanges,
                    previous: previousChanges,
                    format: "%.0f",
                    lowerIsQuieter: true
                )
            }

            if let currentShift =
                    currentMetrics["controlled_shift_range"],
               let previousShift =
                    previousMetrics["controlled_shift_range"] {
                personalMetricRow(
                    title: "Controlled shift range",
                    current: currentShift,
                    previous: previousShift,
                    format: "%.3f",
                    lowerIsQuieter: false
                )
            }

            if let currentSquat =
                    currentMetrics["squat_flexion_p75_deg"],
               let previousSquat =
                    previousMetrics["squat_flexion_p75_deg"] {
                personalMetricRow(
                    title: "Squat flexion P75",
                    current: currentSquat,
                    previous: previousSquat,
                    format: "%.0f°",
                    lowerIsQuieter: false
                )
            }

            Text(
                "This is a within-person comparison, not a population score. "
                    + "Capture quality and camera placement can still affect these proxies."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private func personalMetricRow(
        title: String,
        current: Double,
        previous: Double,
        format: String,
        lowerIsQuieter: Bool
    ) -> some View {
        let change = current - previous
        let relative = abs(previous) > 1e-9
            ? change / abs(previous)
            : nil
        let icon: String
        let detail: String

        if lowerIsQuieter,
           let relative,
           abs(relative) >= 0.05 {
            icon = change < 0
                ? "arrow.down.right.circle.fill"
                : "arrow.up.right.circle.fill"
            detail = String(
                format: "%+.0f%%",
                relative * 100
            )
        } else {
            icon = "arrow.left.and.right.circle"
            detail = "compare"
        }

        return HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(
                    "was "
                        + String(format: format, previous)
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: format, current))
                    .font(
                        .system(
                            .caption,
                            design: .monospaced,
                            weight: .semibold
                        )
                    )
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func coachSummary(
        _ coach: ProductSessionManifest.CoachSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Experimental session cue",
                subtitle: coach.evidenceLabel,
                systemImage: "figure.mind.and.body",
                accent: .cyan
            )

            Text(coach.headline)
                .font(.title3.weight(.semibold))

            Text(coach.observation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let values = coach.numericMetrics,
               let sampleCount = values["board_sample_count"],
               let coverage =
                    values["board_state_coverage_fraction"],
               let confidence =
                    values["board_state_confidence"] {
                boardEvidenceRow(
                    sampleCount:
                        max(0, Int(sampleCount.rounded())),
                    coverage:
                        min(1, max(0, coverage)),
                    confidence:
                        min(1, max(0, confidence))
                )
            }

            if let outcome = coach.experimentOutcome,
               let summary = coach.experimentSummary {
                let improved = outcome == "improved"
                let opposite = outcome == "opposite_direction"

                HStack(alignment: .top, spacing: 9) {
                    Image(
                        systemName: improved
                            ? "checkmark.circle.fill"
                            : (
                                opposite
                                    ? "arrow.uturn.backward.circle.fill"
                                    : "equal.circle.fill"
                            )
                    )
                    .foregroundStyle(
                        improved
                            ? .green
                            : (opposite ? .orange : .secondary)
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            improved
                                ? "Target moved in the intended direction"
                                : (
                                    opposite
                                        ? "Target moved in the opposite direction"
                                        : "No clear change yet"
                                )
                        )
                        .font(.caption.weight(.bold))

                        Text(summary)
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
                    (
                        improved
                            ? Color.green
                            : (opposite ? Color.orange : Color.secondary)
                    )
                    .opacity(0.08),
                    in: RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("TRY NEXT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.cyan)
                Text(coach.tip)
                    .font(.subheadline.weight(.medium))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("REPEAT WITH")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.indigo)
                Text(coach.drill)
                    .font(.subheadline.weight(.semibold))
            }

            if !coach.metrics.isEmpty {
                Divider()
                ForEach(
                    coach.metrics.keys.sorted(),
                    id: \.self
                ) { key in
                    HStack {
                        Text(humanize(key))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(coach.metrics[key] ?? "—")
                            .font(
                                .system(
                                    .caption,
                                    design: .monospaced
                                )
                            )
                    }
                }
            }

            Text(
                "This is an experimental hypothesis from the earlier heuristic "
                    + "coach. It is not yet the reviewed personal baseline or "
                    + "session-delta interpretation. A later comparable attempt "
                    + "can test the cue, but the result is not automatically "
                    + "proof of improvement."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private func boardEvidenceRow(
        sampleCount: Int,
        coverage: Double,
        confidence: Double
    ) -> some View {
        let usable =
            sampleCount
                >= IndoBoardEvidenceQualityThresholds
                    .minimumSessionSamples
            && coverage
                >= IndoBoardEvidenceQualityThresholds
                    .minimumSessionCoverage
            && confidence
                >= IndoBoardEvidenceQualityThresholds
                    .minimumStateConfidence
        let accent: Color = usable ? .green : .yellow

        return HStack(spacing: 9) {
            Image(
                systemName:
                    usable
                        ? "checkmark.shield.fill"
                        : "viewfinder.circle"
            )
            .foregroundStyle(accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    usable
                        ? "Board-relative evidence usable"
                        : "Board tracking partial"
                )
                .font(.caption.weight(.bold))

                Text(
                    String(
                        format:
                            "%d samples · %.0f%% coverage · %.0f%% confidence",
                        sampleCount,
                        coverage * 100,
                        confidence * 100
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

            Spacer()
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

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 13) {
            MotionOSSectionHeader(
                title: "Your session context",
                subtitle: "Pair sensor evidence with what the session actually felt like",
                systemImage: "bubble.left.and.text.bubble.right",
                accent: .purple
            )

            if let savedFeedback {
                HStack(spacing: 8) {
                    feedbackBadge(
                        "Stability",
                        savedFeedback.perceivedStability
                    )
                    feedbackBadge(
                        "Effort",
                        savedFeedback.perceivedEffort
                    )
                }

                if !savedFeedback.movementNotes.isEmpty {
                    note(
                        "Movement",
                        savedFeedback.movementNotes
                    )
                }
                if !savedFeedback.productNotes.isEmpty {
                    note(
                        "Product",
                        savedFeedback.productNotes
                    )
                }

                if let triedCue = savedFeedback.coachTriedCue {
                    Label(
                        triedCue
                            ? "Watch cue tried"
                            : "Watch cue not tried",
                        systemImage: triedCue
                            ? "checkmark.circle.fill"
                            : "minus.circle"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        triedCue ? .green : .secondary
                    )
                }

                if let usefulness = savedFeedback.coachUsefulness {
                    Label(
                        "Coach feedback · \(usefulness.label)",
                        systemImage: usefulness == .helpful
                            ? "hand.thumbsup.fill"
                            : "bubble.left"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        usefulness == .helpful
                            ? .green
                            : .secondary
                    )
                }

                Text(savedFeedback.claimBoundary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                rating(
                    title: "Perceived stability",
                    value: $perceivedStability,
                    low: "wobbly",
                    high: "steady"
                )
                rating(
                    title: "Perceived effort",
                    value: $perceivedEffort,
                    low: "easy",
                    high: "hard"
                )

                TextField(
                    "Movement notes",
                    text: $movementNotes,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)

                TextField(
                    "App / workflow notes",
                    text: $productNotes,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)

                if run.productManifest?.coachSummary != nil {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("DID YOU TRY THE WATCH CUE?")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 7) {
                            Button {
                                coachTriedCue = true
                            } label: {
                                Text("Yes")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(
                                        coachTriedCue == true
                                            ? Color.green.opacity(0.16)
                                            : Color.primary.opacity(0.04),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)

                            Button {
                                coachTriedCue = false
                            } label: {
                                Text("No")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(
                                        coachTriedCue == false
                                            ? Color.orange.opacity(0.14)
                                            : Color.primary.opacity(0.04),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        Text("WAS THIS CUE USEFUL?")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)

                        FlowLayout(spacing: 6) {
                            ForEach(
                                ProductSessionCoachUsefulness.allCases
                            ) { option in
                                Button {
                                    coachUsefulness = option
                                } label: {
                                    Text(option.label)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 7)
                                        .background(
                                            coachUsefulness == option
                                                ? Color.cyan.opacity(0.16)
                                                : Color.primary.opacity(0.04),
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Button {
                    saveFeedback()
                } label: {
                    Label(
                        "Save Session Feedback",
                        systemImage: "square.and.arrow.down"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Text(
                    "These are self-reported context only. They do not become "
                        + "sensor ground truth or a qualification score."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if let feedbackError {
                Label(
                    feedbackError,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 10) {
            MotionOSSectionHeader(
                title: "Export",
                subtitle: "Preserve or inspect the complete local evidence bundle",
                systemImage: "square.and.arrow.up",
                accent: .green
            )

            if let summary = run.watchSummary {
                Text(
                    "Watch source "
                        + String(
                            summary.sourceJournalSHA256.prefix(16)
                        )
                        + "…"
                )
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            ShareLink(items: evidenceURLs) {
                Label(
                    "Share Available Run Evidence",
                    systemImage: "shippingbox.and.arrow.backward"
                )
            }
            .disabled(evidenceURLs.isEmpty)
        }
        .cardStyle()
    }

    private var evidenceURLs: [URL] {
        let reviewURL =
            ReplayReviewLedgerStore
                .url(for: run)
        let existingReviewURL =
            FileManager.default
                .fileExists(
                    atPath:
                        reviewURL.path
                )
                ? reviewURL
                : nil

        return [
            Optional(run.operatorJournalURL),
            Optional(run.operatorMetadataURL),
            run.productManifestURL,
            run.watchJournalURL,
            run.watchSummaryURL,
            run.cameraVideoURL,
            run.cameraJournalURL,
            run.cameraMetadataURL,
            run.externalVideoURL,
            run.externalMetadataURL,
            run.externalSyncProposalURL,
            run.externalAlignmentURL,
            run.externalPoseTrackURL,
            existingReviewURL,
            run.feedbackURL,
        ]
        .compactMap { $0 }
    }

    private func sourceRow(
        _ title: String,
        symbol: String,
        ready: Bool,
        detail: String
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(
                    ready ? .green : .secondary
                )
                .frame(width: 22)

            Text(title)
                .font(.subheadline)

            Spacer(minLength: 8)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)

            Image(
                systemName: ready
                    ? "checkmark.circle.fill"
                    : "circle"
            )
            .foregroundStyle(
                ready ? .green : .secondary
            )
        }
    }

    private func summaryMetric(
        _ label: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(
                    .system(
                        .subheadline,
                        design: .rounded,
                        weight: .semibold
                    )
                )
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rating(
        title: String,
        value: Binding<Int>,
        low: String,
        high: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(value.wrappedValue)/5")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { number in
                    Button {
                        value.wrappedValue = number
                    } label: {
                        Text("\(number)")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                value.wrappedValue == number
                                    ? Color.purple.opacity(0.16)
                                    : Color.primary.opacity(0.035),
                                in: RoundedRectangle(
                                    cornerRadius: 9,
                                    style: .continuous
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Text(low)
                Spacer()
                Text(high)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func feedbackBadge(
        _ title: String,
        _ value: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text("\(value)/5")
                .font(.title3.weight(.semibold))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.purple.opacity(0.06),
            in: RoundedRectangle(
                cornerRadius: 13,
                style: .continuous
            )
        )
    }

    private func note(
        _ title: String,
        _ text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
        }
    }

    private func saveFeedback() {
        let value = ProductSessionFeedback(
            runID: run.runID,
            perceivedStability: perceivedStability,
            perceivedEffort: perceivedEffort,
            movementNotes: movementNotes,
            productNotes: productNotes,
            coachUsefulness: coachUsefulness,
            coachTriedCue: coachTriedCue
        )

        do {
            _ = try ProductSessionFeedbackStore.write(
                value,
                to: run.directoryURL
            )
            savedFeedback = value
            feedbackError = nil
            library.refresh()
        } catch {
            feedbackError = error.localizedDescription
        }
    }

    private func loadFeedback() {
        guard let url = run.feedbackURL else {
            return
        }

        do {
            let value = try ProductSessionFeedbackStore.load(
                from: url
            )
            savedFeedback = value
            perceivedStability = value.perceivedStability
            perceivedEffort = value.perceivedEffort
            movementNotes = value.movementNotes
            productNotes = value.productNotes
            coachUsefulness = value.coachUsefulness
            coachTriedCue = value.coachTriedCue
        } catch {
            feedbackError = (
                "Saved feedback could not be read: "
                    + error.localizedDescription
            )
        }
    }

    private func displayProtocolName(
        _ raw: String
    ) -> String {
        if raw == FieldProtocolKind.indoBoard.rawValue {
            return "Indo Board"
        }
        return raw
            .replacingOccurrences(of: "_", with: " ")
            .localizedCapitalized
    }

    private func humanize(
        _ value: String
    ) -> String {
        value
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private func duration(
        _ seconds: Double
    ) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(
            format: "%d:%02d",
            total / 60,
            total % 60
        )
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    init(
        spacing: CGFloat = 8
    ) {
        self.spacing = spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(
            width: proposal.width ?? x,
            height: y + rowHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX
                && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

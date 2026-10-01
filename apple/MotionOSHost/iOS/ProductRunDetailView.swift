import Charts
import SwiftUI

struct ProductRunDetailView: View {
    let run: ProductRunRecord

    @EnvironmentObject private var library: ProductRunLibrary

    @State private var perceivedStability = 3
    @State private var perceivedEffort = 3
    @State private var movementNotes = ""
    @State private var productNotes = ""
    @State private var savedFeedback:
        ProductSessionFeedback?
    @State private var feedbackError: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                hero
                sourceMap
                protocolEvidence

                if let summary = run.watchSummary {
                    watchSummary(summary)
                }

                feedback
                evidence
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
                    Text(run.protocolKind)
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
                    title: "SEALED",
                    systemImage: "checkmark.seal.fill",
                    color: .green
                )
            }

            Text(run.runID)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                MotionOSStatusBadge(
                    title: "\(run.sourceCount) sources",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    color: .indigo
                )
                MotionOSStatusBadge(
                    title: run.syncComplete
                        ? "3/3 sync"
                        : "\(run.syncCueLabels.count)/3 sync",
                    systemImage: run.syncComplete
                        ? "checkmark.shield.fill"
                        : "waveform.path",
                    color: run.syncComplete
                        ? .green
                        : .yellow
                )
                if run.failureNoteCount > 0 {
                    MotionOSStatusBadge(
                        title: "\(run.failureNoteCount) notes",
                        systemImage: "exclamationmark.bubble",
                        color: .yellow
                    )
                }
            }
        }
        .cardStyle()
    }

    private var sourceMap: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Evidence map",
                subtitle: "Independent source artifacts linked through this run",
                systemImage: "point.3.connected.trianglepath.dotted",
                accent: .cyan
            )

            sourceRow(
                "Operator protocol",
                symbol: "list.clipboard.fill",
                ready: true,
                detail: "sealed"
            )
            sourceRow(
                "Apple Watch",
                symbol: "applewatch",
                ready: run.watchJournalURL != nil,
                detail: run.watchJournalURL != nil
                    ? "journal recovered"
                    : "awaiting journal"
            )
            sourceRow(
                "iPhone camera",
                symbol: "camera.fill",
                ready: run.cameraVideoURL != nil,
                detail: run.cameraVideoURL != nil
                    ? "video + frame evidence"
                    : "not linked"
            )
            sourceRow(
                "Action 4",
                symbol: "video.fill",
                ready: run.externalVideoURL != nil,
                detail: run.externalVideoURL != nil
                    ? "original hash-bound"
                    : "optional / not imported"
            )

            Text(
                "Sources remain independent. This screen is a provenance "
                    + "map, not proof that their clocks are fully synchronized."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var protocolEvidence: some View {
        VStack(alignment: .leading, spacing: 10) {
            MotionOSSectionHeader(
                title: "Protocol evidence",
                subtitle:
                    "\(run.completedBlockIDs.count) blocks complete · "
                    + "\(run.syncCueLabels.count) Watch-backed sync cues",
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
                title: "Watch movement trace",
                subtitle:
                    String(
                        format: "%.1f Hz · %.0f ms max gap",
                        summary.imu.effectiveHz,
                        summary.imu.maxGapMS
                    ),
                systemImage: "waveform.path.ecg",
                accent: .indigo
            )

            HStack(spacing: 8) {
                summaryMetric(
                    "Duration",
                    duration(summary.imu.durationSeconds)
                )
                summaryMetric(
                    "Accel RMS",
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
        [
            Optional(run.operatorJournalURL),
            Optional(run.operatorMetadataURL),
            run.watchJournalURL,
            run.watchSummaryURL,
            run.cameraVideoURL,
            run.cameraJournalURL,
            run.cameraMetadataURL,
            run.externalVideoURL,
            run.externalMetadataURL,
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
            productNotes: productNotes
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
        } catch {
            feedbackError = (
                "Saved feedback could not be read: "
                    + error.localizedDescription
            )
        }
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

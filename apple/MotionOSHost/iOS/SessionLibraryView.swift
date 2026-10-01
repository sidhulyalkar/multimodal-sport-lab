import MotionOSAppleCapture
import Charts
import SwiftUI

struct SessionLibraryView: View {
    @EnvironmentObject private var inbox: PhoneJournalInbox
    @EnvironmentObject private var runLibrary: ProductRunLibrary

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                header

                if let latestRun = runLibrary.runs.first {
                    latestRunSnapshot(latestRun)
                } else if let latest = inbox.latestSessionSummary {
                    latestSnapshot(latest)
                }

                MovementTrendsCard()
                productRuns
                library
            }
            .motionOSPageWidth()
            .padding(.horizontal, MotionOSDesign.pageHorizontalPadding)
            .padding(.top, 10)
            .padding(.bottom, 36)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            inbox.refreshCatalog()
            runLibrary.refresh()
        }
        .task {
            inbox.refreshCatalog()
            runLibrary.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sessions")
                        .font(.largeTitle.weight(.bold))
                    Text(
                        "Your sealed movement evidence, summaries, and "
                            + "progression trail."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.indigo.opacity(0.10))
                        .frame(width: 46, height: 46)
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3)
                        .foregroundStyle(.indigo)
                }
            }

            HStack(spacing: 8) {
                MotionOSStatusBadge(
                    title: "\(completedRunCount) complete",
                    systemImage: "checkmark.seal",
                    color: completedRunCount == 0
                        ? .secondary
                        : .green
                )

                if abortedRunCount > 0 {
                    MotionOSStatusBadge(
                        title: "\(abortedRunCount) aborted",
                        systemImage: "exclamationmark.triangle",
                        color: .yellow
                    )
                }
                MotionOSStatusBadge(
                    title: "\(inbox.sessions.count) Watch",
                    systemImage: "applewatch",
                    color: inbox.sessions.isEmpty
                        ? .secondary
                        : .indigo
                )

                if inbox.catalogLoading {
                    MotionOSStatusBadge(
                        title: "Refreshing",
                        systemImage: "arrow.clockwise",
                        color: .yellow
                    )
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private func latestRunSnapshot(
        _ run: ProductRunRecord
    ) -> some View {
        NavigationLink {
            ProductRunDetailView(run: run)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    MotionOSSectionHeader(
                        title: run.outcome == .completed
                            ? "Latest complete run"
                            : "Latest aborted attempt",
                        subtitle: run.protocolKind,
                        systemImage: run.outcome == .completed
                            ? "figure.surfing"
                            : "exclamationmark.triangle.fill",
                        accent: run.outcome == .completed
                            ? .indigo
                            : .yellow
                    )

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    snapshotMetric(
                        "SOURCES",
                        "\(run.sourceCount)/\(run.expectedSourceCount)",
                        "point.3.connected.trianglepath.dotted"
                    )
                    snapshotMetric(
                        "SYNC",
                        run.syncComplete
                            ? "3/3"
                            : "\(run.syncCueLabels.count)/3",
                        "waveform.path"
                    )
                    snapshotMetric(
                        "WATCH",
                        run.watchSummary.map {
                            String(
                                format: "%.1f Hz",
                                $0.imu.effectiveHz
                            )
                        } ?? "pending",
                        "applewatch"
                    )
                }

                if let summary = run.watchSummary,
                   !summary.trace.isEmpty {
                    Chart(
                        Array(summary.trace.suffix(36)),
                        id: \.elapsedSeconds
                    ) { point in
                        AreaMark(
                            x: .value(
                                "Elapsed",
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
                                    Color.indigo.opacity(0.22),
                                    Color.cyan.opacity(0.02),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value(
                                "Elapsed",
                                point.elapsedSeconds
                            ),
                            y: .value(
                                "User acceleration",
                                point.meanUserAccelerationG
                            )
                        )
                        .foregroundStyle(.indigo)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 88)
                }
            }
            .foregroundStyle(.primary)
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    private func latestSnapshot(
        _ summary: WatchSessionSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Latest capture",
                subtitle: "A quick read from the latest sealed Watch journal",
                systemImage: "waveform.path.ecg.rectangle",
                accent: .indigo
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    snapshotMetric(
                        "DURATION",
                        duration(summary.imu.durationSeconds),
                        "timer"
                    )
                    snapshotMetric(
                        "IMU",
                        String(format: "%.1f Hz", summary.imu.effectiveHz),
                        "waveform.path"
                    )
                    snapshotMetric(
                        "HR",
                        summary.heartRate.meanBPM.map {
                            "\(Int($0.rounded())) bpm"
                        } ?? "—",
                        "heart.fill"
                    )
                }

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        snapshotMetric(
                            "DURATION",
                            duration(summary.imu.durationSeconds),
                            "timer"
                        )
                        snapshotMetric(
                            "IMU",
                            String(
                                format: "%.1f Hz",
                                summary.imu.effectiveHz
                            ),
                            "waveform.path"
                        )
                    }
                    snapshotMetric(
                        "HR",
                        summary.heartRate.meanBPM.map {
                            "\(Int($0.rounded())) bpm"
                        } ?? "—",
                        "heart.fill"
                    )
                }
            }

            if !summary.trace.isEmpty {
                Chart(
                    Array(summary.trace.suffix(36)),
                    id: \.elapsedSeconds
                ) { point in
                    AreaMark(
                        x: .value(
                            "Elapsed",
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
                                Color.indigo.opacity(0.22),
                                Color.cyan.opacity(0.02),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value(
                            "Elapsed",
                            point.elapsedSeconds
                        ),
                        y: .value(
                            "User acceleration",
                            point.meanUserAccelerationG
                        )
                    )
                    .foregroundStyle(.indigo)
                    .lineStyle(
                        .init(
                            lineWidth: 2,
                            lineCap: .round
                        )
                    )
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 90)
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var productRuns: some View {
        if !runLibrary.runs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                MotionOSSectionHeader(
                    title: "Product sessions",
                    subtitle: "Completed runs and inspectable aborted attempts",
                    systemImage: "figure.surfing",
                    accent: .indigo
                )

                ForEach(runLibrary.runs) { run in
                    NavigationLink {
                        ProductRunDetailView(run: run)
                    } label: {
                        productRunRow(run)
                    }
                    .buttonStyle(.plain)

                    if run.id != runLibrary.runs.last?.id {
                        Divider()
                    }
                }
            }
            .cardStyle()
        }
    }

    private func productRunRow(
        _ run: ProductRunRecord
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: 13,
                    style: .continuous
                )
                .fill(
                    LinearGradient(
                        colors: [
                            Color.indigo.opacity(0.15),
                            Color.cyan.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 48, height: 48)

                Image(
                    systemName:
                        run.protocolKind
                            == FieldProtocolKind.indoBoard.rawValue
                            ? "figure.surfing"
                            : "figure.outdoor.cycle"
                )
                .foregroundStyle(.indigo)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(run.protocolKind)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    if run.outcome == .aborted {
                        Text("ABORTED")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.yellow)
                    }
                }

                HStack(spacing: 5) {
                    if let date = run.startedAt ?? run.sealedAt {
                        Text(date, style: .date)
                    }
                    Text("·")
                    Text(run.captureModeLabel)
                    Text("·")
                    Text("\(run.sourceCount)/\(run.expectedSourceCount) sources")
                    Text("·")
                    Text(
                        run.syncComplete
                            ? "3/3 sync"
                            : "\(run.syncCueLabels.count)/3 sync"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 7) {
                    sourceDot(
                        "Watch",
                        present: run.watchJournalURL != nil
                    )
                    sourceDot(
                        "Camera",
                        present: run.cameraVideoURL != nil
                    )
                    if run.externalVideoURL != nil {
                        sourceDot(
                            "Action 4",
                            present: true
                        )
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var completedRunCount: Int {
        runLibrary.runs.filter {
            $0.outcome == .completed
        }.count
    }

    private var abortedRunCount: Int {
        runLibrary.runs.filter {
            $0.outcome == .aborted
        }.count
    }

    private func sourceDot(
        _ title: String,
        present: Bool
    ) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(present ? Color.green : Color.secondary)
                .frame(width: 5, height: 5)
            Text(title)
        }
        .font(.caption2)
        .foregroundStyle(
            present ? .secondary : .tertiary
        )
    }

    @ViewBuilder
    private var library: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                MotionOSSectionHeader(
                    title: "Watch captures",
                    subtitle: "Raw recovered wrist sessions, including qualification runs",
                    systemImage: "square.stack.3d.up.fill",
                    accent: .cyan
                )

                Spacer(minLength: 0)
            }

            if inbox.sessions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.largeTitle)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.indigo, .cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Text("No sealed sessions yet")
                        .font(.headline)
                    Text(
                        "Complete your first Watch or Indo Board capture "
                            + "and MotionOS will build the library here."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(inbox.sessions) { item in
                    NavigationLink {
                        RecoveredSessionDetailView(session: item)
                    } label: {
                        sessionRow(item)
                    }
                    .buttonStyle(.plain)

                    if item.id != inbox.sessions.last?.id {
                        Divider()
                    }
                }
            }
        }
        .cardStyle()
    }

    private func sessionRow(
        _ item: RecoveredWatchSession
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: 13,
                    style: .continuous
                )
                .fill(
                    LinearGradient(
                        colors: [
                            Color.indigo.opacity(0.14),
                            Color.cyan.opacity(0.09),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 48, height: 48)

                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.indigo)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(sessionTitle(item))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let date = item.receivedAt {
                        Text(date, style: .date)
                    }
                    if let duration =
                        item.summary?.imu.durationSeconds {
                        Text("·")
                        Text(self.duration(duration))
                    }
                    if let hz = item.summary?.imu.effectiveHz {
                        Text("·")
                        Text(String(format: "%.1f Hz", hz))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let summary = item.summary {
                    continuityLabel(summary)
                } else {
                    Text("Raw evidence recovered")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func continuityLabel(
        _ summary: WatchSessionSummary
    ) -> some View {
        let clean = summary.imu.missingSequences == 0
            && summary.imu.nonMonotonicSequences == 0
            && summary.imu.nonMonotonicTimestamps == 0

        Label(
            clean
                ? "Continuity clean"
                : "Continuity needs review",
            systemImage: clean
                ? "checkmark.shield.fill"
                : "exclamationmark.triangle.fill"
        )
        .font(.caption2)
        .foregroundStyle(clean ? .green : .yellow)
    }

    private func snapshotMetric(
        _ label: String,
        _ value: String,
        _ symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(
                cornerRadius: 13,
                style: .continuous
            )
        )
    }

    private func sessionTitle(
        _ item: RecoveredWatchSession
    ) -> String {
        if item.sessionID.contains("smoke-watch") {
            return "Watch Sensor Check"
        }
        if item.sessionID.contains("p0-watch") {
            return "Watch Capture"
        }
        return "Movement Session"
    }

    private func duration(
        _ seconds: Double
    ) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 {
            return String(
                format: "%d:%02d:%02d",
                total / 3600,
                (total % 3600) / 60,
                total % 60
            )
        }
        return String(
            format: "%d:%02d",
            total / 60,
            total % 60
        )
    }
}

private struct RecoveredSessionDetailView: View {
    let session: RecoveredWatchSession

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inbox: PhoneJournalInbox
    @EnvironmentObject private var runLibrary: ProductRunLibrary
    @State private var signal = Signal.acceleration
    @State private var confirmDelete = false

    enum Signal: String, CaseIterable, Identifiable {
        case acceleration = "Acceleration"
        case rotation = "Rotation"

        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                identity

                if let summary = session.summary {
                    metrics(summary)
                    chart(summary)
                    integrity(summary)
                } else {
                    Label(
                        "Derived summary has not been generated for this session.",
                        systemImage: "waveform.slash"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .cardStyle()
                }

                evidence
            }
            .motionOSPageWidth()
            .padding(.horizontal, MotionOSDesign.pageHorizontalPadding)
            .padding(.vertical, 12)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MotionOSMark(size: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Recovered session")
                        .font(.title3.weight(.bold))
                    if let date = session.receivedAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                MotionOSStatusBadge(
                    title: "SEALED",
                    systemImage: "checkmark.seal.fill",
                    color: .green
                )
            }

            Text(session.sessionID)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .cardStyle()
    }

    private func metrics(
        _ summary: WatchSessionSummary
    ) -> some View {
        Grid(
            alignment: .leading,
            horizontalSpacing: 8,
            verticalSpacing: 8
        ) {
            GridRow {
                metric(
                    "Duration",
                    formatDuration(summary.imu.durationSeconds),
                    "timer"
                )
                metric(
                    "IMU rate",
                    String(
                        format: "%.1f Hz",
                        summary.imu.effectiveHz
                    ),
                    "waveform.path"
                )
            }
            GridRow {
                metric(
                    "User accel RMS",
                    summary.motion.userAccelerationRMSG.map {
                        String(format: "%.2f g", $0)
                    } ?? "—",
                    "figure.run"
                )
                metric(
                    "Mean HR",
                    summary.heartRate.meanBPM.map {
                        "\(Int($0.rounded())) bpm"
                    } ?? "—",
                    "heart.fill"
                )
            }
        }
        .cardStyle()
    }

    private func chart(
        _ summary: WatchSessionSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Signal", selection: $signal) {
                ForEach(Signal.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)

            Chart(summary.trace, id: \.elapsedSeconds) { point in
                switch signal {
                case .acceleration:
                    LineMark(
                        x: .value("Time", point.elapsedSeconds),
                        y: .value(
                            "User acceleration",
                            point.meanUserAccelerationG
                        )
                    )
                    .foregroundStyle(.indigo)
                    .interpolationMethod(.catmullRom)

                case .rotation:
                    LineMark(
                        x: .value("Time", point.elapsedSeconds),
                        y: .value(
                            "Rotation",
                            point.meanRotationRateRadS
                        )
                    )
                    .foregroundStyle(.cyan)
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                        .foregroundStyle(.secondary.opacity(0.08))
                    AxisValueLabel {
                        if let seconds = value.as(Double.self) {
                            Text(formatDuration(seconds))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 220)
        }
        .cardStyle()
    }

    private func integrity(
        _ summary: WatchSessionSummary
    ) -> some View {
        let clean = summary.imu.missingSequences == 0
            && summary.imu.nonMonotonicSequences == 0
            && summary.imu.nonMonotonicTimestamps == 0

        return VStack(alignment: .leading, spacing: 10) {
            MotionOSSectionHeader(
                title: clean
                    ? "Stream continuity clean"
                    : "Continuity review",
                subtitle: String(
                    format: "Maximum IMU gap %.0f ms",
                    summary.imu.maxGapMS
                ),
                systemImage: clean
                    ? "checkmark.shield.fill"
                    : "exclamationmark.triangle.fill",
                accent: clean ? .green : .yellow
            )

            HStack(spacing: 8) {
                tinyMetric(
                    "missing",
                    summary.imu.missingSequences
                )
                tinyMetric(
                    "sequence rev.",
                    summary.imu.nonMonotonicSequences
                )
                tinyMetric(
                    "time rev.",
                    summary.imu.nonMonotonicTimestamps
                )
            }

            Text(summary.claimBoundary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 10) {
            MotionOSSectionHeader(
                title: "Evidence",
                subtitle: "Raw journal first, derived summary second",
                systemImage: "lock.doc.fill",
                accent: .green
            )

            if let hash = session.journalSHA256 {
                Text("SHA-256  \(hash)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            let urls = [
                Optional(session.journalURL),
                session.hostMetadataURL,
                session.summaryURL,
            ].compactMap { $0 }

            ShareLink(items: urls) {
                Label(
                    "Share session evidence",
                    systemImage: "square.and.arrow.up"
                )
            }

            Divider()

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label(
                    "Delete Recording",
                    systemImage: "trash"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if session.productRunID != nil {
                Text(
                    "This Watch recording is linked to a product session. "
                        + "Deleting it keeps the rest of that session but removes "
                        + "its Watch evidence."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
        .confirmationDialog(
            "Delete this recording?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Recording", role: .destructive) {
                if inbox.deleteSession(session) {
                    runLibrary.refresh()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently removes the recovered Watch recording "
                    + "from this iPhone."
            )
        }
    }

    private func metric(
        _ title: String,
        _ value: String,
        _ symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title.uppercased(), systemImage: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(
                cornerRadius: 14,
                style: .continuous
            )
        )
    }

    private func tinyMetric(
        _ label: String,
        _ value: UInt64
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(.body, design: .monospaced, weight: .semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatDuration(
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

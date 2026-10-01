import MotionOSAppleCapture
import SwiftUI

/// A deliberately secondary engineering surface for physical qualification.
/// The primary MotionOS UI stays athlete-facing; this page turns a capture
/// into a small, exportable systems experiment.
struct SystemsLabView: View {
    @EnvironmentObject private var phone: PhoneSessionCoordinator

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            List {
                Section {
                    experimentHeader(at: context.date)
                }

                if let report = activeReport {
                    Section("Sensing") {
                        DiagnosticRow(
                            "IMU samples",
                            report.imuSamplesObserved.map(String.init)
                                ?? "collecting"
                        )
                        DiagnosticRow(
                            "Mean IMU rate",
                            report.meanEffectiveIMUHz.map {
                                String(format: "%.2f Hz", $0)
                            } ?? "collecting"
                        )
                        DiagnosticRow(
                            "Minimum IMU rate",
                            report.minimumEffectiveIMUHz.map {
                                String(format: "%.2f Hz", $0)
                            } ?? "collecting"
                        )
                        DiagnosticRow(
                            "Maximum IMU gap",
                            String(
                                format: "%.1f ms",
                                report.maximumIMUGapMS
                            )
                        )
                        DiagnosticRow(
                            "Non-monotonic Δ",
                            report.nonMonotonicIMUIncrease.map(String.init)
                                ?? "collecting"
                        )
                    }

                    Section("Live preview") {
                        DiagnosticRow(
                            "Packets received",
                            "\(report.telemetryPacketsReceived)"
                        )
                        DiagnosticRow(
                            "Sequence gaps",
                            "\(report.telemetrySequenceGaps)"
                        )
                        DiagnosticRow(
                            "Duplicate / late",
                            "\(report.telemetryDuplicates) / "
                                + "\(report.telemetryOutOfOrder)"
                        )
                        DiagnosticRow(
                            "Preview coverage",
                            report.previewCoverageFraction.map {
                                String(format: "%.0f%%", $0 * 100)
                            } ?? "collecting"
                        )
                    }

                    Section("Power") {
                        DiagnosticRow(
                            "Watch battery",
                            batterySpan(
                                report.watchBatteryStartFraction,
                                report.watchBatteryEndFraction
                            )
                        )
                        DiagnosticRow(
                            "iPhone battery",
                            batterySpan(
                                report.phoneBatteryStartFraction,
                                report.phoneBatteryEndFraction
                            )
                        )
                        DiagnosticRow(
                            "Watch slope",
                            report.observedWatchBatteryDropPerHour.map {
                                String(
                                    format: "%.1f%% / hour",
                                    $0 * 100
                                )
                            } ?? "run ≥10 min for estimate"
                        )
                    }

                    Section("Evidence") {
                        DiagnosticRow(
                            "Session",
                            shortSessionID(report.sessionID)
                        )
                        DiagnosticRow(
                            "Duration",
                            durationText(
                                report: report,
                                now: context.date
                            )
                        )
                        DiagnosticRow(
                            "Journal",
                            report.journalByteCount.map {
                                ByteCountFormatter.string(
                                    fromByteCount: Int64($0),
                                    countStyle: .file
                                )
                            } ?? "waiting for verified transfer"
                        )
                        DiagnosticRow(
                            "Transfer latency",
                            report.transferLatencySeconds.map {
                                String(format: "%.1f s", $0)
                            } ?? "waiting"
                        )
                        DiagnosticRow(
                            "SHA-256",
                            report.journalSHA256.map {
                                String($0.prefix(12)) + "…"
                            } ?? "waiting"
                        )

                        if let url =
                            phone.systemsLabReportURLs[report.sessionID],
                           report.endedAt != nil {
                            ShareLink(item: url) {
                                Label(
                                    "Share qualification report",
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                        }
                    }
                } else {
                    Section {
                        ContentUnavailableView(
                            "No qualification run yet",
                            systemImage: "waveform.path.ecg.rectangle",
                            description: Text(
                                "Start a Watch Sensor Check or coordinated "
                                    + "capture. MotionOS will measure sensing, "
                                    + "preview delivery, battery change, and "
                                    + "verified journal transfer automatically."
                            )
                        )
                    }
                }

                Section("Physical protocol") {
                    protocolRow(
                        "1",
                        "Open Watch + iPhone",
                        "Confirm Watch ready and two-way app detection."
                    )
                    protocolRow(
                        "2",
                        "Record 2–5 minutes",
                        "Move, hold still, pause, then resume."
                    )
                    protocolRow(
                        "3",
                        "Interrupt the live link",
                        "Lock/background the iPhone. Watch recording must continue."
                    )
                    protocolRow(
                        "4",
                        "Restore",
                        "Observatory should reconnect using fresh packets only."
                    )
                    protocolRow(
                        "5",
                        "Stop and repeat",
                        "Journal should verify, then a second capture should start immediately."
                    )
                    protocolRow(
                        "6",
                        "Run 30 minutes",
                        "Use a longer run for a meaningful battery-drain estimate."
                    )
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Systems Lab")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var activeReport: SystemsLabQualificationReport? {
        if let current = phone.systemsLabCurrentReport,
           current.endedAt == nil {
            return current
        }
        return phone.systemsLabLatestCompletedReport
            ?? phone.systemsLabCurrentReport
    }

    @ViewBuilder
    private func experimentHeader(
        at date: Date
    ) -> some View {
        if let report = activeReport {
            HStack(spacing: 12) {
                Image(
                    systemName: report.endedAt == nil
                        ? "waveform.path.ecg"
                        : "checkmark.seal.fill"
                )
                .font(.title2)
                .foregroundStyle(
                    report.endedAt == nil
                        ? Color.green
                        : Color.blue
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        report.endedAt == nil
                            ? "Qualification recording"
                            : (
                                report.journalReceivedAt == nil
                                    ? "Recording complete"
                                    : "Evidence verified"
                            )
                    )
                    .font(.headline)

                    Text(
                        report.endedAt == nil
                            ? durationText(report: report, now: date)
                            : "Software metrics from the latest physical run"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private func protocolRow(
        _ number: String,
        _ title: String,
        _ detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(
                    Color.secondary.opacity(0.12),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func batterySpan(
        _ start: Double?,
        _ end: Double?
    ) -> String {
        guard let start else { return "unavailable" }
        if let end {
            return String(
                format: "%.0f%% → %.0f%%",
                start * 100,
                end * 100
            )
        }
        return String(format: "%.0f%%", start * 100)
    }

    private func durationText(
        report: SystemsLabQualificationReport,
        now: Date
    ) -> String {
        let end = report.endedAt ?? now
        let seconds = max(
            0,
            Int(end.timeIntervalSince(report.startedAt))
        )
        return String(
            format: "%02d:%02d",
            seconds / 60,
            seconds % 60
        )
    }

    private func shortSessionID(
        _ value: String
    ) -> String {
        if value.count <= 20 {
            return value
        }
        return String(value.prefix(8))
            + "…"
            + String(value.suffix(8))
    }
}

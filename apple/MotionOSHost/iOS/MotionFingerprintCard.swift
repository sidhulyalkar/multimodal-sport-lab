import Charts
import MotionOSAppleCapture
import SwiftUI

struct MotionFingerprintCard: View {
    let summary: WatchSessionSummary

    private var points: [WatchSessionTracePoint] {
        summary.trace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            MotionOSSectionHeader(
                title: "Motion fingerprint",
                subtitle: "How wrist acceleration and rotation co-varied through the sealed session",
                systemImage: "sparkles.rectangle.stack",
                accent: .cyan
            )

            if points.count >= 2 {
                Chart {
                    ForEach(
                        Array(points.enumerated()),
                        id: \.offset
                    ) { index, point in
                        LineMark(
                            x: .value(
                                "User acceleration",
                                point.meanUserAccelerationG
                            ),
                            y: .value(
                                "Rotation",
                                point.meanRotationRateRadS
                            ),
                            series: .value("Session", "motion")
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(
                            .init(
                                lineWidth: 1.6,
                                lineCap: .round
                            )
                        )
                        .foregroundStyle(
                            Color.indigo.opacity(0.55)
                        )

                        PointMark(
                            x: .value(
                                "User acceleration",
                                point.meanUserAccelerationG
                            ),
                            y: .value(
                                "Rotation",
                                point.meanRotationRateRadS
                            )
                        )
                        .symbolSize(
                            index == points.count - 1
                                ? 58
                                : 24
                        )
                        .foregroundStyle(
                            index == points.count - 1
                                ? Color.cyan
                                : Color.indigo.opacity(0.42)
                        )
                    }
                }
                .chartXAxisLabel("user acceleration · g")
                .chartYAxisLabel("rotation · rad/s")
                .chartXAxis {
                    AxisMarks {
                        AxisGridLine()
                            .foregroundStyle(
                                .secondary.opacity(0.08)
                            )
                        AxisValueLabel()
                            .font(.system(size: 9))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine()
                            .foregroundStyle(
                                .secondary.opacity(0.08)
                            )
                        AxisValueLabel()
                            .font(.system(size: 9))
                    }
                }
                .frame(height: 220)

                HStack(spacing: 8) {
                    fingerprintMetric(
                        "ACCEL P95",
                        summary.motion.userAccelerationP95G.map {
                            String(format: "%.2f g", $0)
                        } ?? "—"
                    )
                    fingerprintMetric(
                        "ROT P95",
                        summary.motion.rotationRateP95RadS.map {
                            String(format: "%.2f rad/s", $0)
                        } ?? "—"
                    )
                    fingerprintMetric(
                        "TRACE",
                        "\(points.count) bins"
                    )
                }
            } else {
                Label(
                    "More trace samples are needed for a motion fingerprint.",
                    systemImage: "waveform.path"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text(
                "This phase portrait is a descriptive signature of Watch motion "
                    + "for this task. Its shape is not a performance score and "
                    + "is not a calibrated estimate of whole-body balance."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private func fingerprintMetric(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(
                    .system(
                        .caption,
                        design: .rounded,
                        weight: .semibold
                    )
                )
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.cyan.opacity(0.055),
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
    }
}

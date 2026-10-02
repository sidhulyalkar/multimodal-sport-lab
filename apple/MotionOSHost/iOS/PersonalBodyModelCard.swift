import MotionOSAppleCapture
import SwiftUI

struct PersonalBodyModelCard: View {
    @EnvironmentObject private var bodyModels: PersonalBodyModelCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            MotionOSSectionHeader(
                title: "Personal body model",
                subtitle: subtitle,
                systemImage: "person.crop.rectangle",
                accent: .cyan
            )

            if let model = bodyModels.latestModel {
                HStack(spacing: 8) {
                    metricTile(
                        "VERSION",
                        shortVersion(model.versionID)
                    )
                    metricTile(
                        "PARAMETERS",
                        "\(model.parameters.count)"
                    )
                    metricTile(
                        "CALIBRATED",
                        model.calibratedAt.formatted(
                            .dateTime.month(.abbreviated).day()
                        )
                    )
                }

                if let result = bodyModels.latestCalibrationResult {
                    Text(
                        "\(result.acceptedFrames) complete Vision frames contributed "
                            + "to this calibration."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                NavigationLink {
                    GuidedBodyCalibrationView()
                } label: {
                    Label(
                        "Recalibrate Body",
                        systemImage: "viewfinder"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let url = bodyModels.latestModelURL() {
                    ShareLink(item: url) {
                        Label(
                            "Export body model",
                            systemImage: "square.and.arrow.up"
                        )
                        .font(.caption.weight(.semibold))
                    }
                }
            } else {
                Text(
                    "Create a stable versioned body rig from a guided 40-second "
                        + "iPhone Vision capture. MotionOS will use this geometry "
                        + "as the persistent body underneath future movement scenes."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                NavigationLink {
                    GuidedBodyCalibrationView()
                } label: {
                    Label(
                        "Calibrate My Body",
                        systemImage: "viewfinder.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.cyan)
            }

            Text(
                "Geometry changes only through explicit recalibration. Daily "
                    + "weight or body-composition readings never silently reshape "
                    + "the model."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)

            if let error = bodyModels.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .cardStyle()
    }

    private var subtitle: String {
        if bodyModels.latestModel == nil {
            return "Not calibrated yet"
        }
        return "Versioned stable geometry for movement rendering"
    }

    private func metricTile(
        _ label: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
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
                .minimumScaleFactor(0.68)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
    }

    private func shortVersion(
        _ value: String
    ) -> String {
        if value.count <= 16 {
            return value
        }
        return String(value.prefix(12)) + "…"
    }
}

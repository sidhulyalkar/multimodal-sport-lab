import SwiftUI

struct FitnessChallengesCard: View {
    let mobilityAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Characterize more",
                subtitle: "Standardized challenges add comparable evidence",
                systemImage: "target",
                accent: .orange
            )

            NavigationLink {
                PowerChallengeView()
            } label: {
                challengeRow(
                    title: "Power challenge",
                    detail: "3 standardized jumps · Vision kinematic proxies",
                    symbol: "figure.jumprope",
                    tint: .orange,
                    status: "READY"
                )
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.leading, 42)

            if mobilityAvailable {
                NavigationLink {
                    MobilityChallengeView()
                } label: {
                    challengeRow(
                        title: "Mobility challenge",
                        detail: "Guided Vision pose envelope · 40 seconds",
                        symbol: "figure.flexibility",
                        tint: .purple,
                        status: "READY"
                    )
                }
                .buttonStyle(.plain)
            } else {
                challengeRow(
                    title: "Mobility challenge",
                    detail: "Guided movement envelope · next protocol",
                    symbol: "figure.flexibility",
                    tint: .secondary,
                    status: "SOON"
                )
            }

            Text(
                "Completing a challenge increases evidence coverage. It does not "
                    + "award an arbitrary fitness score."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private func challengeRow(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        status: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(
                    tint == .secondary
                        ? Color.secondary
                        : tint
                )
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(status)
                .font(.caption2.weight(.bold))
                .foregroundStyle(
                    tint == .secondary
                        ? Color.secondary
                        : tint
                )

            if status == "READY" {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

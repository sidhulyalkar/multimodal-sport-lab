import MotionOSAppleCapture
import SwiftUI

/// Optional preparation notes, not a replacement for instrumented preflight.
/// Manual checks deliberately do not gate recording, so an ordinary athlete
/// never has to complete a research form just to capture a session.
struct IndoBoardFirstCaptureGuideCard: View {
    let externalCamera: Bool

    @State private var expanded = true
    @State private var checkedIDs: Set<String> = []

    private var steps: [IndoBoardFirstCaptureStep] {
        IndoBoardFirstCaptureGuide.steps(externalCamera: externalCamera)
    }

    private var checkedCount: Int {
        steps.filter { checkedIDs.contains($0.id) }.count
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "These are physical setup reminders. MotionOS still runs "
                        + "its separate device, framing, and storage checks."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(steps) { step in
                    Button {
                        if checkedIDs.contains(step.id) {
                            checkedIDs.remove(step.id)
                        } else {
                            checkedIDs.insert(step.id)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 11) {
                            Image(
                                systemName: checkedIDs.contains(step.id)
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                            .font(.title3)
                            .foregroundStyle(
                                checkedIDs.contains(step.id)
                                    ? Color.green
                                    : Color.secondary
                            )

                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(step.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(
                                        horizontal: false,
                                        vertical: true
                                    )
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(step.title)
                    .accessibilityValue(
                        checkedIDs.contains(step.id)
                            ? "Checked"
                            : "Not checked"
                    )
                    .accessibilityHint(step.detail)
                }

                Divider()

                Text("During the ride")
                    .font(.subheadline.weight(.semibold))

                Text(
                    "Follow the Watch's guided 2-minute protocol. "
                        + "When START, MIDDLE, or END sync appears, make one "
                        + "distinct arm gesture while the board is near neutral. "
                        + "Do not deliberately destabilize the board."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text(
                    "After sealing, open Sessions and verify video and Watch "
                        + "evidence. Record a short stability/effort note. "
                        + "Keep the original files unchanged."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "checklist")
                    .foregroundStyle(.cyan)

                VStack(alignment: .leading, spacing: 2) {
                    Text("First recording guide")
                        .font(.subheadline.weight(.semibold))
                    Text("\(checkedCount) of \(steps.count) setup notes checked")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cardStyle()
    }
}

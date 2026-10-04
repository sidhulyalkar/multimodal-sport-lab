import AVFoundation
import AVKit
import MotionOSAppleCapture
import SwiftUI

struct Action4AlignmentReviewView: View {
    let run: ProductRunRecord
    let artifact: Action4SyncAnalysisArtifact

    @Environment(\.dismiss) private var dismiss

    @State private var selectedIndex = 0
    @State private var acceptedLabels: Set<String> = []
    @State private var iPhonePlayer: AVPlayer?
    @State private var actionPlayer: AVPlayer?
    @State private var previewTask: Task<Void, Never>?
    @State private var isSealing = false
    @State private var sealError: String?
    @State private var sealedReceipt:
        VideoAlignmentReceiptV1?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                intro
                anchorPicker
                pairedPlayers
                reviewDecision
                sealCard
            }
            .motionOSPageWidth()
            .padding(
                .horizontal,
                MotionOSDesign.pageHorizontalPadding
            )
            .padding(.vertical, 12)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Review Alignment")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: run.runID) {
            preparePlayers()
            loadExistingReceipt()
            seekCurrent(play: false)
        }
        .onChange(of: selectedIndex) {
            _, _ in
            seekCurrent(play: false)
        }
        .onDisappear {
            previewTask?.cancel()
            iPhonePlayer?.pause()
            actionPlayer?.pause()
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            MotionOSSectionHeader(
                title: "Verify three physical landmarks",
                subtitle:
                    "START · MIDDLE · END",
                systemImage: "checkmark.shield",
                accent: .cyan
            )

            Text(
                "Each pair should show the same sharp arm gesture. "
                    + "The two cameras do not need the same viewpoint; "
                    + "you are reviewing event identity and timing."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                metric(
                    "Proposal",
                    String(
                        format:
                            "%.0f%%",
                        artifact.proposal.confidence
                            * 100
                    )
                )
                metric(
                    "Middle residual",
                    String(
                        format:
                            "%.0f ms",
                        artifact.proposal
                            .middleResidualNS
                            / 1_000_000
                    )
                )
                metric(
                    "Reviewed",
                    "\(acceptedLabels.count)/3"
                )
            }

            Text(
                "A proposal is not synchronization authority. "
                    + "MotionOS writes the final video-alignment receipt "
                    + "only after all three correspondences are explicitly reviewed."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private var anchorPicker: some View {
        Picker(
            "Sync landmark",
            selection: $selectedIndex
        ) {
            ForEach(
                Array(
                    artifact.proposal
                        .anchors
                        .enumerated()
                ),
                id: \.offset
            ) { index, anchor in
                Text(anchor.label.capitalized)
                    .tag(index)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Sync landmark")
    }

    @ViewBuilder
    private var pairedPlayers: some View {
        if let anchor = currentAnchor {
            VStack(alignment: .leading, spacing: 10) {
                playerCard(
                    title: "iPhone reference",
                    subtitle:
                        "session +\(formatTime(anchor.referenceTimeNS))",
                    player: iPhonePlayer,
                    accent: .cyan
                )

                HStack {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 1)
                    Label(
                        "same physical gesture?",
                        systemImage:
                            "arrow.up.arrow.down"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 1)
                }

                playerCard(
                    title: "Action 4",
                    subtitle:
                        "video +\(formatTime(anchor.externalPTSNS))",
                    player: actionPlayer,
                    accent: .purple
                )

                Button {
                    seekCurrent(play: true)
                } label: {
                    Label(
                        "Replay Both Landmarks",
                        systemImage: "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .cardStyle()
        }
    }

    private func playerCard(
        title: String,
        subtitle: String,
        player: AVPlayer?,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(
                    title,
                    systemImage: "video.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)

                Spacer()

                Text(subtitle)
                    .font(
                        .system(
                            .caption2,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(.secondary)
            }

            ZStack {
                RoundedRectangle(
                    cornerRadius: 14,
                    style: .continuous
                )
                .fill(Color.black)

                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .aspectRatio(
                16 / 9,
                contentMode: .fit
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 14,
                    style: .continuous
                )
            )
        }
    }

    @ViewBuilder
    private var reviewDecision: some View {
        if let anchor = currentAnchor {
            VStack(alignment: .leading, spacing: 12) {
                MotionOSSectionHeader(
                    title:
                        "\(anchor.label.capitalized) landmark",
                    subtitle:
                        "External ↔ iPhone event correspondence",
                    systemImage: "scope",
                    accent:
                        acceptedLabels
                            .contains(anchor.label)
                            ? .green
                            : .orange
                )

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Action 4")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(
                            formatTime(
                                anchor.externalPTSNS
                            )
                        )
                        .font(
                            .system(
                                .caption,
                                design: .monospaced,
                                weight: .semibold
                            )
                        )
                    }

                    Spacer()

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("iPhone reference")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(
                            formatTime(
                                anchor.referenceTimeNS
                            )
                        )
                        .font(
                            .system(
                                .caption,
                                design: .monospaced,
                                weight: .semibold
                            )
                        )
                    }
                }

                Toggle(
                    "I verified the same sharp arm gesture in both views",
                    isOn: acceptanceBinding(
                        anchor.label
                    )
                )
                .font(.subheadline.weight(.semibold))
                .tint(.green)

                HStack {
                    if selectedIndex > 0 {
                        Button("Previous") {
                            selectedIndex -= 1
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    if selectedIndex
                        < artifact.proposal.anchors.count - 1 {
                        Button("Next Landmark") {
                            selectedIndex += 1
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .cardStyle()
        }
    }

    private var sealCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title:
                    sealedReceipt == nil
                        ? "Seal alignment"
                        : "Alignment sealed",
                subtitle:
                    sealedReceipt == nil
                        ? "Explicit human review → immutable timing receipt"
                        : "Action 4 now has a reviewed reference-time map",
                systemImage:
                    sealedReceipt == nil
                        ? "seal"
                        : "checkmark.seal.fill",
                accent:
                    sealedReceipt == nil
                        ? .indigo
                        : .green
            )

            if let receipt = sealedReceipt {
                HStack(spacing: 8) {
                    metric(
                        "Drift",
                        String(
                            format:
                                "%.1f ppm",
                            receipt.clockModel
                                .driftPPM
                        )
                    )
                    metric(
                        "Fit RMS",
                        String(
                            format:
                                "%.1f ms",
                            receipt.clockModel
                                .residualRMSMS
                        )
                    )
                    metric(
                        "Coverage",
                        receipt.coverage.passed
                            ? "PASS"
                            : "FAIL"
                    )
                }

                Text(
                    "This unlocks temporal fusion and synchronized 3D replay. "
                        + "It does not by itself calibrate the Action 4 image plane "
                        + "or justify projecting iPhone 2D joints onto Action 4 pixels."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button {
                    dismiss()
                } label: {
                    Label(
                        "Return to Replay",
                        systemImage: "checkmark"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text(
                    allAnchorsAccepted
                        ? "All three correspondences are reviewed. Sealing "
                            + "re-fits the affine clock using every anchor, "
                            + "recomputes residuals/coverage, verifies the "
                            + "Action 4 hash, and writes video-alignment.json."
                        : "Review all three landmark pairs before MotionOS "
                            + "will create synchronization authority."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let sealError {
                    Label(
                        sealError,
                        systemImage:
                            "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Button {
                    seal()
                } label: {
                    if isSealing {
                        HStack {
                            ProgressView()
                            Text("Sealing Alignment…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label(
                            "Seal Reviewed Alignment",
                            systemImage: "checkmark.seal.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !allAnchorsAccepted
                        || isSealing
                )
            }
        }
        .cardStyle()
    }

    private var currentAnchor:
        ActionCameraSyncAnchor? {
        guard artifact.proposal.anchors.indices
                .contains(selectedIndex)
        else {
            return nil
        }
        return artifact.proposal
            .anchors[selectedIndex]
    }

    private var allAnchorsAccepted: Bool {
        let labels = Set(
            artifact.proposal.anchors.map(\.label)
        )
        return labels.count >= 3
            && labels.isSubset(
                of: acceptedLabels
            )
    }

    private func acceptanceBinding(
        _ label: String
    ) -> Binding<Bool> {
        Binding(
            get: {
                acceptedLabels.contains(label)
            },
            set: { accepted in
                if accepted {
                    acceptedLabels.insert(label)
                } else {
                    acceptedLabels.remove(label)
                }
            }
        )
    }

    private func preparePlayers() {
        guard iPhonePlayer == nil,
              actionPlayer == nil
        else {
            return
        }
        if let url = run.cameraVideoURL {
            iPhonePlayer = AVPlayer(url: url)
        }
        if let url = run.externalVideoURL {
            actionPlayer = AVPlayer(url: url)
        }
    }

    private func seekCurrent(
        play: Bool
    ) {
        guard let anchor = currentAnchor
        else {
            return
        }

        previewTask?.cancel()
        iPhonePlayer?.pause()
        actionPlayer?.pause()

        let leadNS: UInt64 =
            450_000_000
        let iphoneNS =
            anchor.referenceTimeNS > leadNS
                ? anchor.referenceTimeNS - leadNS
                : 0
        let actionNS =
            anchor.externalPTSNS > leadNS
                ? anchor.externalPTSNS - leadNS
                : 0

        iPhonePlayer?.seek(
            to: mediaTime(iphoneNS),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        actionPlayer?.seek(
            to: mediaTime(actionNS),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )

        guard play else {
            return
        }

        iPhonePlayer?.play()
        actionPlayer?.play()

        previewTask = Task { @MainActor in
            try? await Task.sleep(
                for: .milliseconds(1_400)
            )
            guard !Task.isCancelled else {
                return
            }
            iPhonePlayer?.pause()
            actionPlayer?.pause()
        }
    }

    private func seal() {
        guard allAnchorsAccepted,
              !isSealing
        else {
            return
        }

        isSealing = true
        sealError = nil
        previewTask?.cancel()
        iPhonePlayer?.pause()
        actionPlayer?.pause()

        Task { @MainActor in
            do {
                let receipt =
                    try await Action4AlignmentSealer
                        .seal(
                            run: run,
                            artifact: artifact
                        )
                sealedReceipt = receipt
                isSealing = false
            } catch {
                sealError =
                    error.localizedDescription
                isSealing = false
            }
        }
    }

    private func loadExistingReceipt() {
        do {
            sealedReceipt =
                try Action4AlignmentSealer
                    .loadReceipt(for: run)
        } catch {
            sealError =
                error.localizedDescription
        }
    }

    private func mediaTime(
        _ ns: UInt64
    ) -> CMTime {
        let value = min(
            ns,
            UInt64(Int64.max)
        )
        return CMTime(
            value: Int64(value),
            timescale: 1_000_000_000
        )
    }

    private func formatTime(
        _ ns: UInt64
    ) -> String {
        String(
            format:
                "%.3f s",
            Double(ns) / 1_000_000_000
        )
    }

    private func metric(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(
                    .system(
                        .caption,
                        design: .monospaced,
                        weight: .semibold
                    )
                )
                .lineLimit(1)
        }
        .padding(9)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(
                cornerRadius: 11,
                style: .continuous
            )
        )
    }
}

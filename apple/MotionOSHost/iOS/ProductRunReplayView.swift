import AVFoundation
import AVKit
import Foundation
import MotionOSAppleCapture
import SwiftUI

enum ProductReplayVideoSource: String, CaseIterable, Identifiable {
    case iPhone = "iPhone"
    case action4 = "Action 4"

    var id: String { rawValue }
}

enum ProductReplayBodyMode: String, CaseIterable, Identifiable {
    case video = "Video"
    case body = "Body"

    var id: String { rawValue }
}

struct ProductReplayPoseSample: Sendable {
    let ptsNS: UInt64
    let frame: BodyMovementFrame
}

struct ProductReplayCameraTimeline: Sendable {
    let firstFramePTSNS: UInt64
    let lastFramePTSNS: UInt64
    let poseSamples: [ProductReplayPoseSample]

    var durationSeconds: Double {
        guard lastFramePTSNS > firstFramePTSNS else {
            return 0
        }
        return Double(lastFramePTSNS - firstFramePTSNS)
            / 1_000_000_000
    }
}

enum ProductReplayError: LocalizedError {
    case missingCameraEvidence
    case cameraJournalEmpty
    case cameraJournalMissingFrames

    var errorDescription: String? {
        switch self {
        case .missingCameraEvidence:
            "This run does not contain both iPhone video and frame evidence."
        case .cameraJournalEmpty:
            "The iPhone camera journal is empty."
        case .cameraJournalMissingFrames:
            "The camera journal contains no usable frame timestamps."
        }
    }
}

enum ProductReplayEvidenceLoader {
    nonisolated static func loadCameraTimeline(
        _ url: URL
    ) throws -> ProductReplayCameraTimeline {
        let data = try Data(
            contentsOf: url,
            options: [.mappedIfSafe]
        )
        guard !data.isEmpty else {
            throw ProductReplayError.cameraJournalEmpty
        }

        let decoder = JSONDecoder()
        var firstFramePTSNS: UInt64?
        var lastFramePTSNS: UInt64?
        var poseSamples: [ProductReplayPoseSample] = []

        for line in data.split(separator: 0x0A) {
            guard !line.isEmpty else { continue }
            let event = try decoder.decode(
                SensorEnvelope.self,
                from: Data(line)
            )

            if event.stream == "/camera/frame" {
                firstFramePTSNS = min(
                    firstFramePTSNS ?? event.deviceTimeNS,
                    event.deviceTimeNS
                )
                lastFramePTSNS = max(
                    lastFramePTSNS ?? event.deviceTimeNS,
                    event.deviceTimeNS
                )
                continue
            }

            guard event.stream == "/camera/pose3d",
                  let frame =
                    BodyMovementFrameParser.parseVisionPose(
                        payload: event.payload,
                        sessionID: event.sessionID,
                        sequence: event.sequence,
                        deviceTimeNS: event.deviceTimeNS
                    )
            else {
                continue
            }

            poseSamples.append(
                ProductReplayPoseSample(
                    ptsNS: event.deviceTimeNS,
                    frame: frame
                )
            )
        }

        guard let firstFramePTSNS,
              let lastFramePTSNS
        else {
            throw ProductReplayError.cameraJournalMissingFrames
        }

        poseSamples.sort { $0.ptsNS < $1.ptsNS }

        return ProductReplayCameraTimeline(
            firstFramePTSNS: firstFramePTSNS,
            lastFramePTSNS: lastFramePTSNS,
            poseSamples: poseSamples
        )
    }
}

@MainActor
final class ProductRunReplayController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var timeline:
        ProductReplayCameraTimeline?
    @Published private(set) var currentFrame: BodyMovementFrame?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedSource:
        ProductReplayVideoSource = .iPhone
    @Published private(set) var action4Alignment:
        VideoAlignmentReceiptV1?
    @Published private(set) var action4PoseTrack:
        ExternalVideoPoseTrack?
    @Published private(set) var currentAction4PoseFrame:
        ExternalVideoPoseFrame?

    private var pollTask: Task<Void, Never>?
    private var run: ProductRunRecord?

    func load(_ run: ProductRunRecord) async {
        stopPolling()
        self.run = run
        isLoading = true
        errorMessage = nil

        guard let cameraVideoURL = run.cameraVideoURL,
              let cameraJournalURL = run.cameraJournalURL
        else {
            player = nil
            timeline = nil
            currentFrame = nil
            isLoading = false
            errorMessage =
                ProductReplayError.missingCameraEvidence
                    .localizedDescription
            return
        }

        do {
            let timeline = try await Task.detached(
                priority: .utility
            ) {
                try ProductReplayEvidenceLoader
                    .loadCameraTimeline(cameraJournalURL)
            }
            .value

            self.timeline = timeline
            action4Alignment =
                try? Action4AlignmentSealer
                    .loadReceipt(for: run)
            action4PoseTrack =
                try? Action4PoseTrackAnalyzer
                    .loadTrack(for: run)
            currentAction4PoseFrame = nil
            selectedSource = .iPhone
            player = AVPlayer(url: cameraVideoURL)
            currentFrame = timeline.poseSamples.first?.frame
            isLoading = false
            startPolling()
        } catch {
            player = AVPlayer(url: cameraVideoURL)
            timeline = nil
            currentFrame = nil
            isLoading = false
            errorMessage = (
                "Video is playable, but synchronized pose evidence "
                    + "could not be loaded: "
                    + error.localizedDescription
            )
        }
    }

    func selectSource(
        _ source: ProductReplayVideoSource
    ) {
        guard let run else { return }
        guard source != selectedSource else { return }

        player?.pause()
        selectedSource = source

        switch source {
        case .iPhone:
            guard let cameraVideoURL = run.cameraVideoURL else {
                return
            }
            player = AVPlayer(url: cameraVideoURL)
            currentFrame = timeline?.poseSamples.first?.frame
            currentAction4PoseFrame = nil

        case .action4:
            guard let externalVideoURL = run.externalVideoURL else {
                selectedSource = .iPhone
                return
            }
            player = AVPlayer(url: externalVideoURL)
            currentFrame =
                action4Alignment == nil
                    ? nil
                    : timeline?.poseSamples.first?.frame
        }
    }

    func reloadAction4Alignment() {
        guard let run else {
            action4Alignment = nil
            return
        }
        action4Alignment =
            try? Action4AlignmentSealer
                .loadReceipt(for: run)
        updateCurrentFrame()
    }

    func reloadAction4PoseTrack() {
        guard let run else {
            action4PoseTrack = nil
            currentAction4PoseFrame = nil
            return
        }

        action4PoseTrack =
            try? Action4PoseTrackAnalyzer
                .loadTrack(for: run)
        updateCurrentFrame()
    }

    func stop() {
        player?.pause()
        stopPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.updateCurrentFrame()
                try? await Task.sleep(
                    for: .milliseconds(67)
                )
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func updateCurrentFrame() {
        guard let player,
              let timeline,
              !timeline.poseSamples.isEmpty
        else {
            currentFrame = nil
            currentAction4PoseFrame = nil
            return
        }

        let elapsed = CMTimeGetSeconds(
            player.currentTime()
        )
        guard elapsed.isFinite,
              elapsed >= 0
        else {
            return
        }

        let elapsedNS = UInt64(
            min(
                Double(UInt64.max),
                elapsed * 1_000_000_000
            )
            .rounded(.toNearestOrEven)
        )

        if selectedSource == .action4 {
            currentAction4PoseFrame =
                action4PoseTrack?
                    .interpolatedFrame(
                        at: elapsedNS
                    )
        } else {
            currentAction4PoseFrame = nil
        }

        let referenceElapsedNS: UInt64
        switch selectedSource {
        case .iPhone:
            referenceElapsedNS = elapsedNS

        case .action4:
            guard let action4Alignment else {
                currentFrame = nil
                return
            }
            referenceElapsedNS =
                action4Alignment.mapVideoPTS(
                    elapsedNS
                )
        }

        let addition = timeline.firstFramePTSNS
            .addingReportingOverflow(
                referenceElapsedNS
            )
        guard !addition.overflow else {
            currentFrame = nil
            return
        }
        let targetPTS = addition.partialValue

        guard targetPTS
                <= timeline.lastFramePTSNS
        else {
            currentFrame = nil
            return
        }

        currentFrame = nearestPose(
            to: targetPTS,
            samples: timeline.poseSamples
        )
    }

    private func nearestPose(
        to target: UInt64,
        samples: [ProductReplayPoseSample]
    ) -> BodyMovementFrame? {
        var low = 0
        var high = samples.count

        while low < high {
            let middle = (low + high) / 2
            if samples[middle].ptsNS < target {
                low = middle + 1
            } else {
                high = middle
            }
        }

        let candidates = [
            low > 0 ? samples[low - 1] : nil,
            low < samples.count ? samples[low] : nil,
        ]
        .compactMap { $0 }

        guard let nearest = candidates.min(by: {
            distance($0.ptsNS, target)
                < distance($1.ptsNS, target)
        }) else {
            return nil
        }

        // Pose is sampled at roughly 10 Hz. A large gap means the overlay
        // should disappear rather than visually freezing an old body pose.
        guard distance(nearest.ptsNS, target)
                <= 350_000_000
        else {
            return nil
        }
        return nearest.frame
    }

    private func distance(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }
}

struct ProductRunReplayView: View {
    let run: ProductRunRecord

    @StateObject private var controller =
        ProductRunReplayController()
    @StateObject private var action4Sync =
        Action4SyncAnalysisController()
    @StateObject private var action4Pose =
        Action4PoseTrackController()

    @State private var bodyMode:
        ProductReplayBodyMode = .video
    @State private var showBody = true
    @State private var showBalance = true
    @State private var showMechanics = true
    @State private var showMuscles = true
    @State private var showCoaching = true
    @State private var showConfidence = false
    @State private var showAction4Pose = true
    @State private var showAction4Equipment = true
    @State private var viewpoint:
        BodySceneViewpoint = .orbit

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                hero
                sourceSelector
                replayStage

                if controller.selectedSource == .action4 {
                    action4SyncCard

                    if controller.action4Alignment != nil {
                        action4PoseCard
                    }
                }

                layerControls
                evidenceStatus

                if showCoaching,
                   let coach = run.productManifest?.coachSummary {
                    coachingCard(coach)
                }
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
        .navigationTitle("Replay")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: run.runID) {
            action4Sync.loadExisting(run: run)
            action4Pose.loadExisting(run: run)
            await controller.load(run)
        }
        .onAppear {
            controller.reloadAction4Alignment()
            controller.reloadAction4PoseTrack()
            action4Pose.loadExisting(run: run)
        }
        .onDisappear {
            controller.stop()
            action4Sync.cancel()
            action4Pose.cancel()
        }
        .onChange(of: action4Sync.phase) {
            _, phase in
            if phase == .ready {
                // Sync analysis also caches its already-computed 5 Hz source
                // pose pass, so expose that evidence immediately rather than
                // asking for another full Action 4 decode.
                action4Pose.loadExisting(
                    run: run
                )
                controller
                    .reloadAction4PoseTrack()
            }
        }
        .onChange(of: action4Pose.phase) {
            _, phase in
            if phase == .ready {
                controller.reloadAction4PoseTrack()
            }
        }
        .onChange(of: controller.selectedSource) {
            _, source in
            if source == .action4,
               controller.action4Alignment == nil {
                bodyMode = .video
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Movement Replay")
                        .font(.title2.weight(.bold))
                    Text(
                        controller.selectedSource == .iPhone
                            ? "Recorded video + synchronized body evidence"
                            : "Imported Action 4 original"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                MotionOSStatusBadge(
                    title:
                        controller.selectedSource == .iPhone
                            ? "SYNCED"
                            : "RAW",
                    systemImage:
                        controller.selectedSource == .iPhone
                            ? "checkmark.circle.fill"
                            : "video.fill",
                    color:
                        controller.selectedSource == .iPhone
                            ? .green
                            : .purple
                )
            }

            if let timeline = controller.timeline {
                Text(
                    String(
                        format:
                            "%.1f s camera evidence · %d pose samples",
                        timeline.durationSeconds,
                        timeline.poseSamples.count
                    )
                )
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var sourceSelector: some View {
        if run.externalVideoURL != nil {
            Picker(
                "Video source",
                selection: sourceBinding
            ) {
                Text("iPhone")
                    .tag(ProductReplayVideoSource.iPhone)
                Text("Action 4")
                    .tag(ProductReplayVideoSource.action4)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Replay video source")
        }
    }

    private var sourceBinding:
        Binding<ProductReplayVideoSource> {
        Binding(
            get: { controller.selectedSource },
            set: { controller.selectSource($0) }
        )
    }

    @ViewBuilder
    private var replayStage: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.selectedSource == .iPhone
                || controller.action4Alignment != nil {
                Picker("Replay mode", selection: $bodyMode) {
                    ForEach(ProductReplayBodyMode.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
            }

            ZStack {
                RoundedRectangle(
                    cornerRadius: 20,
                    style: .continuous
                )
                .fill(Color.black)

                if controller.isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text("Loading replay evidence…")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                } else if bodyMode == .body,
                          controller.selectedSource == .iPhone
                            || controller.action4Alignment != nil {
                    bodyStage
                } else if let player = controller.player {
                    VideoPlayer(player: player)

                    if controller.selectedSource == .iPhone,
                       let frame = controller.currentFrame {
                        ReplayPoseOverlay(
                            frame: frame,
                            showBody: showBody,
                            showBalance: showBalance,
                            showMechanics: showMechanics,
                            showConfidence: showConfidence
                        )
                        .allowsHitTesting(false)
                    } else if controller.selectedSource == .action4,
                              showAction4Pose,
                              let frame =
                                controller.currentAction4PoseFrame {
                        ExternalVideoPoseOverlay(
                            frame: frame,
                            showConfidence: showConfidence,
                            showEquipment:
                                showAction4Equipment
                        )
                        .allowsHitTesting(false)
                    }

                    VStack {
                        HStack {
                            sourceBadge
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(10)
                    .allowsHitTesting(false)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.65))
                        Text(
                            controller.errorMessage
                                ?? "Replay evidence unavailable"
                        )
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 20,
                    style: .continuous
                )
            )

            if controller.selectedSource == .action4 {
                Label(
                    controller.action4Alignment != nil
                        ? (
                            controller.action4PoseTrack != nil
                                ? "Temporal alignment and Action 4 source-pose "
                                    + "evidence are ready. Video mode can show "
                                    + "Action 4's own image-space skeleton; 3D "
                                    + "Body follows the synchronized iPhone-derived "
                                    + "body timeline."
                                : "Temporal alignment is sealed. Build Action 4 "
                                    + "source-pose evidence to unlock its own "
                                    + "image-space skeleton while 3D Body follows "
                                    + "the synchronized iPhone-derived timeline."
                        )
                        : (
                            action4Sync.artifact == nil
                                ? "Original preserved. Analyze the three sync gestures "
                                    + "before temporal fusion."
                                : "A motion-based alignment proposal exists. Review "
                                    + "all three paired gestures before sealing."
                        ),
                    systemImage:
                        controller.action4Alignment != nil
                            ? "checkmark.seal.fill"
                            : (
                                action4Sync.artifact == nil
                                    ? "clock.badge.exclamationmark"
                                    : "waveform.path.ecg.rectangle"
                            )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if controller.currentFrame == nil,
                      !controller.isLoading {
                Label(
                    "No fresh pose sample at this playback instant.",
                    systemImage: "viewfinder"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var bodyStage: some View {
        if let frame = controller.currentFrame {
            BodyMovementScene3D(
                frame: frame,
                viewpoint: viewpoint,
                showSupport: showBalance,
                showMuscles:
                    showMuscles
                        && frame.hasModelEstimatedMuscleActivity,
                isReference: false
            )
            .background(
                LinearGradient(
                    colors: [
                        Color.black,
                        Color.black.opacity(0.86),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            VStack {
                HStack {
                    Label(
                        frame.hasModelEstimatedMuscleActivity
                            ? "BODY + MODEL ESTIMATE"
                            : "BODY GEOMETRY",
                        systemImage: "figure.arms.open"
                    )
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        .black.opacity(0.55),
                        in: Capsule()
                    )
                    Spacer()
                }
                Spacer()
            }
            .padding(10)
        } else {
            VStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text("Play or scrub to a detected body frame")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private var sourceBadge: some View {
        Label(
            controller.selectedSource == .iPhone
                ? "IPHONE · POSE TIMELOCK"
                : (
                    controller.action4PoseTrack != nil
                        ? "ACTION 4 · POSE + TIME"
                        : (
                            controller.action4Alignment != nil
                                ? "ACTION 4 · TIME ALIGNED"
                                : "ACTION 4 · UNALIGNED"
                        )
                ),
            systemImage:
                controller.selectedSource == .iPhone
                    ? "camera.fill"
                    : (
                        controller.action4Alignment != nil
                            ? "checkmark.seal.fill"
                            : "video.fill"
                    )
        )
        .font(.caption2.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            .black.opacity(0.55),
            in: Capsule()
        )
    }

    private var action4SyncCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Action 4 alignment",
                subtitle: action4SyncSubtitle,
                systemImage: "waveform.path.ecg.rectangle",
                accent:
                    controller.action4Alignment != nil
                        ? .green
                        : (
                            action4Sync.phase == .ready
                                ? .cyan
                                : .purple
                        )
            )

            if let receipt =
                    controller.action4Alignment {
                HStack(spacing: 8) {
                    alignmentMetric(
                        "Status",
                        "SEALED"
                    )
                    alignmentMetric(
                        "Fit RMS",
                        String(
                            format:
                                "%.1f ms",
                            receipt.clockModel
                                .residualRMSMS
                        )
                    )
                    alignmentMetric(
                        "Drift",
                        String(
                            format:
                                "%.1f ppm",
                            receipt.clockModel
                                .driftPPM
                        )
                    )
                }

                Label(
                    "Reviewed three-point timing authority",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)

                Text(
                    "Temporal fusion is available. Action 4 image-space "
                        + "pose/equipment overlays remain a separate "
                        + "qualification problem."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

            } else if let artifact = action4Sync.artifact {
                let proposal = artifact.proposal

                HStack(spacing: 8) {
                    alignmentMetric(
                        "Confidence",
                        String(
                            format:
                                "%.0f%%",
                            proposal.confidence * 100
                        )
                    )
                    alignmentMetric(
                        "Mid residual",
                        String(
                            format:
                                "%.0f ms",
                            proposal.middleResidualNS
                                / 1_000_000
                        )
                    )
                    alignmentMetric(
                        "Peaks",
                        "\(proposal.externalPeakCount)"
                    )
                }

                ForEach(
                    proposal.anchors,
                    id: \.label
                ) { anchor in
                    HStack(spacing: 8) {
                        Text(anchor.label.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)

                        Text(
                            formatPTS(anchor.externalPTSNS)
                        )
                        .font(
                            .system(
                                .caption,
                                design: .monospaced,
                                weight: .semibold
                            )
                        )

                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Text(
                            formatPTS(anchor.referenceTimeNS)
                        )
                        .font(
                            .system(
                                .caption,
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(.secondary)

                        Spacer()

                        Text(
                            String(
                                format:
                                    "%.0f%%",
                                anchor.confidence * 100
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                Label(
                    proposal.confidence >= 0.70
                        ? "Strong proposal · review before sealing alignment"
                        : "Proposal needs review · do not unlock overlays yet",
                    systemImage:
                        proposal.confidence >= 0.70
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    proposal.confidence >= 0.70
                        ? .green
                        : .orange
                )

                Text(artifact.claimBoundary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                NavigationLink {
                    Action4AlignmentReviewView(
                        run: run,
                        artifact: artifact
                    )
                } label: {
                    Label(
                        "Review Three Landmarks",
                        systemImage: "checkmark.shield"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if action4Sync.phase == .analyzing {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Finding the three sync gestures…")
                            .font(.subheadline.weight(.semibold))
                        Text(
                            "MotionOS samples Action 4 pose at 5 Hz and "
                                + "matches START / MIDDLE / END arm-motion timing."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                if let error = action4Sync.errorMessage {
                    Label(
                        error,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text(
                        "Analyze the imported movie locally. MotionOS uses "
                            + "visible arm motion and the three journal-backed "
                            + "sync cues; file creation time is never treated "
                            + "as timing truth."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Button {
                    action4Sync.startAnalysis(
                        run: run
                    )
                } label: {
                    Label(
                        "Analyze Action 4 Sync",
                        systemImage: "waveform.path.ecg"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    action4Sync.phase == .analyzing
                )
            }
        }
        .cardStyle()
    }

    private var action4PoseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Action 4 body track",
                subtitle: action4PoseSubtitle,
                systemImage: "figure.arms.open",
                accent:
                    action4Pose.phase == .ready
                        ? .green
                        : .cyan
            )

            if let track = action4Pose.track {
                HStack(spacing: 8) {
                    alignmentMetric(
                        "Frames",
                        "\(track.frameCount)"
                    )
                    alignmentMetric(
                        "Coverage",
                        String(
                            format:
                                "%.0f%%",
                            track.observationCoverageFraction
                                * 100
                        )
                    )
                    alignmentMetric(
                        "Confidence",
                        String(
                            format:
                                "%.0f%%",
                            track.meanConfidence
                                * 100
                        )
                    )
                }

                HStack(spacing: 8) {
                    alignmentMetric(
                        "Rate",
                        String(
                            format:
                                "%.0f Hz",
                            1
                                / track
                                    .sampleIntervalSeconds
                        )
                    )
                    alignmentMetric(
                        "Span",
                        String(
                            format:
                                "%.0f%%",
                            track.temporalSpanFraction
                                * 100
                        )
                    )
                    alignmentMetric(
                        "Max gap",
                        track.maximumPoseGapSeconds.map {
                            String(
                                format:
                                    "%.2f s",
                                $0
                            )
                        } ?? "—"
                    )
                }

                if track.equipmentFrameCount > 0 {
                    Label(
                        String(
                            format:
                                "QR board evidence · %d frames · %.0f%% pose-frame coverage",
                            track.equipmentFrameCount,
                            track.equipmentCoverageFraction
                                * 100
                        ),
                        systemImage:
                            "qrcode.viewfinder"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                } else {
                    Label(
                        "No MotionOS board QR triplet detected in this Action 4 view",
                        systemImage:
                            "qrcode.viewfinder"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Label(
                    "Source-camera 2D pose ready",
                    systemImage:
                        "checkmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)

                Text(
                    "Coverage counts detected analysis sample slots at the "
                        + "track's recorded rate; span only shows how much of "
                        + "the clip lies between the first and last detection. "
                        + "The skeleton interpolates only across short gaps and "
                        + "remains Action 4 image-space evidence, not metric "
                        + "world geometry."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(track.claimBoundary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button {
                    action4Pose.startAnalysis(
                        run: run
                    )
                } label: {
                    Label(
                        track.sampleIntervalSeconds > 0.11
                            ? "Refine Pose Track to 10 Hz"
                            : "Rebuild 10 Hz Pose Track",
                        systemImage:
                            track.sampleIntervalSeconds > 0.11
                                ? "sparkles"
                                : "arrow.clockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else if action4Pose.phase
                        == .analyzing {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        ProgressView()
                        Text(
                            "Analyzing Action 4 body pose…"
                        )
                        .font(.subheadline.weight(.semibold))
                    }

                    ProgressView(
                        value: action4Pose.progress
                    )

                    Text(
                        String(
                            format:
                                "%.0f%% · local Vision pass · 10 Hz",
                            action4Pose.progress
                                * 100
                        )
                    )
                    .font(
                        .system(
                            .caption,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(.secondary)

                    Button("Cancel Analysis") {
                        action4Pose.cancel()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                if let error =
                        action4Pose.errorMessage {
                    Label(
                        error,
                        systemImage:
                            "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text(
                        "Temporal alignment is already sealed. Run one "
                            + "higher-rate local Vision pass to create a "
                            + "hash-bound Action 4 image-space pose track "
                            + "for replay and later teacher-data generation."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Button {
                    action4Pose.startAnalysis(
                        run: run
                    )
                } label: {
                    Label(
                        "Build Action 4 Pose Track",
                        systemImage:
                            "figure.arms.open"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .cardStyle()
    }

    private var action4PoseSubtitle: String {
        switch action4Pose.phase {
        case .idle:
            "Create source-specific image-space evidence"
        case .analyzing:
            "Vision body-pose extraction running locally"
        case .ready:
            "Hash-bound source pose is replayable"
        case .failed:
            "Pose evidence needs attention"
        }
    }

    private var action4SyncSubtitle: String {
        if controller.action4Alignment != nil {
            return "Reviewed timing authority available"
        }

        switch action4Sync.phase {
        case .idle:
            return "Find matching physical landmarks"
        case .analyzing:
            return "Vision pose pass running locally"
        case .ready:
            return "Three-point motion proposal ready"
        case .failed:
            return "More evidence needed"
        }
    }

    private func alignmentMetric(
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(
                cornerRadius: 11,
                style: .continuous
            )
        )
    }

    private func formatPTS(
        _ value: UInt64
    ) -> String {
        let seconds =
            Double(value) / 1_000_000_000
        return String(format: "%.3f s", seconds)
    }

    private var layerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Replay layers",
                subtitle:
                    "Show only the evidence needed to understand this moment",
                systemImage: "square.3.layers.3d",
                accent: .cyan
            )

            if controller.selectedSource == .action4 {
                if controller.action4Alignment != nil {
                    VStack(alignment: .leading, spacing: 9) {
                        Label(
                            controller.action4PoseTrack != nil
                                ? "Temporal + source-pose evidence available"
                                : "Temporal fusion available",
                            systemImage:
                                controller.action4PoseTrack != nil
                                    ? "figure.arms.open"
                                    : "checkmark.seal.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)

                        if controller.action4PoseTrack != nil {
                            Toggle(
                                "Action 4 2D pose",
                                isOn: $showAction4Pose
                            )

                            if (
                                controller.action4PoseTrack?
                                    .equipmentFrameCount
                                    ?? 0
                            ) > 0 {
                                Toggle(
                                    "QR board / roller",
                                    isOn:
                                        $showAction4Equipment
                                )
                            }

                            Toggle(
                                "Pose confidence",
                                isOn: $showConfidence
                            )

                            Text(
                                "The cyan skeleton belongs to Action 4's own "
                                    + "image coordinates. Board/equipment pixels "
                                    + "remain off until Action 4 has separately "
                                    + "qualified equipment tracking."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            Text(
                                "Use 3D Body to inspect the synchronized "
                                    + "iPhone-derived body state. Build the "
                                    + "Action 4 pose track above to add its own "
                                    + "image-space skeleton."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        if bodyMode == .body {
                            Picker("3D viewpoint", selection: $viewpoint) {
                                ForEach(BodySceneViewpoint.allCases) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                            .pickerStyle(.segmented)

                            Toggle(
                                "Estimated muscle demand",
                                isOn: $showMuscles
                            )
                            .disabled(
                                controller.currentFrame?
                                    .hasModelEstimatedMuscleActivity != true
                            )
                        }
                    }
                } else {
                    Label(
                        action4Sync.artifact == nil
                            ? "Temporal layers unlock after external-video alignment."
                            : "Proposal found; review + seal alignment before temporal fusion.",
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 108),
                            spacing: 7
                        ),
                    ],
                    alignment: .leading,
                    spacing: 7
                ) {
                    layerToggle(
                        "Body",
                        symbol: "figure.stand",
                        isOn: $showBody
                    )
                    layerToggle(
                        "Mechanics",
                        symbol: "point.3.connected.trianglepath.dotted",
                        isOn: $showMechanics
                    )
                    layerToggle(
                        "Balance",
                        symbol: "scope",
                        isOn: $showBalance
                    )
                    layerToggle(
                        "Confidence",
                        symbol: "checkmark.shield",
                        isOn: $showConfidence
                    )
                    layerToggle(
                        "Coaching",
                        symbol: "figure.mind.and.body",
                        isOn: $showCoaching
                    )
                }

                if bodyMode == .body {
                    Picker("3D viewpoint", selection: $viewpoint) {
                        ForEach(BodySceneViewpoint.allCases) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle(
                        "Estimated muscle demand",
                        isOn: $showMuscles
                    )
                    .disabled(
                        controller.currentFrame?
                            .hasModelEstimatedMuscleActivity != true
                    )

                    Text(
                        controller.currentFrame?
                            .hasModelEstimatedMuscleActivity == true
                            ? "Muscle shading is a model estimate, not EMG."
                            : "No qualified muscle-demand estimate exists for this frame."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .cardStyle()
    }

    private func layerToggle(
        _ title: String,
        symbol: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
    }

    private var evidenceStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            MotionOSSectionHeader(
                title: "What this view means",
                subtitle: "Evidence stays separate from interpretation",
                systemImage: "checkmark.shield",
                accent: .green
            )

            replayStatusRow(
                "Video",
                value:
                    controller.selectedSource == .iPhone
                        ? "observed · sealed iPhone source"
                        : "observed · imported Action 4 original"
            )

            replayStatusRow(
                "Body",
                value:
                    controller.currentFrame == nil
                        ? "not active"
                        : (
                            controller.selectedSource == .iPhone
                                ? "derived · Vision pose"
                                : (
                                    controller.action4Alignment != nil
                                        ? "derived · iPhone 3D pose · time-aligned"
                                        : "not active"
                                )
                        )
            )

            if controller.selectedSource == .action4 {
                replayStatusRow(
                    "Action 4 pose",
                    value:
                        controller.currentAction4PoseFrame != nil
                            ? "derived · source-camera 2D Vision pose"
                            : (
                                controller.action4PoseTrack != nil
                                    ? "track available · no nearby pose frame"
                                    : "not analyzed"
                            )
                )
            }

            replayStatusRow(
                "Muscles",
                value:
                    controller.currentFrame?
                        .hasModelEstimatedMuscleActivity == true
                        ? "inferred · model-estimated demand"
                        : "not estimated"
            )

            Text(
                controller.selectedSource == .action4
                    && controller.action4PoseTrack != nil
                    ? "Action 4 skeleton pixels come from Action 4 itself. "
                        + "The 3D body remains a synchronized, derived iPhone "
                        + "representation. Neither implies metric multiview "
                        + "geometry without camera calibration."
                    : "The 3D body is a derived representation of detected pose. "
                        + "An anatomical-looking render is not automatically an "
                        + "anatomical measurement."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private func replayStatusRow(
        _ title: String,
        value: String
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func coachingCard(
        _ coach: ProductSessionManifest.CoachSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            MotionOSSectionHeader(
                title: "Coach",
                subtitle:
                    "(Int((coach.confidence * 100).rounded()))% confidence · hypothesis",
                systemImage: "figure.mind.and.body",
                accent: .cyan
            )

            Text(coach.observation)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            Text("TRY NEXT")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.cyan)
            Text(coach.tip)
                .font(.subheadline.weight(.semibold))

            Text(
                "Use the replay to inspect the frames behind the observation, "
                    + "then test the cue on the next comparable attempt."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }
}

private struct ExternalVideoPoseOverlay: View {
    let frame: ExternalVideoPoseFrame
    let showConfidence: Bool
    let showEquipment: Bool

    private static let connections:
        [(String, String)] = [
        ("root", "neck"),
        ("neck", "nose"),
        ("neck", "leftShoulder"),
        ("leftShoulder", "leftElbow"),
        ("leftElbow", "leftWrist"),
        ("neck", "rightShoulder"),
        ("rightShoulder", "rightElbow"),
        ("rightElbow", "rightWrist"),
        ("root", "leftHip"),
        ("leftHip", "leftKnee"),
        ("leftKnee", "leftAnkle"),
        ("root", "rightHip"),
        ("rightHip", "rightKnee"),
        ("rightKnee", "rightAnkle"),
        ("nose", "leftEye"),
        ("leftEye", "leftEar"),
        ("nose", "rightEye"),
        ("rightEye", "rightEar"),
    ]

    var body: some View {
        Canvas { context, size in
            let joints = normalizedJointMap

            for connection in Self.connections {
                guard let first =
                        joints[
                            normalize(
                                connection.0
                            )
                        ],
                      let second =
                        joints[
                            normalize(
                                connection.1
                            )
                        ]
                else {
                    continue
                }

                let confidence = min(
                    first.confidence,
                    second.confidence
                )
                var path = Path()
                path.move(
                    to: point(
                        first,
                        size: size
                    )
                )
                path.addLine(
                    to: point(
                        second,
                        size: size
                    )
                )
                context.stroke(
                    path,
                    with: .color(
                        Color.cyan.opacity(
                            showConfidence
                                ? 0.20
                                    + 0.80
                                        * confidence
                                : 0.90
                        )
                    ),
                    lineWidth: 2.6
                )
            }

            if showEquipment,
               let equipment =
                    frame.indoBoardEquipment {
                drawEquipment(
                    equipment,
                    context: &context,
                    size: size
                )
            }

            for joint in frame.joints {
                let center = point(
                    joint,
                    size: size
                )
                let radius =
                    showConfidence
                        ? 2.3
                            + 3.8
                                * joint.confidence
                        : 4.3
                context.fill(
                    Path(
                        ellipseIn: CGRect(
                            x:
                                center.x
                                    - radius,
                            y:
                                center.y
                                    - radius,
                            width:
                                radius * 2,
                            height:
                                radius * 2
                        )
                    ),
                    with: .color(
                        Color.white.opacity(
                            showConfidence
                                ? 0.25
                                    + 0.75
                                        * joint.confidence
                                : 0.92
                        )
                    )
                )
            }

            let badge = Text(
                "ACTION 4 · SOURCE POSE"
            )
            .font(
                .caption2.weight(.bold)
            )
            .foregroundStyle(.white)

            context.draw(
                badge,
                at: CGPoint(
                    x: 92,
                    y: size.height - 18
                )
            )
        }
        .accessibilityLabel(
            "Action 4 source-camera body pose overlay"
        )
    }

    private var normalizedJointMap:
        [String: BodyJoint2D] {
        Dictionary(
            uniqueKeysWithValues:
                frame.joints.map {
                    (
                        normalize($0.id),
                        $0
                    )
                }
        )
    }

    private func normalize(
        _ value: String
    ) -> String {
        value.lowercased().filter {
            $0.isLetter || $0.isNumber
        }
    }

    private func drawEquipment(
        _ equipment:
            IndoBoardEquipmentObservation,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        if let deck = equipment.deck {
            var deckPath = Path()
            deckPath.move(
                to: point(
                    deck.leftEnd,
                    size: size
                )
            )
            deckPath.addLine(
                to: point(
                    deck.rightEnd,
                    size: size
                )
            )
            context.stroke(
                deckPath,
                with: .color(
                    Color.green.opacity(
                        0.35
                            + 0.65
                                * deck.confidence
                    )
                ),
                lineWidth: 4
            )
        }

        if let roller = equipment.roller {
            let center = point(
                roller.center,
                size: size
            )
            let radius = 7.0
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x:
                            center.x - radius,
                        y:
                            center.y - radius,
                        width:
                            radius * 2,
                        height:
                            radius * 2
                    )
                ),
                with: .color(
                    Color.green.opacity(
                        0.35
                            + 0.65
                                * roller.confidence
                    )
                )
            )

            if let axisStart =
                    roller.axisStart,
               let axisEnd =
                    roller.axisEnd {
                var axis = Path()
                axis.move(
                    to: point(
                        axisStart,
                        size: size
                    )
                )
                axis.addLine(
                    to: point(
                        axisEnd,
                        size: size
                    )
                )
                context.stroke(
                    axis,
                    with: .color(
                        Color.green
                            .opacity(0.82)
                    ),
                    lineWidth: 2.5
                )
            }
        }
    }

    private func point(
        _ value: NormalizedImagePoint2D,
        size: CGSize
    ) -> CGPoint {
        CGPoint(
            x:
                min(
                    1,
                    max(0, value.x)
                ) * size.width,
            y:
                (
                    1
                        - min(
                            1,
                            max(0, value.y)
                        )
                ) * size.height
        )
    }

    private func point(
        _ joint: BodyJoint2D,
        size: CGSize
    ) -> CGPoint {
        CGPoint(
            x:
                min(
                    1,
                    max(0, joint.x)
                ) * size.width,
            y:
                (
                    1
                        - min(
                            1,
                            max(0, joint.y)
                        )
                ) * size.height
        )
    }
}

private struct ReplayPoseOverlay: View {
    let frame: BodyMovementFrame
    let showBody: Bool
    let showBalance: Bool
    let showMechanics: Bool
    let showConfidence: Bool

    var body: some View {
        Canvas { context, size in
            if showBody {
                drawSkeleton(
                    context: &context,
                    size: size
                )
            }
            if showMechanics {
                drawMechanics(
                    context: &context,
                    size: size
                )
            }
            if showBalance {
                drawBoard(
                    context: &context,
                    size: size
                )
            }
        }
    }

    private func drawSkeleton(
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let imageJoints = frame.imageJointMap
        guard !imageJoints.isEmpty else { return }

        for joint in frame.joints {
            guard let parentID = joint.parentID,
                  let imageJoint = imageJoints[joint.id],
                  let parent = imageJoints[parentID]
            else {
                continue
            }

            var path = Path()
            path.move(
                to: point(imageJoint, size: size)
            )
            path.addLine(
                to: point(parent, size: size)
            )
            let confidence = min(
                imageJoint.confidence,
                parent.confidence
            )
            context.stroke(
                path,
                with: .color(
                    Color.cyan.opacity(
                        showConfidence
                            ? 0.25 + 0.75 * confidence
                            : 0.86
                    )
                ),
                lineWidth: 2.5
            )
        }

        for joint in imageJoints.values {
            let center = point(joint, size: size)
            let radius = showConfidence
                ? 2.5 + 3.5 * joint.confidence
                : 4.5
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .color(
                    Color.white.opacity(
                        showConfidence
                            ? 0.30 + 0.70 * joint.confidence
                            : 0.92
                    )
                )
            )
        }
    }

    private func drawMechanics(
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let joints = frame.imageJointMap
        guard let pelvis = midpoint(
            joint(
                aliases: ["leftHip", "left_hip"],
                in: joints
            ),
            joint(
                aliases: ["rightHip", "right_hip"],
                in: joints
            )
        ),
        let feet = midpoint(
            joint(
                aliases: [
                    "leftAnkle",
                    "left_ankle",
                    "leftFoot",
                    "left_foot",
                ],
                in: joints
            ),
            joint(
                aliases: [
                    "rightAnkle",
                    "right_ankle",
                    "rightFoot",
                    "right_foot",
                ],
                in: joints
            )
        ) else {
            return
        }

        var path = Path()
        path.move(to: point(pelvis, size: size))
        path.addLine(to: point(feet, size: size))
        context.stroke(
            path,
            with: .color(Color.orange.opacity(0.9)),
            style: StrokeStyle(
                lineWidth: 2,
                dash: [6, 4]
            )
        )

        let pelvisPoint = point(pelvis, size: size)
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: pelvisPoint.x - 5,
                    y: pelvisPoint.y - 5,
                    width: 10,
                    height: 10
                )
            ),
            with: .color(.orange)
        )
    }

    private func drawBoard(
        context: inout GraphicsContext,
        size: CGSize
    ) {
        guard let equipment =
                frame.indoBoardTrackingEquipment
        else {
            return
        }

        if let deck = equipment.deck {
            var path = Path()
            path.move(
                to: point(deck.leftEnd, size: size)
            )
            path.addLine(
                to: point(deck.rightEnd, size: size)
            )
            context.stroke(
                path,
                with: .color(
                    Color.green.opacity(
                        0.35 + 0.65 * deck.confidence
                    )
                ),
                lineWidth: 4
            )
        }

        if let roller = equipment.roller {
            let center = point(
                roller.center,
                size: size
            )
            let radius = 7.0
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                ),
                with: .color(
                    Color.green.opacity(
                        0.35 + 0.65 * roller.confidence
                    )
                )
            )
        }
    }

    private func joint(
        aliases: [String],
        in joints: [String: BodyJoint2D]
    ) -> BodyJoint2D? {
        let targets = Set(aliases.map(normalize))
        return joints.values.first {
            targets.contains(normalize($0.id))
        }
    }

    private func midpoint(
        _ lhs: BodyJoint2D?,
        _ rhs: BodyJoint2D?
    ) -> BodyJoint2D? {
        guard let lhs, let rhs else {
            return nil
        }
        return BodyJoint2D(
            id: "midpoint",
            x: (lhs.x + rhs.x) / 2,
            y: (lhs.y + rhs.y) / 2,
            confidence: min(
                lhs.confidence,
                rhs.confidence
            )
        )
    }

    private func normalize(
        _ value: String
    ) -> String {
        value.lowercased().filter {
            $0.isLetter || $0.isNumber
        }
    }

    private func point(
        _ joint: BodyJoint2D,
        size: CGSize
    ) -> CGPoint {
        CGPoint(
            x: joint.x * size.width,
            y: (1 - joint.y) * size.height
        )
    }

    private func point(
        _ value: NormalizedImagePoint2D,
        size: CGSize
    ) -> CGPoint {
        CGPoint(
            x: value.x * size.width,
            y: (1 - value.y) * size.height
        )
    }
}

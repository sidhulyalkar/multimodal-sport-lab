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

        case .action4:
            guard let externalVideoURL = run.externalVideoURL else {
                selectedSource = .iPhone
                return
            }
            player = AVPlayer(url: externalVideoURL)
            currentFrame = nil
        }
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
        guard selectedSource == .iPhone,
              let player,
              let timeline,
              !timeline.poseSamples.isEmpty
        else {
            if selectedSource == .action4 {
                currentFrame = nil
            }
            return
        }

        let elapsed = CMTimeGetSeconds(player.currentTime())
        guard elapsed.isFinite, elapsed >= 0 else {
            return
        }

        let offsetNS = UInt64(
            min(
                Double(UInt64.max),
                elapsed * 1_000_000_000
            )
            .rounded()
        )
        let addition = timeline.firstFramePTSNS
            .addingReportingOverflow(offsetNS)
        guard !addition.overflow else {
            currentFrame = nil
            return
        }
        let targetPTS = addition.partialValue

        guard targetPTS <= timeline.lastFramePTSNS
        else {
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

    @State private var bodyMode:
        ProductReplayBodyMode = .video
    @State private var showBody = true
    @State private var showBalance = true
    @State private var showMechanics = true
    @State private var showMuscles = true
    @State private var showCoaching = true
    @State private var showConfidence = false
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
            await controller.load(run)
        }
        .onDisappear {
            controller.stop()
        }
        .onChange(of: controller.selectedSource) {
            _, source in
            if source == .action4 {
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
            if controller.selectedSource == .iPhone {
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
                          controller.selectedSource == .iPhone {
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
                    action4Sync.artifact == nil
                        ? "Original preserved. Analyze the three sync gestures "
                            + "before enabling cross-view overlays."
                        : "A motion-based alignment proposal exists. Overlays "
                            + "remain locked until that proposal is reviewed "
                            + "and sealed as synchronization evidence.",
                    systemImage:
                        action4Sync.artifact == nil
                            ? "clock.badge.exclamationmark"
                            : "waveform.path.ecg.rectangle"
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
                : "ACTION 4 · UNALIGNED",
            systemImage:
                controller.selectedSource == .iPhone
                    ? "camera.fill"
                    : "video.fill"
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
                    action4Sync.phase == .ready
                        ? .green
                        : .purple
            )

            if let artifact = action4Sync.artifact {
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
                    Task {
                        await action4Sync.analyze(
                            run: run
                        )
                    }
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

    private var action4SyncSubtitle: String {
        switch action4Sync.phase {
        case .idle:
            "Find matching physical landmarks"
        case .analyzing:
            "Vision pose pass running locally"
        case .ready:
            "Three-point motion proposal ready"
        case .failed:
            "More evidence needed"
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
                Label(
                    action4Sync.artifact == nil
                        ? "Annotation layers unlock after external-video alignment."
                        : "Proposal found; review + seal alignment before layers unlock.",
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    controller.selectedSource == .iPhone
                        && controller.currentFrame != nil
                        ? "derived · Vision pose"
                        : "not active"
            )

            replayStatusRow(
                "Muscles",
                value:
                    controller.currentFrame?
                        .hasModelEstimatedMuscleActivity == true
                        ? "inferred · model-estimated demand"
                        : "not estimated"
            )

            Text(
                "The 3D body is a derived representation of detected pose. "
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

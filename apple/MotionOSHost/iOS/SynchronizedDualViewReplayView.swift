import AVFoundation
import Foundation
import MotionOSAppleCapture
import SwiftUI
import UIKit

enum SynchronizedDualViewReplayError: LocalizedError {
    case missingIPhoneEvidence
    case missingAction4Video
    case missingAlignment
    case noPlayableOverlap

    var errorDescription: String? {
        switch self {
        case .missingIPhoneEvidence:
            "Synchronized comparison needs the sealed iPhone video and camera journal."
        case .missingAction4Video:
            "Synchronized comparison needs the imported Action 4 original."
        case .missingAlignment:
            "Review and seal Action 4 temporal alignment before comparing both cameras."
        case .noPlayableOverlap:
            "The reviewed Action 4 source and iPhone reference timeline do not share a playable interval."
        }
    }
}

@MainActor
final class SynchronizedDualViewReplayController:
    ObservableObject {
    @Published private(set) var iPhonePlayer:
        AVPlayer?
    @Published private(set) var action4Player:
        AVPlayer?
    @Published private(set) var timeline:
        ProductReplayCameraTimeline?
    @Published private(set) var alignment:
        VideoAlignmentReceiptV1?
    @Published private(set) var action4PoseTrack:
        ExternalVideoPoseTrack?
    @Published private(set) var iPhoneFrame:
        BodyMovementFrame?
    @Published private(set) var action4PoseFrame:
        ExternalVideoPoseFrame?
    @Published private(set) var referenceSeconds:
        Double = 0
    @Published private(set) var overlapStartSeconds:
        Double = 0
    @Published private(set) var overlapEndSeconds:
        Double = 0
    @Published private(set) var action4Seconds:
        Double = 0
    @Published private(set) var iPhoneAspectRatio:
        Double = 16.0 / 9.0
    @Published private(set) var action4AspectRatio:
        Double = 16.0 / 9.0
    @Published private(set) var playbackDriftMS:
        Double?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var correctionCount = 0
    @Published private(set) var errorMessage:
        String?

    private var pollTask: Task<Void, Never>?
    private var lastCorrectionAt: Date?

    private static let pollIntervalMS = 67
    private static let correctionThresholdMS = 90.0
    private static let correctionCooldownSeconds = 0.45
    private static let seekToleranceSeconds = 0.025

    var referenceDurationSeconds: Double {
        timeline?.durationSeconds ?? 0
    }

    var playableDurationSeconds: Double {
        max(
            0,
            overlapEndSeconds
                - overlapStartSeconds
        )
    }

    var currentReferenceTimeNS: UInt64 {
        nanoseconds(
            referenceSeconds
        )
    }

    var currentMappedAction4PTSNS:
        UInt64? {
        alignment?
            .mapReferenceTimeToVideoPTS(
                currentReferenceTimeNS
            )
    }

    func load(
        _ run: ProductRunRecord
    ) async {
        stop()
        isLoading = true
        errorMessage = nil
        guard let iPhoneURL =
                run.cameraVideoURL,
              let journalURL =
                run.cameraJournalURL
        else {
            fail(
                SynchronizedDualViewReplayError
                    .missingIPhoneEvidence
            )
            return
        }
        guard let actionURL =
                run.externalVideoURL
        else {
            fail(
                SynchronizedDualViewReplayError
                    .missingAction4Video
            )
            return
        }

        do {
            guard let alignment =
                    try Action4AlignmentSealer
                        .loadReceipt(for: run)
            else {
                throw SynchronizedDualViewReplayError
                    .missingAlignment
            }

            async let timelineTask =
                Task.detached(
                    priority: .utility
                ) {
                    try ProductReplayEvidenceLoader
                        .loadCameraTimeline(
                            journalURL
                        )
                }.value
            async let iPhoneAspectTask =
                MotionOSVideoPresentation
                    .displayAspectRatio(
                        for: iPhoneURL
                    )
            async let action4AspectTask =
                MotionOSVideoPresentation
                    .displayAspectRatio(
                        for: actionURL
                    )

            let timeline =
                try await timelineTask
            let loadedIPhoneAspect =
                await iPhoneAspectTask
            let loadedAction4Aspect =
                await action4AspectTask

            let iPhonePlayer =
                AVPlayer(url: iPhoneURL)
            let action4Player =
                AVPlayer(url: actionURL)

            iPhonePlayer.isMuted = true
            action4Player.isMuted = true
            iPhonePlayer
                .automaticallyWaitsToMinimizeStalling = false
            action4Player
                .automaticallyWaitsToMinimizeStalling = false

            guard let overlap =
                    DualViewPlaybackSyncPolicy
                        .referenceOverlapWindow(
                            referenceDurationSeconds:
                                timeline.durationSeconds,
                            sourceDurationNS:
                                alignment.sourceVideo.durationNS,
                            slope:
                                alignment.clockModel.slope,
                            interceptNS:
                                alignment.clockModel.interceptNS
                        ),
                  overlap.durationSeconds >= 1
            else {
                throw SynchronizedDualViewReplayError
                    .noPlayableOverlap
            }

            self.timeline = timeline
            self.alignment = alignment
            self.action4PoseTrack =
                try? Action4PoseTrackAnalyzer
                    .loadTrack(for: run)
            self.iPhonePlayer = iPhonePlayer
            self.action4Player = action4Player
            iPhoneAspectRatio =
                loadedIPhoneAspect
            action4AspectRatio =
                loadedAction4Aspect
            overlapStartSeconds =
                overlap.startSeconds
            overlapEndSeconds =
                overlap.endSeconds
            referenceSeconds =
                overlap.startSeconds
            playbackDriftMS = nil
            correctionCount = 0
            isLoading = false

            seek(
                toReferenceSeconds:
                    overlap.startSeconds,
                preservePlayback: false
            )
            startPolling()
        } catch {
            fail(error)
        }
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard iPhonePlayer != nil,
              action4Player != nil,
              playableDurationSeconds > 0
        else {
            return
        }

        if referenceSeconds
            >= overlapEndSeconds - 0.05 {
            seek(
                toReferenceSeconds:
                    overlapStartSeconds,
                preservePlayback: false
            )
        }

        startPlayersTogether(
            atReferenceSeconds:
                referenceSeconds
        )
        isPlaying = true
    }

    func pause() {
        iPhonePlayer?.pause()
        action4Player?.pause()
        isPlaying = false
    }

    func seek(
        toReferenceSeconds seconds: Double,
        preservePlayback: Bool = true
    ) {
        guard let iPhonePlayer,
              let action4Player,
              let alignment
        else {
            return
        }

        let wasPlaying =
            preservePlayback && isPlaying
        if wasPlaying {
            iPhonePlayer.pause()
            action4Player.pause()
        }

        let reference =
            min(
                overlapEndSeconds,
                max(
                    overlapStartSeconds,
                    seconds
                )
            )
        let referenceNS =
            nanoseconds(reference)

        guard let actionPTSNS =
                alignment
                    .mapReferenceTimeToVideoPTS(
                        referenceNS
                    )
        else {
            return
        }

        let tolerance = CMTime(
            seconds:
                Self.seekToleranceSeconds,
            preferredTimescale: 600
        )
        iPhonePlayer.seek(
            to: mediaTime(reference),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
        action4Player.seek(
            to:
                mediaTimeNS(
                    actionPTSNS
                ),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )

        referenceSeconds = reference
        action4Seconds =
            Double(actionPTSNS)
                / 1_000_000_000
        playbackDriftMS = 0
        updateEvidenceFrames(
            referenceSeconds: reference,
            action4Seconds: action4Seconds
        )

        if wasPlaying {
            startPlayersTogether(
                atReferenceSeconds:
                    reference
            )
        }
    }

    func skip(
        by seconds: Double
    ) {
        seek(
            toReferenceSeconds:
                referenceSeconds + seconds
        )
    }

    func stop() {
        pause()
        pollTask?.cancel()
        pollTask = nil
        iPhonePlayer = nil
        action4Player = nil
        timeline = nil
        alignment = nil
        action4PoseTrack = nil
        iPhoneFrame = nil
        action4PoseFrame = nil
        playbackDriftMS = nil
        iPhoneAspectRatio =
            16.0 / 9.0
        action4AspectRatio =
            16.0 / 9.0
        overlapStartSeconds = 0
        overlapEndSeconds = 0
        correctionCount = 0
        lastCorrectionAt = nil
        isLoading = false
    }

    private func startPolling() {
        pollTask?.cancel()
        let controller = self
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                controller
                    .updatePlaybackState()
                try? await Task.sleep(
                    for:
                        .milliseconds(
                            Self.pollIntervalMS
                        )
                )
            }
        }
    }

    private func updatePlaybackState() {
        guard let iPhonePlayer,
              let action4Player,
              let alignment,
              playableDurationSeconds > 0
        else {
            return
        }

        let reference =
            CMTimeGetSeconds(
                iPhonePlayer.currentTime()
            )
        guard reference.isFinite,
              reference >= 0
        else {
            return
        }

        let boundedReference =
            min(
                overlapEndSeconds,
                max(
                    overlapStartSeconds,
                    reference
                )
            )
        referenceSeconds =
            boundedReference

        guard let expectedActionNS =
                alignment
                    .mapReferenceTimeToVideoPTS(
                        nanoseconds(
                            boundedReference
                        )
                    )
        else {
            return
        }

        let expectedActionSeconds =
            Double(expectedActionNS)
                / 1_000_000_000
        let actualActionSeconds =
            CMTimeGetSeconds(
                action4Player.currentTime()
            )
        let usableActionSeconds =
            actualActionSeconds.isFinite
                && actualActionSeconds >= 0
                ? actualActionSeconds
                : expectedActionSeconds

        action4Seconds =
            usableActionSeconds

        let correctionAllowed =
            isPlaying && canCorrectNow()
        guard let syncDecision =
                DualViewPlaybackSyncPolicy
                    .evaluateMappedReference(
                        referencePTSNS:
                            nanoseconds(
                                boundedReference
                            ),
                        observedSourcePTSNS:
                            nanoseconds(
                                usableActionSeconds
                            ),
                        slope:
                            alignment
                                .clockModel
                                .slope,
                        interceptNS:
                            alignment
                                .clockModel
                                .interceptNS,
                        correctionThresholdMS:
                            Self
                                .correctionThresholdMS,
                        correctionAllowed:
                            correctionAllowed
                    )
        else {
            playbackDriftMS = nil
            return
        }
        playbackDriftMS =
            syncDecision.driftMS

        updateEvidenceFrames(
            referenceSeconds:
                boundedReference,
            action4Seconds:
                usableActionSeconds
        )

        if syncDecision.shouldCorrect {
            scheduleAction4Correction(
                fromReferenceSeconds:
                    boundedReference
            )
        }

        if boundedReference
            >= overlapEndSeconds - 0.03 {
            pause()
        }
    }

    private func startPlayersTogether(
        atReferenceSeconds reference:
            Double
    ) {
        guard let iPhonePlayer,
              let action4Player,
              let alignment,
              let actionPTSNS =
                alignment
                    .mapReferenceTimeToVideoPTS(
                        nanoseconds(reference)
                    )
        else {
            return
        }

        let hostStart =
            CMTimeAdd(
                CMClockGetTime(
                    CMClockGetHostTimeClock()
                ),
                CMTime(
                    seconds: 0.08,
                    preferredTimescale: 1_000
                )
            )

        iPhonePlayer.setRate(
            1,
            time:
                mediaTime(reference),
            atHostTime: hostStart
        )
        action4Player.setRate(
            1,
            time:
                mediaTimeNS(
                    actionPTSNS
                ),
            atHostTime: hostStart
        )
        lastCorrectionAt = Date()
    }

    private func scheduleAction4Correction(
        fromReferenceSeconds reference:
            Double
    ) {
        guard let action4Player,
              let alignment
        else {
            return
        }

        let leadSeconds = 0.08
        let targetReference =
            min(
                overlapEndSeconds,
                reference
                    + leadSeconds
            )
        guard let actionPTSNS =
                alignment
                    .mapReferenceTimeToVideoPTS(
                        nanoseconds(
                            targetReference
                        )
                    )
        else {
            return
        }

        let hostTime =
            CMTimeAdd(
                CMClockGetTime(
                    CMClockGetHostTimeClock()
                ),
                CMTime(
                    seconds:
                        leadSeconds,
                    preferredTimescale:
                        1_000
                )
            )

        action4Player.setRate(
            1,
            time:
                mediaTimeNS(
                    actionPTSNS
                ),
            atHostTime:
                hostTime
        )
        lastCorrectionAt = Date()
        correctionCount += 1
    }

    private func canCorrectNow() -> Bool {
        guard let lastCorrectionAt else {
            return true
        }
        return Date()
            .timeIntervalSince(
                lastCorrectionAt
            )
            >= Self
                .correctionCooldownSeconds
    }

    private func updateEvidenceFrames(
        referenceSeconds: Double,
        action4Seconds: Double
    ) {
        if let timeline {
            let offset =
                nanoseconds(
                    referenceSeconds
                )
            let addition =
                timeline.firstFramePTSNS
                    .addingReportingOverflow(
                        offset
                    )
            if !addition.overflow {
                iPhoneFrame =
                    nearestPose(
                        to:
                            addition
                                .partialValue,
                        samples:
                            timeline.poseSamples
                    )
            } else {
                iPhoneFrame = nil
            }
        } else {
            iPhoneFrame = nil
        }

        action4PoseFrame =
            action4PoseTrack?
                .interpolatedFrame(
                    at:
                        nanoseconds(
                            action4Seconds
                        )
                )
    }

    private func nearestPose(
        to target: UInt64,
        samples: [ProductReplayPoseSample]
    ) -> BodyMovementFrame? {
        guard !samples.isEmpty else {
            return nil
        }

        var low = 0
        var high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].ptsNS
                < target {
                low = middle + 1
            } else {
                high = middle
            }
        }

        let candidates = [
            low > 0
                ? samples[low - 1]
                : nil,
            low < samples.count
                ? samples[low]
                : nil,
        ]
        .compactMap { $0 }

        guard let nearest =
                candidates.min(by: {
                    distance(
                        $0.ptsNS,
                        target
                    )
                        < distance(
                            $1.ptsNS,
                            target
                        )
                }),
              distance(
                nearest.ptsNS,
                target
              ) <= 350_000_000
        else {
            return nil
        }

        return nearest.frame
    }

    private func distance(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        lhs >= rhs
            ? lhs - rhs
            : rhs - lhs
    }

    private func nanoseconds(
        _ seconds: Double
    ) -> UInt64 {
        guard seconds.isFinite,
              seconds > 0
        else {
            return 0
        }
        return UInt64(
            min(
                Double(UInt64.max),
                seconds
                    * 1_000_000_000
            )
            .rounded(
                .toNearestOrEven
            )
        )
    }

    private func mediaTime(
        _ seconds: Double
    ) -> CMTime {
        CMTime(
            seconds:
                max(0, seconds),
            preferredTimescale: 600
        )
    }

    private func mediaTimeNS(
        _ value: UInt64
    ) -> CMTime {
        CMTime(
            value:
                Int64(
                    min(
                        value,
                        UInt64(Int64.max)
                    )
                ),
            timescale:
                1_000_000_000
        )
    }

    private func fail(
        _ error: Error
    ) {
        pause()
        isLoading = false
        errorMessage =
            error.localizedDescription
    }
}

private struct SynchronizedVideoSurface:
    UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(
        context: Context
    ) -> SynchronizedPlayerLayerView {
        let view =
            SynchronizedPlayerLayerView()
        view.player = player
        return view
    }

    func updateUIView(
        _ uiView:
            SynchronizedPlayerLayerView,
        context: Context
    ) {
        uiView.player = player
    }
}

private final class SynchronizedPlayerLayerView:
    UIView {
    override class var layerClass:
        AnyClass {
        AVPlayerLayer.self
    }

    private var playerLayer:
        AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    var player: AVPlayer? {
        get {
            playerLayer.player
        }
        set {
            playerLayer.player =
                newValue
            playerLayer.videoGravity =
                .resizeAspect
            backgroundColor = .black
        }
    }
}

struct SynchronizedDualViewReplayView: View {
    let run: ProductRunRecord

    @StateObject private var controller =
        SynchronizedDualViewReplayController()

    @State private var sliderSeconds:
        Double = 0
    @State private var isScrubbing = false
    @State private var resumeAfterScrub = false
    @State private var showIPhonePose = true
    @State private var showAction4Pose = true
    @State private var showAction4Equipment = true
    @State private var showConfidence = false
    @State private var reviewLedger:
        ReplayReviewLedgerV1?
    @State private var reviewError:
        String?
    @State private var isSavingReview = false
    @State private var lastSavedReviewID:
        String?

    var body: some View {
        ScrollView {
            LazyVStack(
                spacing:
                    MotionOSDesign
                        .pageSpacing
            ) {
                hero
                comparisonStage
                transportControls
                reviewMarkersCard

                if let alignment =
                        controller.alignment {
                    reviewedLandmarks(
                        alignment
                    )
                }

                evidenceCard
            }
            .motionOSPageWidth()
            .padding(
                .horizontal,
                MotionOSDesign
                    .pageHorizontalPadding
            )
            .padding(.vertical, 12)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Compare Views")
        .navigationBarTitleDisplayMode(
            .inline
        )
        .task(id: run.runID) {
            loadReviewLedger()
            await controller.load(run)
        }
        .onDisappear {
            controller.stop()
        }
        .onChange(
            of:
                controller
                    .referenceSeconds
        ) { _, value in
            guard !isScrubbing else {
                return
            }
            sliderSeconds = value
        }
    }

    private var hero: some View {
        VStack(
            alignment: .leading,
            spacing: 10
        ) {
            MotionOSSectionHeader(
                title:
                    "Synchronized camera comparison",
                subtitle:
                    "One reference clock · two preserved videos",
                systemImage:
                    "rectangle.on.rectangle",
                accent: .cyan
            )

            Text(
                "The iPhone timeline is the playback reference. "
                    + "Action 4 time is mapped through the reviewed "
                    + "video-alignment receipt and corrected only when "
                    + "local-player drift exceeds 90 ms."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let alignment =
                    controller.alignment {
                HStack(spacing: 8) {
                    metric(
                        "Fit RMS",
                        String(
                            format:
                                "%.1f ms",
                            alignment
                                .clockModel
                                .residualRMSMS
                        )
                    )
                    metric(
                        "Drift",
                        controller
                            .playbackDriftMS
                            .map {
                                String(
                                    format:
                                        "%+.0f ms",
                                    $0
                                )
                            }
                            ?? "—"
                    )
                    metric(
                        "Corrections",
                        "\(controller.correctionCount)"
                    )
                }

                HStack(spacing: 8) {
                    metric(
                        "Shared window",
                        String(
                            format:
                                "%.1f s",
                            controller
                                .playableDurationSeconds
                        )
                    )
                    metric(
                        "Starts",
                        formatTime(
                            controller
                                .overlapStartSeconds
                        )
                    )
                    metric(
                        "Ends",
                        formatTime(
                            controller
                                .overlapEndSeconds
                        )
                    )
                }
            }
        }
        .cardStyle()
    }

    private var comparisonStage: some View {
        VStack(spacing: 12) {
            cameraPane(
                title: "iPhone",
                subtitle:
                    "Reference · "
                    + formatTime(
                        controller
                            .referenceSeconds
                    ),
                player:
                    controller
                        .iPhonePlayer,
                aspectRatio:
                    controller
                        .iPhoneAspectRatio,
                accent: .cyan
            ) {
                if showIPhonePose,
                   let frame =
                    controller.iPhoneFrame {
                    ReplayPoseOverlay(
                        frame: frame,
                        showBody: true,
                        showBalance: true,
                        showMechanics: true,
                        showConfidence:
                            showConfidence
                    )
                    .allowsHitTesting(false)
                }
            }

            HStack(spacing: 8) {
                Capsule()
                    .fill(
                        Color.secondary
                            .opacity(0.22)
                    )
                    .frame(height: 1)
                Label(
                    "same physical instant",
                    systemImage:
                        "arrow.up.arrow.down"
                )
                .font(
                    .caption.weight(
                        .semibold
                    )
                )
                .foregroundStyle(.secondary)
                Capsule()
                    .fill(
                        Color.secondary
                            .opacity(0.22)
                    )
                    .frame(height: 1)
            }

            cameraPane(
                title: "Action 4",
                subtitle:
                    "Source · "
                    + formatTime(
                        controller
                            .action4Seconds
                    ),
                player:
                    controller
                        .action4Player,
                aspectRatio:
                    controller
                        .action4AspectRatio,
                accent: .purple
            ) {
                if showAction4Pose,
                   let frame =
                    controller
                        .action4PoseFrame {
                    ExternalVideoPoseOverlay(
                        frame: frame,
                        showConfidence:
                            showConfidence,
                        showEquipment:
                            showAction4Equipment
                    )
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func cameraPane<Overlay: View>(
        title: String,
        subtitle: String,
        player: AVPlayer?,
        aspectRatio: Double,
        accent: Color,
        @ViewBuilder overlay:
            () -> Overlay
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 7
        ) {
            HStack {
                Text(title)
                    .font(
                        .headline.weight(
                            .semibold
                        )
                    )
                    .foregroundStyle(accent)

                Spacer()

                Text(subtitle)
                    .font(
                        .system(
                            .caption,
                            design:
                                .monospaced
                        )
                    )
                    .foregroundStyle(
                        .secondary
                    )
            }

            ZStack {
                RoundedRectangle(
                    cornerRadius: 18,
                    style: .continuous
                )
                .fill(Color.black)

                if controller.isLoading {
                    ProgressView()
                        .tint(.white)
                } else if let player {
                    SynchronizedVideoSurface(
                        player: player
                    )
                    .allowsHitTesting(false)

                    overlay()
                } else {
                    Text(
                        controller
                            .errorMessage
                            ?? "Video unavailable"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        .white.opacity(0.75)
                    )
                    .multilineTextAlignment(
                        .center
                    )
                    .padding()
                }
            }
            .aspectRatio(
                aspectRatio,
                contentMode: .fit
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 18,
                    style: .continuous
                )
            )
        }
        .cardStyle()
    }

    private var scrubRange:
        ClosedRange<Double> {
        let lower =
            controller
                .overlapStartSeconds
        let upper =
            max(
                lower + 0.01,
                controller
                    .overlapEndSeconds
            )
        return lower...upper
    }

    private var transportControls: some View {
        VStack(spacing: 12) {
            Slider(
                value: $sliderSeconds,
                in: scrubRange,
                onEditingChanged: {
                    editing in
                    if editing {
                        isScrubbing = true
                        resumeAfterScrub =
                            controller
                                .isPlaying
                        controller.pause()
                    } else {
                        controller.seek(
                            toReferenceSeconds:
                                sliderSeconds,
                            preservePlayback:
                                false
                        )
                        isScrubbing = false
                        if resumeAfterScrub {
                            controller.play()
                        }
                        resumeAfterScrub =
                            false
                    }
                }
            )
            .disabled(
                controller
                    .playableDurationSeconds
                    <= 0
            )

            HStack {
                Text(
                    formatTime(
                        sliderSeconds
                    )
                )
                Spacer()
                Text(
                    formatTime(
                        controller
                            .overlapEndSeconds
                    )
                )
            }
            .font(
                .system(
                    .caption,
                    design: .monospaced
                )
            )
            .foregroundStyle(.secondary)

            HStack(spacing: 18) {
                Button {
                    controller.skip(
                        by: -5
                    )
                } label: {
                    Image(
                        systemName:
                            "gobackward.5"
                    )
                }

                Button {
                    controller
                        .togglePlayback()
                } label: {
                    Image(
                        systemName:
                            controller
                                .isPlaying
                                ? "pause.fill"
                                : "play.fill"
                    )
                    .font(.title2)
                    .frame(
                        width: 54,
                        height: 40
                    )
                }
                .buttonStyle(
                    .borderedProminent
                )

                Button {
                    controller.skip(
                        by: 5
                    )
                } label: {
                    Image(
                        systemName:
                            "goforward.5"
                    )
                }

                Menu {
                    reviewMenuButton(
                        "Needs review",
                        systemImage:
                            "flag.fill",
                        scope: .other,
                        verdict: .inspect
                    )
                    reviewMenuButton(
                        "Timing mismatch",
                        systemImage:
                            "clock.badge.exclamationmark",
                        scope: .timing,
                        verdict: .wrong
                    )
                    reviewMenuButton(
                        "iPhone pose wrong",
                        systemImage:
                            "figure.stand.line.dotted.figure.stand",
                        scope: .iPhonePose,
                        verdict: .wrong
                    )
                    reviewMenuButton(
                        "Action 4 pose wrong",
                        systemImage:
                            "figure.arms.open",
                        scope: .action4Pose,
                        verdict: .wrong
                    )
                    reviewMenuButton(
                        "Board / roller wrong",
                        systemImage:
                            "skateboard",
                        scope: .equipment,
                        verdict: .wrong
                    )
                    reviewMenuButton(
                        "Occluded / unsupported",
                        systemImage:
                            "eye.slash",
                        scope: .other,
                        verdict: .occluded
                    )
                    Divider()
                    reviewMenuButton(
                        "Good example",
                        systemImage:
                            "star.fill",
                        scope: .behavior,
                        verdict: .goodExample
                    )
                } label: {
                    Image(
                        systemName:
                            isSavingReview
                                ? "hourglass"
                                : "flag"
                    )
                }
                .disabled(
                    isSavingReview
                        || controller.alignment
                            == nil
                )
            }
            .buttonStyle(.bordered)
            .disabled(
                controller.isLoading
                    || controller
                        .errorMessage
                        != nil
            )

            Divider()

            Toggle(
                "iPhone body / mechanics",
                isOn: $showIPhonePose
            )
            Toggle(
                "Action 4 source pose",
                isOn: $showAction4Pose
            )

            if (
                controller.action4PoseTrack?
                    .equipmentFrameCount
                    ?? 0
            ) > 0 {
                Toggle(
                    "Action 4 QR board / roller",
                    isOn:
                        $showAction4Equipment
                )
            }

            Toggle(
                "Pose confidence",
                isOn: $showConfidence
            )
        }
        .cardStyle()
    }

    private func reviewedLandmarks(
        _ alignment:
            VideoAlignmentReceiptV1
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 10
        ) {
            MotionOSSectionHeader(
                title:
                    "Reviewed landmarks",
                subtitle:
                    "Jump both videos to the accepted physical sync events",
                systemImage:
                    "scope",
                accent: .green
            )

            HStack(spacing: 8) {
                ForEach(
                    alignment.anchors,
                    id: \.label
                ) { anchor in
                    let seconds =
                        Double(
                            anchor
                                .referenceTimeNS
                        )
                        / 1_000_000_000
                    Button {
                        controller.seek(
                            toReferenceSeconds:
                                seconds
                        )
                    } label: {
                        VStack(spacing: 3) {
                            Text(
                                anchor.label
                                    .uppercased()
                            )
                            .font(
                                .caption2
                                    .weight(
                                        .bold
                                    )
                            )
                            Text(
                                formatTime(
                                    seconds
                                )
                            )
                            .font(
                                .system(
                                    .caption2,
                                    design:
                                        .monospaced
                                )
                            )
                        }
                        .frame(
                            maxWidth:
                                .infinity
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        seconds
                            < controller
                                .overlapStartSeconds
                            || seconds
                                > controller
                                    .overlapEndSeconds
                    )
                }
            }

            Text(
                "These buttons use the sealed reviewed anchors directly. "
                    + "A disabled landmark lies outside the shared playable "
                    + "interval and is never synthesized by clamping."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private var evidenceCard: some View {
        VStack(
            alignment: .leading,
            spacing: 9
        ) {
            MotionOSSectionHeader(
                title: "Interpretation boundary",
                subtitle:
                    "Timing comparison, not calibrated geometry",
                systemImage:
                    "checkmark.shield",
                accent: .green
            )

            evidenceRow(
                "iPhone time",
                "reference camera elapsed PTS"
            )
            evidenceRow(
                "Action 4 time",
                "reviewed affine video-alignment map"
            )
            evidenceRow(
                "iPhone overlay",
                controller.iPhoneFrame == nil
                    ? "no nearby pose"
                    : "derived Vision/body evidence"
            )
            evidenceRow(
                "Action 4 overlay",
                controller.action4PoseFrame
                    == nil
                    ? "no nearby source pose"
                    : "derived from Action 4 RGB"
            )

            Text(
                "Playback drift is a player-scheduling diagnostic, not "
                    + "alignment uncertainty. Agreement between the two "
                    + "pictures is useful evidence, but 3D triangulation "
                    + "still requires calibrated intrinsics, distortion, "
                    + "extrinsics, mount verification, and a qualified rig."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private func evidenceRow(
        _ label: String,
        _ value: String
    ) -> some View {
        HStack(
            alignment: .firstTextBaseline
        ) {
            Text(label)
                .font(
                    .caption.weight(
                        .semibold
                    )
                )
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(
                    .trailing
                )
        }
    }

    private func metric(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 3
        ) {
            Text(title.uppercased())
                .font(
                    .caption2.weight(
                        .bold
                    )
                )
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

    private func formatTime(
        _ seconds: Double
    ) -> String {
        guard seconds.isFinite,
              seconds >= 0
        else {
            return "—"
        }
        let minutes =
            Int(seconds) / 60
        let remainder =
            seconds
                - Double(minutes * 60)
        return String(
            format:
                "%d:%05.2f",
            minutes,
            remainder
        )
    }
}

import Foundation
import MotionOSAppleCapture

struct IndoBoardStanceAssessment: Equatable, Sendable {
    enum State: String, Sendable {
        case waitingForFraming = "waiting_for_framing"
        case settling
        case stable
    }

    let state: State
    let progress: Double
    let stableDurationSeconds: Double
    let title: String
    let instruction: String

    static let waiting = IndoBoardStanceAssessment(
        state: .waitingForFraming,
        progress: 0,
        stableDurationSeconds: 0,
        title: "Find a usable camera position",
        instruction: "Get your full body and both feet into frame first."
    )
}

@MainActor
final class IndoBoardStanceGate {
    private struct Sample: Sendable {
        let timeSeconds: Double
        let centerX: Double
        let centerY: Double
        let width: Double
        let height: Double
    }

    private var samples: [Sample] = []

    let requiredStableSeconds: Double

    init(requiredStableSeconds: Double = 2.0) {
        self.requiredStableSeconds = requiredStableSeconds
    }

    func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    func update(
        frame: BodyMovementFrame?,
        framing: CameraFramingAssessment
    ) -> IndoBoardStanceAssessment {
        guard framing.state == .ready,
              let frame,
              let image = frame.imageFraming
        else {
            reset()
            return .waiting
        }

        let sample = Sample(
            timeSeconds: Double(frame.deviceTimeNS) / 1_000_000_000.0,
            centerX: image.bounds.centerX,
            centerY: image.bounds.centerY,
            width: image.bounds.width,
            height: image.bounds.height
        )
        append(sample)

        let stableSuffix = longestStableSuffix()
        guard let first = stableSuffix.first,
              let last = stableSuffix.last
        else {
            return settling(duration: 0)
        }

        let duration = max(0, last.timeSeconds - first.timeSeconds)
        let progress = min(1, duration / requiredStableSeconds)

        if duration >= requiredStableSeconds,
           stableSuffix.count >= 8 {
            return IndoBoardStanceAssessment(
                state: .stable,
                progress: 1,
                stableDurationSeconds: duration,
                title: "Stable stance detected",
                instruction: "Hold here. Your Watch is ready to start the session."
            )
        }

        return IndoBoardStanceAssessment(
            state: .settling,
            progress: progress,
            stableDurationSeconds: duration,
            title: progress > 0.55
                ? "Almost ready"
                : "Hold a comfortable neutral stance",
            instruction:
                "Stay naturally balanced for about \(Int(ceil(max(0, requiredStableSeconds - duration)))) more second"
                + (requiredStableSeconds - duration > 1.05 ? "s." : ".")
        )
    }

    private func append(_ sample: Sample) {
        if let previous = samples.last,
           sample.timeSeconds <= previous.timeSeconds
                || sample.timeSeconds - previous.timeSeconds > 0.75 {
            samples.removeAll(keepingCapacity: true)
        }

        samples.append(sample)

        let cutoff = sample.timeSeconds - max(3.0, requiredStableSeconds + 0.75)
        if let firstKept = samples.firstIndex(where: {
            $0.timeSeconds >= cutoff
        }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
    }

    private func longestStableSuffix() -> [Sample] {
        guard let newest = samples.last else {
            return []
        }

        var suffix: [Sample] = []
        var minCenterX = newest.centerX
        var maxCenterX = newest.centerX
        var minCenterY = newest.centerY
        var maxCenterY = newest.centerY
        var minWidth = newest.width
        var maxWidth = newest.width
        var minHeight = newest.height
        var maxHeight = newest.height

        for sample in samples.reversed() {
            minCenterX = min(minCenterX, sample.centerX)
            maxCenterX = max(maxCenterX, sample.centerX)
            minCenterY = min(minCenterY, sample.centerY)
            maxCenterY = max(maxCenterY, sample.centerY)
            minWidth = min(minWidth, sample.width)
            maxWidth = max(maxWidth, sample.width)
            minHeight = min(minHeight, sample.height)
            maxHeight = max(maxHeight, sample.height)

            let stable =
                maxCenterX - minCenterX <= 0.040
                    && maxCenterY - minCenterY <= 0.045
                    && maxWidth - minWidth <= 0.070
                    && maxHeight - minHeight <= 0.060

            if !stable {
                break
            }
            suffix.append(sample)
        }

        return suffix.reversed()
    }

    private func settling(
        duration: Double
    ) -> IndoBoardStanceAssessment {
        IndoBoardStanceAssessment(
            state: .settling,
            progress: min(1, duration / requiredStableSeconds),
            stableDurationSeconds: duration,
            title: "Hold a comfortable neutral stance",
            instruction: "Stay naturally balanced while MotionOS checks the setup."
        )
    }
}

import Foundation

/// Physical/setup reminders only. This is not a substitute for the app's
/// Watch, camera, battery, storage, or evidence-sealing qualification gates.
public struct IndoBoardFirstCaptureStep: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

public enum IndoBoardFirstCaptureGuide {
    public static let standardSteps: [IndoBoardFirstCaptureStep] = [
        .init(
            id: "safety",
            title: "Clear the riding area",
            detail: "Keep a stable handhold nearby. Move the phone, tripod, and other obstacles outside your fall and recovery space."
        ),
        .init(
            id: "framing",
            title: "Frame the entire movement",
            detail: "Keep your head, both feet, board, roller, and room for arm and knee corrections visible. Use a fixed rear-camera view."
        ),
        .init(
            id: "lighting",
            title: "Check lighting and clothing",
            detail: "Use even, bright light to limit blur. Avoid strong backlighting and clothing that hides knees or ankles."
        ),
        .init(
            id: "devices",
            title: "Confirm Watch and camera readiness",
            detail: "Open MotionOS on both devices and run Check My Setup. The app verifies camera format, battery, storage, and Watch state."
        ),
    ]

    public static let multiviewStep = IndoBoardFirstCaptureStep(
        id: "action4",
        title: "Start the external camera manually",
        detail: "Use a fixed second view and start Action 4 recording before stepping onto the board. Import the original movie after the run."
    )

    public static func steps(externalCamera: Bool) -> [IndoBoardFirstCaptureStep] {
        externalCamera ? standardSteps + [multiviewStep] : standardSteps
    }

    // Keep this view tied to the capture authority rather than duplicating
    // a stale protocol in app strings or printed runbooks.
    public static var blocks: [TimedProtocolBlock] {
        IndoBoardProductProtocol.blocks
    }

    public static var syncWindows: [TimedSyncWindow] {
        IndoBoardProductProtocol.syncWindows
    }

    public static var durationSeconds: Double {
        IndoBoardProductProtocol.targetDurationSeconds
    }
}

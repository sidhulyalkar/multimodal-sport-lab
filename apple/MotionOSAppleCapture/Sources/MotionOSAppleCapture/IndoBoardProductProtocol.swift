import Foundation

public struct TimedProtocolBlock: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let instruction: String
    public let startSeconds: Double
    public let endSeconds: Double

    public init(
        id: String,
        title: String,
        instruction: String,
        startSeconds: Double,
        endSeconds: Double
    ) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    public func contains(_ elapsedSeconds: Double) -> Bool {
        elapsedSeconds >= startSeconds && elapsedSeconds < endSeconds
    }
}

public struct TimedSyncWindow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let startSeconds: Double
    public let preferredSeconds: Double
    public let endSeconds: Double
    public let instruction: String

    public init(
        id: String,
        label: String,
        startSeconds: Double,
        preferredSeconds: Double,
        endSeconds: Double,
        instruction: String
    ) {
        self.id = id
        self.label = label
        self.startSeconds = startSeconds
        self.preferredSeconds = preferredSeconds
        self.endSeconds = endSeconds
        self.instruction = instruction
    }

    public func contains(_ elapsedSeconds: Double) -> Bool {
        elapsedSeconds >= startSeconds && elapsedSeconds <= endSeconds
    }
}

public enum IndoBoardProductProtocol {
    public static let protocolID = "motionos.indo-board-product-session.v1"
    public static let targetDurationSeconds = 120.0

    public static let blocks: [TimedProtocolBlock] = [
        .init(
            id: "neutral-settle",
            title: "Neutral settle",
            instruction:
                "Balance naturally with soft knees. Let MotionOS learn your baseline.",
            startSeconds: 0,
            endSeconds: 15
        ),
        .init(
            id: "free-balance-a",
            title: "Natural free balance",
            instruction:
                "Balance normally. Do not exaggerate corrections for the camera.",
            startSeconds: 15,
            endSeconds: 35
        ),
        .init(
            id: "controlled-shifts",
            title: "Controlled side shifts",
            instruction:
                "Make five slow left/right shifts. Return to a clear center pause each time.",
            startSeconds: 35,
            endSeconds: 60
        ),
        .init(
            id: "partial-squats",
            title: "Partial squat control",
            instruction:
                "Perform three shallow controlled squats. Hold each bottom position briefly.",
            startSeconds: 60,
            endSeconds: 85
        ),
        .init(
            id: "free-balance-b",
            title: "Natural balance repeat",
            instruction:
                "Return to natural balance. Use whatever strategy now feels most controlled.",
            startSeconds: 85,
            endSeconds: 105
        ),
        .init(
            id: "neutral-finish",
            title: "Neutral finish",
            instruction:
                "Finish near neutral with quiet, comfortable corrections.",
            startSeconds: 105,
            endSeconds: 120
        ),
    ]

    public static let syncWindows: [TimedSyncWindow] = [
        .init(
            id: "sync-start",
            label: "start",
            startSeconds: 8,
            preferredSeconds: 10,
            endSeconds: 14,
            instruction:
                "When the Watch cues START sync, make one sharp arm gesture while keeping the board near neutral."
        ),
        .init(
            id: "sync-middle",
            label: "middle",
            startSeconds: 82,
            preferredSeconds: 85,
            endSeconds: 89,
            instruction:
                "When the Watch cues MIDDLE sync, make one sharp arm gesture, then return to natural balance."
        ),
        .init(
            id: "sync-end",
            label: "end",
            startSeconds: 110,
            preferredSeconds: 114,
            endSeconds: 119,
            instruction:
                "When the Watch cues END sync, make one sharp arm gesture while keeping the board near neutral."
        ),
    ]

    public static func reachedTarget(
        at elapsedSeconds: Double
    ) -> Bool {
        elapsedSeconds >= targetDurationSeconds
    }

    public static func activeBlock(
        at elapsedSeconds: Double
    ) -> TimedProtocolBlock? {
        blocks.first {
            $0.contains(elapsedSeconds)
        }
    }

    public static func activeSyncWindow(
        at elapsedSeconds: Double
    ) -> TimedSyncWindow? {
        syncWindows.first {
            $0.contains(elapsedSeconds)
        }
    }

    public static func instruction(
        at elapsedSeconds: Double,
        acknowledgedSyncLabels: Set<String>
    ) -> String {
        if let sync = activeSyncWindow(at: elapsedSeconds),
           !acknowledgedSyncLabels.contains(sync.label) {
            return sync.instruction
        }

        if let block = activeBlock(at: elapsedSeconds) {
            return block.instruction
        }

        return "Session target reached. Finish and seal when stable."
    }

    public static var isInternallyConsistent: Bool {
        guard blocks.first?.startSeconds == 0,
              blocks.last?.endSeconds == targetDurationSeconds
        else {
            return false
        }

        for block in blocks {
            guard block.startSeconds >= 0,
                  block.endSeconds > block.startSeconds,
                  block.endSeconds <= targetDurationSeconds
            else {
                return false
            }
        }

        for (first, second) in zip(blocks, blocks.dropFirst()) {
            guard first.endSeconds == second.startSeconds else {
                return false
            }
        }

        for sync in syncWindows {
            guard sync.startSeconds >= 0,
                  sync.preferredSeconds >= sync.startSeconds,
                  sync.endSeconds >= sync.preferredSeconds,
                  sync.endSeconds <= targetDurationSeconds
            else {
                return false
            }
        }

        return Set(syncWindows.map(\.label))
            == Set(["start", "middle", "end"])
    }
}

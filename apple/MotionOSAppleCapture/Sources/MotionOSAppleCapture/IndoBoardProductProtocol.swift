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
    public let endSeconds: Double
    public let instruction: String

    public init(
        id: String,
        label: String,
        startSeconds: Double,
        endSeconds: Double,
        instruction: String
    ) {
        self.id = id
        self.label = label
        self.startSeconds = startSeconds
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
            instruction: "Settle into a comfortable neutral balance.",
            startSeconds: 0,
            endSeconds: 20
        ),
        .init(
            id: "free-balance-a",
            title: "Natural free balance",
            instruction: "Balance naturally. Stay comfortable and visible to camera.",
            startSeconds: 20,
            endSeconds: 55
        ),
        .init(
            id: "tilt-recover",
            title: "Tilt + recover",
            instruction: "Perform five comfortable controlled tilt-and-recover cycles, alternating directions.",
            startSeconds: 55,
            endSeconds: 95
        ),
        .init(
            id: "free-balance-b",
            title: "Free balance repeat",
            instruction: "Return to natural free balance, then settle toward neutral.",
            startSeconds: 95,
            endSeconds: 110
        ),
        .init(
            id: "neutral-finish",
            title: "Neutral finish",
            instruction: "Finish near neutral with minimal voluntary motion.",
            startSeconds: 110,
            endSeconds: 120
        ),
    ]

    public static let syncWindows: [TimedSyncWindow] = [
        .init(
            id: "sync-start",
            label: "start",
            startSeconds: 10,
            endSeconds: 20,
            instruction: "Send START sync, then make one sharp arm gesture while keeping the board near neutral."
        ),
        .init(
            id: "sync-middle",
            label: "middle",
            startSeconds: 45,
            endSeconds: 60,
            instruction: "Send MIDDLE sync, then make one sharp arm gesture while keeping the board near neutral."
        ),
        .init(
            id: "sync-end",
            label: "end",
            startSeconds: 105,
            endSeconds: 120,
            instruction: "Send END sync, then make one sharp arm gesture while keeping the board near neutral."
        ),
    ]

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
                  sync.endSeconds >= sync.startSeconds,
                  sync.endSeconds <= targetDurationSeconds
            else {
                return false
            }
        }

        return Set(syncWindows.map(\.label))
            == Set(["start", "middle", "end"])
    }
}

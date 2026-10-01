import Foundation

/// A live snapshot stamped with the iPhone's own receive time, which is what
/// freshness and chart timing use. Watch wall clocks are not assumed to agree.
public struct LiveTelemetryFrame: Sendable, Equatable, Identifiable {
    public let snapshot: LiveTelemetrySnapshot
    public let receivedAt: Date

    public init(snapshot: LiveTelemetrySnapshot, receivedAt: Date) {
        self.snapshot = snapshot
        self.receivedAt = receivedAt
    }

    public var id: UInt64 { snapshot.sequence }
}

/// Deterministic reducer for the iPhone's live preview trace.
///
/// - One session at a time: a new session ID clears the previous trace and
///   retires the old ID, so late packets from it can never reappear.
/// - Duplicate and out-of-order sequences are ignored.
/// - Memory is bounded by a receive-time window and a hard frame cap.
public struct LiveTelemetryBuffer: Sendable, Equatable {
    public static let defaultRetention: TimeInterval = 60
    public static let defaultCapacity = 480

    public enum IngestOutcome: Sendable, Equatable {
        case startedSession
        case appended
        case duplicate
        case outOfOrder
        case retiredSession
    }

    /// Beta-qualification counters. Not shown in the normal product UI.
    public struct Diagnostics: Sendable, Equatable {
        public var received: UInt64 = 0
        public var appended: UInt64 = 0
        public var duplicates: UInt64 = 0
        public var outOfOrder: UInt64 = 0
        public var retiredSessionPackets: UInt64 = 0
        public var invalidPackets: UInt64 = 0
        public var sessionStarts: UInt64 = 0
        /// Sequence numbers skipped between appended packets, i.e. packets
        /// the Watch attempted but the iPhone never received.
        public var missingSequences: UInt64 = 0

        public init() {}
    }

    public let retention: TimeInterval
    public let capacity: Int
    public private(set) var sessionID: String?
    public private(set) var frames: [LiveTelemetryFrame] = []
    public private(set) var diagnostics = Diagnostics()
    private var lastSequence: UInt64?
    private var retiredSessionIDs: [String] = []
    private let retiredSessionLimit = 16

    public init(
        retention: TimeInterval = Self.defaultRetention,
        capacity: Int = Self.defaultCapacity
    ) {
        self.retention = max(1, retention)
        self.capacity = max(2, capacity)
    }

    public var latest: LiveTelemetryFrame? { frames.last }

    @discardableResult
    public mutating func ingest(
        _ snapshot: LiveTelemetrySnapshot,
        receivedAt: Date
    ) -> IngestOutcome {
        diagnostics.received &+= 1

        if retiredSessionIDs.contains(snapshot.sessionID) {
            diagnostics.retiredSessionPackets &+= 1
            return .retiredSession
        }

        let outcome: IngestOutcome
        if snapshot.sessionID != sessionID {
            if let sessionID {
                retire(sessionID)
            }
            sessionID = snapshot.sessionID
            frames.removeAll(keepingCapacity: true)
            lastSequence = nil
            diagnostics.sessionStarts &+= 1
            outcome = .startedSession
        } else if let lastSequence {
            if snapshot.sequence == lastSequence {
                diagnostics.duplicates &+= 1
                return .duplicate
            }
            if snapshot.sequence < lastSequence {
                diagnostics.outOfOrder &+= 1
                return .outOfOrder
            }
            diagnostics.missingSequences &+= snapshot.sequence - lastSequence - 1
            outcome = .appended
        } else {
            outcome = .appended
        }

        lastSequence = snapshot.sequence
        frames.append(
            LiveTelemetryFrame(snapshot: snapshot, receivedAt: receivedAt)
        )
        diagnostics.appended &+= 1
        trim(relativeTo: receivedAt)
        return outcome
    }

    public mutating func recordInvalidPacket() {
        diagnostics.invalidPackets &+= 1
    }

    /// Clears the trace, for example when the active Watch changes. Retired
    /// session IDs and diagnostics are kept.
    public mutating func clear() {
        if let sessionID {
            retire(sessionID)
        }
        sessionID = nil
        frames.removeAll()
        lastSequence = nil
    }

    /// Frames received at or after `date`.
    public func framesReceived(since date: Date) -> ArraySlice<LiveTelemetryFrame> {
        guard let index = frames.firstIndex(where: { $0.receivedAt >= date })
        else {
            return []
        }
        return frames[index...]
    }

    private mutating func retire(_ id: String) {
        guard !retiredSessionIDs.contains(id) else { return }
        retiredSessionIDs.append(id)
        if retiredSessionIDs.count > retiredSessionLimit {
            retiredSessionIDs.removeFirst(
                retiredSessionIDs.count - retiredSessionLimit
            )
        }
    }

    private mutating func trim(relativeTo now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        if let firstKept = frames.firstIndex(where: { $0.receivedAt >= cutoff }),
           firstKept > 0 {
            frames.removeFirst(firstKept)
        }
        if frames.count > capacity {
            frames.removeFirst(frames.count - capacity)
        }
    }
}

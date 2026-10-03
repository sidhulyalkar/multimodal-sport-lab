import Foundation

/// Why a capture event was not appended to the session journal.
public enum CaptureEventRejection: String, Sendable, Equatable, CaseIterable {
    /// The event belongs to the session being captured, but arrived after
    /// finalization began.
    case afterShutdown = "after_shutdown"
    /// The event's session ID differs from the active or finalizing session.
    case sessionMismatch = "session_mismatch"
    /// No capture session had been started when the event arrived.
    case noActiveSession = "no_active_session"
}

/// Counts of events rejected at the capture boundary.
///
/// These are operator evidence-health diagnostics, not raw evidence. They are
/// never written into the sensor journal and do not describe sample content.
public struct CaptureRejectionCounts: Sendable, Equatable {
    public private(set) var afterShutdown: UInt64 = 0
    public private(set) var sessionMismatch: UInt64 = 0
    public private(set) var noActiveSession: UInt64 = 0
    /// Core Motion callbacks dropped by the recorder's generation fence.
    public private(set) var staleMotionGeneration: UInt64 = 0

    public init() {}

    public var total: UInt64 {
        afterShutdown &+ sessionMismatch &+ noActiveSession
            &+ staleMotionGeneration
    }

    mutating func record(_ rejection: CaptureEventRejection) {
        switch rejection {
        case .afterShutdown:
            afterShutdown &+= 1
        case .sessionMismatch:
            sessionMismatch &+= 1
        case .noActiveSession:
            noActiveSession &+= 1
        }
    }

    mutating func setStaleMotionGeneration(_ count: UInt64) {
        staleMotionGeneration = count
    }
}

/// Decides, synchronously and before any journal I/O, whether a late or
/// foreign callback may append to the capture journal.
///
/// Once `beginFinalizing()` is called, events for the session are rejected as
/// `.afterShutdown`; events for any other session are rejected fail-closed as
/// `.sessionMismatch`. Rejections are counted rather than surfaced as errors,
/// so they never move capture state to failed.
public struct CaptureEventAdmission: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case capturing(sessionID: String)
        case finalizing(sessionID: String)
        case finished(sessionID: String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var rejections = CaptureRejectionCounts()

    public init() {}

    public var isCapturing: Bool {
        if case .capturing = phase { return true }
        return false
    }

    /// Starts a new session and resets the rejection counts.
    public mutating func begin(sessionID: String) {
        phase = .capturing(sessionID: sessionID)
        rejections = CaptureRejectionCounts()
    }

    public mutating func beginFinalizing() {
        if case .capturing(let sessionID) = phase {
            phase = .finalizing(sessionID: sessionID)
        }
    }

    public mutating func finish() {
        switch phase {
        case .capturing(let sessionID), .finalizing(let sessionID):
            phase = .finished(sessionID: sessionID)
        case .idle, .finished:
            break
        }
    }

    /// Returns `nil` when the event may be appended; otherwise the counted
    /// rejection reason.
    public mutating func admit(
        sessionID eventSessionID: String
    ) -> CaptureEventRejection? {
        let rejection: CaptureEventRejection?
        switch phase {
        case .idle:
            rejection = .noActiveSession
        case .capturing(let sessionID):
            rejection = eventSessionID == sessionID ? nil : .sessionMismatch
        case .finalizing(let sessionID), .finished(let sessionID):
            rejection = eventSessionID == sessionID
                ? .afterShutdown
                : .sessionMismatch
        }

        if let rejection {
            rejections.record(rejection)
        }
        return rejection
    }

    /// Counts a rejection decided elsewhere, such as by the journal itself.
    public mutating func recordRejection(_ rejection: CaptureEventRejection) {
        rejections.record(rejection)
    }

    /// Records how many Core Motion callbacks the generation fence dropped
    /// since this session began.
    public mutating func setStaleMotionGenerationCount(_ count: UInt64) {
        rejections.setStaleMotionGeneration(count)
    }
}

/// The write side of a capture journal. `JSONLJournal` is the production
/// writer; tests inject writers that suspend mid-append.
protocol CaptureJournalWriting: Sendable {
    func append(_ event: SensorEnvelope) async throws
    func close() async throws
}

extension JSONLJournal: CaptureJournalWriting {}

/// A single-session JSONL journal whose `close()` is a deterministic boundary.
///
/// - Appends that began before `close()` are drained and persisted.
/// - Appends that arrive once closing has begun are not written and return
///   `.rejected(.afterShutdown)` instead of throwing, so a late callback cannot
///   be mistaken for a journal I/O failure.
/// - Events for another session are rejected fail-closed.
public actor CaptureSessionJournal {
    public enum AppendOutcome: Sendable, Equatable {
        case appended(count: Int)
        case rejected(CaptureEventRejection)
    }

    public nonisolated let sessionID: String
    public nonisolated let url: URL

    private let journal: any CaptureJournalWriting
    private(set) var isClosing = false
    private var journalClosed = false
    private var inFlightAppends = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var appendedCount = 0

    public init(sessionID: String, url: URL) throws {
        self.init(
            sessionID: sessionID,
            url: url,
            writer: try JSONLJournal(url: url)
        )
    }

    init(
        sessionID: String,
        url: URL,
        writer: any CaptureJournalWriting
    ) {
        self.sessionID = sessionID
        self.url = url
        self.journal = writer
    }

    public func append(_ event: SensorEnvelope) async throws -> AppendOutcome {
        guard event.sessionID == sessionID else {
            return .rejected(.sessionMismatch)
        }
        guard !isClosing else {
            return .rejected(.afterShutdown)
        }

        // The journal hop below is an actor suspension point, so close() can
        // run meanwhile. Track this append so close() waits for it.
        inFlightAppends += 1
        defer { finishAppend() }

        try await journal.append(event)
        appendedCount += 1
        return .appended(count: appendedCount)
    }

    /// Stops admitting appends, waits for admitted appends to finish, then
    /// flushes and closes the journal. Returns the number of events written.
    public func close() async throws -> Int {
        isClosing = true

        while inFlightAppends > 0 {
            await withCheckedContinuation { continuation in
                drainWaiters.append(continuation)
            }
        }

        if !journalClosed {
            journalClosed = true
            try await journal.close()
        }
        return appendedCount
    }

    private func finishAppend() {
        inFlightAppends -= 1
        guard inFlightAppends == 0 else { return }

        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

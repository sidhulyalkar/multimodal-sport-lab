import Foundation

/// The Watch capture state as reported by MotionOS Watch presence. Raw values
/// match `WatchSessionController.CaptureState`.
public enum WatchCapturePhase: Sendable, Equatable {
    case idle
    case authorizing
    case starting
    case recording
    case paused
    case finishing
    case saved
    case failed
    case unknown

    public init(presenceCaptureState raw: String) {
        switch raw.lowercased() {
        case "idle":
            self = .idle
        case "authorizing":
            self = .authorizing
        case "starting":
            self = .starting
        case "running":
            self = .recording
        case "paused":
            self = .paused
        case "ending":
            self = .finishing
        case "journalready", "transferqueued", "transportcomplete",
            "transferred":
            self = .saved
        case "failed":
            self = .failed
        default:
            self = .unknown
        }
    }

    public var isRecordingActive: Bool {
        switch self {
        case .starting, .recording, .paused, .finishing:
            true
        default:
            false
        }
    }
}

/// The iPhone's mirrored-workout view of a Watch recording it launched.
public enum MirroredWorkoutPhase: Sendable, Equatable {
    case none
    case launching
    case recording
    case paused
}

/// Product-facing Apple Watch status. One value, used by every screen.
/// Pairing, reachability, install bits, and presence age are diagnostics.
public enum WatchLinkStatus: Sendable, Equatable {
    case checking
    case ready
    case recording
    case appSetup(needsInstall: Bool)
    case noWatch
    case issue

    public var isReady: Bool {
        self == .ready || self == .recording
    }
}

/// What the Live Observatory should present. Exactly one phase at a time.
public enum LiveObservatoryPhase: Sendable, Equatable {
    case checking
    case watchSetupRequired
    case ready
    case starting
    case live
    case reconnecting
    case paused
    case finishing
    case saved
    case issue

    /// Only `.live` may present the trace as moving and badge it LIVE.
    public var isLive: Bool { self == .live }

    /// Whether the current session's trace belongs on screen at all.
    public var showsSessionTrace: Bool {
        switch self {
        case .live, .reconnecting, .paused, .finishing:
            true
        default:
            false
        }
    }

    public var isRecordingActive: Bool {
        switch self {
        case .starting, .live, .reconnecting, .paused, .finishing:
            true
        default:
            false
        }
    }
}

public struct WatchObservationInput: Sendable, Equatable {
    public struct Presence: Sendable, Equatable {
        public let capturePhase: WatchCapturePhase
        public let sessionID: String?
        /// iPhone receive time of this presence, not re-stamped on replay.
        public let receivedAt: Date

        public init(
            capturePhase: WatchCapturePhase,
            sessionID: String?,
            receivedAt: Date
        ) {
            self.capturePhase = capturePhase
            self.sessionID = sessionID
            self.receivedAt = receivedAt
        }
    }

    public var now: Date
    public var connectivityActivated: Bool
    public var paired: Bool
    public var systemAppInstalled: Bool
    public var reachable: Bool
    /// A MotionOS Watch presence packet was seen recently enough to count
    /// as "the MotionOS apps detected each other".
    public var presenceRecent: Bool
    public var presence: Presence?
    public var mirroredWorkout: MirroredWorkoutPhase
    public var latestFrame: LiveTelemetryFrame?

    public init(
        now: Date,
        connectivityActivated: Bool,
        paired: Bool,
        systemAppInstalled: Bool,
        reachable: Bool,
        presenceRecent: Bool,
        presence: Presence?,
        mirroredWorkout: MirroredWorkoutPhase,
        latestFrame: LiveTelemetryFrame?
    ) {
        self.now = now
        self.connectivityActivated = connectivityActivated
        self.paired = paired
        self.systemAppInstalled = systemAppInstalled
        self.reachable = reachable
        self.presenceRecent = presenceRecent
        self.presence = presence
        self.mirroredWorkout = mirroredWorkout
        self.latestFrame = latestFrame
    }
}

public struct WatchObservation: Sendable, Equatable {
    public let link: WatchLinkStatus
    public let observatory: LiveObservatoryPhase
    /// The Watch session the Observatory is describing, if any.
    public let sessionID: String?
    /// The frame that may be shown for this session. `nil` when the latest
    /// frame belongs to a different or finished session.
    public let sessionFrame: LiveTelemetryFrame?
}

/// The single resolver for Watch link status and Live Observatory phase.
public enum WatchObservationResolver {
    /// A frame received within this window counts as live. Snapshots arrive
    /// every ~0.25 s, so this tolerates several dropped packets.
    public static let liveFreshness: TimeInterval = 1.5
    /// With no telemetry or presence update for this long, an apparently
    /// active recording is reported as an issue instead of reconnecting.
    public static let unresponsiveAfter: TimeInterval = 600
    /// How long a saved recording is announced before returning to ready.
    public static let savedAnnouncement: TimeInterval = 600

    public static func resolve(
        _ input: WatchObservationInput
    ) -> WatchObservation {
        guard input.connectivityActivated else {
            return WatchObservation(
                link: .checking,
                observatory: .checking,
                sessionID: nil,
                sessionFrame: nil
            )
        }

        let current = currentCapture(input)
        let phase = current.phase

        let link: WatchLinkStatus
        if !input.paired {
            link = .noWatch
        } else if phase.isRecordingActive {
            link = .recording
        } else if phase == .failed {
            link = .issue
        } else if input.reachable || input.presenceRecent {
            link = .ready
        } else {
            link = .appSetup(needsInstall: !input.systemAppInstalled)
        }

        let sessionFrame = input.latestFrame.flatMap { frame in
            current.sessionID == nil
                || frame.snapshot.sessionID == current.sessionID
                ? frame
                : nil
        }

        let observatory: LiveObservatoryPhase
        switch link {
        case .checking:
            observatory = .checking
        case .noWatch, .appSetup:
            observatory = .watchSetupRequired
        case .issue:
            observatory = .issue
        case .ready, .recording:
            observatory = observatoryPhase(
                phase,
                lastEvidenceAt: current.at,
                sessionFrame: phase.isRecordingActive ? sessionFrame : nil,
                now: input.now
            )
        }

        return WatchObservation(
            link: link,
            observatory: observatory,
            sessionID: phase.isRecordingActive ? current.sessionID : nil,
            sessionFrame: observatory.showsSessionTrace ? sessionFrame : nil
        )
    }

    private struct CurrentCapture {
        var phase: WatchCapturePhase
        var sessionID: String?
        var at: Date?
    }

    /// The most recent source of capture state wins: a durable presence
    /// update, or a newer live snapshot. The mirrored workout only fills
    /// gaps; it never overrides a newer Watch report.
    private static func currentCapture(
        _ input: WatchObservationInput
    ) -> CurrentCapture {
        var current = CurrentCapture(
            phase: input.presence?.capturePhase ?? .unknown,
            sessionID: input.presence?.sessionID,
            at: input.presence?.receivedAt
        )

        // A session the Watch has reported as finished can never be revived
        // by a late, in-flight snapshot from that same session.
        let presenceEndedFrameSession: Bool = {
            guard let presence = input.presence,
                  let frame = input.latestFrame,
                  presence.sessionID == frame.snapshot.sessionID
            else {
                return false
            }
            switch presence.capturePhase {
            case .finishing, .saved, .failed:
                return true
            default:
                return false
            }
        }()

        if let frame = input.latestFrame,
           !presenceEndedFrameSession,
           current.at.map({ frame.receivedAt > $0 }) ?? true {
            current = CurrentCapture(
                phase: frame.snapshot.activity == .paused
                    ? .paused
                    : .recording,
                sessionID: frame.snapshot.sessionID,
                at: frame.receivedAt
            )
        }

        if !current.phase.isRecordingActive {
            switch input.mirroredWorkout {
            case .launching where current.phase != .failed:
                current.phase = .starting
            case .recording where current.phase == .idle
                || current.phase == .unknown:
                current.phase = .recording
            case .paused where current.phase == .idle
                || current.phase == .unknown:
                current.phase = .paused
            default:
                break
            }
        }
        return current
    }

    private static func observatoryPhase(
        _ phase: WatchCapturePhase,
        lastEvidenceAt: Date?,
        sessionFrame: LiveTelemetryFrame?,
        now: Date
    ) -> LiveObservatoryPhase {
        switch phase {
        case .starting:
            return .starting
        case .recording:
            if let sessionFrame,
               sessionFrame.snapshot.activity == .recording,
               age(of: sessionFrame.receivedAt, at: now) <= liveFreshness {
                return .live
            }
            let latestEvidence = [lastEvidenceAt, sessionFrame?.receivedAt]
                .compactMap { $0 }
                .max()
            if let latestEvidence,
               age(of: latestEvidence, at: now) > unresponsiveAfter {
                return .issue
            }
            return .reconnecting
        case .paused:
            return .paused
        case .finishing:
            return .finishing
        case .saved:
            if let lastEvidenceAt,
               age(of: lastEvidenceAt, at: now) <= savedAnnouncement {
                return .saved
            }
            return .ready
        case .failed:
            return .issue
        case .idle, .authorizing, .unknown:
            return .ready
        }
    }

    private static func age(of date: Date, at now: Date) -> TimeInterval {
        now.timeIntervalSince(date)
    }
}

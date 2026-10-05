import Foundation

public enum ReplayReviewScopeV1:
    String,
    Codable,
    CaseIterable,
    Sendable {
    case timing
    case iPhonePose = "iphone_pose"
    case action4Pose = "action4_pose"
    case equipment
    case behavior
    case coaching
    case other
}

public enum ReplayReviewVerdictV1:
    String,
    Codable,
    CaseIterable,
    Sendable {
    case inspect
    case wrong
    case goodExample = "good_example"
    case occluded
}

public struct ReplayReviewArtifactBindingV1:
    Codable,
    Equatable,
    Sendable {
    public let role: String
    public let sha256: String
    public let filename: String?

    enum CodingKeys: String, CodingKey {
        case role
        case sha256
        case filename
    }

    public init(
        role: String,
        sha256: String,
        filename: String? = nil
    ) {
        self.role =
            role.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        self.sha256 =
            sha256.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        self.filename =
            filename?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
    }
}

public struct ReplayReviewFlagV1:
    Codable,
    Equatable,
    Sendable,
    Identifiable {
    public static let schemaVersion =
        "motionos.replay-review-flag.v1"

    public let schemaVersion: String
    public let id: String
    public let runID: String
    public let recordedAtUTC: String
    public let referenceTimeNS: UInt64
    public let action4VideoPTSNS: UInt64?
    public let windowBeforeNS: UInt64
    public let windowAfterNS: UInt64
    public let scope: ReplayReviewScopeV1
    public let verdict: ReplayReviewVerdictV1
    public let note: String
    public let iPhonePoseAvailable: Bool
    public let action4PoseAvailable: Bool
    public let equipmentAvailable: Bool
    public let observedPlaybackDriftMS: Double?
    public let artifactBindings:
        [ReplayReviewArtifactBindingV1]
    public let claimBoundary: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case runID = "run_id"
        case recordedAtUTC = "recorded_at_utc"
        case referenceTimeNS =
            "reference_time_ns"
        case action4VideoPTSNS =
            "action4_video_pts_ns"
        case windowBeforeNS =
            "window_before_ns"
        case windowAfterNS =
            "window_after_ns"
        case scope
        case verdict
        case note
        case iPhonePoseAvailable =
            "iphone_pose_available"
        case action4PoseAvailable =
            "action4_pose_available"
        case equipmentAvailable =
            "equipment_available"
        case observedPlaybackDriftMS =
            "observed_playback_drift_ms"
        case artifactBindings =
            "artifact_bindings"
        case claimBoundary =
            "claim_boundary"
    }

    public init(
        id: String = UUID().uuidString,
        runID: String,
        recordedAtUTC: String =
            ISO8601DateFormatter()
                .string(from: Date()),
        referenceTimeNS: UInt64,
        action4VideoPTSNS: UInt64?,
        windowBeforeNS: UInt64 =
            1_500_000_000,
        windowAfterNS: UInt64 =
            1_500_000_000,
        scope: ReplayReviewScopeV1,
        verdict: ReplayReviewVerdictV1 =
            .inspect,
        note: String = "",
        iPhonePoseAvailable: Bool,
        action4PoseAvailable: Bool,
        equipmentAvailable: Bool,
        observedPlaybackDriftMS: Double?,
        artifactBindings:
            [ReplayReviewArtifactBindingV1]
    ) {
        self.schemaVersion =
            Self.schemaVersion
        self.id = id
        self.runID =
            runID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        self.recordedAtUTC =
            recordedAtUTC
        self.referenceTimeNS =
            referenceTimeNS
        self.action4VideoPTSNS =
            action4VideoPTSNS
        self.windowBeforeNS =
            windowBeforeNS
        self.windowAfterNS =
            windowAfterNS
        self.scope = scope
        self.verdict = verdict
        self.note =
            note.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        self.iPhonePoseAvailable =
            iPhonePoseAvailable
        self.action4PoseAvailable =
            action4PoseAvailable
        self.equipmentAvailable =
            equipmentAvailable
        if let observedPlaybackDriftMS,
           observedPlaybackDriftMS.isFinite {
            self.observedPlaybackDriftMS =
                observedPlaybackDriftMS
        } else {
            self.observedPlaybackDriftMS =
                nil
        }
        self.artifactBindings =
            artifactBindings.sorted {
                if $0.role == $1.role {
                    return $0.sha256
                        < $1.sha256
                }
                return $0.role < $1.role
            }
        self.claimBoundary = (
            "This is a human-authored replay review marker bound to "
                + "preserved evidence and a reference-time window. It can "
                + "support QA, annotation, and model debugging, but it is "
                + "not metric biomechanics ground truth, a medical label, "
                + "or cross-camera geometry calibration."
        )
    }
}

public enum ReplayReviewLedgerError:
    Error,
    Equatable,
    Sendable {
    case runMismatch
}

public struct ReplayReviewLedgerV1:
    Codable,
    Equatable,
    Sendable {
    public static let schemaVersion =
        "motionos.replay-review-ledger.v1"

    public let schemaVersion: String
    public let runID: String
    public let flags: [ReplayReviewFlagV1]
    public let claimBoundary: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case flags
        case claimBoundary =
            "claim_boundary"
    }

    public init(
        runID: String,
        flags: [ReplayReviewFlagV1] = []
    ) {
        self.schemaVersion =
            Self.schemaVersion
        self.runID =
            runID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        self.flags =
            flags.sorted(by: Self.order)
        self.claimBoundary = (
            "This ledger preserves human replay-review markers. Flags are "
                + "annotation and QA evidence only. They do not upgrade "
                + "derived camera or wearable signals into validated "
                + "biomechanical measurements."
        )
    }

    public func appending(
        _ flag: ReplayReviewFlagV1
    ) throws -> ReplayReviewLedgerV1 {
        guard flag.runID == runID else {
            throw ReplayReviewLedgerError
                .runMismatch
        }
        return ReplayReviewLedgerV1(
            runID: runID,
            flags: flags + [flag]
        )
    }

    private static func order(
        _ lhs: ReplayReviewFlagV1,
        _ rhs: ReplayReviewFlagV1
    ) -> Bool {
        if lhs.referenceTimeNS
            == rhs.referenceTimeNS {
            if lhs.recordedAtUTC
                == rhs.recordedAtUTC {
                return lhs.id < rhs.id
            }
            return lhs.recordedAtUTC
                < rhs.recordedAtUTC
        }
        return lhs.referenceTimeNS
            < rhs.referenceTimeNS
    }
}

import Foundation

public enum IndoBoardRemoteAction: String, Codable, CaseIterable, Sendable {
    case refreshStatus = "refresh_status"
    case prepareCamera = "prepare_camera"
    case startSession = "start_session"
    case finishSession = "finish_session"
    case resetSession = "reset_session"
}

public struct IndoBoardRemoteCommand: Equatable, Sendable {
    public static let messageType = "indo_remote_command_v1"

    public let requestID: String
    public let action: IndoBoardRemoteAction
    public let sentAtUnixSeconds: Double

    public init(
        requestID: String = UUID().uuidString,
        action: IndoBoardRemoteAction,
        sentAtUnixSeconds: Double = Date().timeIntervalSince1970
    ) {
        self.requestID = requestID
        self.action = action
        self.sentAtUnixSeconds = sentAtUnixSeconds
    }

    public init?(message: [String: Any]) {
        guard message["motionos_message"] as? String == Self.messageType,
              let requestID = message["request_id"] as? String,
              !requestID.isEmpty,
              let rawAction = message["action"] as? String,
              let action = IndoBoardRemoteAction(rawValue: rawAction)
        else {
            return nil
        }

        self.requestID = requestID
        self.action = action
        self.sentAtUnixSeconds =
            Self.double(message["sent_at_unix_s"])
                ?? Date().timeIntervalSince1970
    }

    public var message: [String: Any] {
        [
            "motionos_message": Self.messageType,
            "request_id": requestID,
            "action": action.rawValue,
            "sent_at_unix_s": sentAtUnixSeconds,
        ]
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }
}

public struct IndoBoardRemoteCommandAck: Equatable, Sendable {
    public static let messageType = "indo_remote_command_ack_v1"

    public let requestID: String
    public let action: IndoBoardRemoteAction
    public let accepted: Bool
    public let messageText: String?
    public let receivedAtUnixSeconds: Double

    public init(
        requestID: String,
        action: IndoBoardRemoteAction,
        accepted: Bool,
        messageText: String? = nil,
        receivedAtUnixSeconds: Double = Date().timeIntervalSince1970
    ) {
        self.requestID = requestID
        self.action = action
        self.accepted = accepted
        self.messageText = messageText
        self.receivedAtUnixSeconds = receivedAtUnixSeconds
    }

    public init?(message: [String: Any]) {
        guard message["motionos_message"] as? String == Self.messageType,
              let requestID = message["request_id"] as? String,
              let rawAction = message["action"] as? String,
              let action = IndoBoardRemoteAction(rawValue: rawAction),
              let accepted = message["accepted"] as? Bool
        else {
            return nil
        }

        self.requestID = requestID
        self.action = action
        self.accepted = accepted
        self.messageText = message["message"] as? String
        self.receivedAtUnixSeconds =
            Self.double(message["received_at_unix_s"])
                ?? Date().timeIntervalSince1970
    }

    public var message: [String: Any] {
        var payload: [String: Any] = [
            "motionos_message": Self.messageType,
            "request_id": requestID,
            "action": action.rawValue,
            "accepted": accepted,
            "received_at_unix_s": receivedAtUnixSeconds,
        ]
        if let messageText, !messageText.isEmpty {
            payload["message"] = messageText
        }
        return payload
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }
}

public struct IndoBoardRemoteStatus: Equatable, Sendable {
    public static let messageType = "indo_remote_status_v1"

    public let cameraPhase: String
    public let framingState: String
    public let framingScore: Int
    public let framingTitle: String
    public let framingInstruction: String
    public let stanceState: String
    public let stanceProgressPercent: Int
    public let stanceTitle: String
    public let sessionPhase: String
    public let sessionInstruction: String?
    public let countdownRemaining: Int?
    public let startReady: Bool
    public let startBlocker: String?
    public let phoneBatteryFraction: Double?
    public let phoneStorageGB: Double?
    public let sentAtUnixSeconds: Double

    public init(
        cameraPhase: String,
        framingState: String,
        framingScore: Int,
        framingTitle: String,
        framingInstruction: String,
        stanceState: String,
        stanceProgressPercent: Int,
        stanceTitle: String,
        sessionPhase: String,
        sessionInstruction: String?,
        countdownRemaining: Int?,
        startReady: Bool,
        startBlocker: String?,
        phoneBatteryFraction: Double?,
        phoneStorageGB: Double?,
        sentAtUnixSeconds: Double = Date().timeIntervalSince1970
    ) {
        self.cameraPhase = cameraPhase
        self.framingState = framingState
        self.framingScore = min(100, max(0, framingScore))
        self.framingTitle = framingTitle
        self.framingInstruction = framingInstruction
        self.stanceState = stanceState
        self.stanceProgressPercent =
            min(100, max(0, stanceProgressPercent))
        self.stanceTitle = stanceTitle
        self.sessionPhase = sessionPhase
        self.sessionInstruction = sessionInstruction
        self.countdownRemaining = countdownRemaining
        self.startReady = startReady
        self.startBlocker = startBlocker
        self.phoneBatteryFraction = phoneBatteryFraction
        self.phoneStorageGB = phoneStorageGB
        self.sentAtUnixSeconds = sentAtUnixSeconds
    }

    public init?(message: [String: Any]) {
        guard message["motionos_message"] as? String == Self.messageType,
              let cameraPhase = message["camera_phase"] as? String,
              let framingState = message["framing_state"] as? String,
              let framingTitle = message["framing_title"] as? String,
              let framingInstruction =
                message["framing_instruction"] as? String,
              let sessionPhase = message["session_phase"] as? String,
              let startReady = message["start_ready"] as? Bool
        else {
            return nil
        }

        self.cameraPhase = cameraPhase
        self.framingState = framingState
        self.framingScore =
            Self.int(message["framing_score"]) ?? 0
        self.framingTitle = framingTitle
        self.framingInstruction = framingInstruction
        self.stanceState =
            message["stance_state"] as? String
                ?? "waiting_for_framing"
        self.stanceProgressPercent =
            min(
                100,
                max(
                    0,
                    Self.int(message["stance_progress_percent"]) ?? 0
                )
            )
        self.stanceTitle =
            message["stance_title"] as? String
                ?? "Hold a neutral stance"
        self.sessionPhase = sessionPhase
        self.sessionInstruction =
            message["session_instruction"] as? String
        self.countdownRemaining =
            Self.int(message["countdown_remaining"])
        self.startReady = startReady
        self.startBlocker = message["start_blocker"] as? String
        self.phoneBatteryFraction =
            Self.double(message["phone_battery_fraction"])
        self.phoneStorageGB =
            Self.double(message["phone_storage_gb"])
        self.sentAtUnixSeconds =
            Self.double(message["sent_at_unix_s"])
                ?? Date().timeIntervalSince1970
    }

    public var message: [String: Any] {
        var payload: [String: Any] = [
            "motionos_message": Self.messageType,
            "camera_phase": cameraPhase,
            "framing_state": framingState,
            "framing_score": framingScore,
            "framing_title": framingTitle,
            "framing_instruction": framingInstruction,
            "stance_state": stanceState,
            "stance_progress_percent": stanceProgressPercent,
            "stance_title": stanceTitle,
            "session_phase": sessionPhase,
            "start_ready": startReady,
            "sent_at_unix_s": sentAtUnixSeconds,
        ]

        if let sessionInstruction, !sessionInstruction.isEmpty {
            payload["session_instruction"] = sessionInstruction
        }
        if let countdownRemaining {
            payload["countdown_remaining"] = countdownRemaining
        }
        if let startBlocker, !startBlocker.isEmpty {
            payload["start_blocker"] = startBlocker
        }
        if let phoneBatteryFraction {
            payload["phone_battery_fraction"] = phoneBatteryFraction
        }
        if let phoneStorageGB {
            payload["phone_storage_gb"] = phoneStorageGB
        }
        return payload
    }

    public var isSessionActive: Bool {
        ["starting", "countdown", "running", "finishing"].contains(
            sessionPhase.lowercased()
        )
    }

    public var framingReady: Bool {
        framingState.lowercased() == "ready"
    }

    public func equivalentForDelivery(
        to other: IndoBoardRemoteStatus
    ) -> Bool {
        cameraPhase == other.cameraPhase
            && framingState == other.framingState
            && framingScore == other.framingScore
            && framingTitle == other.framingTitle
            && framingInstruction == other.framingInstruction
            && stanceState == other.stanceState
            && stanceProgressPercent == other.stanceProgressPercent
            && stanceTitle == other.stanceTitle
            && sessionPhase == other.sessionPhase
            && sessionInstruction == other.sessionInstruction
            && countdownRemaining == other.countdownRemaining
            && startReady == other.startReady
            && startBlocker == other.startBlocker
            && phoneBatteryFraction == other.phoneBatteryFraction
            && phoneStorageGB == other.phoneStorageGB
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }
}

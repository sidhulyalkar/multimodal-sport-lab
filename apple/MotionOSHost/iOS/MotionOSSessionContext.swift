import Foundation
import MotionOSAppleCapture

enum IndoBoardStancePreference: String, CaseIterable, Identifiable {
    case leftFootForward = "left_foot_forward"
    case rightFootForward = "right_foot_forward"
    case variesOrUnsure = "varies_or_unsure"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftFootForward:
            "Left foot forward"
        case .rightFootForward:
            "Right foot forward"
        case .variesOrUnsure:
            "Varies / not sure"
        }
    }

    var shortTitle: String {
        switch self {
        case .leftFootForward:
            "Left forward"
        case .rightFootForward:
            "Right forward"
        case .variesOrUnsure:
            "Varies"
        }
    }
}

/// Privacy-first local identity used to keep one installation's longitudinal
/// movement history separate from another profile. It is intentionally not a
/// name, email address, Health identifier, or account credential.
enum MotionOSLocalProfile {
    static let profileIDDefaultsKey =
        "motionos.local-profile-id.v1"

    static func profileID(
        defaults: UserDefaults = .standard
    ) -> String {
        if let existing = defaults.string(
            forKey: profileIDDefaultsKey
        ),
           !existing.isEmpty {
            return existing
        }

        let identifier = "local-" + UUID().uuidString.lowercased()
        defaults.set(
            identifier,
            forKey: profileIDDefaultsKey
        )
        return identifier
    }
}

enum MotionOSSessionContextFactory {
    static func indoBoard(
        profileID: String,
        stance: IndoBoardStancePreference,
        captureMode: IndoBoardSessionCoordinator.CaptureMode
    ) -> ProductSessionManifest.SessionContext {
        ProductSessionManifest.SessionContext(
            profileID: profileID,
            activityID: "indo_board",
            protocolID: IndoBoardProductProtocol.protocolID,
            dimensions: [
                "stance": stance.rawValue,
                "capture_mode": captureMode.rawValue,
            ]
        )
    }
}

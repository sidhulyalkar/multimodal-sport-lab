import Foundation
import MotionOSAppleCapture

struct CameraFramingAssessment: Equatable, Sendable {
    enum State: String, Sendable {
        case searching
        case adjust
        case ready
    }

    let state: State
    let score: Int
    let title: String
    let instruction: String
    let detail: String

    static let waiting = CameraFramingAssessment(
        state: .searching,
        score: 0,
        title: "Step into the camera view",
        instruction: "Show your full body from head to feet.",
        detail: "MotionOS will guide framing before you record."
    )

    static func evaluate(
        _ frame: BodyMovementFrame?
    ) -> CameraFramingAssessment {
        guard let framing = frame?.imageFraming else {
            return .waiting
        }

        let bounds = framing.bounds
        let jointIDs = Set(
            framing.visibleJointIDs.map(normalize)
        )

        let hasUpperBody =
            containsAny(
                jointIDs,
                [
                    "nose",
                    "neck",
                    "leftshoulder",
                    "rightshoulder",
                ]
            )
        let hasLeftFoot =
            containsAny(
                jointIDs,
                ["leftankle", "leftfoot"]
            )
        let hasRightFoot =
            containsAny(
                jointIDs,
                ["rightankle", "rightfoot"]
            )
        let feetVisible = hasLeftFoot && hasRightFoot

        let confidenceGood =
            framing.meanConfidence >= 0.55
                && framing.visibleJointCount >= 10
        let sizeGood =
            bounds.height >= 0.48
                && bounds.height <= 0.82
                && bounds.width <= 0.72
        let horizontalGood =
            bounds.centerX >= 0.38
                && bounds.centerX <= 0.62
        let floorMarginGood = bounds.minY >= 0.08
        let headroomGood = bounds.maxY <= 0.93

        var passed = 0
        for value in [
            hasUpperBody,
            feetVisible,
            confidenceGood,
            sizeGood,
            horizontalGood,
            floorMarginGood,
            headroomGood,
        ] where value {
            passed += 1
        }
        let score = Int(
            (Double(passed) / 7.0 * 100.0).rounded()
        )

        if !hasUpperBody || !feetVisible {
            return CameraFramingAssessment(
                state: .adjust,
                score: score,
                title: "Fit your whole body in frame",
                instruction:
                    "Move the phone farther back until your head and both feet are visible.",
                detail:
                    "Both feet matter because MotionOS uses them to estimate the support region."
            )
        }

        if bounds.height > 0.82 || bounds.width > 0.72 {
            return CameraFramingAssessment(
                state: .adjust,
                score: score,
                title: "A little too close",
                instruction:
                    "Move the phone farther back. Leave space around your hands, head, feet, and board.",
                detail:
                    "Extra margin prevents arm reaches and board corrections from leaving frame."
            )
        }

        if bounds.height < 0.48 {
            return CameraFramingAssessment(
                state: .adjust,
                score: score,
                title: "You are too small in frame",
                instruction:
                    "Move the phone closer until your body fills about half to three quarters of the picture height.",
                detail:
                    "A larger subject improves joint precision without sacrificing recovery-room around you."
            )
        }

        if !horizontalGood {
            let direction =
                bounds.centerX < 0.38 ? "left" : "right"
            return CameraFramingAssessment(
                state: .adjust,
                score: score,
                title: "Re-center the frame",
                instruction:
                    "Aim the phone slightly \(direction), or shift your setup toward the middle of the preview.",
                detail:
                    "Centering leaves equal room for lateral balance corrections."
            )
        }

        if !floorMarginGood {
            return CameraFramingAssessment(
                state: .adjust,
                score: score,
                title: "Leave more room below your feet",
                instruction:
                    "Tilt the phone slightly down or move it back so the board and floor remain visible.",
                detail:
                    "MotionOS needs space beneath the feet for equipment tracking."
            )
        }

        if !headroomGood {
            return CameraFramingAssessment(
                state: .adjust,
                score: score,
                title: "Leave more headroom",
                instruction:
                    "Tilt the phone slightly up or move it back.",
                detail:
                    "This keeps your head and raised arms measurable during recovery movements."
            )
        }

        if !confidenceGood {
            return CameraFramingAssessment(
                state: .adjust,
                score: score,
                title: "Pose signal is weak",
                instruction:
                    "Face the camera more clearly and improve the room lighting if possible.",
                detail:
                    "MotionOS is seeing you, but not enough joints are stable yet."
            )
        }

        return CameraFramingAssessment(
            state: .ready,
            score: 100,
            title: "Camera is ready",
            instruction:
                "Full body, feet, movement margin, and pose confidence look usable.",
            detail:
                "You can start the Indo Board session without touching the camera again."
        )
    }

    private static func containsAny(
        _ ids: Set<String>,
        _ targets: [String]
    ) -> Bool {
        targets.contains { target in
            ids.contains(normalize(target))
        }
    }

    private static func normalize(
        _ value: String
    ) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

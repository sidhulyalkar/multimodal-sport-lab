import Foundation

public enum IndoBoardFiducialMarkerID:
    String,
    Codable,
    CaseIterable,
    Sendable {
    case deckLeft = "MOTIONOS_INDO_DECK_LEFT_V1"
    case deckRight = "MOTIONOS_INDO_DECK_RIGHT_V1"
    case rollerLeft = "MOTIONOS_INDO_ROLLER_LEFT_V1"
    case rollerRight = "MOTIONOS_INDO_ROLLER_RIGHT_V1"
    case rollerCenter = "MOTIONOS_INDO_ROLLER_CENTER_V1"
}

public struct IndoBoardFiducialDetection:
    Equatable,
    Sendable {
    public let marker: IndoBoardFiducialMarkerID
    public let center: NormalizedImagePoint2D
    public let confidence: Double

    public init(
        marker: IndoBoardFiducialMarkerID,
        center: NormalizedImagePoint2D,
        confidence: Double
    ) {
        self.marker = marker
        self.center = center
        self.confidence = min(1, max(0, confidence))
    }
}

public enum IndoBoardFiducialEquipmentBuilder {
    public static let modelID =
        "vision-qr-indo-fiducials-v1"

    public static func makeObservation(
        detections: [IndoBoardFiducialDetection],
        sequence: UInt64 = 0,
        deviceTimeNS: UInt64 = 0
    ) -> IndoBoardEquipmentObservation? {
        let best = bestDetections(detections)

        guard let deckLeft = best[.deckLeft],
              let deckRight = best[.deckRight]
        else {
            return nil
        }

        let roller: IndoBoardRollerObservation?
        if let rollerLeft = best[.rollerLeft],
           let rollerRight = best[.rollerRight] {
            roller = IndoBoardRollerObservation(
                center: midpoint(
                    rollerLeft.center,
                    rollerRight.center
                ),
                axisStart: rollerLeft.center,
                axisEnd: rollerRight.center,
                confidence: min(
                    rollerLeft.confidence,
                    rollerRight.confidence
                ),
                provenance: .fiducialMeasured
            )
        } else if let rollerCenter = best[.rollerCenter] {
            roller = IndoBoardRollerObservation(
                center: rollerCenter.center,
                confidence: rollerCenter.confidence,
                provenance: .fiducialMeasured
            )
        } else {
            roller = nil
        }

        guard let roller else {
            return nil
        }

        let deck = IndoBoardDeckObservation(
            polygon: [],
            leftEnd: deckLeft.center,
            rightEnd: deckRight.center,
            confidence: min(
                deckLeft.confidence,
                deckRight.confidence
            ),
            provenance: .fiducialMeasured
        )

        return IndoBoardEquipmentObservation(
            sequence: sequence,
            deviceTimeNS: deviceTimeNS,
            deck: deck,
            roller: roller,
            modelID: modelID
        )
    }

    private static func bestDetections(
        _ detections: [IndoBoardFiducialDetection]
    ) -> [IndoBoardFiducialMarkerID: IndoBoardFiducialDetection] {
        var result:
            [IndoBoardFiducialMarkerID: IndoBoardFiducialDetection] = [:]

        for detection in detections {
            if let existing = result[detection.marker],
               existing.confidence >= detection.confidence {
                continue
            }
            result[detection.marker] = detection
        }
        return result
    }

    private static func midpoint(
        _ first: NormalizedImagePoint2D,
        _ second: NormalizedImagePoint2D
    ) -> NormalizedImagePoint2D {
        NormalizedImagePoint2D(
            x: (first.x + second.x) / 2,
            y: (first.y + second.y) / 2
        )
    }
}

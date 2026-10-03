import Foundation

public struct NormalizedImagePoint2D:
    Codable,
    Equatable,
    Sendable {
    public let x: Double
    public let y: Double

    public init(
        x: Double,
        y: Double
    ) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
    }
}

public enum IndoBoardEquipmentProvenance:
    String,
    Codable,
    Equatable,
    Sendable {
    case manualAnnotated = "manual_annotated"
    case modelEstimated = "model_estimated"
    case geometricProxy = "geometric_proxy"
}

public struct IndoBoardDeckObservation:
    Codable,
    Equatable,
    Sendable {
    public let polygon: [NormalizedImagePoint2D]
    public let leftEnd: NormalizedImagePoint2D
    public let rightEnd: NormalizedImagePoint2D
    public let confidence: Double
    public let provenance: IndoBoardEquipmentProvenance

    public init(
        polygon: [NormalizedImagePoint2D],
        leftEnd: NormalizedImagePoint2D,
        rightEnd: NormalizedImagePoint2D,
        confidence: Double,
        provenance: IndoBoardEquipmentProvenance
    ) {
        self.polygon = polygon
        self.leftEnd = leftEnd
        self.rightEnd = rightEnd
        self.confidence = min(1, max(0, confidence))
        self.provenance = provenance
    }
}

public struct IndoBoardRollerObservation:
    Codable,
    Equatable,
    Sendable {
    public let center: NormalizedImagePoint2D
    public let axisStart: NormalizedImagePoint2D?
    public let axisEnd: NormalizedImagePoint2D?
    public let confidence: Double
    public let provenance: IndoBoardEquipmentProvenance

    public init(
        center: NormalizedImagePoint2D,
        axisStart: NormalizedImagePoint2D? = nil,
        axisEnd: NormalizedImagePoint2D? = nil,
        confidence: Double,
        provenance: IndoBoardEquipmentProvenance
    ) {
        self.center = center
        self.axisStart = axisStart
        self.axisEnd = axisEnd
        self.confidence = min(1, max(0, confidence))
        self.provenance = provenance
    }
}

public struct IndoBoardEquipmentObservation:
    Codable,
    Equatable,
    Sendable {
    public static let schemaVersion =
        "motionos.indo-equipment-observation.v1"

    public let schemaVersion: String
    public let sequence: UInt64
    public let deviceTimeNS: UInt64
    public let deck: IndoBoardDeckObservation?
    public let roller: IndoBoardRollerObservation?
    public let modelID: String?
    public let claimBoundary: String

    public init(
        schemaVersion: String =
            IndoBoardEquipmentObservation.schemaVersion,
        sequence: UInt64,
        deviceTimeNS: UInt64,
        deck: IndoBoardDeckObservation?,
        roller: IndoBoardRollerObservation?,
        modelID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.deviceTimeNS = deviceTimeNS
        self.deck = deck
        self.roller = roller
        self.modelID = modelID
        self.claimBoundary = (
            "Image-space deck and roller observations are not calibrated "
                + "physical positions unless a separate calibration contract "
                + "has been satisfied."
        )
    }
}

public struct IndoBoardBalanceState:
    Codable,
    Equatable,
    Sendable {
    public static let schemaVersion =
        "motionos.indo-balance-state.v1"

    public let schemaVersion: String
    public let sequence: UInt64
    public let deviceTimeNS: UInt64
    public let deckAngleImageRadians: Double
    public let rollerAlongDeck: Double
    public let rollerPerpendicularOffsetDeckLengths: Double
    public let centerProximity: Double
    public let confidence: Double
    public let provenance: IndoBoardEquipmentProvenance
    public let claimBoundary: String

    public init(
        sequence: UInt64,
        deviceTimeNS: UInt64,
        deckAngleImageRadians: Double,
        rollerAlongDeck: Double,
        rollerPerpendicularOffsetDeckLengths: Double,
        centerProximity: Double,
        confidence: Double,
        provenance: IndoBoardEquipmentProvenance
    ) {
        self.schemaVersion = Self.schemaVersion
        self.sequence = sequence
        self.deviceTimeNS = deviceTimeNS
        self.deckAngleImageRadians = deckAngleImageRadians
        self.rollerAlongDeck = rollerAlongDeck
        self.rollerPerpendicularOffsetDeckLengths =
            rollerPerpendicularOffsetDeckLengths
        self.centerProximity = min(1, max(0, centerProximity))
        self.confidence = min(1, max(0, confidence))
        self.provenance = provenance
        self.claimBoundary = (
            "rollerAlongDeck is an image-plane geometric proxy. "
                + "It is not a calibrated force, center-of-mass, or "
                + "physical-distance measurement."
        )
    }
}

public enum IndoBoardBalanceStateEstimator {
    public static func estimate(
        from observation: IndoBoardEquipmentObservation
    ) -> IndoBoardBalanceState? {
        guard let deck = observation.deck,
              let roller = observation.roller
        else {
            return nil
        }

        let left = deck.leftEnd
        let right = deck.rightEnd
        let axisX = right.x - left.x
        let axisY = right.y - left.y
        let axisLengthSquared =
            axisX * axisX + axisY * axisY

        guard axisLengthSquared > 1e-6 else {
            return nil
        }

        let rollerVectorX = roller.center.x - left.x
        let rollerVectorY = roller.center.y - left.y

        let projection =
            (
                rollerVectorX * axisX
                    + rollerVectorY * axisY
            ) / axisLengthSquared

        // Map deck endpoints to approximately -1...+1. Values outside
        // that range are retained because they are useful failure evidence.
        let alongDeck = (projection - 0.5) * 2

        let cross =
            axisX * rollerVectorY
                - axisY * rollerVectorX
        let perpendicular =
            cross / max(axisLengthSquared, 1e-9)

        let centerProximity =
            max(0, 1 - abs(alongDeck))

        let confidence = min(
            deck.confidence,
            roller.confidence
        )

        let provenance: IndoBoardEquipmentProvenance
        if deck.provenance == .manualAnnotated
            && roller.provenance == .manualAnnotated {
            provenance = .manualAnnotated
        } else if deck.provenance == .modelEstimated
            || roller.provenance == .modelEstimated {
            provenance = .modelEstimated
        } else {
            provenance = .geometricProxy
        }

        return IndoBoardBalanceState(
            sequence: observation.sequence,
            deviceTimeNS: observation.deviceTimeNS,
            deckAngleImageRadians: atan2(axisY, axisX),
            rollerAlongDeck: alongDeck,
            rollerPerpendicularOffsetDeckLengths:
                perpendicular,
            centerProximity: centerProximity,
            confidence: confidence,
            provenance: provenance
        )
    }
}

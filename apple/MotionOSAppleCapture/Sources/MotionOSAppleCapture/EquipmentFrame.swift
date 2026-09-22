import Foundation

public struct MotionVector3: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = try container.decode([Double].self)
        guard values.count == 3 else {
            throw EquipmentFrameError.invalidVector
        }
        self.init(values[0], values[1], values[2])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([x, y, z])
    }

    public var array: [Double] { [x, y, z] }

    public func dot(_ other: MotionVector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    public func cross(_ other: MotionVector3) -> MotionVector3 {
        MotionVector3(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }

    public var norm: Double {
        sqrt(dot(self))
    }

    public func normalized() throws -> MotionVector3 {
        guard norm > 1e-9 else { throw EquipmentFrameError.nearZeroVector }
        return scaled(by: 1.0 / norm)
    }

    public func scaled(by scale: Double) -> MotionVector3 {
        MotionVector3(x * scale, y * scale, z * scale)
    }

    public func subtracting(_ other: MotionVector3) -> MotionVector3 {
        MotionVector3(x - other.x, y - other.y, z - other.z)
    }
}

public struct Rotation3: Codable, Sendable, Equatable {
    public let rows: [[Double]]

    public init(rows: [[Double]]) throws {
        guard rows.count == 3, rows.allSatisfy({ $0.count == 3 }) else {
            throw EquipmentFrameError.invalidRotation
        }
        self.rows = rows
        guard isProperRotation(tolerance: 1e-5) else {
            throw EquipmentFrameError.invalidRotation
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rows: container.decode([[Double]].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rows)
    }

    public func transform(_ vector: MotionVector3) -> MotionVector3 {
        MotionVector3(
            rows[0][0] * vector.x + rows[0][1] * vector.y + rows[0][2] * vector.z,
            rows[1][0] * vector.x + rows[1][1] * vector.y + rows[1][2] * vector.z,
            rows[2][0] * vector.x + rows[2][1] * vector.y + rows[2][2] * vector.z
        )
    }

    public var determinant: Double {
        let a = rows[0], b = rows[1], c = rows[2]
        return
            a[0] * (b[1] * c[2] - b[2] * c[1])
            - a[1] * (b[0] * c[2] - b[2] * c[0])
            + a[2] * (b[0] * c[1] - b[1] * c[0])
    }

    public func isProperRotation(tolerance: Double) -> Bool {
        let vectors = rows.map { MotionVector3($0[0], $0[1], $0[2]) }
        let unit = vectors.allSatisfy { abs($0.norm - 1.0) <= tolerance }
        let orthogonal =
            abs(vectors[0].dot(vectors[1])) <= tolerance
            && abs(vectors[0].dot(vectors[2])) <= tolerance
            && abs(vectors[1].dot(vectors[2])) <= tolerance
        return unit && orthogonal && abs(determinant - 1.0) <= tolerance
    }
}

public struct EquipmentMountCalibration: Codable, Sendable, Equatable {
    public let sensorToEquipment: Rotation3
    public let levelMeanAccel: MotionVector3
    public let noseUpMeanAccel: MotionVector3
    public let forwardExcitation: Double
    public let orthogonalityError: Double

    enum CodingKeys: String, CodingKey {
        case sensorToEquipment = "sensor_to_equipment"
        case levelMeanAccel = "level_mean_accel"
        case noseUpMeanAccel = "nose_up_mean_accel"
        case forwardExcitation = "forward_excitation"
        case orthogonalityError = "orthogonality_error"
    }
}

public struct EquipmentProfileContract: Codable, Sendable, Equatable {
    public let equipmentID: String
    public let equipmentType: String
    public let mountID: String
    public let calibration: EquipmentMountCalibration
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case equipmentID = "equipment_id"
        case equipmentType = "equipment_type"
        case mountID = "mount_id"
        case calibration
        case notes
    }

    public init(
        equipmentID: String,
        equipmentType: String,
        mountID: String,
        calibration: EquipmentMountCalibration,
        notes: String? = nil
    ) {
        self.equipmentID = equipmentID
        self.equipmentType = equipmentType
        self.mountID = mountID
        self.calibration = calibration
        self.notes = notes
    }
}

public enum EquipmentMountCalibrator {
    public static func calibrate(
        levelSamples: [MotionVector3],
        noseUpSamples: [MotionVector3],
        minimumExcitation: Double = 0.15
    ) throws -> EquipmentMountCalibration {
        let level = try mean(levelSamples)
        let nose = try mean(noseUpSamples)

        let zSensor = try level.normalized()
        let noseUnit = try nose.normalized()
        let projected = noseUnit.subtracting(
            zSensor.scaled(by: noseUnit.dot(zSensor))
        )
        let excitation = projected.norm
        guard excitation >= minimumExcitation else {
            throw EquipmentFrameError.insufficientPitchExcitation
        }

        var xSensor = try projected.normalized().scaled(by: -1.0)
        let ySensor = try zSensor.cross(xSensor).normalized()
        xSensor = try ySensor.cross(zSensor).normalized()

        let rotation = try Rotation3(
            rows: [
                xSensor.array,
                ySensor.array,
                zSensor.array
            ]
        )

        let error = [
            abs(xSensor.dot(ySensor)),
            abs(xSensor.dot(zSensor)),
            abs(ySensor.dot(zSensor)),
            abs(xSensor.norm - 1.0),
            abs(ySensor.norm - 1.0),
            abs(zSensor.norm - 1.0),
        ].max() ?? 0.0

        return EquipmentMountCalibration(
            sensorToEquipment: rotation,
            levelMeanAccel: level,
            noseUpMeanAccel: nose,
            forwardExcitation: excitation,
            orthogonalityError: error
        )
    }

    private static func mean(_ values: [MotionVector3]) throws -> MotionVector3 {
        guard !values.isEmpty else { throw EquipmentFrameError.noSamples }
        let count = Double(values.count)
        return MotionVector3(
            values.reduce(0.0) { $0 + $1.x } / count,
            values.reduce(0.0) { $0 + $1.y } / count,
            values.reduce(0.0) { $0 + $1.z } / count
        )
    }
}

public enum EquipmentFrameError: Error, Equatable {
    case noSamples
    case nearZeroVector
    case invalidVector
    case insufficientPitchExcitation
    case invalidRotation
}

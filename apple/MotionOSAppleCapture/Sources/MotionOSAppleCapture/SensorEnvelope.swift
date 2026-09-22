import Foundation

public struct SensorEnvelope: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let sessionID: String
    public let deviceID: String
    public let stream: String
    public let sequence: UInt64
    public let deviceTimeNS: UInt64
    public let sessionTimeNS: UInt64?
    public let syncQuality: Double?
    public let payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case deviceID = "device_id"
        case stream
        case sequence
        case deviceTimeNS = "device_time_ns"
        case sessionTimeNS = "session_time_ns"
        case syncQuality = "sync_quality"
        case payload
    }

    public init(
        schemaVersion: String = "motionos.m0.v1",
        sessionID: String,
        deviceID: String,
        stream: String,
        sequence: UInt64,
        deviceTimeNS: UInt64,
        sessionTimeNS: UInt64? = nil,
        syncQuality: Double? = nil,
        payload: [String: JSONValue]
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.stream = stream
        self.sequence = sequence
        self.deviceTimeNS = deviceTimeNS
        self.sessionTimeNS = sessionTimeNS
        self.syncQuality = syncQuality
        self.payload = payload
    }
}

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }
}

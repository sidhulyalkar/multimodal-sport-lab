import Foundation

public enum MotionOSUnitPreference:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Sendable
{
    case automatic
    case metric
    case imperial
}

public struct AthleteProfile:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    public static let schemaVersion = "motionos.athlete-profile.v1"
    public static let legacyDefaultID = "local-athlete"

    public let schemaVersion: String
    public let id: String
    public var displayName: String
    public var unitPreference: MotionOSUnitPreference
    public let createdAtUTC: String
    public var updatedAtUTC: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        displayName: String,
        unitPreference: MotionOSUnitPreference = .automatic,
        createdAtUTC: String = ISO8601DateFormatter().string(from: Date()),
        updatedAtUTC: String? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.id = id
        self.displayName = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.unitPreference = unitPreference
        self.createdAtUTC = createdAtUTC
        self.updatedAtUTC = updatedAtUTC ?? createdAtUTC
    }

    public static func defaultLocal() -> AthleteProfile {
        AthleteProfile(
            id: legacyDefaultID,
            displayName: "Me"
        )
    }

    public func renamed(
        _ name: String,
        at date: Date = Date()
    ) -> AthleteProfile {
        AthleteProfile(
            id: id,
            displayName: name,
            unitPreference: unitPreference,
            createdAtUTC: createdAtUTC,
            updatedAtUTC: ISO8601DateFormatter().string(from: date)
        )
    }

    public func withUnits(
        _ units: MotionOSUnitPreference,
        at date: Date = Date()
    ) -> AthleteProfile {
        AthleteProfile(
            id: id,
            displayName: displayName,
            unitPreference: units,
            createdAtUTC: createdAtUTC,
            updatedAtUTC: ISO8601DateFormatter().string(from: date)
        )
    }
}

public struct AthleteProfileRegistry:
    Codable,
    Equatable,
    Sendable
{
    public static let schemaVersion = "motionos.athlete-profile-registry.v1"

    public let schemaVersion: String
    public var activeProfileID: String
    public var profiles: [AthleteProfile]

    public init(
        activeProfileID: String,
        profiles: [AthleteProfile]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.activeProfileID = activeProfileID
        self.profiles = profiles
    }

    public static func defaultLocal() -> AthleteProfileRegistry {
        let profile = AthleteProfile.defaultLocal()
        return AthleteProfileRegistry(
            activeProfileID: profile.id,
            profiles: [profile]
        )
    }

    public var activeProfile: AthleteProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    public func validated() throws -> AthleteProfileRegistry {
        guard schemaVersion == Self.schemaVersion else {
            throw AthleteProfileRegistryError.unsupportedSchema(
                schemaVersion
            )
        }
        guard !profiles.isEmpty else {
            throw AthleteProfileRegistryError.emptyRegistry
        }

        let ids = profiles.map(\.id)
        guard Set(ids).count == ids.count else {
            throw AthleteProfileRegistryError.duplicateProfileID
        }
        guard profiles.allSatisfy({
            !$0.id.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
                && !$0.displayName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                && $0.schemaVersion == AthleteProfile.schemaVersion
        }) else {
            throw AthleteProfileRegistryError.invalidProfile
        }
        guard activeProfile != nil else {
            throw AthleteProfileRegistryError.activeProfileMissing
        }
        return self
    }
}

public enum AthleteProfileRegistryError:
    Error,
    Equatable,
    Sendable
{
    case unsupportedSchema(String)
    case emptyRegistry
    case duplicateProfileID
    case invalidProfile
    case activeProfileMissing
}

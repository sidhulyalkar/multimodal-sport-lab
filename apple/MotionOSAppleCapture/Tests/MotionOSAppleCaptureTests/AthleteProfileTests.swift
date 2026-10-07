import Foundation
import Testing
@testable import MotionOSAppleCapture

@Test
func athleteProfileRegistryRoundTrips() throws {
    let createdAt = "2026-10-07T00:00:00Z"
    let primary = AthleteProfile(
        id: AthleteProfile.legacyDefaultID,
        displayName: "Me",
        unitPreference: .automatic,
        createdAtUTC: createdAt
    )
    let second = AthleteProfile(
        id: "profile-2",
        displayName: "Alex",
        unitPreference: .metric,
        createdAtUTC: createdAt
    )
    let registry = AthleteProfileRegistry(
        activeProfileID: second.id,
        profiles: [primary, second]
    )

    let encoded = try JSONEncoder().encode(registry)
    let decoded = try JSONDecoder().decode(
        AthleteProfileRegistry.self,
        from: encoded
    )

    #expect(try decoded.validated() == registry)
    #expect(decoded.activeProfile?.displayName == "Alex")
}

@Test
func defaultProfileKeepsLegacyIdentity() throws {
    let registry = AthleteProfileRegistry.defaultLocal()

    #expect(
        registry.activeProfileID
            == AthleteProfile.legacyDefaultID
    )
    #expect(registry.activeProfile?.displayName == "Me")
    #expect(try registry.validated() == registry)
}

@Test
func registryRejectsDuplicateProfileIDs() {
    let first = AthleteProfile(
        id: "same",
        displayName: "One"
    )
    let second = AthleteProfile(
        id: "same",
        displayName: "Two"
    )
    let registry = AthleteProfileRegistry(
        activeProfileID: "same",
        profiles: [first, second]
    )

    #expect(throws: AthleteProfileRegistryError.duplicateProfileID) {
        try registry.validated()
    }
}

@Test
func registryRejectsMissingActiveProfile() {
    let profile = AthleteProfile(
        id: "one",
        displayName: "One"
    )
    let registry = AthleteProfileRegistry(
        activeProfileID: "missing",
        profiles: [profile]
    )

    #expect(throws: AthleteProfileRegistryError.activeProfileMissing) {
        try registry.validated()
    }
}

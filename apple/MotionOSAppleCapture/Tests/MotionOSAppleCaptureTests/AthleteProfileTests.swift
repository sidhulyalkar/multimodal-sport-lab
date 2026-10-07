import Foundation
import XCTest
@testable import MotionOSAppleCapture

final class AthleteProfileTests: XCTestCase {
    func testAthleteProfileRegistryRoundTrips() throws {
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

        XCTAssertEqual(try decoded.validated(), registry)
        XCTAssertEqual(decoded.activeProfile?.displayName, "Alex")
    }

    func testDefaultProfileKeepsLegacyIdentity() throws {
        let registry = AthleteProfileRegistry.defaultLocal()

        XCTAssertEqual(
            registry.activeProfileID,
            AthleteProfile.legacyDefaultID
        )
        XCTAssertEqual(registry.activeProfile?.displayName, "Me")
        XCTAssertEqual(try registry.validated(), registry)
    }

    func testRegistryRejectsDuplicateProfileIDs() {
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

        XCTAssertThrowsError(try registry.validated()) { error in
            XCTAssertEqual(
                error as? AthleteProfileRegistryError,
                .duplicateProfileID
            )
        }
    }

    func testRegistryRejectsMissingActiveProfile() {
        let profile = AthleteProfile(
            id: "one",
            displayName: "One"
        )
        let registry = AthleteProfileRegistry(
            activeProfileID: "missing",
            profiles: [profile]
        )

        XCTAssertThrowsError(try registry.validated()) { error in
            XCTAssertEqual(
                error as? AthleteProfileRegistryError,
                .activeProfileMissing
            )
        }
    }
}

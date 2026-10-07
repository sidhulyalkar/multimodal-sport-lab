import Combine
import Foundation
import MotionOSAppleCapture

@MainActor
final class AthleteProfileStore: ObservableObject {
    @Published private(set) var registry: AthleteProfileRegistry
    @Published private(set) var errorMessage: String?

    private let fileURL: URL?

    var profiles: [AthleteProfile] {
        registry.profiles
    }

    var activeProfile: AthleteProfile {
        registry.activeProfile ?? AthleteProfile.defaultLocal()
    }

    init(fileURL: URL? = nil) {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        self.fileURL = resolvedURL

        if let resolvedURL,
           FileManager.default.fileExists(atPath: resolvedURL.path) {
            do {
                let data = try Data(contentsOf: resolvedURL)
                let decoded = try JSONDecoder().decode(
                    AthleteProfileRegistry.self,
                    from: data
                )
                registry = try decoded.validated()
                errorMessage = nil
                return
            } catch {
                registry = AthleteProfileRegistry.defaultLocal()
                errorMessage = (
                    "MotionOS could not read the saved profile list. "
                        + "Your session files were not changed."
                )
                return
            }
        }

        registry = AthleteProfileRegistry.defaultLocal()
        errorMessage = nil
        persist()
    }

    @discardableResult
    func createProfile(
        displayName: String
    ) -> AthleteProfile? {
        let cleaned = cleanName(displayName)
        guard !cleaned.isEmpty else {
            errorMessage = "Enter a name for this profile."
            return nil
        }

        let profile = AthleteProfile(displayName: cleaned)
        registry.profiles.append(profile)
        registry.activeProfileID = profile.id
        persist()
        return profile
    }

    func setActiveProfile(
        id: String
    ) {
        guard registry.profiles.contains(where: { $0.id == id }) else {
            errorMessage = "That profile is no longer available."
            return
        }

        registry.activeProfileID = id
        persist()
    }

    func renameActiveProfile(
        to displayName: String
    ) {
        let cleaned = cleanName(displayName)
        guard !cleaned.isEmpty else {
            errorMessage = "Profile name cannot be empty."
            return
        }
        guard let index = registry.profiles.firstIndex(
            where: { $0.id == registry.activeProfileID }
        ) else {
            errorMessage = "The active profile could not be found."
            return
        }

        registry.profiles[index] = registry.profiles[index].renamed(
            cleaned
        )
        persist()
    }

    func setUnitPreference(
        _ units: MotionOSUnitPreference
    ) {
        guard let index = registry.profiles.firstIndex(
            where: { $0.id == registry.activeProfileID }
        ) else {
            errorMessage = "The active profile could not be found."
            return
        }

        registry.profiles[index] = registry.profiles[index].withUnits(
            units
        )
        persist()
    }

    func clearError() {
        errorMessage = nil
    }

    private func persist() {
        guard let fileURL else {
            errorMessage = (
                "Profile preferences cannot be saved on this device right now."
            )
            return
        }

        do {
            _ = try registry.validated()
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(registry).write(
                to: fileURL,
                options: [.atomic]
            )
            errorMessage = nil
        } catch {
            errorMessage = (
                "MotionOS could not save profile preferences. "
                    + "Session recordings were not changed."
            )
        }
    }

    private func cleanName(
        _ value: String
    ) -> String {
        String(
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(40)
        )
    }

    private static func defaultFileURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }

        return base
            .appendingPathComponent(
                "MotionOS",
                isDirectory: true
            )
            .appendingPathComponent("athlete-profiles-v1.json")
    }
}

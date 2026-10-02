import Combine
import Foundation
import MotionOSAppleCapture

@MainActor
final class PersonaEvidenceLibrary: ObservableObject {
    @Published private(set) var evidence: [PersonaSessionEvidence] = []
    @Published private(set) var errorMessage: String?

    func refresh() {
        do {
            let directory = try Self.evidenceDirectory()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter {
                $0.pathExtension.lowercased() == "json"
            }

            evidence = files.compactMap {
                try? PersonaEvidenceStore.load(from: $0)
            }
            .sorted {
                $0.observedAt > $1.observedAt
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func save(
        _ item: PersonaSessionEvidence
    ) -> URL? {
        do {
            let directory = try Self.evidenceDirectory()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent(
                sanitize(item.id) + ".json"
            )
            try PersonaEvidenceStore.write(
                item,
                to: url
            )
            refresh()
            return url
        } catch {
            errorMessage = (
                "Persona evidence could not be saved: "
                    + error.localizedDescription
            )
            return nil
        }
    }

    static func evidenceDirectory() throws -> URL {
        try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(
            "MotionOSPersona",
            isDirectory: true
        )
        .appendingPathComponent(
            "evidence",
            isDirectory: true
        )
    }

    private func sanitize(
        _ value: String
    ) -> String {
        value.map { character in
            if character.isLetter
                || character.isNumber
                || character == "-"
                || character == "_" {
                return String(character)
            }
            return "_"
        }
        .joined()
    }
}

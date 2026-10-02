import Combine
import Foundation
import MotionOSAppleCapture

@MainActor
final class PersonalBodyModelCoordinator: ObservableObject {
    @Published private(set) var models: [PersonalBodyModel] = []
    @Published private(set) var latestModel: PersonalBodyModel?
    @Published private(set) var latestCalibrationResult: BodyCalibrationResult?
    @Published private(set) var errorMessage: String?

    init() {
        reload()
    }

    func reload() {
        do {
            let directory = try modelsDirectory()
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
                    && $0.lastPathComponent.hasPrefix("body-model-")
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = files.compactMap { url -> PersonalBodyModel? in
                guard let data = try? Data(contentsOf: url) else {
                    return nil
                }
                return try? decoder.decode(
                    PersonalBodyModel.self,
                    from: data
                )
            }
            .sorted {
                $0.calibratedAt > $1.calibratedAt
            }

            models = loaded
            latestModel = loaded.first

            if let latest = loaded.first,
               let result = loadResult(
                    versionID: latest.versionID,
                    directory: directory
               ) {
                latestCalibrationResult = result
            } else {
                latestCalibrationResult = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func save(
        _ result: BodyCalibrationResult
    ) -> URL? {
        do {
            let directory = try modelsDirectory()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let safeVersion = sanitize(
                result.model.versionID
            )
            let modelURL = directory.appendingPathComponent(
                "body-model-\(safeVersion).json"
            )
            let resultURL = directory.appendingPathComponent(
                "body-calibration-\(safeVersion).json"
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            try encoder.encode(result.model).write(
                to: modelURL,
                options: .atomic
            )
            try encoder.encode(result).write(
                to: resultURL,
                options: .atomic
            )

            reload()
            return modelURL
        } catch {
            errorMessage = (
                "Body model could not be saved: "
                    + error.localizedDescription
            )
            return nil
        }
    }

    func latestModelURL() -> URL? {
        guard let latestModel else { return nil }
        return try? modelsDirectory().appendingPathComponent(
            "body-model-\(sanitize(latestModel.versionID)).json"
        )
    }

    private func modelsDirectory() throws -> URL {
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
            "body-models",
            isDirectory: true
        )
    }

    private func loadResult(
        versionID: String,
        directory: URL
    ) -> BodyCalibrationResult? {
        let url = directory.appendingPathComponent(
            "body-calibration-\(sanitize(versionID)).json"
        )
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(
            BodyCalibrationResult.self,
            from: data
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

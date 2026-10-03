import Foundation

public enum IndoBoardEquipmentQualificationRegistryError:
    LocalizedError,
    Equatable {
    case unreadable(String)
    case invalidSchema(String)
    case duplicateModelID(String)
    case emptyModelID

    public var errorDescription: String? {
        switch self {
        case .unreadable(let message):
            return "Qualification registry could not be decoded: \(message)"
        case .invalidSchema(let schema):
            return "Unsupported qualification registry schema: \(schema)"
        case .duplicateModelID(let modelID):
            return "Qualification registry contains duplicate model ID: \(modelID)"
        case .emptyModelID:
            return "Qualification registry contains an empty model ID."
        }
    }
}

public enum IndoBoardEquipmentQualificationRegistryLoader {
    public static func load(
        from data: Data
    ) throws -> IndoBoardEquipmentModelQualificationRegistry {
        let registry: IndoBoardEquipmentModelQualificationRegistry
        do {
            registry = try JSONDecoder().decode(
                IndoBoardEquipmentModelQualificationRegistry.self,
                from: data
            )
        } catch {
            throw IndoBoardEquipmentQualificationRegistryError
                .unreadable(error.localizedDescription)
        }

        guard registry.schemaVersion
                == IndoBoardEquipmentModelQualificationRegistry
                    .schemaVersion
        else {
            throw IndoBoardEquipmentQualificationRegistryError
                .invalidSchema(registry.schemaVersion)
        }

        var seen = Set<String>()
        for qualification in registry.qualifications {
            let modelID =
                qualification.modelID
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
            guard !modelID.isEmpty else {
                throw IndoBoardEquipmentQualificationRegistryError
                    .emptyModelID
            }
            guard seen.insert(modelID).inserted else {
                throw IndoBoardEquipmentQualificationRegistryError
                    .duplicateModelID(modelID)
            }
        }

        return registry
    }

    public static func load(
        from url: URL
    ) throws -> IndoBoardEquipmentModelQualificationRegistry {
        do {
            return try load(
                from: Data(contentsOf: url)
            )
        } catch let error as IndoBoardEquipmentQualificationRegistryError {
            throw error
        } catch {
            throw IndoBoardEquipmentQualificationRegistryError
                .unreadable(error.localizedDescription)
        }
    }
}

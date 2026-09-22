import Combine
import Foundation

@MainActor
final class PhoneJournalInbox: ObservableObject {
    @Published private(set) var latestSessionID: String?
    @Published private(set) var latestJournalURL: URL?
    @Published private(set) var lastError: String?

    func ingest(fileURL: URL, metadata: [String: Any]?) {
        do {
            let sessionID = (metadata?["session_id"] as? String)
                ?? "unknown-\(UUID().uuidString.prefix(8).lowercased())"

            let manager = FileManager.default
            let documents = try manager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = documents
                .appendingPathComponent("MotionOSInbox", isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)

            let destination = directory.appendingPathComponent("watch.jsonl")
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }

            try manager.copyItem(at: fileURL, to: destination)
            latestSessionID = sessionID
            latestJournalURL = destination
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

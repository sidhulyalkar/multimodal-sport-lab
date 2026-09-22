import Combine
import Foundation
import UIKit

@MainActor
final class PhoneJournalInbox: ObservableObject {
    @Published private(set) var latestSessionID: String?
    @Published private(set) var latestJournalURL: URL?
    @Published private(set) var latestHostMetadataURL: URL?
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
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let destination = directory.appendingPathComponent("watch.jsonl")
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(at: fileURL, to: destination)

            let hostMetadataURL = directory.appendingPathComponent(
                "iphone-host.json"
            )
            let device = UIDevice.current
            let appVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown"
            let appBuild = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown"
            let hostMetadata: [String: Any] = [
                "session_id": sessionID,
                "received_at_utc": ISO8601DateFormatter().string(from: Date()),
                "iphone_model": device.model,
                "iphone_localized_model": device.localizedModel,
                "iphone_system_name": device.systemName,
                "iphone_system_version": device.systemVersion,
                "app_version": appVersion,
                "app_build": appBuild,
            ]
            let hostData = try JSONSerialization.data(
                withJSONObject: hostMetadata,
                options: [.prettyPrinted, .sortedKeys]
            )
            try hostData.write(
                to: hostMetadataURL,
                options: .atomic
            )

            latestSessionID = sessionID
            latestJournalURL = destination
            latestHostMetadataURL = hostMetadataURL
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

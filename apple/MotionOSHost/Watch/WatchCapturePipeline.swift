import Foundation
import MotionOSAppleCapture

actor WatchCapturePipeline {
    let sessionID: String
    let journalURL: URL

    private let journal: JSONLJournal
    private var eventCount = 0

    init(sessionID: String, journalURL: URL) throws {
        self.sessionID = sessionID
        self.journalURL = journalURL
        self.journal = try JSONLJournal(url: journalURL)
    }

    func append(_ event: SensorEnvelope) async throws -> Int {
        try await journal.append(event)
        eventCount += 1
        return eventCount
    }

    func close() async throws -> Int {
        try await journal.close()
        return eventCount
    }
}

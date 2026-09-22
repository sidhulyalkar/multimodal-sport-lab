import Foundation

public actor JSONLJournal {
    public let url: URL
    private var handle: FileHandle?
    private let encoder: JSONEncoder

    public init(url: URL) throws {
        self.url = url
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !manager.fileExists(atPath: url.path) {
            _ = manager.createFile(atPath: url.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try self.handle?.seekToEnd()
    }

    public func append(_ event: SensorEnvelope) throws {
        guard let handle else { throw JournalError.closed }
        var data = try encoder.encode(event)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    public func close() throws {
        try handle?.synchronize()
        try handle?.close()
        handle = nil
    }

    public enum JournalError: Error {
        case closed
    }
}

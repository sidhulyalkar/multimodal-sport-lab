import CryptoKit
import Foundation

public struct FileEvidenceDigest: Codable, Equatable, Sendable {
    public let sha256: String
    public let byteCount: UInt64

    public init(sha256: String, byteCount: UInt64) {
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

public enum FileEvidence {
    public static func digest(
        _ url: URL,
        chunkSize: Int = 1_048_576
    ) throws -> FileEvidenceDigest {
        precondition(chunkSize > 0)

        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        var byteCount: UInt64 = 0

        while true {
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
            byteCount += UInt64(data.count)
        }

        let digest = hasher.finalize()
        let sha256 = digest.map {
            String(format: "%02x", $0)
        }.joined()

        return FileEvidenceDigest(
            sha256: sha256,
            byteCount: byteCount
        )
    }
}

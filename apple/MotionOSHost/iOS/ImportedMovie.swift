import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// File-backed movie transfer for PhotosPicker.
///
/// A 4K action-camera movie can be multiple gigabytes. Keeping the transfer
/// file-backed avoids materializing the complete movie as Data in app memory.
struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let manager = FileManager.default
            let ext = received.file.pathExtension.isEmpty
                ? "mov"
                : received.file.pathExtension
            let destination = manager.temporaryDirectory
                .appendingPathComponent(
                    "motionos-import-\(UUID().uuidString).\(ext)"
                )
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(
                at: received.file,
                to: destination
            )
            return ImportedMovie(url: destination)
        }
    }
}

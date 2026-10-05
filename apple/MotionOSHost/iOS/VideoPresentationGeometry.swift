import AVFoundation
import CoreGraphics
import Foundation

enum MotionOSVideoPresentation {
    static let fallbackAspectRatio =
        16.0 / 9.0

    nonisolated static func displayAspectRatio(
        for url: URL
    ) async -> Double {
        do {
            let asset =
                AVURLAsset(url: url)
            guard let track =
                    try await asset
                        .loadTracks(
                            withMediaType:
                                .video
                        )
                        .first
            else {
                return fallbackAspectRatio
            }

            let naturalSize =
                try await track.load(
                    .naturalSize
                )
            let transform =
                try await track.load(
                    .preferredTransform
                )
            let transformed =
                CGRect(
                    origin: .zero,
                    size: naturalSize
                )
                .applying(transform)
            let width =
                abs(transformed.width)
            let height =
                abs(transformed.height)

            guard width.isFinite,
                  height.isFinite,
                  width > 0,
                  height > 0
            else {
                return fallbackAspectRatio
            }
            return width / height
        } catch {
            return fallbackAspectRatio
        }
    }
}

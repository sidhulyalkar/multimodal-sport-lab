import CoreImage
import CoreImage.CIFilterBuiltins
import MotionOSAppleCapture
import SwiftUI
import UIKit

struct IndoBoardMarkerSetupView: View {
    @State private var artifacts: [URL] = []
    @State private var errorMessage: String?

    private let markers: [
        (
            id: IndoBoardFiducialMarkerID,
            title: String,
            placement: String
        )
    ] = [
        (
            .deckLeft,
            "Deck left",
            "Place near the camera-visible left end of the deck."
        ),
        (
            .deckRight,
            "Deck right",
            "Place near the camera-visible right end of the deck."
        ),
        (
            .rollerCenter,
            "Roller",
            "Place on the center of the camera-facing roller end cap."
        ),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                intro

                ForEach(markers, id: \.id) { marker in
                    markerCard(marker)
                }

                shareCard
            }
            .motionOSPageWidth()
            .padding(.horizontal, MotionOSDesign.pageHorizontalPadding)
            .padding(.vertical, 14)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Beta Board Markers")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            generateArtifacts()
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            MotionOSSectionHeader(
                title: "Bootstrap board tracking",
                subtitle: "Optional beta accelerant",
                systemImage: "qrcode.viewfinder",
                accent: .cyan
            )

            Text(
                "These three small QR markers let the existing iPhone Vision "
                    + "pass measure deck endpoints and roller position now, "
                    + "while MotionOS collects data for the future markerless model."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Label(
                "The normal body-only session still works without markers.",
                systemImage: "figure.stand"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            Label(
                "For early testing, keep a clear area and use a stable support or spotter.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
        .cardStyle()
    }

    private func markerCard(
        _ marker: (
            id: IndoBoardFiducialMarkerID,
            title: String,
            placement: String
        )
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                if let image = Self.qrImage(
                    payload: marker.id.rawValue,
                    size: 420
                ) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 132, height: 132)
                        .background(.white)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 8,
                                style: .continuous
                            )
                        )
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(marker.title)
                        .font(.headline)

                    Text(marker.placement)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(marker.id.rawValue)
                        .font(
                            .system(
                                size: 8,
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }

            Text(
                marker.id == .rollerCenter
                    ? "Mount this on the end cap facing the camera. Rotation is okay; keep the code unobstructed."
                    : "Keep the code flat and visible from the iPhone. Do not cover the deck stop or riding surface where it could affect footing."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var shareCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !artifacts.isEmpty {
                ShareLink(items: artifacts) {
                    Label(
                        "Share / Print Marker PNGs",
                        systemImage: "square.and.arrow.up"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Text(
                    "Print near original size, cut the three codes, and attach them once. "
                        + "The Watch will show “Board + roller tracked” when all required markers are visible."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let errorMessage {
                Label(
                    errorMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            } else {
                ProgressView("Preparing marker files…")
                    .font(.caption)
            }
        }
        .cardStyle()
    }

    private func generateArtifacts() {
        do {
            artifacts = try Self.writeArtifacts(
                markers.map(\.id)
            )
            errorMessage = nil
        } catch {
            errorMessage =
                "Marker export failed: "
                    + error.localizedDescription
        }
    }

    private static func writeArtifacts(
        _ markers: [IndoBoardFiducialMarkerID]
    ) throws -> [URL] {
        let manager = FileManager.default
        let documents = try manager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents
            .appendingPathComponent(
                "MotionOSSetup",
                isDirectory: true
            )
            .appendingPathComponent(
                "IndoBoardFiducialsV1",
                isDirectory: true
            )
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        return try markers.map { marker in
            guard let image = qrImage(
                payload: marker.rawValue,
                size: 900
            ),
            let data = image.pngData()
            else {
                throw CocoaError(.fileWriteUnknown)
            }

            let name = marker.rawValue
                .lowercased()
                .replacingOccurrences(
                    of: ":",
                    with: "_"
                )
                + ".png"
            let url = directory
                .appendingPathComponent(name)
            try data.write(
                to: url,
                options: .atomic
            )
            return url
        }
    }

    private static func qrImage(
        payload: String,
        size: CGFloat
    ) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else {
            return nil
        }

        let extent = output.extent
        let scale = min(
            size / extent.width,
            size / extent.height
        )
        let scaled = output.transformed(
            by: CGAffineTransform(
                scaleX: scale,
                y: scale
            )
        )

        let context = CIContext(
            options: [.useSoftwareRenderer: false]
        )
        guard let image = context.createCGImage(
            scaled,
            from: scaled.extent
        ) else {
            return nil
        }

        return UIImage(cgImage: image)
    }
}

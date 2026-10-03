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
                        "Share / Print Marker Kit",
                        systemImage: "square.and.arrow.up"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Text(
                    "The kit includes a 100%-scale printable PDF plus individual PNGs. Cut the three codes and attach them once. "
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
                markers
            )
            errorMessage = nil
        } catch {
            errorMessage =
                "Marker export failed: "
                    + error.localizedDescription
        }
    }

    private static func writeArtifacts(
        _ markers: [
            (
                id: IndoBoardFiducialMarkerID,
                title: String,
                placement: String
            )
        ]
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

        var outputs: [URL] = []

        for marker in markers {
            guard let image = qrImage(
                payload: marker.id.rawValue,
                size: 900
            ),
            let data = image.pngData()
            else {
                throw CocoaError(.fileWriteUnknown)
            }

            let name = marker.id.rawValue
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
            outputs.append(url)
        }

        let printableURL = directory
            .appendingPathComponent(
                "motionos-indo-board-markers-v1.pdf"
            )
        try writePrintablePDF(
            markers,
            to: printableURL
        )
        outputs.insert(printableURL, at: 0)

        return outputs
    }

    private static func writePrintablePDF(
        _ markers: [
            (
                id: IndoBoardFiducialMarkerID,
                title: String,
                placement: String
            )
        ],
        to url: URL
    ) throws {
        // US Letter at 72 pt/in. Each QR is exactly 2 in square when
        // printed at 100%, but QR physical size is not used as calibration.
        let page = CGRect(
            x: 0,
            y: 0,
            width: 612,
            height: 792
        )
        let renderer = UIGraphicsPDFRenderer(
            bounds: page
        )

        let data = renderer.pdfData { context in
            context.beginPage()

            let titleAttributes: [
                NSAttributedString.Key: Any
            ] = [
                .font: UIFont.systemFont(
                    ofSize: 20,
                    weight: .bold
                ),
                .foregroundColor: UIColor.label,
            ]
            let subtitleAttributes: [
                NSAttributedString.Key: Any
            ] = [
                .font: UIFont.systemFont(
                    ofSize: 10,
                    weight: .regular
                ),
                .foregroundColor: UIColor.secondaryLabel,
            ]
            let markerTitleAttributes: [
                NSAttributedString.Key: Any
            ] = [
                .font: UIFont.systemFont(
                    ofSize: 14,
                    weight: .semibold
                ),
                .foregroundColor: UIColor.label,
            ]
            let bodyAttributes: [
                NSAttributedString.Key: Any
            ] = [
                .font: UIFont.systemFont(
                    ofSize: 9.5,
                    weight: .regular
                ),
                .foregroundColor: UIColor.secondaryLabel,
            ]
            let codeAttributes: [
                NSAttributedString.Key: Any
            ] = [
                .font: UIFont.monospacedSystemFont(
                    ofSize: 8,
                    weight: .medium
                ),
                .foregroundColor: UIColor.secondaryLabel,
            ]

            NSString(
                string: "MotionOS · INDO BOARD beta markers"
            )
            .draw(
                in: CGRect(
                    x: 36,
                    y: 30,
                    width: 540,
                    height: 26
                ),
                withAttributes: titleAttributes
            )

            NSString(
                string:
                    "Print at 100% scale. Three visible markers enable deck-relative beta tracking. Marker size is not a physical calibration reference."
            )
            .draw(
                in: CGRect(
                    x: 36,
                    y: 58,
                    width: 540,
                    height: 28
                ),
                withAttributes: subtitleAttributes
            )

            let qrSize: CGFloat = 144
            let rowHeight: CGFloat = 210
            let startY: CGFloat = 102

            for (index, marker) in markers.enumerated() {
                let y =
                    startY + CGFloat(index) * rowHeight
                let qrRect = CGRect(
                    x: 40,
                    y: y,
                    width: qrSize,
                    height: qrSize
                )

                UIColor.white.setFill()
                context.cgContext.fill(qrRect)

                qrImage(
                    payload: marker.id.rawValue,
                    size: 900
                )?.draw(in: qrRect)

                context.cgContext.setStrokeColor(
                    UIColor.systemGray4.cgColor
                )
                context.cgContext.setLineWidth(0.75)
                context.cgContext.stroke(qrRect)

                NSString(string: marker.title)
                    .draw(
                        in: CGRect(
                            x: 206,
                            y: y + 10,
                            width: 350,
                            height: 24
                        ),
                        withAttributes:
                            markerTitleAttributes
                    )

                NSString(string: marker.placement)
                    .draw(
                        in: CGRect(
                            x: 206,
                            y: y + 40,
                            width: 350,
                            height: 46
                        ),
                        withAttributes: bodyAttributes
                    )

                NSString(string: marker.id.rawValue)
                    .draw(
                        in: CGRect(
                            x: 206,
                            y: y + 95,
                            width: 350,
                            height: 20
                        ),
                        withAttributes: codeAttributes
                    )

                NSString(
                    string:
                        "2.0 in QR at 100% print scale · keep the full white/black code visible to the iPhone camera."
                )
                .draw(
                    in: CGRect(
                        x: 206,
                        y: y + 122,
                        width: 350,
                        height: 36
                    ),
                    withAttributes: bodyAttributes
                )

                context.cgContext.setStrokeColor(
                    UIColor.systemGray5.cgColor
                )
                context.cgContext.move(
                    to: CGPoint(
                        x: 36,
                        y: y + 176
                    )
                )
                context.cgContext.addLine(
                    to: CGPoint(
                        x: 576,
                        y: y + 176
                    )
                )
                context.cgContext.strokePath()
            }

            NSString(
                string:
                    "Safety: do not place markers where they change footing, interfere with deck stops or roller contact, or create a snag hazard. If tracking is intermittent, improve lighting/visibility or move the iPhone before increasing marker size."
            )
            .draw(
                in: CGRect(
                    x: 36,
                    y: 738,
                    width: 540,
                    height: 42
                ),
                withAttributes: subtitleAttributes
            )
        }

        try data.write(
            to: url,
            options: .atomic
        )
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

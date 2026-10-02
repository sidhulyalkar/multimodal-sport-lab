import MotionOSAppleCapture
import SwiftUI
import UIKit

@MainActor
final class PlayerCardExportCoordinator: ObservableObject {
    @Published private(set) var imageURL: URL?
    @Published private(set) var metadataURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRendering = false

    func render(
        snapshot: PlayerCardSnapshot,
        displayName: String
    ) async {
        isRendering = true
        errorMessage = nil
        imageURL = nil
        metadataURL = nil
        defer { isRendering = false }

        let normalizedName = displayName
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        let poster = PlayerCardPoster(
            snapshot: snapshot,
            displayName: normalizedName.isEmpty
                ? "MotionOS Player"
                : normalizedName
        )
        .frame(width: 400, height: 500)
        .environment(.colorScheme, .dark)

        let renderer = ImageRenderer(
            content: poster
        )
        renderer.proposedSize = ProposedViewSize(
            width: 400,
            height: 500
        )
        renderer.scale = 3

        guard let image = renderer.uiImage,
              let png = image.pngData()
        else {
            errorMessage =
                "MotionOS could not render the Player Card image."
            return
        }

        do {
            let directory = try exportDirectory()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let stamp = Self.timestamp()
            let imageURL = directory.appendingPathComponent(
                "motionos-player-card-(stamp).png"
            )
            let metadataURL = directory.appendingPathComponent(
                "motionos-player-card-(stamp).json"
            )

            try png.write(
                to: imageURL,
                options: .atomic
            )
            try PlayerCardStore.write(
                snapshot,
                to: metadataURL
            )

            self.imageURL = imageURL
            self.metadataURL = metadataURL
        } catch {
            errorMessage =
                "Player Card export failed: "
                    + error.localizedDescription
        }
    }

    private func exportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(
            "MotionOSPersona",
            isDirectory: true
        )
        .appendingPathComponent(
            "player-cards",
            isDirectory: true
        )
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(
            identifier: "en_US_POSIX"
        )
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(
            from: Date()
        )
    }
}

struct PlayerCardLauncher: View {
    @EnvironmentObject private var persona: FitnessPersonaCoordinator
    @State private var showingCard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Player Card",
                subtitle: "A shareable movement profile, not a fitness score",
                systemImage: "person.text.rectangle",
                accent: .cyan
            )

            HStack(spacing: 12) {
                MotionOSMark(size: 54)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Movement passport")
                        .font(.headline)
                    Text(
                        "(shareableCoverageCount) / "
                            + "(PlayerCardEngine.shareableDimensions.count) "
                            + "share-safe movement domains"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Button {
                showingCard = true
            } label: {
                Label(
                    "Build Shareable Player Card",
                    systemImage: "sparkles.rectangle.stack"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text(
                "The default share card excludes HealthKit values, sleep, HRV, "
                    + "heart-rate metrics, body measurements, body composition, "
                    + "and raw sensor evidence."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
        .sheet(
            isPresented: $showingCard
        ) {
            NavigationStack {
                PlayerCardShareView(
                    snapshot:
                        PlayerCardEngine.build(
                            from: persona.snapshot
                        )
                )
            }
        }
    }

    private var shareableCoverageCount: Int {
        PlayerCardEngine.shareableDimensions
            .filter {
                persona.snapshot.state(
                    for: $0
                )?.coverage != .none
            }
            .count
    }
}

struct PlayerCardShareView: View {
    let snapshot: PlayerCardSnapshot

    @AppStorage(
        "motionos.player-card.display-name"
    )
    private var displayName = "MotionOS Player"

    @StateObject private var exporter =
        PlayerCardExportCoordinator()

    @Environment(.dismiss)
    private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PlayerCardPoster(
                    snapshot: snapshot,
                    displayName:
                        normalizedDisplayName
                )
                .frame(width: 320, height: 400)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 28,
                        style: .continuous
                    )
                )
                .shadow(
                    color: .black.opacity(0.20),
                    radius: 20,
                    y: 10
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Card name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField(
                        "Display name",
                        text: $displayName
                    )
                    .textFieldStyle(.roundedBorder)

                    Text(
                        "This name is stored locally on the device and appears "
                            + "only on cards you explicitly render."
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: 520)

                exportControls
                    .frame(maxWidth: 520)

                privacyBoundary
                    .frame(maxWidth: 520)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Player Card")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(
                placement: .topBarTrailing
            ) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private var exportControls: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    await exporter.render(
                        snapshot: snapshot,
                        displayName:
                            normalizedDisplayName
                    )
                }
            } label: {
                HStack {
                    if exporter.isRendering {
                        ProgressView()
                    } else {
                        Image(
                            systemName:
                                "square.and.arrow.up"
                        )
                    }

                    Text(
                        exporter.imageURL == nil
                            ? "Render Share Card"
                            : "Render Updated Card"
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(exporter.isRendering)

            if let imageURL = exporter.imageURL {
                ShareLink(
                    item: imageURL
                ) {
                    Label(
                        "Share PNG",
                        systemImage: "photo"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if let metadataURL =
                exporter.metadataURL {
                ShareLink(
                    item: metadataURL
                ) {
                    Label(
                        "Export Card Evidence JSON",
                        systemImage:
                            "doc.text.magnifyingglass"
                    )
                    .font(.caption.weight(.semibold))
                }
            }

            if let error = exporter.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(
                        horizontal: false,
                        vertical: true
                    )
            }
        }
    }

    private var privacyBoundary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                "Privacy-first social surface",
                systemImage: "lock.shield.fill"
            )
            .font(.subheadline.weight(.semibold))

            Text(snapshot.privacyBoundary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(snapshot.claimBoundary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(
                cornerRadius: 16,
                style: .continuous
            )
        )
    }

    private var normalizedDisplayName: String {
        let value = displayName
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        return value.isEmpty
            ? "MotionOS Player"
            : value
    }
}

struct PlayerCardPoster: View {
    let snapshot: PlayerCardSnapshot
    let displayName: String

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / 400

            ZStack {
                background

                VStack(
                    alignment: .leading,
                    spacing: 0
                ) {
                    header(scale: scale)

                    Spacer(minLength: 18 * scale)

                    coverageStrip(
                        scale: scale
                    )

                    Spacer(minLength: 18 * scale)

                    highlights(
                        scale: scale
                    )

                    Spacer()

                    footer(scale: scale)
                }
                .padding(24 * scale)
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 30 * scale,
                    style: .continuous
                )
            )
        }
        .aspectRatio(4.0 / 5.0, contentMode: .fit)
        .accessibilityElement(
            children: .combine
        )
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color.indigo.opacity(0.82),
                    Color.cyan.opacity(0.46),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(
                    Color.cyan.opacity(0.13)
                )
                .frame(width: 260)
                .blur(radius: 4)
                .offset(x: 130, y: -190)

            Circle()
                .fill(
                    Color.indigo.opacity(0.18)
                )
                .frame(width: 300)
                .blur(radius: 12)
                .offset(x: -150, y: 210)
        }
    }

    private func header(
        scale: CGFloat
    ) -> some View {
        HStack(alignment: .center, spacing: 12 * scale) {
            MotionOSMark(
                size: 52 * scale
            )

            VStack(alignment: .leading, spacing: 2 * scale) {
                Text("MOTIONOS PLAYER")
                    .font(
                        .system(
                            size: 10 * scale,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .tracking(1.8 * scale)
                    .foregroundStyle(
                        .white.opacity(0.66)
                    )

                Text(displayName)
                    .font(
                        .system(
                            size: 25 * scale,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.64)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2 * scale) {
                Text(
                    "(snapshot.sourceSessionCount)"
                )
                .font(
                    .system(
                        size: 23 * scale,
                        weight: .bold,
                        design: .rounded
                    )
                )
                .monospacedDigit()
                .foregroundStyle(.white)

                Text("PROFILE DEPTH")
                    .font(
                        .system(
                            size: 7.5 * scale,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(
                        .white.opacity(0.56)
                    )
            }
        }
    }

    private func coverageStrip(
        scale: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            Text("MOVEMENT PROFILE")
                .font(
                    .system(
                        size: 9 * scale,
                        weight: .bold,
                        design: .rounded
                    )
                )
                .tracking(1.4 * scale)
                .foregroundStyle(
                    .white.opacity(0.55)
                )

            HStack(spacing: 8 * scale) {
                ForEach(snapshot.dimensions) {
                    state in
                    VStack(
                        alignment: .leading,
                        spacing: 4 * scale
                    ) {
                        HStack(spacing: 5 * scale) {
                            Circle()
                                .fill(
                                    coverageColor(
                                        state.coverage
                                    )
                                )
                                .frame(
                                    width: 7 * scale,
                                    height: 7 * scale
                                )

                            Text(
                                state.dimension
                                    .displayName
                                    .uppercased()
                            )
                            .font(
                                .system(
                                    size: 8 * scale,
                                    weight: .bold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(
                                .white.opacity(0.82)
                            )
                        }

                        Text(
                            state.coverage.displayName
                        )
                        .font(
                            .system(
                                size: 8.5 * scale,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(
                            .white.opacity(0.62)
                        )
                    }
                    .padding(9 * scale)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .background(
                        Color.white.opacity(0.07),
                        in: RoundedRectangle(
                            cornerRadius: 12 * scale,
                            style: .continuous
                        )
                    )
                }
            }
        }
    }

    private func highlights(
        scale: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 9 * scale) {
            HStack {
                Text("LATEST SIGNALS")
                    .font(
                        .system(
                            size: 9 * scale,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .tracking(1.4 * scale)
                    .foregroundStyle(
                        .white.opacity(0.55)
                    )

                Spacer()

                if snapshot.bodyModelCalibrated {
                    Label(
                        "BODY RIG",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(
                        .system(
                            size: 8 * scale,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(
                        .cyan.opacity(0.92)
                    )
                }
            }

            if snapshot.highlights.isEmpty {
                VStack(
                    alignment: .leading,
                    spacing: 5 * scale
                ) {
                    Text("Build the profile")
                        .font(
                            .system(
                                size: 17 * scale,
                                weight: .bold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(.white)

                    Text(
                        "Complete standardized MotionOS sessions to populate share-safe movement signals."
                    )
                    .font(
                        .system(
                            size: 10 * scale,
                            weight: .medium,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(
                        .white.opacity(0.64)
                    )
                }
                .padding(14 * scale)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .background(
                    Color.white.opacity(0.07),
                    in: RoundedRectangle(
                        cornerRadius: 14 * scale,
                        style: .continuous
                    )
                )
            } else {
                ForEach(
                    snapshot.highlights.prefix(3)
                ) { highlight in
                    HStack(
                        alignment: .firstTextBaseline,
                        spacing: 10 * scale
                    ) {
                        VStack(
                            alignment: .leading,
                            spacing: 2 * scale
                        ) {
                            Text(
                                highlight.dimension
                                    .displayName
                                    .uppercased()
                            )
                            .font(
                                .system(
                                    size: 7.5 * scale,
                                    weight: .bold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(
                                .cyan.opacity(0.82)
                            )

                            Text(highlight.label)
                                .font(
                                    .system(
                                        size: 11 * scale,
                                        weight: .semibold,
                                        design: .rounded
                                    )
                                )
                                .foregroundStyle(
                                    .white.opacity(0.84)
                                )
                                .lineLimit(1)
                        }

                        Spacer()

                        VStack(
                            alignment: .trailing,
                            spacing: 1 * scale
                        ) {
                            Text(
                                formattedValue(
                                    highlight
                                )
                            )
                            .font(
                                .system(
                                    size: 17 * scale,
                                    weight: .bold,
                                    design: .rounded
                                )
                            )
                            .monospacedDigit()
                            .foregroundStyle(.white)

                            Text(
                                highlight.sampleCount == 1
                                    ? "1 sample"
                                    : "(highlight.sampleCount) samples"
                            )
                            .font(
                                .system(
                                    size: 7.5 * scale,
                                    weight: .medium,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(
                                .white.opacity(0.50)
                            )
                        }
                    }
                    .padding(
                        .horizontal,
                        12 * scale
                    )
                    .padding(
                        .vertical,
                        9 * scale
                    )
                    .background(
                        Color.white.opacity(0.065),
                        in: RoundedRectangle(
                            cornerRadius: 13 * scale,
                            style: .continuous
                        )
                    )
                }
            }
        }
    }

    private func footer(
        scale: CGFloat
    ) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text("EVIDENCE, NOT A SCORE")
                    .font(
                        .system(
                            size: 8 * scale,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .tracking(1.1 * scale)
                    .foregroundStyle(
                        .white.opacity(0.56)
                    )

                Text(
                    snapshot.generatedAt.formatted(
                        date: .abbreviated,
                        time: .omitted
                    )
                )
                .font(
                    .system(
                        size: 8.5 * scale,
                        weight: .medium,
                        design: .rounded
                    )
                )
                .foregroundStyle(
                    .white.opacity(0.48)
                )
            }

            Spacer()

            Text("motionOS")
                .font(
                    .system(
                        size: 13 * scale,
                        weight: .bold,
                        design: .rounded
                    )
                )
                .foregroundStyle(
                    .white.opacity(0.78)
                )
        }
    }

    private func coverageColor(
        _ coverage: PersonaEvidenceCoverage
    ) -> Color {
        switch coverage {
        case .none:
            return .white.opacity(0.24)
        case .singleSession:
            return .orange
        case .repeated:
            return .cyan
        case .longitudinal:
            return .indigo
        }
    }

    private func formattedValue(
        _ highlight: PlayerCardHighlight
    ) -> String {
        let decimals: Int
        switch highlight.unit {
        case "bpm", "deg":
            decimals = 0
        case "ratio":
            return String(
                format: "%.0f%%",
                highlight.value * 100
            )
        default:
            decimals = 2
        }

        return String(
            format: "%.*f %@",
            decimals,
            highlight.value,
            highlight.unit
        )
    }
}

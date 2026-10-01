import SwiftUI

struct WatchMotionTrace: View {
    let points: [WatchSessionController.VisualTelemetryPoint]
    let currentDeltaG: Double?
    let currentRotationRate: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("MOTION TRACE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)

                    Text(
                        currentDeltaG.map {
                            String(format: "%.2f Δg", $0)
                        } ?? "warming up"
                    )
                    .font(
                        .system(.caption, design: .rounded)
                            .weight(.semibold)
                    )
                }

                Spacer(minLength: 4)

                if let currentRotationRate {
                    Text(
                        String(format: "%.2f rad/s", currentRotationRate)
                    )
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
            }

            GeometryReader { proxy in
                let values = points.map(\.motionDeltaG)
                let maxValue = max(values.max() ?? 0.25, 0.25)

                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.04))

                    Path { path in
                        guard values.count > 1 else { return }

                        for index in values.indices {
                            let x = proxy.size.width
                                * CGFloat(index)
                                / CGFloat(max(values.count - 1, 1))
                            let normalized = min(
                                max(values[index] / maxValue, 0),
                                1
                            )
                            let y = proxy.size.height
                                * CGFloat(1 - normalized)

                            if index == values.startIndex {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(
                        LinearGradient(
                            colors: [.cyan, .indigo],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(
                            lineWidth: 2,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .shadow(color: .cyan.opacity(0.25), radius: 3)
                }
            }
            .frame(height: 40)
        }
        .padding(8)
        .background(
            LinearGradient(
                colors: [
                    Color.cyan.opacity(0.10),
                    Color.indigo.opacity(0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live dynamic acceleration trace")
    }
}

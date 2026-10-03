import SwiftUI

struct MotionOSMark: View {
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: size * 0.28,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [
                        Color.indigo,
                        Color.cyan
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height

                Path { path in
                    path.move(
                        to: CGPoint(
                            x: width * 0.16,
                            y: height * 0.62
                        )
                    )
                    path.addLine(
                        to: CGPoint(
                            x: width * 0.31,
                            y: height * 0.39
                        )
                    )
                    path.addLine(
                        to: CGPoint(
                            x: width * 0.47,
                            y: height * 0.66
                        )
                    )
                    path.addLine(
                        to: CGPoint(
                            x: width * 0.63,
                            y: height * 0.29
                        )
                    )
                    path.addLine(
                        to: CGPoint(
                            x: width * 0.83,
                            y: height * 0.51
                        )
                    )
                }
                .stroke(
                    Color.white,
                    style: StrokeStyle(
                        lineWidth: max(2.5, size * 0.075),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

                Circle()
                    .fill(Color.white)
                    .frame(
                        width: size * 0.11,
                        height: size * 0.11
                    )
                    .position(
                        x: width * 0.83,
                        y: height * 0.51
                    )
            }
            .padding(size * 0.08)
        }
        .frame(width: size, height: size)
        .shadow(
            color: Color.indigo.opacity(0.20),
            radius: size * 0.13,
            y: size * 0.06
        )
        .accessibilityHidden(true)
    }
}

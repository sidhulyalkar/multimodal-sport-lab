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
                            x: width * 0.18,
                            y: height * 0.62
                        )
                    )
                    path.addLine(
                        to: CGPoint(
                            x: width * 0.33,
                            y: height * 0.38
                        )
                    )
                    path.addLine(
                        to: CGPoint(
                            x: width * 0.48,
                            y: height * 0.65
                        )
                    )
                    path.addLine(
                        to: CGPoint(
                            x: width * 0.64,
                            y: height * 0.30
                        )
                    )
                    path.addLine(
                        to: CGPoint(
                            x: width * 0.82,
                            y: height * 0.52
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
                        width: size * 0.12,
                        height: size * 0.12
                    )
                    .position(
                        x: width * 0.82,
                        y: height * 0.52
                    )
            }
            .padding(size * 0.08)
        }
        .frame(width: size, height: size)
        .shadow(
            color: Color.black.opacity(0.14),
            radius: size * 0.10,
            y: size * 0.04
        )
        .accessibilityHidden(true)
    }
}

#Preview("MotionOS mark") {
    VStack(spacing: 24) {
        MotionOSMark(size: 52)
        MotionOSMark(size: 96)
    }
    .padding()
}

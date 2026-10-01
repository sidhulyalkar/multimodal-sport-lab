import SwiftUI

enum MotionOSDesign {
    static let pageMaxWidth: CGFloat = 820
    static let cardRadius: CGFloat = 22
    static let compactCardRadius: CGFloat = 16
    static let pageSpacing: CGFloat = 14
    static let pageHorizontalPadding: CGFloat = 16
}

struct MotionOSCardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(
                    cornerRadius: MotionOSDesign.cardRadius,
                    style: .continuous
                )
                .fill(
                    Color(.secondarySystemGroupedBackground)
                        .opacity(0.94)
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: MotionOSDesign.cardRadius,
                    style: .continuous
                )
                .stroke(
                    Color.primary.opacity(0.055),
                    lineWidth: 1
                )
            }
            .shadow(
                color: Color.black.opacity(0.035),
                radius: 14,
                y: 7
            )
    }
}

struct MotionOSSectionHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var accent: Color = .accentColor

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: 9,
                    style: .continuous
                )
                .fill(accent.opacity(0.10))
                .frame(width: 34, height: 34)

                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

struct MotionOSStatusBadge: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(color.opacity(0.10), in: Capsule())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

struct MotionOSPageBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground)

            LinearGradient(
                colors: [
                    Color.indigo.opacity(0.13),
                    Color.cyan.opacity(0.055),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .center
            )
            .frame(height: 420)
        }
        .ignoresSafeArea()
    }
}

extension View {
    func cardStyle(
        padding: CGFloat = 16
    ) -> some View {
        modifier(MotionOSCardModifier(padding: padding))
    }

    func motionOSPageWidth() -> some View {
        frame(maxWidth: MotionOSDesign.pageMaxWidth)
            .frame(maxWidth: .infinity)
    }
}

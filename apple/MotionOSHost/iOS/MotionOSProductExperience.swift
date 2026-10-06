import SwiftUI

struct MotionOSActivityDescriptor: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let sessionSummary: String
    let systemImage: String
    let requirementSummary: String
    let accent: Color

    static func == (
        lhs: MotionOSActivityDescriptor,
        rhs: MotionOSActivityDescriptor
    ) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum MotionOSActivityCatalog {
    static let indoBoard = MotionOSActivityDescriptor(
        id: "indo_board",
        title: "Indo Board",
        subtitle: "Balance and control",
        sessionSummary: "Guided 2-minute session",
        systemImage: "figure.surfing",
        requirementSummary: "Apple Watch + iPhone video",
        accent: .indigo
    )

    static let available: [MotionOSActivityDescriptor] = [
        indoBoard
    ]
}

struct MotionOSFirstRunView: View {
    let onComplete: () -> Void

    var body: some View {
        ZStack {
            MotionOSPageBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 26) {
                    Spacer(minLength: 26)

                    MotionOSMark(size: 72)
                        .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Text("Move. Measure. Learn.")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)

                        Text(
                            "MotionOS helps you understand how your movement "
                                + "changes over time without reducing you to "
                                + "one mystery score."
                        )
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 12) {
                        onboardingRow(
                            symbol: "record.circle",
                            title: "Record a real session",
                            detail:
                                "Choose an activity. MotionOS checks only "
                                + "what that activity needs and guides setup."
                        )

                        onboardingRow(
                            symbol: "person.crop.circle.badge.checkmark",
                            title: "Compare with yourself",
                            detail:
                                "Repeat similar sessions to build your "
                                + "personal range and make changes easier "
                                + "to understand."
                        )

                        onboardingRow(
                            symbol: "checkmark.shield",
                            title: "Keep insights traceable",
                            detail:
                                "Measurements stay connected to the sensor "
                                + "and video evidence that produced them."
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Indo Board is the first guided activity",
                            systemImage: "figure.surfing"
                        )
                        .font(.subheadline.weight(.semibold))

                        Text(
                            "The product shell is activity-based so new sports "
                                + "can use the same recording, progress, and "
                                + "session experience as their measurement "
                                + "workflows are validated."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        Color.primary.opacity(0.04),
                        in: RoundedRectangle(
                            cornerRadius: 18,
                            style: .continuous
                        )
                    )

                    Button(action: onComplete) {
                        Label(
                            "Get Started",
                            systemImage: "arrow.right"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.indigo)

                    Text(
                        "Permissions are requested only when a feature needs "
                            + "them. You can review devices and technical "
                            + "details later."
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 20)
                }
                .motionOSPageWidth()
                .padding(.horizontal, 24)
            }
        }
        .interactiveDismissDisabled()
    }

    private func onboardingRow(
        symbol: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: 14,
                    style: .continuous
                )
                .fill(Color.indigo.opacity(0.11))
                .frame(width: 48, height: 48)

                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.indigo)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProgressHomeView: View {
    @Binding var selectedTab: MotionOSTab

    @EnvironmentObject private var runLibrary: ProductRunLibrary

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                progressIntro
                MovementTrendsCard()
                comparisonPrinciple
            }
            .motionOSPageWidth()
            .padding(
                .horizontal,
                MotionOSDesign.pageHorizontalPadding
            )
            .padding(.top, 4)
            .padding(.bottom, 36)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Progress")
        .navigationBarTitleDisplayMode(.large)
        .task {
            runLibrary.refresh()
        }
        .refreshable {
            runLibrary.refresh()
        }
    }

    private var completedRuns: Int {
        runLibrary.runs.filter { $0.outcome == .completed }.count
    }

    private var progressIntro: some View {
        VStack(alignment: .leading, spacing: 13) {
            MotionOSSectionHeader(
                title: progressTitle,
                subtitle: progressSubtitle,
                systemImage: "chart.line.uptrend.xyaxis",
                accent: .indigo
            )

            if completedRuns < 2 {
                Button {
                    selectedTab = .record
                } label: {
                    Label(
                        completedRuns == 0
                            ? "Record Your First Session"
                            : "Repeat the Same Activity",
                        systemImage: "record.circle"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .cardStyle()
    }

    private var progressTitle: String {
        switch completedRuns {
        case 0:
            "Your movement starts here"
        case 1:
            "One session saved"
        default:
            "(completedRuns) sessions in your history"
        }
    }

    private var progressSubtitle: String {
        switch completedRuns {
        case 0:
            "Record a guided activity to create your first reference point."
        case 1:
            "Repeat a similar session to begin seeing personal trends."
        default:
            "Session history is available now. Personal ranges use only like-for-like reviewed sessions."
        }
    }

    private var comparisonPrinciple: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Like-for-like comparisons",
                systemImage: "equal.circle"
            )
            .font(.headline)

            Text(
                "MotionOS keeps activity and recording context separate. "
                    + "A change is shown as a change first, not automatically "
                    + "labeled better or worse."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "As repeated reviewed sessions accumulate, personal ranges "
                    + "and session-to-baseline comparisons can replace generic "
                    + "population scores."
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }
}

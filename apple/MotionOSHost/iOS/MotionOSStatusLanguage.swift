import MotionOSAppleCapture
import SwiftUI

/// The one product vocabulary for Apple Watch state. Every screen uses these
/// strings; pairing, reachability, and install bits stay in diagnostics.
extension WatchLinkStatus {
    var title: String {
        switch self {
        case .checking: "Checking Watch"
        case .ready: "Watch ready"
        case .recording: "Watch recording"
        case .appSetup: "Watch app setup"
        case .noWatch: "No Watch"
        case .issue: "Issue"
        }
    }

    var badge: String {
        switch self {
        case .checking: "CHECKING"
        case .ready: "READY"
        case .recording: "RECORDING"
        case .appSetup: "SETUP"
        case .noWatch: "NO WATCH"
        case .issue: "ISSUE"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "Looking for MotionOS on Apple Watch"
        case .ready:
            "MotionOS apps detected each other"
        case .recording:
            "MotionOS is recording on Apple Watch"
        case .appSetup(let needsInstall):
            needsInstall
                ? "Install MotionOS on Apple Watch"
                : "Open MotionOS on Apple Watch once"
        case .noWatch:
            "Pair an Apple Watch with this iPhone"
        case .issue:
            "Open MotionOS on Apple Watch to review the last recording"
        }
    }

    var symbol: String {
        switch self {
        case .checking: "applewatch"
        case .ready: "applewatch"
        case .recording: "applewatch.radiowaves.left.and.right"
        case .appSetup: "applewatch.slash"
        case .noWatch: "applewatch.slash"
        case .issue: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .checking: .secondary
        case .ready: .green
        case .recording: .red
        case .appSetup: .orange
        case .noWatch: .secondary
        case .issue: .orange
        }
    }
}

extension LiveObservatoryPhase {
    var badge: String {
        switch self {
        case .checking: "CHECKING"
        case .watchSetupRequired: "SETUP"
        case .ready: "READY"
        case .starting: "STARTING"
        case .live: "LIVE"
        case .reconnecting: "RECONNECTING"
        case .paused: "PAUSED"
        case .finishing: "FINISHING"
        case .saved: "SAVED"
        case .issue: "ISSUE"
        }
    }

    var tint: Color {
        switch self {
        case .live: .green
        case .reconnecting, .starting, .finishing: .yellow
        case .paused: .secondary
        case .saved: .green
        case .issue, .watchSetupRequired: .orange
        case .checking, .ready: .secondary
        }
    }
}

/// One status capsule. Used wherever a single device state is shown.
struct MotionOSStatusPill: View {
    let title: String
    let tint: Color
    var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .opacity(pulsing ? 1 : 0.9)
                .modifier(PulseModifier(active: pulsing))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct PulseModifier: ViewModifier {
    let active: Bool
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(active && dimmed ? 0.35 : 1)
            .onAppear { animate() }
            .onChange(of: active) { _, _ in animate() }
    }

    private func animate() {
        guard active, !reduceMotion else {
            dimmed = false
            return
        }
        withAnimation(.easeInOut(duration: 0.8).repeatForever()) {
            dimmed = true
        }
    }
}

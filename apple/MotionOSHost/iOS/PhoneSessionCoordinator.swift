import Combine
import Foundation
import HealthKit
import MotionOSAppleCapture
import WatchConnectivity

@MainActor
final class PhoneSessionCoordinator: NSObject, ObservableObject {
    enum State: String {
        case idle
        case authorizing
        case launchingWatch
        case waitingForMirror
        case running
        case paused
        case disconnected
        case ended
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var watchPaired = false
    @Published private(set) var watchAppInstalled = false
    @Published private(set) var watchReachable = false
    @Published private(set) var errorMessage: String?

    let inbox = PhoneJournalInbox()

    private let healthStore = HKHealthStore()
    private let transport = WatchConnectivityTransport()
    private var mirroredSession: HKWorkoutSession?

    override init() {
        super.init()

        healthStore.workoutSessionMirroringStartHandler = { [weak self] session in
            guard let self else { return }
            Task { @MainActor in
                self.adoptMirroredSession(session)
            }
        }

        transport.onStateChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.refreshWatchState()
            }
        }

        transport.onFileReceived = { [weak self] url, metadata in
            guard let self else { return }
            // WCSession's received file URL is temporary, so copy it while
            // handling the callback rather than retaining the source URL.
            Task { @MainActor in
                self.inbox.ingest(fileURL: url, metadata: metadata)
            }
        }

        refreshWatchState()
    }

    func refreshWatchState() {
        let session = transport.session
        watchPaired = session.isPaired
        watchAppInstalled = session.isWatchAppInstalled
        watchReachable = session.isReachable
    }

    func requestAuthorization() async {
        state = .authorizing
        errorMessage = nil
        do {
            let workout = HKObjectType.workoutType()
            let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate)
            var read: Set<HKObjectType> = [workout]
            if let heartRate { read.insert(heartRate) }

            try await healthStore.requestAuthorization(
                toShare: [workout],
                read: read
            )
            state = .idle
        } catch {
            fail(error)
        }
    }

    func startP0() async {
        errorMessage = nil
        refreshWatchState()

        guard watchPaired else {
            fail(CoordinatorError.watchNotPaired)
            return
        }
        guard watchAppInstalled else {
            fail(CoordinatorError.watchAppNotInstalled)
            return
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .outdoor

        state = .launchingWatch
        do {
            try await healthStore.startWatchApp(toHandle: configuration)
            state = .waitingForMirror
        } catch {
            fail(error)
        }
    }

    private func adoptMirroredSession(_ session: HKWorkoutSession) {
        mirroredSession = session
        session.delegate = self
        switch session.state {
        case .running:
            state = .running
        case .paused:
            state = .paused
        case .ended:
            state = .ended
        default:
            state = .waitingForMirror
        }
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        state = .failed
    }

    enum CoordinatorError: LocalizedError {
        case watchNotPaired
        case watchAppNotInstalled

        var errorDescription: String? {
            switch self {
            case .watchNotPaired:
                "No paired Apple Watch is available."
            case .watchAppNotInstalled:
                "Install MotionOS on the paired Apple Watch first."
            }
        }
    }
}

extension PhoneSessionCoordinator: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            switch toState {
            case .running:
                self.state = .running
            case .paused:
                self.state = .paused
            case .ended:
                self.state = .ended
                self.mirroredSession = nil
            default:
                break
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.fail(error)
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        Task { @MainActor in
            self.state = .disconnected
            if let error {
                self.errorMessage = error.localizedDescription
            }
            self.mirroredSession = nil
        }
    }
}

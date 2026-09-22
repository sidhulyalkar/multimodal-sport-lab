import Combine
import Foundation

@MainActor
final class EquipmentPodController: ObservableObject {
    enum Phase: String {
        case idle
        case scanning
        case connecting
        case ready
        case previewing
        case recording
        case linkLost = "link lost"
        case recovering
        case downloading
        case evidenceReady = "evidence ready"
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var candidates: [MetaMotionCandidate] = []
    @Published private(set) var deviceMetadata: MetaMotionDeviceMetadata?
    @Published private(set) var latestAccel: MetaMotionVector?
    @Published private(set) var latestGyro: MetaMotionVector?
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var evidenceBundle: MetaMotionEvidenceBundle?
    @Published private(set) var errorMessage: String?

    private let discovery = MetaMotionDiscovery()
    private var engine: MetaMotionCaptureEngine?
    private var scanRefreshTask: Task<Void, Never>?
    private var stateRefreshTask: Task<Void, Never>?
    private var lastPreviewPublish = Date.distantPast

    func startScanning() {
        errorMessage = nil
        candidates = []
        discovery.startScanning()
        phase = .scanning

        scanRefreshTask?.cancel()
        scanRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.candidates = self.discovery.candidates()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    func stopScanning() {
        discovery.stopScanning()
        scanRefreshTask?.cancel()
        scanRefreshTask = nil
        if engine == nil {
            phase = .idle
        }
    }

    func connect(_ candidate: MetaMotionCandidate) async {
        stopScanning()
        phase = .connecting
        errorMessage = nil

        do {
            let engine = try await discovery.connect(
                identifier: candidate.id
            )
            self.engine = engine
            deviceMetadata = await engine.deviceMetadata()
            phase = .ready
            startStateRefresh()
        } catch {
            fail(error)
        }
    }

    func startPreview() async {
        guard let engine else { return }
        errorMessage = nil

        do {
            try await engine.startPreview { [weak self] sample in
                Task { @MainActor in
                    self?.ingestPreview(sample)
                }
            }
            phase = .previewing
        } catch {
            fail(error)
        }
    }

    func stopPreview() async {
        guard let engine else { return }
        do {
            try await engine.stopPreview()
            phase = .ready
        } catch {
            fail(error)
        }
    }

    func armRecording(
        clearExistingFlash: Bool
    ) async {
        guard let engine else { return }
        errorMessage = nil
        evidenceBundle = nil
        downloadProgress = 0

        do {
            try await engine.startRecording(
                clearExistingFlash: clearExistingFlash
            )
            phase = .recording
        } catch {
            fail(error)
        }
    }

    func reconnectForRecovery() async {
        guard let engine else { return }
        phase = .recovering
        errorMessage = nil

        do {
            try await engine.reconnectForRecovery()
            phase = .recording
        } catch {
            fail(error)
        }
    }

    func stopRecoverAndExport() async {
        guard let engine else { return }
        phase = .downloading
        errorMessage = nil
        downloadProgress = 0

        do {
            let recovered = try await engine.stopAndRecover(
                clearFlashAfterSuccess: true
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                }
            }

            let sessionID = Self.makeSessionID()
            evidenceBundle = try await recovered.writeEvidenceBundle(
                sessionID: sessionID
            )
            downloadProgress = 1
            phase = .evidenceReady
        } catch {
            fail(error)
        }
    }

    func disconnect() async {
        guard let engine else { return }
        do {
            try await engine.disconnect()
            stateRefreshTask?.cancel()
            stateRefreshTask = nil
            self.engine = nil
            deviceMetadata = nil
            latestAccel = nil
            latestGyro = nil
            phase = .idle
        } catch {
            fail(error)
        }
    }

    private func startStateRefresh() {
        stateRefreshTask?.cancel()
        stateRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let engine = self.engine else { return }
                let state = await engine.currentState()
                self.apply(state)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func apply(
        _ state: MetaMotionCaptureState
    ) {
        switch state {
        case .ready:
            if phase != .evidenceReady {
                phase = .ready
            }
        case .previewing:
            phase = .previewing
        case .recording:
            phase = .recording
        case .linkLostRecording(let message):
            phase = .linkLost
            errorMessage = message
        case .recovering:
            phase = .recovering
        case .downloading(let progress):
            phase = .downloading
            downloadProgress = progress
        case .failed(let message):
            phase = .failed
            errorMessage = message
        }
    }

    private func ingestPreview(
        _ sample: MetaMotionLiveSample
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastPreviewPublish) >= 0.08 else {
            return
        }
        lastPreviewPublish = now

        switch sample.channel {
        case .accelerometer:
            latestAccel = sample.valueSI
        case .gyroscope:
            latestGyro = sample.valueSI
        }
    }

    private func fail(_ error: Error) {
        phase = .failed
        errorMessage = error.localizedDescription
    }

    private static func makeSessionID() -> String {
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "p1-pod-\(stamp)-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

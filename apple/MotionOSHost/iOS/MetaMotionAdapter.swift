import Foundation
import MetaWear
import MotionOSAppleCapture

struct MetaMotionCandidate: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int?
}

@MainActor
final class MetaMotionDiscovery {
    private let scanner = MetaWearScanner()

    var isScanning: Bool { scanner.isScanning }
    var isBluetoothUnavailable: Bool { scanner.isBluetoothUnavailable }

    func startScanning() {
        scanner.startScan()
    }

    func stopScanning() {
        scanner.stopScan()
    }

    func candidates() -> [MetaMotionCandidate] {
        scanner.discoveredDevices.keys
            .map { identifier in
                MetaMotionCandidate(
                    id: identifier,
                    name: scanner.advertisedNames[identifier] ?? "MetaWear",
                    rssi: scanner.advertisementRSSI[identifier]
                )
            }
            .sorted { lhs, rhs in
                switch (lhs.rssi, rhs.rssi) {
                case let (l?, r?) where l != r:
                    return l > r
                default:
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                        == .orderedAscending
                }
            }
    }

    func connect(
        identifier: UUID
    ) async throws -> MetaMotionCaptureEngine {
        scanner.stopScan()
        let device = scanner.discoveredDevices[identifier]
            ?? scanner.device(forKnownIdentifier: identifier)
        return try await MetaMotionCaptureEngine.connect(to: device)
    }
}

struct MetaMotionVector: Sendable, Equatable {
    let x: Double
    let y: Double
    let z: Double
}

enum MetaMotionChannel: String, Sendable, Equatable {
    case accelerometer
    case gyroscope
}

struct MetaMotionLiveSample: Sendable, Equatable {
    let channel: MetaMotionChannel
    let hostReceivedAt: Date
    let valueSI: MetaMotionVector
}

struct MetaMotionLoggedSample: Sendable, Equatable {
    let channel: MetaMotionChannel
    let wallTime: Date
    let deviceTickMS: Double
    let valueSI: MetaMotionVector

    var deviceTimeNS: UInt64 {
        UInt64(max(0, (deviceTickMS * 1_000_000).rounded()))
    }
}

struct MetaMotionDeviceMetadata: Sendable, Equatable {
    let identifier: UUID
    let model: String
    let modelNumber: String
    let serialNumber: String
    let firmwareRevision: String
    let hardwareRevision: String
    let requestedAccelHz: Double
    let requestedAccelRangeG: Float
    let requestedGyroHz: Double
    let requestedGyroRangeDPS: Float
    let sdkRevision: String
}

struct MetaMotionRecoveredSession: Sendable {
    let metadata: MetaMotionDeviceMetadata
    let accelerometer: [MetaMotionLoggedSample]
    let gyroscope: [MetaMotionLoggedSample]

    func sensorEvents(
        sessionID: String,
        deviceID: String = "metamotion-s"
    ) -> [SensorEnvelope] {
        let accelEvents = accelerometer.enumerated().map { sequence, sample in
            SensorEnvelope(
                sessionID: sessionID,
                deviceID: deviceID,
                stream: "/equipment/imu/accel",
                sequence: UInt64(sequence),
                deviceTimeNS: sample.deviceTimeNS,
                payload: [
                    "sensor": .string("accelerometer"),
                    "ax": .number(sample.valueSI.x),
                    "ay": .number(sample.valueSI.y),
                    "az": .number(sample.valueSI.z),
                    "timestamp_basis": .string("device_tick_ms"),
                    "wall_time_unix_s": .number(
                        sample.wallTime.timeIntervalSince1970
                    ),
                    "units": .string("m/s^2"),
                    "source": .string("metamotion_s_bmi270_flash"),
                ]
            )
        }

        let gyroEvents = gyroscope.enumerated().map { sequence, sample in
            SensorEnvelope(
                sessionID: sessionID,
                deviceID: deviceID,
                stream: "/equipment/imu/gyro",
                sequence: UInt64(sequence),
                deviceTimeNS: sample.deviceTimeNS,
                payload: [
                    "sensor": .string("gyroscope"),
                    "gx": .number(sample.valueSI.x),
                    "gy": .number(sample.valueSI.y),
                    "gz": .number(sample.valueSI.z),
                    "timestamp_basis": .string("device_tick_ms"),
                    "wall_time_unix_s": .number(
                        sample.wallTime.timeIntervalSince1970
                    ),
                    "units": .string("rad/s"),
                    "source": .string("metamotion_s_bmi270_flash"),
                ]
            )
        }

        return (accelEvents + gyroEvents).sorted {
            if $0.deviceTimeNS == $1.deviceTimeNS {
                return $0.stream < $1.stream
            }
            return $0.deviceTimeNS < $1.deviceTimeNS
        }
    }
}

enum MetaMotionCaptureState: Sendable, Equatable {
    case ready
    case previewing
    case recording
    case linkLostRecording(String)
    case recovering
    case downloading(Double)
    case failed(String)
}

enum MetaMotionAdapterError: LocalizedError {
    case unsupportedModel(String)
    case unsupportedHardware(String)
    case missingDeviceInformation
    case missingAccelerometer
    case missingGyroscope
    case invalidState(String)
    case existingOnBoardLoggers(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedModel(let model):
            "MotionOS P1 currently requires MetaMotionS; found \(model)."
        case .unsupportedHardware(let revision):
            "Unsupported MetaMotionS hardware revision: \(revision)."
        case .missingDeviceInformation:
            "MetaWear connected without readable device information."
        case .missingAccelerometer:
            "MetaMotionS accelerometer module was not discovered."
        case .missingGyroscope:
            "MetaMotionS gyroscope module was not discovered."
        case .invalidState(let detail):
            detail
        case .existingOnBoardLoggers(let count):
            "The pod already has \(count) active logger entries. Recover or explicitly clear them before starting a new recording."
        }
    }
}

actor MetaMotionCaptureEngine {
    static let sdkRevision = "7dd2a5dbddafb2f8d583cb8d018be476d8ee9a71"
    static let accelerationMS2PerG = 9.80665
    static let radiansPerDegree = Double.pi / 180.0

    private let device: MetaWearDevice
    private let accelerometer: MWAccelerometer
    private let gyroscope: MWGyroscope
    private let metadata: MetaMotionDeviceMetadata

    private var state: MetaMotionCaptureState = .ready
    private var accelPreviewTask: Task<Void, Never>?
    private var gyroPreviewTask: Task<Void, Never>?

    private init(
        device: MetaWearDevice,
        accelerometer: MWAccelerometer,
        gyroscope: MWGyroscope,
        metadata: MetaMotionDeviceMetadata
    ) {
        self.device = device
        self.accelerometer = accelerometer
        self.gyroscope = gyroscope
        self.metadata = metadata
    }

    static func connect(
        to device: MetaWearDevice
    ) async throws -> MetaMotionCaptureEngine {
        try await device.connect()

        guard let info = await device.deviceInfo else {
            try? await device.disconnect()
            throw MetaMotionAdapterError.missingDeviceInformation
        }
        guard info.model == .motionS else {
            try? await device.disconnect()
            throw MetaMotionAdapterError.unsupportedModel(info.model.name)
        }
        guard info.isHardwareRevisionSupported else {
            try? await device.disconnect()
            throw MetaMotionAdapterError.unsupportedHardware(
                info.hardwareRevision
            )
        }

        let requestedAccelHz = 100.0
        let requestedAccelRangeG: Float = 16.0
        let requestedGyroHz = 100.0
        let requestedGyroRangeDPS: Float = 2_000.0

        guard let accelerometer = await device.makeAccelerometer(
            odrHz: requestedAccelHz,
            rangeG: requestedAccelRangeG
        ) else {
            try? await device.disconnect()
            throw MetaMotionAdapterError.missingAccelerometer
        }
        guard let gyroscope = await device.makeGyroscope(
            odrHz: requestedGyroHz,
            rangeDPS: requestedGyroRangeDPS
        ) else {
            try? await device.disconnect()
            throw MetaMotionAdapterError.missingGyroscope
        }

        let metadata = MetaMotionDeviceMetadata(
            identifier: device.identifier,
            model: info.model.name,
            modelNumber: info.modelNumber,
            serialNumber: info.serialNumber,
            firmwareRevision: info.firmwareRevision,
            hardwareRevision: info.hardwareRevision,
            requestedAccelHz: accelerometer.odrHz,
            requestedAccelRangeG: accelerometer.rangeG,
            requestedGyroHz: gyroscope.odrHz,
            requestedGyroRangeDPS: gyroscope.rangeDPS,
            sdkRevision: sdkRevision
        )

        let engine = MetaMotionCaptureEngine(
            device: device,
            accelerometer: accelerometer,
            gyroscope: gyroscope,
            metadata: metadata
        )
        await device.motionOSSetUnexpectedDisconnectHandler { error in
            Task {
                await engine.handleUnexpectedDisconnect(error)
            }
        }
        return engine
    }

    func currentState() -> MetaMotionCaptureState {
        state
    }

    func deviceMetadata() -> MetaMotionDeviceMetadata {
        metadata
    }

    func startPreview(
        sink: @escaping @Sendable (MetaMotionLiveSample) -> Void
    ) async throws {
        guard state == .ready else {
            throw MetaMotionAdapterError.invalidState(
                "Preview requires a ready pod."
            )
        }

        let accelStream = try await device.startStream(
            accelerometer,
            usePacked: true
        )
        do {
            let gyroStream = try await device.startStream(
                gyroscope,
                usePacked: true
            )
            state = .previewing

            accelPreviewTask = Task {
                do {
                    for try await sample in accelStream {
                        sink(
                            MetaMotionLiveSample(
                                channel: .accelerometer,
                                hostReceivedAt: sample.time,
                                valueSI: Self.accelerationToSI(sample.value)
                            )
                        )
                    }
                } catch {
                    await self.previewFailed(error)
                }
            }

            gyroPreviewTask = Task {
                do {
                    for try await sample in gyroStream {
                        sink(
                            MetaMotionLiveSample(
                                channel: .gyroscope,
                                hostReceivedAt: sample.time,
                                valueSI: Self.gyroscopeToSI(sample.value)
                            )
                        )
                    }
                } catch {
                    await self.previewFailed(error)
                }
            }
        } catch {
            try? await device.stopStreaming(accelerometer)
            throw error
        }
    }

    func stopPreview() async throws {
        guard state == .previewing else { return }

        accelPreviewTask?.cancel()
        gyroPreviewTask?.cancel()
        accelPreviewTask = nil
        gyroPreviewTask = nil

        try await device.stopStreaming(accelerometer)
        try await device.stopStreaming(gyroscope)
        state = .ready
    }

    func startRecording(
        clearExistingFlash: Bool = false
    ) async throws {
        guard state == .ready else {
            throw MetaMotionAdapterError.invalidState(
                "Recording requires a ready pod. Stop preview first."
            )
        }

        if clearExistingFlash {
            try await device.clearLog()
        } else {
            let active = try await device.queryActiveLoggers()
            guard active.isEmpty else {
                throw MetaMotionAdapterError.existingOnBoardLoggers(
                    active.count
                )
            }
        }

        try await device.startLogging(accelerometer)
        do {
            try await device.startLogging(gyroscope)
            state = .recording
        } catch {
            try? await device.stopLogging(accelerometer)
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func reconnectForRecovery() async throws {
        switch state {
        case .linkLostRecording, .failed:
            break
        default:
            throw MetaMotionAdapterError.invalidState(
                "Recovery reconnect is only valid after a recording link loss."
            )
        }

        state = .recovering
        do {
            try await device.reconnect()
            try await validateConnectedDevice()

            let active = try await device.queryActiveLoggers()
            try await device.recoverLoggers(
                for: accelerometer,
                using: active
            )
            try await device.recoverLoggers(
                for: gyroscope,
                using: active
            )
            state = .recording
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func stopAndRecover(
        clearFlashAfterSuccess: Bool = true,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MetaMotionRecoveredSession {
        if case .linkLostRecording = state {
            try await reconnectForRecovery()
        }

        guard state == .recording else {
            throw MetaMotionAdapterError.invalidState(
                "No recoverable recording is active."
            )
        }

        do {
            try await device.stopLogging(accelerometer)
            try await device.stopLogging(gyroscope)
            _ = try await device.flushLogPage()

            state = .downloading(0)

            let accelDownload = try await device.downloadLogs(accelerometer)
            let accelSamples = try await collect(
                accelDownload,
                channel: .accelerometer,
                progressBase: 0.0,
                progressScale: 0.5,
                progress: progress
            )

            let gyroDownload = try await device.downloadLogs(gyroscope)
            let gyroSamples = try await collect(
                gyroDownload,
                channel: .gyroscope,
                progressBase: 0.5,
                progressScale: 0.5,
                progress: progress
            )

            guard !accelSamples.isEmpty, !gyroSamples.isEmpty else {
                throw MetaMotionAdapterError.invalidState(
                    "Recovered pod log is missing accelerometer or gyroscope samples."
                )
            }

            if clearFlashAfterSuccess {
                try await device.clearLog()
            }

            state = .ready
            return MetaMotionRecoveredSession(
                metadata: metadata,
                accelerometer: accelSamples,
                gyroscope: gyroSamples
            )
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func disconnect() async throws {
        switch state {
        case .ready:
            try await device.disconnect()
        case .previewing:
            try await stopPreview()
            try await device.disconnect()
        case .recording, .linkLostRecording, .recovering, .downloading:
            throw MetaMotionAdapterError.invalidState(
                "Do not intentionally disconnect while evidence is pending. Stop and recover the flash log first."
            )
        case .failed:
            try? await device.disconnect()
        }
    }

    private func collect(
        _ stream: AsyncThrowingStream<
            Download<[MWLoggedSample<CartesianFloat>]>,
            Error
        >,
        channel: MetaMotionChannel,
        progressBase: Double,
        progressScale: Double,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [MetaMotionLoggedSample] {
        var final: [MWLoggedSample<CartesianFloat>] = []

        for try await snapshot in stream {
            final = snapshot.data
            let combined = progressBase
                + progressScale * snapshot.percentComplete
            state = .downloading(combined)
            progress?(combined)
        }

        switch channel {
        case .accelerometer:
            return final.map {
                MetaMotionLoggedSample(
                    channel: channel,
                    wallTime: $0.date,
                    deviceTickMS: $0.tickMs,
                    valueSI: Self.accelerationToSI($0.value)
                )
            }
        case .gyroscope:
            return final.map {
                MetaMotionLoggedSample(
                    channel: channel,
                    wallTime: $0.date,
                    deviceTickMS: $0.tickMs,
                    valueSI: Self.gyroscopeToSI($0.value)
                )
            }
        }
    }

    private func validateConnectedDevice() async throws {
        guard let info = await device.deviceInfo else {
            throw MetaMotionAdapterError.missingDeviceInformation
        }
        guard info.model == .motionS else {
            throw MetaMotionAdapterError.unsupportedModel(info.model.name)
        }
        guard info.isHardwareRevisionSupported else {
            throw MetaMotionAdapterError.unsupportedHardware(
                info.hardwareRevision
            )
        }
    }

    private func handleUnexpectedDisconnect(_ error: Error) {
        accelPreviewTask?.cancel()
        gyroPreviewTask?.cancel()
        accelPreviewTask = nil
        gyroPreviewTask = nil

        switch state {
        case .recording:
            state = .linkLostRecording(error.localizedDescription)
        default:
            state = .failed(error.localizedDescription)
        }
    }

    private func previewFailed(_ error: Error) {
        if state == .previewing {
            state = .failed(error.localizedDescription)
        }
    }

    private static func accelerationToSI(
        _ value: CartesianFloat
    ) -> MetaMotionVector {
        MetaMotionVector(
            x: Double(value.x) * accelerationMS2PerG,
            y: Double(value.y) * accelerationMS2PerG,
            z: Double(value.z) * accelerationMS2PerG
        )
    }

    private static func gyroscopeToSI(
        _ value: CartesianFloat
    ) -> MetaMotionVector {
        MetaMotionVector(
            x: Double(value.x) * radiansPerDegree,
            y: Double(value.y) * radiansPerDegree,
            z: Double(value.z) * radiansPerDegree
        )
    }
}

extension MetaWearDevice {
    func motionOSSetUnexpectedDisconnectHandler(
        _ handler: (@Sendable (Error) -> Void)?
    ) {
        onUnexpectedDisconnect = handler
    }
}

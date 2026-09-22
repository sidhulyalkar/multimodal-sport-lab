import Foundation
import MotionOSAppleCapture

struct MetaMotionEvidenceBundle: Sendable {
    let directory: URL
    let journalURL: URL
    let metadataURL: URL
}

extension MetaMotionRecoveredSession {
    func writeEvidenceBundle(
        sessionID: String,
        rootURL: URL? = nil
    ) async throws -> MetaMotionEvidenceBundle {
        let manager = FileManager.default
        let root: URL
        if let rootURL {
            root = rootURL
        } else {
            root = try manager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("MotionOSPod", isDirectory: true)
        }

        let directory = root
            .appendingPathComponent(sessionID, isDirectory: true)
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let journalURL = directory.appendingPathComponent("pod.jsonl")
        if manager.fileExists(atPath: journalURL.path) {
            try manager.removeItem(at: journalURL)
        }

        let journal = try JSONLJournal(url: journalURL)
        do {
            try await writeChronologicalEvents(
                to: journal,
                sessionID: sessionID
            )
            try await journal.close()
        } catch {
            try? await journal.close()
            throw error
        }

        let metadataURL = directory.appendingPathComponent(
            "pod-metadata.json"
        )
        let metadataObject: [String: Any] = [
            "schema_version": "motionos.p1.pod.v1",
            "session_id": sessionID,
            "recovered_at_utc": ISO8601DateFormatter().string(from: Date()),
            "device": [
                "identifier": metadata.identifier.uuidString,
                "model": metadata.model,
                "model_number": metadata.modelNumber,
                "serial_number": metadata.serialNumber,
                "firmware_revision": metadata.firmwareRevision,
                "hardware_revision": metadata.hardwareRevision,
                "metawear_sdk_revision": metadata.sdkRevision,
            ],
            "requested_capture": [
                "accelerometer_hz": metadata.requestedAccelHz,
                "accelerometer_range_g": Double(
                    metadata.requestedAccelRangeG
                ),
                "gyroscope_hz": metadata.requestedGyroHz,
                "gyroscope_range_dps": Double(
                    metadata.requestedGyroRangeDPS
                ),
            ],
            "recovered_samples": [
                "accelerometer": accelerometer.count,
                "gyroscope": gyroscope.count,
            ],
            "device_tick_ms": [
                "accelerometer_start": accelerometer.first!.deviceTickMS,
                "accelerometer_end": accelerometer.last!.deviceTickMS,
                "gyroscope_start": gyroscope.first!.deviceTickMS,
                "gyroscope_end": gyroscope.last!.deviceTickMS,
            ],
            "streams": [
                "/equipment/imu/accel",
                "/equipment/imu/gyro",
            ],
            "timestamp_authority": "device_tick_ms",
            "live_preview_timestamp_authority": "ble_host_arrival_only",
            "flash_cleared_only_after_successful_dual_download": true,
        ]

        let metadataData = try JSONSerialization.data(
            withJSONObject: metadataObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        try metadataData.write(
            to: metadataURL,
            options: .atomic
        )

        return MetaMotionEvidenceBundle(
            directory: directory,
            journalURL: journalURL,
            metadataURL: metadataURL
        )
    }

    private func writeChronologicalEvents(
        to journal: JSONLJournal,
        sessionID: String
    ) async throws {
        var accelIndex = 0
        var gyroIndex = 0

        while accelIndex < accelerometer.count
            || gyroIndex < gyroscope.count {
            let useAccel: Bool
            if gyroIndex >= gyroscope.count {
                useAccel = true
            } else if accelIndex >= accelerometer.count {
                useAccel = false
            } else {
                useAccel = accelerometer[accelIndex].deviceTimeNS
                    <= gyroscope[gyroIndex].deviceTimeNS
            }

            if useAccel {
                let event = Self.accelEvent(
                    accelerometer[accelIndex],
                    sequence: UInt64(accelIndex),
                    sessionID: sessionID
                )
                try await journal.append(event)
                accelIndex += 1
            } else {
                let event = Self.gyroEvent(
                    gyroscope[gyroIndex],
                    sequence: UInt64(gyroIndex),
                    sessionID: sessionID
                )
                try await journal.append(event)
                gyroIndex += 1
            }
        }
    }

    private static func accelEvent(
        _ sample: MetaMotionLoggedSample,
        sequence: UInt64,
        sessionID: String
    ) -> SensorEnvelope {
        SensorEnvelope(
            sessionID: sessionID,
            deviceID: "metamotion-s",
            stream: "/equipment/imu/accel",
            sequence: sequence,
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

    private static func gyroEvent(
        _ sample: MetaMotionLoggedSample,
        sequence: UInt64,
        sessionID: String
    ) -> SensorEnvelope {
        SensorEnvelope(
            sessionID: sessionID,
            deviceID: "metamotion-s",
            stream: "/equipment/imu/gyro",
            sequence: sequence,
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
}

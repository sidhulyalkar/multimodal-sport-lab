import Foundation

public struct SystemsLabQualificationReport: Codable, Sendable, Equatable, Identifiable {
    public static let schemaVersion = "motionos.systems-lab.v1"

    public let id: String
    public let schemaVersion: String
    public let sessionID: String
    public let startedAt: Date
    public let endedAt: Date?
    public let firstTelemetryReceivedAt: Date?
    public let lastTelemetryReceivedAt: Date?
    public let telemetryPacketsReceived: UInt64
    public let telemetrySequenceGaps: UInt64
    public let telemetryDuplicates: UInt64
    public let telemetryOutOfOrder: UInt64
    public let firstIMUSampleCount: UInt64?
    public let lastIMUSampleCount: UInt64?
    public let meanEffectiveIMUHz: Double?
    public let minimumEffectiveIMUHz: Double?
    public let maximumIMUGapMS: Double
    public let firstNonMonotonicIMUCount: UInt64?
    public let lastNonMonotonicIMUCount: UInt64?
    public let watchBatteryStartFraction: Double?
    public let watchBatteryEndFraction: Double?
    public let phoneBatteryStartFraction: Double?
    public let phoneBatteryEndFraction: Double?
    public let journalReceivedAt: Date?
    public let journalByteCount: UInt64?
    public let journalSHA256: String?

    public init(
        id: String,
        schemaVersion: String = Self.schemaVersion,
        sessionID: String,
        startedAt: Date,
        endedAt: Date?,
        firstTelemetryReceivedAt: Date?,
        lastTelemetryReceivedAt: Date?,
        telemetryPacketsReceived: UInt64,
        telemetrySequenceGaps: UInt64,
        telemetryDuplicates: UInt64,
        telemetryOutOfOrder: UInt64,
        firstIMUSampleCount: UInt64?,
        lastIMUSampleCount: UInt64?,
        meanEffectiveIMUHz: Double?,
        minimumEffectiveIMUHz: Double?,
        maximumIMUGapMS: Double,
        firstNonMonotonicIMUCount: UInt64?,
        lastNonMonotonicIMUCount: UInt64?,
        watchBatteryStartFraction: Double?,
        watchBatteryEndFraction: Double?,
        phoneBatteryStartFraction: Double?,
        phoneBatteryEndFraction: Double?,
        journalReceivedAt: Date?,
        journalByteCount: UInt64?,
        journalSHA256: String?
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.firstTelemetryReceivedAt = firstTelemetryReceivedAt
        self.lastTelemetryReceivedAt = lastTelemetryReceivedAt
        self.telemetryPacketsReceived = telemetryPacketsReceived
        self.telemetrySequenceGaps = telemetrySequenceGaps
        self.telemetryDuplicates = telemetryDuplicates
        self.telemetryOutOfOrder = telemetryOutOfOrder
        self.firstIMUSampleCount = firstIMUSampleCount
        self.lastIMUSampleCount = lastIMUSampleCount
        self.meanEffectiveIMUHz = meanEffectiveIMUHz
        self.minimumEffectiveIMUHz = minimumEffectiveIMUHz
        self.maximumIMUGapMS = maximumIMUGapMS
        self.firstNonMonotonicIMUCount = firstNonMonotonicIMUCount
        self.lastNonMonotonicIMUCount = lastNonMonotonicIMUCount
        self.watchBatteryStartFraction = watchBatteryStartFraction
        self.watchBatteryEndFraction = watchBatteryEndFraction
        self.phoneBatteryStartFraction = phoneBatteryStartFraction
        self.phoneBatteryEndFraction = phoneBatteryEndFraction
        self.journalReceivedAt = journalReceivedAt
        self.journalByteCount = journalByteCount
        self.journalSHA256 = journalSHA256
    }

    public var durationSeconds: TimeInterval? {
        guard let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    public var transferLatencySeconds: TimeInterval? {
        guard let endedAt, let journalReceivedAt else { return nil }
        return max(0, journalReceivedAt.timeIntervalSince(endedAt))
    }

    public var imuSamplesObserved: UInt64? {
        guard let firstIMUSampleCount,
              let lastIMUSampleCount,
              lastIMUSampleCount >= firstIMUSampleCount
        else {
            return nil
        }
        return lastIMUSampleCount - firstIMUSampleCount
    }

    public var nonMonotonicIMUIncrease: UInt64? {
        guard let firstNonMonotonicIMUCount,
              let lastNonMonotonicIMUCount,
              lastNonMonotonicIMUCount >= firstNonMonotonicIMUCount
        else {
            return nil
        }
        return lastNonMonotonicIMUCount - firstNonMonotonicIMUCount
    }

    public var watchBatteryDropFraction: Double? {
        batteryDrop(
            start: watchBatteryStartFraction,
            end: watchBatteryEndFraction
        )
    }

    public var phoneBatteryDropFraction: Double? {
        batteryDrop(
            start: phoneBatteryStartFraction,
            end: phoneBatteryEndFraction
        )
    }

    /// Experimental observation only. Battery percentages are coarse and
    /// short runs can be dominated by quantization. Require at least 10 min.
    public var observedWatchBatteryDropPerHour: Double? {
        guard let durationSeconds,
              durationSeconds >= 600,
              let drop = watchBatteryDropFraction
        else {
            return nil
        }
        return drop * 3600 / durationSeconds
    }

    /// Fraction of ideal 4 Hz preview slots seen on the phone. This is a
    /// presentation-coverage metric, not a network packet-loss estimate,
    /// because the Watch intentionally drops slots while unreachable.
    public var previewCoverageFraction: Double? {
        guard let firstTelemetryReceivedAt,
              let lastTelemetryReceivedAt
        else {
            return nil
        }
        let span = max(
            0.25,
            lastTelemetryReceivedAt.timeIntervalSince(firstTelemetryReceivedAt)
        )
        let idealSlots = max(1, UInt64((span / 0.25).rounded(.up)) + 1)
        return min(
            1,
            Double(telemetryPacketsReceived) / Double(idealSlots)
        )
    }

    private func batteryDrop(
        start: Double?,
        end: Double?
    ) -> Double? {
        guard let start, let end else { return nil }
        return max(0, start - end)
    }
}

public struct SystemsLabQualificationTracker: Sendable, Equatable {
    public private(set) var current: SystemsLabQualificationReport?
    public private(set) var latestCompleted: SystemsLabQualificationReport?
    public private(set) var recentCompleted: [SystemsLabQualificationReport] = []

    private let completedCapacity = 12
    private var lastSequence: UInt64?
    private var effectiveRateSum = 0.0
    private var effectiveRateCount: UInt64 = 0

    public init() {}

    public mutating func observePresence(
        sessionID: String?,
        captureState: String,
        watchBatteryFraction: Double?,
        phoneBatteryFraction: Double?,
        receivedAt: Date
    ) {
        let normalized = captureState
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        let isActive = [
            "starting",
            "running",
            "paused",
            "ending",
        ].contains(normalized)

        if isActive, let sessionID, !sessionID.isEmpty {
            ensureCurrent(
                sessionID: sessionID,
                startedAt: receivedAt,
                watchBatteryFraction: watchBatteryFraction,
                phoneBatteryFraction: phoneBatteryFraction
            )
            updateBattery(
                watchBatteryFraction: watchBatteryFraction,
                phoneBatteryFraction: phoneBatteryFraction
            )
            return
        }

        guard var report = current else { return }
        guard sessionID == nil || sessionID == report.sessionID else {
            return
        }
        guard report.endedAt == nil else { return }

        report = copying(
            report,
            endedAt: receivedAt,
            watchBatteryEndFraction:
                watchBatteryFraction ?? report.watchBatteryEndFraction,
            phoneBatteryEndFraction:
                phoneBatteryFraction ?? report.phoneBatteryEndFraction
        )
        current = report
        storeCompleted(report)
    }

    public mutating func ingest(
        _ snapshot: LiveTelemetrySnapshot,
        receivedAt: Date,
        phoneBatteryFraction: Double?
    ) {
        ensureCurrent(
            sessionID: snapshot.sessionID,
            startedAt: receivedAt,
            watchBatteryFraction: snapshot.watchBatteryFraction,
            phoneBatteryFraction: phoneBatteryFraction
        )

        guard var report = current,
              report.sessionID == snapshot.sessionID
        else {
            return
        }

        var gaps = report.telemetrySequenceGaps
        var duplicates = report.telemetryDuplicates
        var outOfOrder = report.telemetryOutOfOrder

        if let lastSequence {
            if snapshot.sequence == lastSequence {
                duplicates &+= 1
                current = copying(
                    report,
                    telemetryDuplicates: duplicates
                )
                return
            }
            if snapshot.sequence < lastSequence {
                outOfOrder &+= 1
                current = copying(
                    report,
                    telemetryOutOfOrder: outOfOrder
                )
                return
            }
            if snapshot.sequence > lastSequence + 1 {
                gaps &+= snapshot.sequence - lastSequence - 1
            }
        }

        lastSequence = snapshot.sequence

        if let rate = snapshot.effectiveIMUHz, rate.isFinite {
            effectiveRateSum += rate
            effectiveRateCount &+= 1
        }

        let meanRate: Double?
        if effectiveRateCount > 0 {
            meanRate = effectiveRateSum / Double(effectiveRateCount)
        } else {
            meanRate = nil
        }

        let minimumRate: Double?
        if let rate = snapshot.effectiveIMUHz {
            if let existing = report.minimumEffectiveIMUHz {
                minimumRate = min(existing, rate)
            } else {
                minimumRate = rate
            }
        } else {
            minimumRate = report.minimumEffectiveIMUHz
        }

        report = copying(
            report,
            firstTelemetryReceivedAt:
                report.firstTelemetryReceivedAt ?? receivedAt,
            lastTelemetryReceivedAt: receivedAt,
            telemetryPacketsReceived: report.telemetryPacketsReceived + 1,
            telemetrySequenceGaps: gaps,
            telemetryDuplicates: duplicates,
            telemetryOutOfOrder: outOfOrder,
            firstIMUSampleCount:
                report.firstIMUSampleCount ?? snapshot.imuSampleCount,
            lastIMUSampleCount: snapshot.imuSampleCount,
            meanEffectiveIMUHz: meanRate,
            minimumEffectiveIMUHz: minimumRate,
            maximumIMUGapMS:
                max(report.maximumIMUGapMS, snapshot.maxIMUGapMS),
            firstNonMonotonicIMUCount:
                report.firstNonMonotonicIMUCount
                    ?? snapshot.nonMonotonicIMUCount,
            lastNonMonotonicIMUCount:
                snapshot.nonMonotonicIMUCount,
            watchBatteryEndFraction:
                snapshot.watchBatteryFraction
                    ?? report.watchBatteryEndFraction,
            phoneBatteryEndFraction:
                phoneBatteryFraction
                    ?? report.phoneBatteryEndFraction
        )
        current = report
    }

    @discardableResult
    public mutating func markJournalReceived(
        sessionID: String,
        receivedAt: Date,
        byteCount: UInt64,
        sha256: String
    ) -> SystemsLabQualificationReport? {
        if var report = current,
           report.sessionID == sessionID {
            report = copying(
                report,
                journalReceivedAt: receivedAt,
                journalByteCount: byteCount,
                journalSHA256: sha256
            )
            current = report
            if report.endedAt != nil {
                storeCompleted(report)
            }
            return report
        }

        if let index = recentCompleted.firstIndex(where: {
            $0.sessionID == sessionID
        }) {
            let report = copying(
                recentCompleted[index],
                journalReceivedAt: receivedAt,
                journalByteCount: byteCount,
                journalSHA256: sha256
            )
            recentCompleted[index] = report
            if latestCompleted?.sessionID == sessionID {
                latestCompleted = report
            }
            return report
        }

        if var report = latestCompleted,
           report.sessionID == sessionID {
            report = copying(
                report,
                journalReceivedAt: receivedAt,
                journalByteCount: byteCount,
                journalSHA256: sha256
            )
            storeCompleted(report)
            return report
        }

        return nil
    }

    public mutating func clearCompleted() {
        latestCompleted = nil
        recentCompleted.removeAll()
        if current?.endedAt != nil {
            current = nil
        }
    }

    private mutating func ensureCurrent(
        sessionID: String,
        startedAt: Date,
        watchBatteryFraction: Double?,
        phoneBatteryFraction: Double?
    ) {
        if let current, current.sessionID == sessionID {
            return
        }

        if let current, current.endedAt != nil {
            storeCompleted(current)
        }

        self.current = SystemsLabQualificationReport(
            id: sessionID,
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: nil,
            firstTelemetryReceivedAt: nil,
            lastTelemetryReceivedAt: nil,
            telemetryPacketsReceived: 0,
            telemetrySequenceGaps: 0,
            telemetryDuplicates: 0,
            telemetryOutOfOrder: 0,
            firstIMUSampleCount: nil,
            lastIMUSampleCount: nil,
            meanEffectiveIMUHz: nil,
            minimumEffectiveIMUHz: nil,
            maximumIMUGapMS: 0,
            firstNonMonotonicIMUCount: nil,
            lastNonMonotonicIMUCount: nil,
            watchBatteryStartFraction: watchBatteryFraction,
            watchBatteryEndFraction: watchBatteryFraction,
            phoneBatteryStartFraction: phoneBatteryFraction,
            phoneBatteryEndFraction: phoneBatteryFraction,
            journalReceivedAt: nil,
            journalByteCount: nil,
            journalSHA256: nil
        )
        lastSequence = nil
        effectiveRateSum = 0
        effectiveRateCount = 0
    }

    private mutating func updateBattery(
        watchBatteryFraction: Double?,
        phoneBatteryFraction: Double?
    ) {
        guard let report = current else { return }
        current = copying(
            report,
            watchBatteryEndFraction:
                watchBatteryFraction ?? report.watchBatteryEndFraction,
            phoneBatteryEndFraction:
                phoneBatteryFraction ?? report.phoneBatteryEndFraction
        )
    }

    private mutating func storeCompleted(
        _ report: SystemsLabQualificationReport
    ) {
        guard report.endedAt != nil else { return }

        recentCompleted.removeAll {
            $0.sessionID == report.sessionID
        }
        recentCompleted.insert(report, at: 0)
        if recentCompleted.count > completedCapacity {
            recentCompleted.removeLast(
                recentCompleted.count - completedCapacity
            )
        }
        latestCompleted = recentCompleted.first
    }

    private func copying(
        _ report: SystemsLabQualificationReport,
        endedAt: Date? = nil,
        firstTelemetryReceivedAt: Date? = nil,
        lastTelemetryReceivedAt: Date? = nil,
        telemetryPacketsReceived: UInt64? = nil,
        telemetrySequenceGaps: UInt64? = nil,
        telemetryDuplicates: UInt64? = nil,
        telemetryOutOfOrder: UInt64? = nil,
        firstIMUSampleCount: UInt64? = nil,
        lastIMUSampleCount: UInt64? = nil,
        meanEffectiveIMUHz: Double? = nil,
        minimumEffectiveIMUHz: Double? = nil,
        maximumIMUGapMS: Double? = nil,
        firstNonMonotonicIMUCount: UInt64? = nil,
        lastNonMonotonicIMUCount: UInt64? = nil,
        watchBatteryEndFraction: Double? = nil,
        phoneBatteryEndFraction: Double? = nil,
        journalReceivedAt: Date? = nil,
        journalByteCount: UInt64? = nil,
        journalSHA256: String? = nil
    ) -> SystemsLabQualificationReport {
        SystemsLabQualificationReport(
            id: report.id,
            schemaVersion: report.schemaVersion,
            sessionID: report.sessionID,
            startedAt: report.startedAt,
            endedAt: endedAt ?? report.endedAt,
            firstTelemetryReceivedAt:
                firstTelemetryReceivedAt ?? report.firstTelemetryReceivedAt,
            lastTelemetryReceivedAt:
                lastTelemetryReceivedAt ?? report.lastTelemetryReceivedAt,
            telemetryPacketsReceived:
                telemetryPacketsReceived ?? report.telemetryPacketsReceived,
            telemetrySequenceGaps:
                telemetrySequenceGaps ?? report.telemetrySequenceGaps,
            telemetryDuplicates:
                telemetryDuplicates ?? report.telemetryDuplicates,
            telemetryOutOfOrder:
                telemetryOutOfOrder ?? report.telemetryOutOfOrder,
            firstIMUSampleCount:
                firstIMUSampleCount ?? report.firstIMUSampleCount,
            lastIMUSampleCount:
                lastIMUSampleCount ?? report.lastIMUSampleCount,
            meanEffectiveIMUHz:
                meanEffectiveIMUHz ?? report.meanEffectiveIMUHz,
            minimumEffectiveIMUHz:
                minimumEffectiveIMUHz ?? report.minimumEffectiveIMUHz,
            maximumIMUGapMS:
                maximumIMUGapMS ?? report.maximumIMUGapMS,
            firstNonMonotonicIMUCount:
                firstNonMonotonicIMUCount
                    ?? report.firstNonMonotonicIMUCount,
            lastNonMonotonicIMUCount:
                lastNonMonotonicIMUCount
                    ?? report.lastNonMonotonicIMUCount,
            watchBatteryStartFraction:
                report.watchBatteryStartFraction,
            watchBatteryEndFraction:
                watchBatteryEndFraction ?? report.watchBatteryEndFraction,
            phoneBatteryStartFraction:
                report.phoneBatteryStartFraction,
            phoneBatteryEndFraction:
                phoneBatteryEndFraction ?? report.phoneBatteryEndFraction,
            journalReceivedAt:
                journalReceivedAt ?? report.journalReceivedAt,
            journalByteCount:
                journalByteCount ?? report.journalByteCount,
            journalSHA256:
                journalSHA256 ?? report.journalSHA256
        )
    }
}

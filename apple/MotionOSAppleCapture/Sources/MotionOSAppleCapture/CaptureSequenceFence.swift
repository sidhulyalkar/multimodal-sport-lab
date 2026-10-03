import Foundation

/// Serializes sequence allocation across Core Motion callbacks and invalidates
/// callbacks that belong to an earlier capture generation.
final class CaptureSequenceFence: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var nextSequence: UInt64 = 0
    private var rejectedCallbacks: UInt64 = 0

    /// Callbacks rejected because their generation was invalidated, over the
    /// fence's lifetime. Evidence-health diagnostics only; never journaled.
    var rejectedCallbackCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }

        return rejectedCallbacks
    }

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        generation &+= 1
        nextSequence = 0
        return generation
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }

        generation &+= 1
        nextSequence = 0
    }

    func takeNextSequence(for expectedGeneration: UInt64) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }

        guard expectedGeneration == generation else {
            rejectedCallbacks &+= 1
            return nil
        }

        let sequence = nextSequence
        nextSequence &+= 1
        return sequence
    }
}

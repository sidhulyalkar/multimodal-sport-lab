import Foundation

public enum MonotonicClock {
    public static func nowNS() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

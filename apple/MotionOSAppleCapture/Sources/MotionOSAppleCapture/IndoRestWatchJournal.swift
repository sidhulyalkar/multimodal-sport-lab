import Foundation

/// Source-native, Watch-monotonic research annotations. These are not aligned
/// with the phone's operator clock until independent synchronization qualifies.
public enum IndoRestWatchJournal {
    public static let stream = "/experiments/indo/rest_annotation"
    public static let clockSemantics = "watch_monotonic_input_time"

    public static func envelope(
        sessionID: String,
        runID: String?,
        sequence: UInt64,
        deviceTimeNS: UInt64,
        eventID: String,
        event: (kind: String, payload: [String: String])
    ) -> SensorEnvelope {
        var values = event.payload.mapValues { JSONValue.string($0) }
        values["event_id"] = .string(eventID)
        values["event_type"] = .string(event.kind)
        values["clock_semantics"] = .string(clockSemantics)
        values["run_binding"] = .string(runID == nil ? "unbound" : "bound")
        if let runID {
            values["linked_run_id"] = .string(runID)
        }
        return SensorEnvelope(
            sessionID: sessionID,
            deviceID: "apple-watch",
            stream: stream,
            sequence: sequence,
            deviceTimeNS: deviceTimeNS,
            payload: values
        )
    }
}
